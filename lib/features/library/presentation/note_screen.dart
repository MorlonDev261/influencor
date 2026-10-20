import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../core/widgets/app_inputs.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../app/constants/app_constants.dart';
import '../../../app/nav.dart';
import '../../../core/clipboard/note_copier.dart';
import '../../../core/formatting/note_separator.dart';
import '../../../core/formatting/note_clipboard.dart';
import '../../../core/formatting/list_format.dart';
import 'preview_screen.dart' show ImageViewerDialog;
import '../../../core/formatting/unicode_styler.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/picker/app_file_picker.dart';
import '../../../core/picker/pick_mode.dart';
import '../../../core/providers/settings_providers.dart';
import '../../../core/services/content_share_ui.dart';
import '../domain/library_entry.dart';
import '../application/library_providers.dart';
import 'widgets/chat_preview_dialog.dart';
import 'widgets/formatting_toolbar.dart';

/// Creates or edits a Markdown note (a real `.md` file on disk), with media
/// attachments copied next to the note and embedded as Markdown links.
class NoteScreen extends ConsumerStatefulWidget {
  const NoteScreen({this.existingPath, this.newDir, super.key})
      : assert(existingPath != null || newDir != null);

  final String? existingPath;
  final String? newDir;

  @override
  ConsumerState<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends ConsumerState<NoteScreen> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _titleFocus = FocusNode();
  final _contentFocus = FocusNode();
  bool _loading = false;
  bool _saving = false;
  bool _sharing = false;

  /// View mode (blocks with per-block copy) vs. edit mode. Existing notes open
  /// in view mode; a brand-new note opens straight in edit mode.
  bool _editing = false;

  /// Attachment image tags (`![name](link)`) kept OUT of the editor text so they
  /// never clutter the content. They are stored back into the `.md` on save, so
  /// stats, the media filter and the note↔image association keep working.
  final List<String> _imageTags = [];

  /// Attachment paths selected by the user. When non-empty, share/copy actions
  /// include only these images; otherwise they include all attached images.
  final Set<String> _selectedAttachments = <String>{};
  String? _noteSeparatorOverride;

  /// Pending "active" style: what freshly-typed text is converted into when no
  /// selection is targeted (like clicking Bold then typing).
  InlineStyle _activeStyle = InlineStyle.none;
  String _prevText = '';
  bool _applyingStyle = false;
  static const _styler = UnicodeStyler();
  static const _clip = NoteClipboard();

  bool get _isEditing => widget.existingPath != null;

  /// The folder the note lives in (known even for a not-yet-saved note).
  String get _dir => widget.newDir ?? p.dirname(widget.existingPath!);

  static final _imageLinkRegExp = RegExp(r'!?\[[^\]]*\]\(([^)]+)\)');

  @override
  void initState() {
    super.initState();
    // Refresh the live preview / copy content on any edit, including the
    // programmatic edits made by the formatting toolbar.
    _contentController.addListener(_onContentChanged);
    _editing = widget.existingPath == null; // new note → edit; existing → view
    if (_isEditing) {
      _titleController.text = p.basenameWithoutExtension(widget.existingPath!);
      _loadContent();
    }
    if (_editing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _titleFocus.requestFocus();
      });
    }
  }

  void _onContentChanged() {
    if (_applyingStyle) return;
    final value = _contentController.value;
    final newText = value.text;

    // Convert freshly-typed characters into the active style. Skip while an IME
    // composition is in progress to avoid disrupting it.
    if (value.composing.isCollapsed) {
      final insertion = _extractInsertion(_prevText, newText);
      if (insertion != null) {
        final (start, inserted) = insertion;
        // Enter inside a list → continue it, or exit on an empty item.
        if (inserted == '\n' && _handleListNewline(newText, start)) {
          return;
        }
        // Active style → convert the freshly-typed characters.
        final styled = _activeStyle.isEmpty
            ? inserted
            : _styler.transform(_styler.plainify(inserted), _activeStyle);
        if (styled != inserted) {
          final replaced =
              newText.replaceRange(start, start + inserted.length, styled);
          _applyingStyle = true;
          _contentController.value = TextEditingValue(
            text: replaced,
            selection: TextSelection.collapsed(offset: start + styled.length),
            composing: TextRange.empty,
          );
          _applyingStyle = false;
          _prevText = replaced;
          if (mounted) setState(() {});
          return;
        }
      }
    }
    _prevText = newText;
    if (mounted) setState(() {});
  }

  /// Returns the (start, text) of a single contiguous insertion between [oldT]
  /// and [newT], or null if the change is not a plain insertion.
  (int, String)? _extractInsertion(String oldT, String newT) {
    if (newT.length <= oldT.length) return null;
    var prefix = 0;
    final min = oldT.length;
    while (prefix < min && oldT.codeUnitAt(prefix) == newT.codeUnitAt(prefix)) {
      prefix++;
    }
    final insertedLen = newT.length - oldT.length;
    final inserted = newT.substring(prefix, prefix + insertedLen);
    // Verify the rest matches (pure insertion, not a replacement).
    if (oldT ==
        newT.substring(0, prefix) + newT.substring(prefix + insertedLen)) {
      return (prefix, inserted);
    }
    return null;
  }

  /// Handles Enter pressed on a list line: continue the list with the next
  /// prefix, or — if the current item is empty — exit the list. Returns true
  /// when it changed the text.
  bool _handleListNewline(String newText, int newlinePos) {
    final before = newText.substring(0, newlinePos);
    final lineStart = before.lastIndexOf('\n') + 1;
    final curLine = before.substring(lineStart);

    final bullet = ListFormat.bulletRe.firstMatch(curLine);
    final numbered = ListFormat.numberedRe.firstMatch(curLine);
    if (bullet == null && numbered == null) return false;

    final content =
        (bullet != null ? bullet.group(2) : numbered!.group(3)) ?? '';

    final String replaced;
    final int cursor;
    if (content.trim().isEmpty) {
      // Empty item + Enter → leave the list: drop the prefix and the newline.
      replaced =
          newText.substring(0, lineStart) + newText.substring(newlinePos + 1);
      cursor = lineStart;
    } else {
      // Continue the list on the new line.
      final prefix = bullet != null
          ? ListFormat.bullet
          : ListFormat.numbered((int.tryParse(numbered!.group(2)!) ?? 1) + 1);
      replaced = newText.substring(0, newlinePos + 1) +
          prefix +
          newText.substring(newlinePos + 1);
      cursor = newlinePos + 1 + prefix.length;
    }

    _applyingStyle = true;
    _contentController.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: cursor),
      composing: TextRange.empty,
    );
    _applyingStyle = false;
    _prevText = replaced;
    if (mounted) setState(() {});
    return true;
  }

  Future<void> _loadContent() async {
    setState(() => _loading = true);
    try {
      final raw = await ref
          .read(libraryControllerProvider)
          .readNote(widget.existingPath!);
      final (body, tags) = _splitBodyAndImages(raw);
      _imageTags
        ..clear()
        ..addAll(tags);
      _selectedAttachments.clear();
      _contentController.text = body;
      _prevText = body;
      _noteSeparatorOverride = await ref
          .read(libraryControllerProvider)
          .noteSeparator(widget.existingPath!);
    } catch (_) {
      // leave empty on error
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Separates the editable body from the attachment image tags. Lines that are
  /// only an image tag are dropped from the body; inline tags are lifted out too.
  (String, List<String>) _splitBodyAndImages(String raw) {
    final tags = <String>[];
    final bodyLines = <String>[];
    for (final line in raw.split('\n')) {
      final matches = _imageLinkRegExp.allMatches(line).toList();
      if (matches.isEmpty) {
        bodyLines.add(line);
        continue;
      }
      for (final m in matches) {
        tags.add(m.group(0)!);
      }
      final stripped = line.replaceAll(_imageLinkRegExp, '').trim();
      if (stripped.isNotEmpty) bodyLines.add(stripped);
    }
    return (bodyLines.join('\n').trimRight(), tags);
  }

  /// Rebuilds the full `.md` content: the body followed by the attachment tags.
  String _composeContent() {
    final body = _contentController.text.trimRight();
    if (_imageTags.isEmpty) return body;
    final block = _imageTags.join('\n');
    return body.isEmpty ? block : '$body\n\n$block';
  }

  @override
  void dispose() {
    _contentController.removeListener(_onContentChanged);
    _titleController.dispose();
    _contentController.dispose();
    _titleFocus.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  /// Absolute paths of the attached images (from the separated tag list).
  List<String> _attachedImages() {
    final out = <String>[];
    for (final tag in _imageTags) {
      final m = _imageLinkRegExp.firstMatch(tag);
      if (m == null) continue;
      final link = Uri.decodeFull(m.group(1)!.trim());
      final abs = p.isAbsolute(link) ? link : p.normalize(p.join(_dir, link));
      out.add(abs);
    }
    return out;
  }

  List<String> _activeAttachmentImages(List<String> images) {
    if (_selectedAttachments.isEmpty) return images;
    return images.where(_selectedAttachments.contains).toList();
  }

  void _toggleAttachment(String path) {
    setState(() {
      if (!_selectedAttachments.remove(path)) {
        _selectedAttachments.add(path);
      }
    });
  }

  void _clearAttachmentSelection() {
    if (_selectedAttachments.isEmpty) return;
    setState(_selectedAttachments.clear);
  }

  bool _tagPointsTo(String tag, String path) {
    final m = _imageLinkRegExp.firstMatch(tag);
    if (m == null) return false;
    final link = Uri.decodeFull(m.group(1)!.trim());
    final abs = p.isAbsolute(link) ? link : p.normalize(p.join(_dir, link));
    return p.equals(abs, path);
  }

  bool _isManagedAttachment(String path) {
    final attachmentsDir = p.normalize(p.join(_dir, '.attachments'));
    final normalized = p.normalize(path);
    return p.equals(p.dirname(normalized), attachmentsDir) ||
        p.isWithin(attachmentsDir, normalized);
  }

  Future<void> _deleteAttachment(String path, AppStrings strings) async {
    final ok = await showConfirmDialog(
      context,
      title: strings.deleteAttachmentTitle,
      message: strings.deleteAttachmentMessage,
      confirmLabel: strings.delete,
      cancelLabel: strings.cancel,
      destructive: true,
    );
    if (!ok) return;

    setState(() {
      _imageTags.removeWhere((tag) => _tagPointsTo(tag, path));
      _selectedAttachments.remove(path);
    });

    if (_isManagedAttachment(path)) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // The note tag has still been removed; ignore stale/missing files.
      }
    }

    if (_isEditing) {
      try {
        await ref
            .read(libraryControllerProvider)
            .saveNote(widget.existingPath!, _composeContent());
        ref.invalidate(directoryProvider(_dir));
      } catch (_) {
        if (mounted) _snack(strings.genericError);
        return;
      }
    }

    ref.invalidate(libraryIndexProvider);
    ref.invalidate(dirStatsProvider);
    ref.invalidate(dirRecursiveProvider);
    if (mounted) _snack(strings.attachmentDeleted);
  }

  Future<void> _attachPhotos(AppStrings strings) async {
    final paths = await AppFilePicker.pick(
      context,
      mode: PickMode.mediaFiles,
      title: strings.attachPhoto,
    );
    if (paths.isEmpty) return;
    final controller = ref.read(libraryControllerProvider);
    final newTags = <String>[];
    for (final src in paths) {
      try {
        final link = await controller.attachImage(_dir, src);
        final name = p.basenameWithoutExtension(src);
        final kind = kindForFile(src);
        // Kept separate from the editor text; merged into the .md only on save.
        newTags.add(kind == EntryKind.video
            ? '[$name](${Uri.encodeFull(link)})'
            : '![$name](${Uri.encodeFull(link)})');
      } catch (_) {
        // skip failed attachment
      }
    }
    if (newTags.isEmpty) return;
    setState(() => _imageTags.addAll(newTags));
    if (mounted) _snack(strings.photosAttached(newTags.length));
  }

  void _viewImage(String path) {
    if (kindForFile(path) == EntryKind.video) {
      context.push(previewRoute(path));
      return;
    }
    final strings = ref.read(appStringsProvider);
    ImageViewerDialog.show(
      context,
      path: path,
      onCopy: () => _copyAttachmentImage(path, strings),
    );
  }

  Future<void> _copyAttachmentImage(String path, AppStrings strings) async {
    try {
      final files = await copyNoteToClipboard('', imagePaths: [path]);
      if (!mounted) return;
      _snack(files > 0
          ? strings.copiedWithFiles(files)
          : strings.copiedToClipboard);
    } catch (_) {
      if (mounted) _snack(strings.copyFailed);
    }
  }

  Future<void> _save(AppStrings strings) async {
    final content = _composeContent();
    if (content.trim().isEmpty) {
      _snack(strings.emptyNoteError);
      return;
    }
    setState(() => _saving = true);
    final controller = ref.read(libraryControllerProvider);
    var renamed = false;
    try {
      if (_isEditing) {
        final path = widget.existingPath!;
        final parent = p.dirname(path);
        await controller.saveNote(path, content);
        final newTitle = _titleController.text.trim();
        if (newTitle.isNotEmpty &&
            newTitle != p.basenameWithoutExtension(path)) {
          await controller.rename(path, newTitle, parentDir: parent);
          renamed = true;
        } else {
          ref.invalidate(directoryProvider(parent));
        }
      } else {
        final created = await controller.createNote(
          widget.newDir!,
          title: _titleController.text.trim(),
          content: content,
        );
        final separator = _normalizedSeparator(_noteSeparatorOverride);
        if (separator != null) {
          await controller.setNoteSeparator(created, separator,
              parentDir: widget.newDir!);
        }
      }
      if (!mounted) return;
      _snack(strings.noteSaved);
      // Existing note (unchanged path) → back to view mode; new or renamed
      // note (path changed) → leave the screen.
      if (_isEditing && !renamed) {
        setState(() {
          _saving = false;
          _editing = false;
        });
      } else {
        context.pop();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        _snack(strings.genericError);
      }
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String? _normalizedSeparator(String? value) {
    return NoteSeparator.normalize(value);
  }

  String _effectiveSeparator(String? globalSeparator) =>
      NoteSeparator.effective(_noteSeparatorOverride, globalSeparator);

  List<String> _noteSegments(String text, String separator) =>
      NoteSeparator.segments(text, separator);

  String _renderSeparatedContent(String separator) =>
      NoteSeparator.render(_contentController.text, separator);

  String _separatorLabel(AppStrings strings, String? globalSeparator) {
    final note = _normalizedSeparator(_noteSeparatorOverride);
    if (note != null) return note;
    final global = _normalizedSeparator(globalSeparator);
    if (global != null) return strings.noteSeparatorInherited;
    return strings.defaultSeparator;
  }

  Future<void> _editNoteSeparator(
    AppStrings strings,
    String? globalSeparator,
  ) async {
    final controller =
        TextEditingController(text: _noteSeparatorOverride ?? '');
    const inheritValue = '__inherit_separator__';
    const cancelValue = '__cancel_separator__';
    final result = await showAppDialog<String>(
      context,
      builder: (context) => AppDialog(
        title: strings.noteSeparatorOverride,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTextField(
              controller: controller,
              autofocus: true,
              label: strings.customSeparator,
              hint: '########',
              helper: _normalizedSeparator(globalSeparator) == null
                  ? strings.defaultSeparator
                  : globalSeparator,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '########   [ ----- ]',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, cancelValue),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, inheritValue),
            child: Text(strings.noteSeparatorInherited),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(strings.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result == cancelValue) return;
    if (!mounted) return;

    final next = result == inheritValue ? null : _normalizedSeparator(result);
    setState(() => _noteSeparatorOverride = next);
    if (_isEditing) {
      try {
        await ref
            .read(libraryControllerProvider)
            .setNoteSeparator(widget.existingPath!, next, parentDir: _dir);
      } catch (_) {
        if (mounted) _snack(strings.genericError);
      }
    }
  }

  Future<void> _copyText(String text, AppStrings strings) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) _snack(strings.copiedToClipboard);
    } catch (_) {
      if (mounted) _snack(strings.copyFailed);
    }
  }

  Future<void> _copyNote(
    AppStrings strings,
    String text, {
    List<String> mediaPaths = const [],
  }) async {
    try {
      final files = await copyNoteToClipboard(text, imagePaths: mediaPaths);
      if (!mounted) return;
      _snack(files > 0
          ? strings.copiedWithFiles(files)
          : strings.copiedToClipboard);
    } catch (_) {
      if (mounted) _snack(strings.copyFailed);
    }
  }

  /// Opens the system share sheet with the caption and attached images.
  Future<void> _share(
    AppStrings strings,
    List<String> images,
    String text,
  ) async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await shareWithFeedback(
        context,
        strings,
        text: text,
        mediaPaths: images,
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final settings = ref.watch(settingsProvider);
    final images = _attachedImages();
    final activeImages = _activeAttachmentImages(images);
    final separator = _effectiveSeparator(settings.noteSeparator);
    final renderedContent = _renderSeparatedContent(separator);
    final isEmpty = renderedContent.trim().isEmpty && _imageTags.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(_appBarTitle(strings)),
        actions: [
          if (!_editing)
            IconButton(
              tooltip: strings.edit,
              icon: const Icon(Icons.edit_outlined),
              onPressed: () {
                setState(() => _editing = true);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _titleFocus.requestFocus();
                });
              },
            ),
          if (_editing)
            IconButton(
              tooltip: strings.save,
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              onPressed: _saving ? null : () => _save(strings),
            ),
          IconButton(
            tooltip: strings.share,
            icon: const Icon(Icons.ios_share),
            onPressed: isEmpty || _sharing
                ? null
                : () => _share(strings, activeImages, renderedContent),
          ),
          _NoteMoreMenu(
            editing: _editing,
            isEmpty: isEmpty,
            hasMedia: activeImages.isNotEmpty,
            strings: strings,
            onSeparator: () =>
                _editNoteSeparator(strings, settings.noteSeparator),
            onPreview: isEmpty
                ? null
                : () => ChatPreviewDialog.show(
                      context,
                      markdown: renderedContent,
                      imagePaths: activeImages,
                    ),
            onAttach: _editing ? () => _attachPhotos(strings) : null,
            onCopyNote: isEmpty
                ? null
                : () => _copyNote(
                      strings,
                      _clip.render(CopyMode.social, renderedContent),
                    ),
            onCopyNoteMedia: isEmpty
                ? null
                : () => _copyNote(
                      strings,
                      _clip.render(CopyMode.social, renderedContent),
                      mediaPaths: activeImages,
                    ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: _editing
                    ? _buildEdit(strings, images, settings.noteSeparator)
                    : _buildView(strings, images, separator),
              ),
            ),
    );
  }

  String _appBarTitle(AppStrings strings) {
    if (_editing) {
      return _isEditing ? strings.editNoteTitle : strings.newNoteTitle;
    }
    return _isEditing
        ? p.basenameWithoutExtension(widget.existingPath!)
        : strings.newNoteTitle;
  }

  // --- View mode: read-only blocks, each copyable ----------------------------

  Widget _buildView(
    AppStrings strings,
    List<String> images,
    String separator,
  ) {
    final blocks = _noteSegments(_contentController.text, separator);
    return ListView(
      padding: const EdgeInsets.all(AppConstants.defaultPadding),
      children: [
        Text(
          _titleController.text.isEmpty
              ? strings.newNoteTitle
              : _titleController.text,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        if (blocks.isEmpty && images.isEmpty)
          Text(strings.noContents,
              style: Theme.of(context).textTheme.bodyMedium),
        for (final block in blocks) ...[
          _CopyableBlock(
            text: block,
            onCopy: () => _copyText(block, strings),
            copyTooltip: strings.copy,
          ),
          const SizedBox(height: 12),
        ],
        if (images.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(strings.attachments,
              style: Theme.of(context).textTheme.labelLarge),
          if (_selectedAttachments.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  strings.selectedAttachments(_selectedAttachments.length),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                TextButton(
                  onPressed: _clearAttachmentSelection,
                  child: Text(strings.clear),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          _AttachmentStrip(
            images: images,
            selected: _selectedAttachments,
            onToggle: _toggleAttachment,
            onView: _viewImage,
            onCopy: (path) => _copyAttachmentImage(path, strings),
            onDelete: (path) => _deleteAttachment(path, strings),
            deleteTooltip: strings.delete,
            openTooltip: strings.open,
            copyTooltip: strings.copy,
          ),
        ],
      ],
    );
  }

  // --- Edit mode -------------------------------------------------------------

  /// Note fields keep a visible outline: the theme's borderless fill matches
  /// the page background, so without it the title and content blend in.
  InputDecoration _outlined({
    required String labelText,
    String? hintText,
    bool alignLabelWithHint = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      alignLabelWithHint: alignLabelWithHint,
      border: border(scheme.outline),
      enabledBorder: border(scheme.outline),
      focusedBorder: border(scheme.primary, 2),
    );
  }

  Widget _buildEdit(
    AppStrings strings,
    List<String> images,
    String? globalSeparator,
  ) {
    return ListView(
      padding: const EdgeInsets.all(AppConstants.defaultPadding),
      children: [
        TextField(
          controller: _titleController,
          focusNode: _titleFocus,
          decoration: _outlined(
            labelText: strings.noteTitle,
            hintText: strings.noteTitleHint,
          ),
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.sentences,
        ),
        const SizedBox(height: 8),
        FormattingToolbar(
          controller: _contentController,
          focusNode: _contentFocus,
          activeStyle: _activeStyle,
          onActiveStyleChanged: (s) => setState(() => _activeStyle = s),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _contentController,
          focusNode: _contentFocus,
          style: const TextStyle(
            fontFamily: AppConstants.noteFontFamily,
            fontFamilyFallback: AppConstants.noteFontFallback,
            fontSize: 16,
            height: 1.4,
          ),
          decoration: _outlined(
            labelText: strings.noteContent,
            alignLabelWithHint: true,
          ),
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          textAlignVertical: TextAlignVertical.top,
          // Grow with real content only; avoid a large empty editable area that
          // can be selected just to fill the page.
          minLines: 1,
          maxLines: null,
        ),
        const SizedBox(height: 20),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              IconButton.filled(
                tooltip: strings.save,
                onPressed: _saving ? null : () => _save(strings),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: strings.attachPhoto,
                onPressed: () => _attachPhotos(strings),
                icon: const Icon(Icons.add_photo_alternate_outlined),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: _separatorLabel(strings, globalSeparator),
                onPressed: () => _editNoteSeparator(strings, globalSeparator),
                icon: const Icon(Icons.splitscreen_outlined),
              ),
            ],
          ),
        ),
        if (images.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(strings.attachments,
              style: Theme.of(context).textTheme.labelLarge),
          if (_selectedAttachments.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  strings.selectedAttachments(_selectedAttachments.length),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                TextButton(
                  onPressed: _clearAttachmentSelection,
                  child: Text(strings.clear),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          _AttachmentStrip(
            images: images,
            selected: _selectedAttachments,
            onToggle: _toggleAttachment,
            onView: _viewImage,
            onCopy: (path) => _copyAttachmentImage(path, strings),
            onDelete: (path) => _deleteAttachment(path, strings),
            deleteTooltip: strings.delete,
            openTooltip: strings.open,
            copyTooltip: strings.copy,
          ),
        ],
      ],
    );
  }
}

enum _NoteMenuAction {
  separator,
  preview,
  attach,
  copyNote,
  copyNoteMedia,
}

class _NoteMoreMenu extends StatelessWidget {
  const _NoteMoreMenu({
    required this.editing,
    required this.isEmpty,
    required this.hasMedia,
    required this.strings,
    required this.onSeparator,
    required this.onPreview,
    required this.onAttach,
    required this.onCopyNote,
    required this.onCopyNoteMedia,
  });

  final bool editing;
  final bool isEmpty;
  final bool hasMedia;
  final AppStrings strings;
  final VoidCallback onSeparator;
  final VoidCallback? onPreview;
  final VoidCallback? onAttach;
  final VoidCallback? onCopyNote;
  final VoidCallback? onCopyNoteMedia;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_NoteMenuAction>(
      tooltip: strings.more,
      icon: const Icon(Icons.more_vert),
      onSelected: (action) {
        switch (action) {
          case _NoteMenuAction.separator:
            onSeparator();
          case _NoteMenuAction.preview:
            onPreview?.call();
          case _NoteMenuAction.attach:
            onAttach?.call();
          case _NoteMenuAction.copyNote:
            onCopyNote?.call();
          case _NoteMenuAction.copyNoteMedia:
            onCopyNoteMedia?.call();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _NoteMenuAction.separator,
          child: _menuRow(Icons.splitscreen_outlined, strings.noteSeparator),
        ),
        PopupMenuItem(
          value: _NoteMenuAction.preview,
          enabled: !isEmpty && onPreview != null,
          child: _menuRow(Icons.visibility_outlined, strings.preview),
        ),
        if (editing)
          PopupMenuItem(
            value: _NoteMenuAction.attach,
            enabled: onAttach != null,
            child: _menuRow(
              Icons.add_photo_alternate_outlined,
              strings.attachPhoto,
            ),
          ),
        PopupMenuItem(
          value: _NoteMenuAction.copyNote,
          enabled: !isEmpty && onCopyNote != null,
          child: _menuRow(Icons.copy, strings.copyForSocial),
        ),
        PopupMenuItem(
          value: _NoteMenuAction.copyNoteMedia,
          enabled: !isEmpty && hasMedia && onCopyNoteMedia != null,
          child: _menuRow(Icons.perm_media_outlined, strings.copyPlainText),
        ),
      ],
    );
  }

  Widget _menuRow(IconData icon, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Flexible(child: Text(label)),
        ],
      );
}

/// A read-only text block with a copy button (view mode).
class _CopyableBlock extends StatelessWidget {
  const _CopyableBlock({
    required this.text,
    required this.onCopy,
    required this.copyTooltip,
  });

  final String text;
  final VoidCallback onCopy;
  final String copyTooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              text,
              style: const TextStyle(
                fontFamily: AppConstants.noteFontFamily,
                fontFamilyFallback: AppConstants.noteFontFallback,
                fontSize: 16,
                height: 1.4,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: copyTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}

class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({
    required this.images,
    required this.selected,
    required this.onToggle,
    required this.onView,
    required this.onCopy,
    required this.onDelete,
    required this.deleteTooltip,
    required this.openTooltip,
    required this.copyTooltip,
  });

  final List<String> images;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onView;
  final ValueChanged<String> onCopy;
  final ValueChanged<String> onDelete;
  final String deleteTooltip;
  final String openTooltip;
  final String copyTooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selectionActive = selected.isNotEmpty;
    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final path = images[i];
          final isSelected = selected.contains(path);
          final isVideo = kindForFile(path) == EntryKind.video;
          return SizedBox(
            width: 104,
            child: Column(
              children: [
                GestureDetector(
                  onTap: () => selectionActive ? onToggle(path) : onView(path),
                  onLongPress: () => onToggle(path),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: isSelected
                          ? Border.all(color: scheme.primary, width: 2)
                          : null,
                    ),
                    padding: const EdgeInsets.all(2),
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: isVideo
                              ? Container(
                                  width: 96,
                                  height: 96,
                                  color: scheme.surfaceContainerHighest,
                                  child: Icon(
                                    Icons.videocam_outlined,
                                    color: scheme.primary,
                                  ),
                                )
                              : Image.file(
                                  File(path),
                                  width: 96,
                                  height: 96,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                  cacheWidth: 200,
                                  errorBuilder: (_, __, ___) => Container(
                                    width: 96,
                                    height: 96,
                                    color: scheme.surfaceContainerHighest,
                                    child:
                                        const Icon(Icons.broken_image_outlined),
                                  ),
                                ),
                        ),
                        if (isSelected)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Icon(
                              Icons.check_circle,
                              color: scheme.primary,
                              shadows: const [Shadow(blurRadius: 4)],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      tooltip: openTooltip,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onView(path),
                    ),
                    if (!isVideo)
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: copyTooltip,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => onCopy(path),
                      ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: deleteTooltip,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onDelete(path),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
