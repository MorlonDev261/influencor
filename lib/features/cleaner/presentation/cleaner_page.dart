import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/l10n/app_strings.dart';
import '../../../core/picker/app_file_picker.dart';
import '../../../core/picker/pick_mode.dart';
import '../../../core/providers/workspace_providers.dart';
import '../../library/application/library_providers.dart';
import '../../library/domain/library_entry.dart';
import '../../library/presentation/widgets/video_preview.dart';
import '../application/metadata_cleaner_service.dart';
import '../domain/clean_report.dart';
import 'clean_report_card.dart';
import 'metadata_inspector_card.dart';

/// One file in the Deganeo queue.
class _Job {
  _Job(this.source);

  final String source;
  String? cleanPath;
  CleanReport? report;

  /// Metadata the original carries (null while being read).
  List<MetadataFinding>? inspection;
  bool inspectFailed = false;
  bool cleaning = false;
  bool detailsOpen = false;
}

/// The "Deganeo" tool: add up to [CleanerPage.maxFiles] photos / videos /
/// PDFs of the workspace, inspect their metadata, strip it (one by one or all
/// at once), verify each result with an independent re-scan, then save /
/// replace / discard. Files from elsewhere on the device are refused: they
/// must be imported into the library first.
class CleanerPage extends ConsumerStatefulWidget {
  const CleanerPage({super.key});

  static const maxFiles = 20;

  @override
  ConsumerState<CleanerPage> createState() => _CleanerPageState();
}

class _CleanerPageState extends ConsumerState<CleanerPage> {
  final _cleaner = const MetadataCleanerService();
  final _jobs = <_Job>[];
  _Job? _selected;
  bool _dragging = false;
  bool _busyAll = false;

  @override
  void initState() {
    super.initState();
    // Housekeeping: cleaned copies orphaned by a killed app.
    unawaited(_cleaner.purgeStaleCopies());
  }

  @override
  void dispose() {
    for (final job in _jobs) {
      _deleteTempSync(job.cleanPath);
    }
    super.dispose();
  }

  Future<void> _pick() async {
    final strings = ref.read(appStringsProvider);
    final root = ref.read(workspaceRootProvider);
    if (root == null) {
      _snack(strings.needWorkspace);
      return;
    }
    final paths = await AppFilePicker.pick(
      context,
      mode: PickMode.mediaFiles,
      title: strings.selectMediaTitle,
      allowMultiple: true,
      root: root,
    );
    if (paths.isNotEmpty && mounted) _addPaths(paths);
  }

  void _addPaths(List<String> paths) {
    final strings = ref.read(appStringsProvider);
    final root = ref.read(workspaceRootProvider);
    if (root == null) {
      _snack(strings.needWorkspace);
      return;
    }
    final known = _jobs.map((j) => j.source).toSet();
    final fresh = <String>[];
    var outside = 0;
    for (final path in paths) {
      if (!isInWorkspace(root, path)) {
        outside++;
      } else if (_isMediaPath(path) && known.add(path)) {
        fresh.add(path);
      }
    }
    if (outside > 0) _snack(strings.outsideWorkspace(outside));
    if (fresh.isEmpty) return;
    final room = (CleanerPage.maxFiles - _jobs.length).clamp(0, 1 << 30);
    final accepted = fresh.take(room).toList();
    final added = [for (final path in accepted) _Job(path)];
    setState(() {
      _jobs.addAll(added);
      _selected ??= _jobs.isEmpty ? null : _jobs.first;
    });
    if (accepted.length < fresh.length) {
      _snack(strings.tooManyFiles(CleanerPage.maxFiles));
    }
    for (final job in added) {
      unawaited(_inspect(job));
    }
  }

  Future<void> _inspect(_Job job) async {
    final result = await _cleaner.inspect(job.source);
    if (!mounted || !_jobs.contains(job)) return;
    setState(() {
      job.inspection = result.findings;
      job.inspectFailed = result.error != null;
    });
  }

  void _remove(_Job job) {
    _deleteTempSync(job.cleanPath);
    setState(() {
      final index = _jobs.indexOf(job);
      _jobs.remove(job);
      if (_selected == job) {
        _selected =
            _jobs.isEmpty ? null : _jobs[index.clamp(0, _jobs.length - 1)];
      }
    });
  }

  Future<void> _clean(_Job job) async {
    final strings = ref.read(appStringsProvider);
    setState(() => job.cleaning = true);
    try {
      final started = DateTime.now();
      final report = await _cleaner.clean(job.source);
      final elapsed = DateTime.now().difference(started);
      const minimum = Duration(milliseconds: 1500);
      if (elapsed < minimum) {
        await Future<void>.delayed(minimum - elapsed);
      }
      if (!mounted || !_jobs.contains(job)) {
        await _deleteTemp(report.outputPath);
        return;
      }
      setState(() {
        job.cleanPath = report.outputPath;
        job.report = report;
        job.cleaning = false;
        job.detailsOpen = !report.isClean;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => job.cleaning = false);
      _snack(strings.genericError);
    }
  }

  /// One file at a time: cleaning is CPU/IO heavy and each run is an isolate.
  Future<void> _cleanAll() async {
    setState(() => _busyAll = true);
    try {
      for (final job in List.of(_jobs)) {
        if (!mounted) return;
        if (job.report == null && !job.cleaning && _jobs.contains(job)) {
          await _clean(job);
        }
      }
    } finally {
      if (mounted) setState(() => _busyAll = false);
    }
  }

  /// Writes the cleaned copy next to its original (same folder, `_clean`
  /// suffix and the extension of its *real* format, never overwriting),
  /// registers it in the gallery index so other apps (Facebook, WhatsApp...)
  /// list it, and refreshes the library.
  Future<void> _saveCopy(_Job job) => ref
      .read(libraryControllerProvider)
      .storeCleaned(job.source, job.cleanPath!,
          replace: false, parentDir: p.dirname(job.source));

  Future<void> _download(_Job job) async {
    if (job.cleanPath == null) return;
    final strings = ref.read(appStringsProvider);
    try {
      await _saveCopy(job);
      await _eraseCleanCopy(job, showSnack: false);
      if (mounted) _snack(strings.fileDownloaded);
    } catch (_) {
      if (mounted) _snack(strings.genericError);
    }
  }

  /// Saves every cleaned copy next to its own original.
  Future<void> _downloadAll() async {
    final strings = ref.read(appStringsProvider);
    final ready = _jobs.where((j) => j.cleanPath != null).toList();
    var saved = 0;
    try {
      for (final job in ready) {
        await _saveCopy(job);
        saved++;
        if (mounted) await _eraseCleanCopy(job, showSnack: false);
      }
      if (mounted && saved > 0) _snack(strings.filesSaved(saved));
    } catch (_) {
      if (mounted) _snack(strings.genericError);
    }
  }

  Future<void> _replace(_Job job) async {
    final clean = job.cleanPath;
    if (clean == null) return;
    final source = job.source;
    final strings = ref.read(appStringsProvider);
    try {
      // Copy next to the original, then swap with one rename (a failure
      // halfway never leaves the original truncated, nor a stray copy).
      await ref.read(libraryControllerProvider).storeCleaned(source, clean,
          replace: true, parentDir: p.dirname(source));
      await _deleteTemp(clean);
      if (!mounted) return;
      _snack(strings.fileReplaced);
      setState(() {
        job.cleanPath = null;
        job.report = null;
        job.detailsOpen = false;
        job.inspection = null;
      });
      unawaited(_inspect(job));
    } catch (_) {
      if (mounted) _snack(strings.genericError);
    }
  }

  Future<void> _eraseCleanCopy(_Job job, {bool showSnack = true}) async {
    final clean = job.cleanPath;
    if (clean == null) return;
    final strings = ref.read(appStringsProvider);
    await _deleteTemp(clean);
    if (!mounted) return;
    setState(() {
      job.cleanPath = null;
      job.report = null;
      job.detailsOpen = false;
    });
    if (showSnack) _snack(strings.cleanCopyErased);
  }

  Future<void> _deleteTemp(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort cleanup: never block the user's flow if temp deletion fails.
    }
  }

  void _deleteTempSync(String? path) {
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Best-effort cleanup during state changes/dispose.
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final selected = _selected;
    final pending = _jobs.where((j) => j.report == null).length;
    final ready = _jobs.where((j) => j.cleanPath != null).length;

    return DropTarget(
      key: const ValueKey('deganeo-page'),
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        _addPaths([
          for (final file in detail.files)
            if (file.path.isNotEmpty) file.path,
        ]);
      },
      child: Stack(
        children: [
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_jobs.isEmpty)
                      _UploadPanel(onPick: _pick)
                    else ...[
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _jobs.length >= CleanerPage.maxFiles
                                ? null
                                : _pick,
                            icon:
                                const Icon(Icons.add_photo_alternate_outlined),
                            label: Text(
                              '${strings.addFiles} '
                              '(${_jobs.length}/${CleanerPage.maxFiles})',
                            ),
                          ),
                          if (_jobs.length > 1 && pending > 0)
                            FilledButton.icon(
                              onPressed: _busyAll ? null : _cleanAll,
                              icon: _busyAll
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.auto_fix_high_outlined),
                              label: Text('${strings.cleanAll} ($pending)'),
                            ),
                          if (ready > 0)
                            FilledButton.tonalIcon(
                              onPressed: _downloadAll,
                              icon: const Icon(Icons.download_outlined),
                              label: Text('${strings.downloadAll} ($ready)'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      for (final job in _jobs)
                        _JobTile(
                          job: job,
                          selected: job == selected,
                          onTap: () => setState(() => _selected = job),
                          onRemove: job.cleaning ? null : () => _remove(job),
                          removeTooltip: strings.removeFromList,
                        ),
                      if (selected != null) ...[
                        const SizedBox(height: 16),
                        _detail(selected, strings),
                      ],
                    ],
                    const SizedBox(height: 12),
                    _WatermarkNotice(
                        message: strings.visibleWatermarkNotRemoved),
                  ],
                ),
              ),
            ),
          ),
          if (_dragging)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.08),
                ),
                child: Center(
                  child: FilledButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.upload_file_outlined),
                    label: Text(strings.dropToImport),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _detail(_Job job, AppStrings strings) {
    final clean = job.cleanPath;
    final report = job.report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MediaPreview(
          path: clean ?? job.source,
          cleaning: job.cleaning,
          cleaned: clean != null,
        ),
        const SizedBox(height: 16),
        if (report == null) ...[
          if (!job.inspectFailed)
            MetadataInspectorCard(
              key: ValueKey(job),
              findings: job.inspection,
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: job.cleaning ? null : () => _clean(job),
            icon: job.cleaning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high_outlined),
            label: Text(strings.cleanMediaCta),
          ),
        ] else ...[
          CleanReportCard(
            key: ValueKey(job),
            report: report,
            expanded: job.detailsOpen,
            onToggle: () => setState(() => job.detailsOpen = !job.detailsOpen),
          ),
          const SizedBox(height: 12),
          if (clean != null)
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => _download(job),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(strings.download),
                ),
                OutlinedButton.icon(
                  onPressed: () => _replace(job),
                  icon: const Icon(Icons.find_replace_outlined),
                  label: Text(strings.replace),
                ),
                OutlinedButton.icon(
                  onPressed: () => _eraseCleanCopy(job),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: Text(strings.eraseCleanCopy),
                ),
              ],
            ),
        ],
      ],
    );
  }

  bool _isMediaPath(String path) {
    final kind = kindForFile(path);
    return kind == EntryKind.image ||
        kind == EntryKind.video ||
        isCleanableDocument(path);
  }
}

/// A compact row in the queue: thumbnail, name, status, remove button.
class _JobTile extends StatelessWidget {
  const _JobTile({
    required this.job,
    required this.selected,
    required this.onTap,
    required this.onRemove,
    required this.removeTooltip,
  });

  final _Job job;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final String removeTooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = job.cleanPath ?? job.source;
    final kind = kindForFile(path);
    final report = job.report;
    final (statusIcon, statusColor) = job.cleaning
        ? (Icons.hourglass_top, scheme.primary)
        : report == null
            ? (Icons.circle_outlined, scheme.outline)
            : report.isClean
                ? (Icons.verified_outlined, scheme.primary)
                : (Icons.warning_amber_outlined, scheme.error);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : null,
      child: ListTile(
        dense: true,
        selected: selected,
        onTap: onTap,
        leading: SizedBox(
          width: 44,
          height: 44,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: kind == EntryKind.image && canRenderThumbnail(path)
                ? Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    cacheWidth: 96,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image_outlined),
                  )
                : Icon(
                    isCleanableDocument(path)
                        ? Icons.picture_as_pdf_outlined
                        : kind == EntryKind.video
                            ? Icons.movie_outlined
                            : Icons.image_outlined,
                  ),
          ),
        ),
        title: Text(p.basename(job.source),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(statusIcon, size: 18, color: statusColor),
            IconButton(
              tooltip: removeTooltip,
              icon: const Icon(Icons.close, size: 18),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _WatermarkNotice extends StatelessWidget {
  const _WatermarkNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: 18,
              color: scheme.onTertiaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onTertiaryContainer,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UploadPanel extends ConsumerWidget {
  const _UploadPanel({required this.onPick});

  final VoidCallback onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onPick,
      child: Container(
        constraints: const BoxConstraints(minHeight: 260),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant, width: 2),
          borderRadius: BorderRadius.circular(12),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_photo_alternate_outlined,
                size: 64, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              strings.uploadMedia,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(strings.dropToImport),
          ],
        ),
      ),
    );
  }
}

class _MediaPreview extends StatelessWidget {
  const _MediaPreview({
    required this.path,
    required this.cleaning,
    required this.cleaned,
  });

  final String path;
  final bool cleaning;
  final bool cleaned;

  @override
  Widget build(BuildContext context) {
    final kind = kindForFile(path);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420, maxWidth: 640),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border:
                cleaned ? Border.all(color: scheme.primary, width: 2) : null,
            boxShadow: cleaned
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.18),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
              ),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: cleaning ? 2.5 : 0,
                        sigmaY: cleaning ? 2.5 : 0,
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: kind == EntryKind.video
                            ? VideoPreview(key: ValueKey(path), path: path)
                            : canRenderThumbnail(path)
                                ? Image.file(
                                    File(path),
                                    key: ValueKey(path),
                                    fit: BoxFit.contain,
                                    gaplessPlayback: true,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.broken_image_outlined),
                                  )
                                : _FilePlaceholder(
                                    key: ValueKey(path),
                                    path: path,
                                  ),
                      ),
                    ),
                    AnimatedOpacity(
                      opacity: cleaning ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: scheme.scrim.withValues(alpha: 0.28),
                          child: Center(
                            child: SizedBox(
                              width: 74,
                              height: 74,
                              child: CircularProgressIndicator(
                                strokeWidth: 5,
                                color: scheme.primary,
                                backgroundColor:
                                    scheme.surface.withValues(alpha: 0.78),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Preview for formats Flutter cannot decode (HEIC, TIFF, PDF, MKV…).
class _FilePlaceholder extends StatelessWidget {
  const _FilePlaceholder({required this.path, super.key});

  final String path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = isCleanableDocument(path)
        ? Icons.picture_as_pdf_outlined
        : kindForFile(path) == EntryKind.video
            ? Icons.movie_outlined
            : Icons.image_outlined;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: scheme.primary),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              p.basename(path),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
