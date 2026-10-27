import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../widgets/app_dialog.dart';
import '../../features/library/domain/library_entry.dart';
import '../widgets/empty_state.dart';
import '../l10n/app_strings.dart';
import 'pick_mode.dart';

/// Opens the in-app file browser as a full-screen route and returns the chosen
/// absolute paths (empty if cancelled). For [PickMode.directory] the list holds
/// the single chosen folder. With [root], browsing is confined to that folder.
Future<List<String>> launchInAppBrowser(
  BuildContext context, {
  required PickMode mode,
  bool allowMultiple = true,
  String? title,
  String? initialDirectory,
  String? actionLabel,
  String? root,
}) async {
  if (mode == PickMode.mediaFiles) {
    final result = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _MediaGalleryScreen(
          allowMultiple: allowMultiple,
          title: title,
          initialDirectory: initialDirectory,
          actionLabel: actionLabel,
          root: root,
        ),
      ),
    );
    return result ?? const [];
  }
  final result = await Navigator.of(context).push<List<String>>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _FileBrowserScreen(
        mode: mode,
        allowMultiple: allowMultiple,
        title: title,
        initialDirectory: initialDirectory,
        actionLabel: actionLabel,
        root: root,
      ),
    ),
  );
  return result ?? const [];
}

Future<({List<String> paths, bool move})> launchInAppBrowserForImport(
  BuildContext context, {
  String? title,
}) async {
  final result =
      await Navigator.of(context).push<({List<String> paths, bool move})>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _FileBrowserScreen(
        mode: PickMode.files,
        allowMultiple: true,
        title: title,
        showImportMoveActions: true,
      ),
    ),
  );
  return result ?? (paths: const <String>[], move: false);
}

class _FileBrowserScreen extends ConsumerStatefulWidget {
  const _FileBrowserScreen({
    required this.mode,
    required this.allowMultiple,
    this.title,
    this.initialDirectory,
    this.actionLabel,
    this.showImportMoveActions = false,
    this.root,
  });

  final PickMode mode;
  final bool allowMultiple;
  final String? title;
  final String? initialDirectory;
  final String? actionLabel;
  final bool showImportMoveActions;

  /// When set, nothing outside this folder can be browsed or chosen.
  final String? root;

  @override
  ConsumerState<_FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _Shortcut {
  const _Shortcut(this.label, this.icon, this.path);
  final String label;
  final IconData icon;
  final String path;
}

class _MediaItem {
  const _MediaItem({
    required this.path,
    required this.modified,
    required this.kind,
  });

  final String path;
  final DateTime modified;
  final EntryKind kind;
}

class _MediaGroup {
  const _MediaGroup({
    required this.date,
    required this.label,
    required this.items,
  });

  final DateTime date;
  final String label;
  final List<_MediaItem> items;
}

class _MediaGalleryScreen extends ConsumerStatefulWidget {
  const _MediaGalleryScreen({
    required this.allowMultiple,
    this.title,
    this.initialDirectory,
    this.actionLabel,
    this.root,
  });

  final bool allowMultiple;
  final String? title;
  final String? initialDirectory;
  final String? actionLabel;

  /// When set, only the media of this folder (and its sub-folders) is shown.
  final String? root;

  @override
  ConsumerState<_MediaGalleryScreen> createState() =>
      _MediaGalleryScreenState();
}

class _MediaGalleryScreenState extends ConsumerState<_MediaGalleryScreen> {
  final _scroll = ScrollController();
  final _selected = <String>{};
  final _groupKeys = <GlobalKey>[];
  var _groups = <_MediaGroup>[];
  var _currentDateLabel = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncDateFromScroll);
    _scan();
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_syncDateFromScroll)
      ..dispose();
    super.dispose();
  }

  String _env(String key) => Platform.environment[key] ?? '';

  List<Directory> _roots() {
    final seen = <String>{};
    final dirs = <Directory>[];
    void add(String path) {
      if (path.isEmpty) return;
      final dir = Directory(path);
      if (!dir.existsSync()) return;
      final normalized = p.normalize(dir.path);
      if (seen.add(normalized)) dirs.add(Directory(normalized));
    }

    final root = widget.root;
    if (root != null) {
      add(root);
      return dirs;
    }

    final initial = widget.initialDirectory;
    if (initial != null && initial.isNotEmpty) add(initial);

    if (Platform.isAndroid) {
      const base = '/storage/emulated/0';
      add('$base/DCIM');
      add('$base/Pictures');
      add('$base/Movies');
      add('$base/Download');
      add(base);
    } else if (Platform.isWindows) {
      final home = _env('USERPROFILE');
      add(p.join(home, 'Pictures'));
      add(p.join(home, 'Videos'));
      add(p.join(home, 'Downloads'));
      add(p.join(home, 'Desktop'));
    } else {
      final home = _env('HOME');
      add(p.join(home, 'Pictures'));
      add(p.join(home, 'Movies'));
      add(p.join(home, 'Videos'));
      add(p.join(home, 'Downloads'));
      add(p.join(home, 'Desktop'));
    }
    return dirs;
  }

  Future<void> _scan() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final items = <_MediaItem>[];
    final paths = <String>{};
    try {
      for (final root in _roots()) {
        await _collectMedia(root, items, paths);
      }
      items.sort((a, b) => b.modified.compareTo(a.modified));
      final groups = _group(items);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _groupKeys
          ..clear()
          ..addAll(List.generate(groups.length, (_) => GlobalKey()));
        _currentDateLabel = groups.isEmpty ? '' : groups.first.label;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = ref.read(appStringsProvider).folderAccessError;
        _loading = false;
      });
    }
  }

  Future<void> _collectMedia(
    Directory dir,
    List<_MediaItem> items,
    Set<String> paths,
  ) async {
    List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    for (final ent in children) {
      final name = p.basename(ent.path);
      if (name.startsWith('.')) continue;
      if (ent is Directory) {
        await _collectMedia(ent, items, paths);
        continue;
      }
      if (ent is! File) continue;
      final kind = kindForFile(ent.path);
      if (kind != EntryKind.image &&
          kind != EntryKind.video &&
          !isCleanableDocument(ent.path)) {
        continue;
      }
      final normalized = p.normalize(ent.path);
      if (!paths.add(normalized)) continue;
      FileStat stat;
      try {
        stat = await ent.stat();
      } catch (_) {
        continue;
      }
      items.add(_MediaItem(
        path: normalized,
        modified: stat.modified,
        kind: kind,
      ));
    }
  }

  List<_MediaGroup> _group(List<_MediaItem> items) {
    final byDay = <String, List<_MediaItem>>{};
    for (final item in items) {
      final key = _dayKey(item.modified);
      byDay.putIfAbsent(key, () => []).add(item);
    }
    return [
      for (final entry in byDay.entries)
        _MediaGroup(
          date: entry.value.first.modified,
          label: _dateLabel(entry.value.first.modified),
          items: entry.value,
        ),
    ];
  }

  String _dayKey(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  String _dateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final strings = ref.read(appStringsProvider);
    if (day == today) return strings.today;
    if (day == today.subtract(const Duration(days: 1))) {
      return strings.yesterday;
    }
    const months = [
      'janv.',
      'févr.',
      'mars',
      'avr.',
      'mai',
      'juin',
      'juil.',
      'août',
      'sept.',
      'oct.',
      'nov.',
      'déc.',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  void _syncDateFromScroll() {
    if (_groups.isEmpty || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final ratio = max <= 0 ? 0.0 : (_scroll.offset / max).clamp(0.0, 1.0);
    final index = (ratio * (_groups.length - 1)).round();
    final label = _groups[index].label;
    if (label != _currentDateLabel) {
      setState(() => _currentDateLabel = label);
    }
  }

  void _jumpToRatio(double localDy, double height) {
    if (_groups.isEmpty) return;
    final ratio = (localDy / height).clamp(0.0, 1.0);
    final index = (ratio * (_groups.length - 1)).round();
    setState(() => _currentDateLabel = _groups[index].label);
    final context = _groupKeys[index].currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: 0.02,
      );
    }
  }

  void _tap(_MediaItem item) {
    if (!widget.allowMultiple) {
      Navigator.of(context).pop(<String>[item.path]);
      return;
    }
    setState(() {
      if (!_selected.add(item.path)) _selected.remove(item.path);
    });
  }

  void _confirm(AppStrings strings) {
    if (_selected.isEmpty) return;
    Navigator.of(context).pop(_selected.toList());
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final title = widget.title ?? strings.selectMediaTitle;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: strings.cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: strings.refresh,
            onPressed: _scan,
          ),
        ],
      ),
      body: _buildBody(strings),
      bottomNavigationBar: widget.allowMultiple
          ? _BottomBar(
              child: Row(
                children: [
                  Text(strings.nSelected(_selected.length)),
                  const Spacer(),
                  FilledButton(
                    onPressed:
                        _selected.isEmpty ? null : () => _confirm(strings),
                    child: Text(
                        '${widget.actionLabel ?? strings.selectAction} (${_selected.length})'),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  Widget _buildBody(AppStrings strings) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_groups.isEmpty) {
      return EmptyState(
        icon: Icons.photo_library_outlined,
        title: strings.noMedia,
        message: strings.uploadMedia,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 1000
            ? 6
            : width >= 720
                ? 5
                : width >= 520
                    ? 4
                    : 3;
        return Stack(
          children: [
            CustomScrollView(
              controller: _scroll,
              slivers: [
                for (var i = 0; i < _groups.length; i++) ...[
                  SliverToBoxAdapter(
                    key: _groupKeys[i],
                    child: Padding(
                      padding:
                          EdgeInsets.fromLTRB(16, i == 0 ? 16 : 36, 16, 12),
                      child: Text(
                        _groups[i].label,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    sliver: SliverGrid(
                      delegate: SliverChildBuilderDelegate(
                        (context, itemIndex) {
                          final item = _groups[i].items[itemIndex];
                          return _MediaTile(
                            item: item,
                            selected: _selected.contains(item.path),
                            onTap: () => _tap(item),
                          );
                        },
                        childCount: _groups[i].items.length,
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                        childAspectRatio: 1,
                      ),
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 96)),
              ],
            ),
            Positioned(
              top: 16,
              right: 8,
              bottom: 16,
              child: _TimelineRail(
                label: _currentDateLabel,
                onDrag: _jumpToRatio,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _MediaItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isImage =
        item.kind == EntryKind.image && canRenderThumbnail(item.path);
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isImage)
              Image.file(
                File(item.path),
                fit: BoxFit.cover,
                cacheWidth: 260,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) =>
                    Icon(Icons.broken_image_outlined, color: scheme.primary),
              )
            else
              Center(
                child: Icon(
                  item.kind == EntryKind.video
                      ? Icons.play_circle_outline
                      : isCleanableDocument(item.path)
                          ? Icons.picture_as_pdf_outlined
                          : Icons.image_outlined,
                  size: 40,
                  color: scheme.primary,
                ),
              ),
            if (item.kind == EntryKind.video)
              Positioned(
                left: 6,
                bottom: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    child: Icon(Icons.videocam, size: 14, color: Colors.white),
                  ),
                ),
              ),
            Positioned(
              top: 6,
              right: 6,
              child: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? scheme.primary : Colors.white,
                shadows: const [Shadow(blurRadius: 4)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineRail extends StatelessWidget {
  const _TimelineRail({
    required this.label,
    required this.onDrag,
  });

  final String label;
  final void Function(double localDy, double height) onDrag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragDown: (d) =>
            onDrag(d.localPosition.dy, constraints.maxHeight),
        onVerticalDragUpdate: (d) =>
            onDrag(d.localPosition.dy, constraints.maxHeight),
        onTapDown: (d) => onDrag(d.localPosition.dy, constraints.maxHeight),
        child: SizedBox(
          width: 72,
          child: Column(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: const [
                    BoxShadow(blurRadius: 8, color: Colors.black26)
                  ],
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text(
                    label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Center(
                  child: Container(
                    width: 8,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileBrowserScreenState extends ConsumerState<_FileBrowserScreen> {
  Directory? _current;
  List<FileSystemEntity> _entries = const [];
  final Set<String> _selected = <String>{};
  final List<Directory> _history = <Directory>[];
  final _fileKindCache = <String, _FileKindCacheEntry>{};
  var _shortcuts = <_Shortcut>[];
  bool _loading = true;
  bool _multi = false;
  String? _error;

  bool get _fileMode => widget.mode != PickMode.directory;

  @override
  void initState() {
    super.initState();
    _multi = _fileMode && widget.allowMultiple;
    _shortcuts = _buildShortcuts();
    final start = widget.initialDirectory;
    _load(
      Directory(
        start != null &&
                start.isNotEmpty &&
                _allowed(start) &&
                Directory(start).existsSync()
            ? start
            : _initialDir(),
      ),
      remember: false,
    );
  }

  /// Inside [_FileBrowserScreen.root] (or anywhere when there is none).
  bool _allowed(String path) {
    final root = widget.root;
    return root == null || p.equals(root, path) || p.isWithin(root, path);
  }

  /// At the top of what may be browsed: the root, or a drive / `/`.
  bool _atTop(Directory dir) {
    final root = widget.root;
    if (root != null) return p.equals(root, dir.path);
    return p.equals(dir.parent.path, dir.path);
  }

  // --- Locations -------------------------------------------------------------

  String _env(String key) => Platform.environment[key] ?? '';

  String _initialDir() {
    final root = widget.root;
    if (root != null) return root;
    if (Platform.isWindows) {
      final home = _env('USERPROFILE');
      if (home.isNotEmpty && Directory(home).existsSync()) return home;
      return 'C:\\';
    }
    if (Platform.isAndroid) {
      const internal = '/storage/emulated/0';
      if (Directory(internal).existsSync()) return internal;
      return '/';
    }
    final home = _env('HOME');
    if (Platform.isIOS) {
      // HOME is the app container; only Documents is the user's (and the
      // folder the Files app shows as "On My iPhone > Influencor").
      final documents = p.join(home, 'Documents');
      if (Directory(documents).existsSync()) return documents;
    }
    if (home.isNotEmpty && Directory(home).existsSync()) return home;
    return '/';
  }

  List<_Shortcut> _buildShortcuts() {
    final strings = ref.read(appStringsProvider);
    final out = <_Shortcut>[];
    void add(String label, IconData icon, String path) {
      if (path.isNotEmpty && Directory(path).existsSync()) {
        out.add(_Shortcut(label, icon, path));
      }
    }

    final root = widget.root;
    if (root != null) {
      add(strings.workspaceFolder, Icons.folder_special_outlined, root);
      return out;
    }

    if (Platform.isWindows) {
      final home = _env('USERPROFILE');
      add(strings.locationHome, Icons.home_outlined, home);
      add(strings.locationDesktop, Icons.desktop_windows_outlined,
          p.join(home, 'Desktop'));
      add(strings.locationDocuments, Icons.description_outlined,
          p.join(home, 'Documents'));
      add(strings.locationDownloads, Icons.download_outlined,
          p.join(home, 'Downloads'));
      for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
        final letter = String.fromCharCode(c);
        add('$letter:', Icons.storage_outlined, '$letter:\\');
      }
    } else if (Platform.isAndroid) {
      const internal = '/storage/emulated/0';
      add(strings.locationHome, Icons.smartphone_outlined, internal);
      add(strings.locationDownloads, Icons.download_outlined,
          '$internal/Download');
      add('DCIM', Icons.photo_camera_outlined, '$internal/DCIM');
      add(strings.images, Icons.image_outlined, '$internal/Pictures');
    } else if (Platform.isIOS) {
      add(strings.locationDocuments, Icons.smartphone_outlined,
          p.join(_env('HOME'), 'Documents'));
    } else {
      final home = _env('HOME');
      add(strings.locationHome, Icons.home_outlined, home);
      add(strings.locationDesktop, Icons.desktop_mac_outlined,
          p.join(home, 'Desktop'));
      add(strings.locationDocuments, Icons.description_outlined,
          p.join(home, 'Documents'));
      add(strings.locationDownloads, Icons.download_outlined,
          p.join(home, 'Downloads'));
    }
    return out;
  }

  // --- Loading ---------------------------------------------------------------

  Future<void> _load(Directory dir, {bool remember = true}) async {
    if (!_allowed(dir.path)) return;
    final previous = _current;
    if (remember && previous != null && !p.equals(previous.path, dir.path)) {
      _history.add(previous);
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final items = <FileSystemEntity>[];
    try {
      await for (final ent in dir.list(followLinks: false)) {
        final name = p.basename(ent.path);
        if (name.startsWith('.')) continue; // hidden
        if (ent is Directory) {
          items.add(ent);
        } else if (ent is File) {
          if (widget.mode == PickMode.directory) continue;
          if (!await _isVisibleFile(ent.path)) continue;
          items.add(ent);
        }
      }
    } catch (_) {
      final strings = ref.read(appStringsProvider);
      if (mounted) {
        setState(() {
          _current = dir;
          _loading = false;
          _error = strings.folderAccessError;
          _entries = const [];
        });
      }
      return;
    }
    items.sort((a, b) {
      final ad = a is Directory;
      final bd = b is Directory;
      if (ad != bd) return ad ? -1 : 1;
      return p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase());
    });
    if (!mounted) return;
    setState(() {
      _current = dir;
      _entries = items;
      _loading = false;
    });
  }

  void _goUp() {
    final cur = _current;
    if (cur == null || _atTop(cur)) return;
    _load(cur.parent);
  }

  bool get _canGoBackInBrowser => _history.isNotEmpty;

  void _goBackInBrowser() {
    if (_history.isEmpty) return;
    final previous = _history.removeLast();
    _load(previous, remember: false);
  }

  /// Prompts for a name and creates a sub-folder in the current directory,
  /// then reloads so it shows up (and can be entered or picked).
  Future<void> _createFolder() async {
    final cur = _current;
    if (cur == null) return;
    final strings = ref.read(appStringsProvider);
    final name = await showTextPromptDialog(
      context,
      title: strings.newFolderTitle,
      label: strings.folderNameLabel,
      confirmLabel: strings.create,
      cancelLabel: strings.cancel,
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    try {
      final dir = Directory(p.join(cur.path, trimmed));
      if (!dir.existsSync()) await dir.create();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(strings.folderCreated(trimmed))));
      await _load(cur); // refresh listing to reveal the new folder
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(strings.folderAccessError)));
    }
  }

  // --- Selection / confirmation ---------------------------------------------

  Future<void> _onFileTap(File file) async {
    if (!_multi) {
      if (!await _isAcceptedForAction(file.path)) {
        _snack(ref.read(appStringsProvider).fileNotAccepted);
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(<String>[file.path]);
      return;
    }
    _toggleSelected(file.path);
  }

  void _toggleSelected(String path) {
    setState(() {
      if (!_selected.add(path)) _selected.remove(path);
    });
  }

  Future<void> _confirmFiles({bool move = false}) async {
    final paths = _selected.toList();
    final accepted = <String>[];
    var rejected = 0;
    for (final path in paths) {
      if (await _isAcceptedForAction(path)) {
        accepted.add(path);
      } else {
        rejected++;
      }
    }
    if (rejected > 0) {
      _snack(ref.read(appStringsProvider).filesNotAccepted(rejected));
    }
    if (accepted.isEmpty) return;
    if (!mounted) return;
    if (widget.showImportMoveActions) {
      Navigator.of(context).pop((paths: accepted, move: move));
    } else {
      Navigator.of(context).pop(accepted);
    }
  }

  Future<bool> _isAcceptedForAction(String path) async {
    if (widget.mode != PickMode.imageFiles &&
        widget.mode != PickMode.mediaFiles) {
      return true;
    }
    final type = await FileSystemEntity.type(path);
    if (type != FileSystemEntityType.file) return false;
    final kind = await _kindForFile(path);
    return widget.mode == PickMode.imageFiles
        ? kind == EntryKind.image
        : kind == EntryKind.image ||
            kind == EntryKind.video ||
            isCleanableDocument(path);
  }

  Future<bool> _isVisibleFile(String path) async {
    if (widget.mode != PickMode.imageFiles &&
        widget.mode != PickMode.mediaFiles) {
      return true;
    }
    final kind = await _kindForFile(path);
    return widget.mode == PickMode.imageFiles
        ? kind == EntryKind.image
        : kind == EntryKind.image ||
            kind == EntryKind.video ||
            isCleanableDocument(path);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _confirmDirectory() {
    final cur = _current;
    if (cur != null) Navigator.of(context).pop(<String>[cur.path]);
  }

  String _confirmLabel(AppStrings s) {
    if (widget.actionLabel != null) return widget.actionLabel!;
    return widget.mode == PickMode.imageFiles ||
            widget.mode == PickMode.mediaFiles
        ? s.selectAction
        : s.importAction;
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final title = widget.title ??
        (widget.mode == PickMode.directory
            ? strings.chooseDestination
            : widget.mode == PickMode.imageFiles
                ? strings.selectImagesTitle
                : widget.mode == PickMode.mediaFiles
                    ? strings.selectMediaTitle
                    : strings.selectFilesTitle);

    return PopScope<Object?>(
      canPop: !_canGoBackInBrowser,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _goBackInBrowser();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: strings.cancel,
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(title),
          actions: [
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: strings.newFolder,
              onPressed:
                  (_current == null || _error != null) ? null : _createFolder,
            ),
          ],
        ),
        body: Column(
          children: [
            _ShortcutsBar(
              shortcuts: _shortcuts,
              currentPath: _current?.path,
              onTap: (path) => _load(Directory(path)),
            ),
            _PathBar(
              path: _current?.path ?? '',
              canGoUp: _current != null && !_atTop(_current!),
              onUp: _goUp,
              upTooltip: strings.parentFolder,
            ),
            if (_fileMode && widget.allowMultiple)
              CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _multi,
                onChanged: (v) => setState(() {
                  _multi = v ?? false;
                  if (!_multi) _selected.clear();
                }),
                title: Text(strings.multipleSelection),
              ),
            const Divider(height: 1),
            Expanded(child: _buildList(strings)),
          ],
        ),
        bottomNavigationBar: _buildBottomBar(strings),
      ),
    );
  }

  Widget _buildList(AppStrings strings) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(child: Text(strings.emptyFolderTitle));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, i) {
        final ent = _entries[i];
        final name = p.basename(ent.path);
        if (ent is Directory) {
          // Whole folders can be picked as an import source too — the
          // checkbox selects the folder itself, the row still navigates in.
          final canSelectFolder = widget.mode == PickMode.files && _multi;
          final folderSelected = _selected.contains(ent.path);
          return ListTile(
            selected: canSelectFolder && folderSelected,
            leading: Icon(Icons.folder,
                color: Theme.of(context).colorScheme.primary),
            title: Text(name),
            trailing: canSelectFolder
                ? Checkbox(
                    value: folderSelected,
                    onChanged: (_) => _toggleSelected(ent.path),
                  )
                : const Icon(Icons.chevron_right),
            onTap: () => _load(ent),
          );
        }
        final file = ent as File;
        final selected = _selected.contains(file.path);
        return ListTile(
          selected: selected,
          leading: _FileLeading(file: file, name: name),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(_formatSize(file)),
          trailing: _multi
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => _onFileTap(file),
                )
              : null,
          onTap: () => _onFileTap(file),
        );
      },
    );
  }

  Widget? _buildBottomBar(AppStrings strings) {
    if (widget.mode == PickMode.directory) {
      return _BottomBar(
        child: FilledButton.icon(
          icon: const Icon(Icons.check),
          label: Text(strings.chooseThisFolder),
          onPressed: _current == null ? null : _confirmDirectory,
        ),
      );
    }
    if (!_multi) return null; // single tap confirms directly
    final n = _selected.length;
    if (widget.showImportMoveActions) {
      return _BottomBar(
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: n == 0 ? null : () => _confirmFiles(),
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(
                  '${strings.importAction} ($n)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: n == 0 ? null : () => _confirmFiles(move: true),
                icon: const Icon(Icons.drive_file_move_outlined),
                label: Text(
                  '${strings.move} ($n)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return _BottomBar(
      child: Row(
        children: [
          Text(strings.nSelected(n)),
          const Spacer(),
          FilledButton(
            onPressed: n == 0 ? null : () => _confirmFiles(),
            child: Text('${_confirmLabel(strings)} ($n)'),
          ),
        ],
      ),
    );
  }

  String _formatSize(File file) {
    int bytes;
    try {
      bytes = file.lengthSync();
    } catch (_) {
      return '';
    }
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<EntryKind> _kindForFile(String path) async {
    final ext = p.extension(path).toLowerCase();
    if (!tableExtensions.contains(ext)) return kindForFile(path);
    FileStat stat;
    try {
      stat = await File(path).stat();
    } catch (_) {
      return EntryKind.other;
    }
    final cached = _fileKindCache[path];
    if (cached != null &&
        cached.modified == stat.modified &&
        cached.size == stat.size) {
      return cached.kind;
    }
    final kind = await kindForFilePath(path);
    _fileKindCache[path] = _FileKindCacheEntry(
      modified: stat.modified,
      size: stat.size,
      kind: kind,
    );
    return kind;
  }
}

class _FileKindCacheEntry {
  const _FileKindCacheEntry({
    required this.modified,
    required this.size,
    required this.kind,
  });

  final DateTime modified;
  final int size;
  final EntryKind kind;
}

/// Thumbnail (for decodable images) or a type icon for a file row.
class _FileLeading extends StatelessWidget {
  const _FileLeading({required this.file, required this.name});

  final File file;
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (canRenderThumbnail(name)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          file,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          cacheWidth: 96,
          errorBuilder: (_, __, ___) =>
              Icon(Icons.image_outlined, color: scheme.primary),
        ),
      );
    }
    return FutureBuilder<EntryKind>(
      future: kindForFilePath(file.path),
      builder: (context, snapshot) {
        final icon = switch (snapshot.data ?? kindForFile(name)) {
          EntryKind.image => Icons.image_outlined,
          EntryKind.video => Icons.videocam_outlined,
          EntryKind.note => Icons.description_outlined,
          EntryKind.table => Icons.table_chart_outlined,
          _ => Icons.insert_drive_file_outlined,
        };
        return Icon(icon, color: scheme.onSurfaceVariant);
      },
    );
  }
}

class _ShortcutsBar extends StatelessWidget {
  const _ShortcutsBar({
    required this.shortcuts,
    required this.currentPath,
    required this.onTap,
  });

  final List<_Shortcut> shortcuts;
  final String? currentPath;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    if (shortcuts.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: shortcuts.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final s = shortcuts[i];
          final selected =
              currentPath != null && p.equals(currentPath!, s.path);
          return ActionChip(
            avatar: Icon(s.icon, size: 18),
            label: Text(s.label),
            backgroundColor: selected
                ? Theme.of(context).colorScheme.secondaryContainer
                : null,
            onPressed: () => onTap(s.path),
          );
        },
      ),
    );
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.path,
    required this.canGoUp,
    required this.onUp,
    required this.upTooltip,
  });

  final String path;
  final bool canGoUp;
  final VoidCallback onUp;
  final String upTooltip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward),
            tooltip: upTooltip,
            onPressed: canGoUp ? onUp : null,
          ),
          Expanded(
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: SizedBox(height: 48, child: child),
      ),
    );
  }
}
