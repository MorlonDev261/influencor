import 'dart:async';

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/widgets/app_inputs.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../reseller/application/reseller_providers.dart';
import '../../../app/constants/app_constants.dart';

import '../../../app/nav.dart';

import '../../../app/widgets/app_header_title.dart';

import '../../../core/l10n/app_strings.dart';

import '../../../core/picker/app_file_picker.dart';

import '../../../core/picker/pick_mode.dart';

import '../../../core/providers/settings_providers.dart';

import '../../../core/providers/workspace_providers.dart';

import '../../../core/services/content_share_ui.dart';

import '../../../core/widgets/empty_state.dart';

import '../../../shared/enums/enums.dart';

import '../../cleaner/presentation/deganeo_clean_dialog.dart';

import '../../cleaner/presentation/deganeo_icon.dart';

import '../application/browse_filtering.dart';

import '../application/library_providers.dart';

import '../domain/library_entry.dart';
import '../domain/table_document.dart';

/// Browses a real directory on disk: subfolders + files, with breadcrumb,

/// sort, filters, create, import, drag & drop and per-entry actions.

class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({required this.dirPath, this.showBack = true, super.key});

  final String dirPath;

  /// When false (used as the Home tab's root view), no back button is shown

  /// and the title falls back to the app name.

  final bool showBack;

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
  bool _dragging = false;

  /// Paths currently selected for a batch action (move / delete). Selection
  /// mode is active whenever this is non-empty. Synchronized with the preview
  /// screen so selections made while previewing media persist back in the list.
  Set<String> get _selected => ref.watch(selectedEntriesProvider);

  bool get _selecting => _selected.isNotEmpty;

  /// The entries currently shown in the list (kept so "select all" can act on
  /// exactly what is visible, filters included).
  List<LibraryEntry> _visible = const [];

  String get _dir => widget.dirPath;

  void _toggleSelect(String path) {
    final current = ref.read(selectedEntriesProvider);
    final next = Set<String>.from(current);
    if (!next.remove(path)) {
      next.add(path);
    }
    ref.read(selectedEntriesProvider.notifier).state = next;
  }

  void _startSelection(String path) {
    final current = ref.read(selectedEntriesProvider);
    ref.read(selectedEntriesProvider.notifier).state = {...current, path};
  }

  void _clearSelection() {
    if (_selected.isEmpty) return;
    ref.read(selectedEntriesProvider.notifier).state = <String>{};
  }

  void _selectAll(List<LibraryEntry> entries) {
    ref.read(selectedEntriesProvider.notifier).state =
        entries.map((e) => e.path).toSet();
  }

  /// The selected entries that are images (the only ones Deganeo cleans here).
  List<String> get _selectedImagePaths {
    final visibleByPath = {for (final entry in _visible) entry.path: entry};
    return [
      for (final path in _selected)
        if ((visibleByPath[path]?.kind ?? kindForFile(p.basename(path))) ==
            EntryKind.image)
          path,
    ];
  }

  bool get _selectedOnlyImages {
    if (_selected.isEmpty) return false;
    return _selectedImagePaths.length == _selected.length;
  }

  /// Deganeo over the selected images, one at a time, then leaves selection.
  Future<void> _cleanSelectedImages() async {
    final paths = _selectedImagePaths;
    if (paths.isEmpty) return;
    await _runDeganeo(context, ref, paths, _dir);
    _clearSelection();
  }

  Future<void> _shareSelectedImages() async {
    final strings = ref.read(appStringsProvider);
    final paths = _selected.toList();
    if (paths.isEmpty) return;

    await shareWithFeedback(context, strings, text: null, mediaPaths: paths);
  }

  /// Moves every selected entry into a destination folder chosen inside the
  /// workspace, then leaves selection mode.
  Future<void> _moveSelected() async {
    final strings = ref.read(appStringsProvider);
    final paths = _selected.toList();
    if (paths.isEmpty) return;
    final dests = await AppFilePicker.pick(
      context,
      mode: PickMode.directory,
      title: strings.chooseDestination,
      initialDirectory: ref.read(workspaceRootProvider) ?? _dir,
    );
    if (dests.isEmpty) return;
    final dest = dests.first;
    final controller = ref.read(libraryControllerProvider);
    var moved = 0;
    for (final path in paths) {
      if (p.equals(dest, path) || p.equals(dest, p.dirname(path))) continue;
      try {
        await controller.move(path, dest, parentDir: _dir);
        moved++;
      } catch (_) {/* skip entries that can't be moved */}
    }
    _clearSelection();
    if (mounted) _snack(strings.nMoved(moved));
  }

  /// Sends every selected entry to the trash, then leaves selection mode.
  Future<void> _deleteSelected() async {
    final strings = ref.read(appStringsProvider);
    final paths = _selected.toList();
    if (paths.isEmpty) return;
    final ok = await confirmDelete(context, strings);
    if (ok != true) return;
    final controller = ref.read(libraryControllerProvider);
    var deleted = 0;
    for (final path in paths) {
      try {
        await controller.moveToTrash(path, parentDir: _dir);
        deleted++;
      } catch (_) {/* skip entries that can't be deleted */}
    }
    _clearSelection();
    if (mounted) _snack(strings.nDeleted(deleted));
  }

  /// The app bar shown while items are selected: count, close, select-all,
  /// move and delete.
  AppBar _buildSelectionBar(AppStrings strings) {
    final allSelected =
        _visible.isNotEmpty && _selected.length >= _visible.length;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: strings.cancel,
        onPressed: _clearSelection,
      ),
      title: Text(strings.nSelected(_selected.length)),
      actions: [
        IconButton(
          icon: const Icon(Icons.select_all),
          tooltip: strings.selectAll,
          onPressed: allSelected ? _clearSelection : () => _selectAll(_visible),
        ),
        if (_selectedImagePaths.isNotEmpty)
          IconButton(
            icon: const DeganeoIcon(size: 24),
            tooltip: 'Deganeo',
            onPressed: _cleanSelectedImages,
          ),
        if (_selectedOnlyImages)
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: strings.share,
            onPressed: _shareSelectedImages,
          ),
        IconButton(
          icon: const Icon(Icons.drive_file_move_outlined),
          tooltip: strings.move,
          onPressed: _moveSelected,
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: strings.delete,
          onPressed: _deleteSelected,
        ),
      ],
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _openSearch() {
    context.push(searchRoute());
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);

    final root = ref.watch(workspaceRootProvider);

    final isRoot = root != null && p.equals(root, _dir);

    final viewMode = ref.watch(settingsProvider).viewMode;

    final sort = ref.watch(browseSortProvider);

    final filter = ref.watch(browseFilterProvider);

    // With a kind filter active we need the recursive listing so that, for any

    // match nested deep down, entriesForFilter can surface the direct

    // sub-folder that leads to it (never the deep item itself), ordered by how

    // close the match is. The unfiltered "all" view stays a plain,

    // direct-children listing for normal browsing.

    final listing = filter == null
        ? ref.watch(directoryProvider(_dir))
        : ref.watch(dirRecursiveProvider(_dir));

    final titleWidget = widget.showBack
        ? Text(isRoot ? strings.library : p.basename(_dir))
        : const AppHeaderTitle(showModeBadge: true);

    return Scaffold(
      appBar: _selecting
          ? _buildSelectionBar(strings)
          : AppBar(
              toolbarHeight:
                  !widget.showBack && ref.watch(modeBadgeVisibleProvider)
                      ? AppHeaderTitle.heightWithBadge
                      : null,
              automaticallyImplyLeading: widget.showBack,
              leading: widget.showBack
                  ? BackButton(onPressed: () => _back(context))
                  : null,
              title: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.12, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: const ValueKey('browse-title'),
                  child: titleWidget,
                ),
              ),
              actions: [
                IconButton(
                  tooltip: strings.search,
                  icon: const Icon(Icons.search),
                  onPressed: _openSearch,
                ),
                _SortMenu(),
                IconButton(
                  tooltip: strings.refresh,
                  icon: const Icon(Icons.refresh),
                  onPressed: () {
                    ref.invalidate(directoryProvider(_dir));
                    ref.invalidate(dirStatsProvider(_dir));
                  },
                ),
                IconButton(
                  tooltip: strings.contents,
                  icon: Icon(viewMode == ViewMode.grid
                      ? Icons.view_list_outlined
                      : Icons.grid_view_outlined),
                  onPressed: () => ref
                      .read(settingsControllerProvider.notifier)
                      .setViewMode(viewMode == ViewMode.grid
                          ? ViewMode.list
                          : ViewMode.grid),
                ),
              ],
            ),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _showAddSheet(context),
              icon: const Icon(Icons.add),
              label: Text(strings.add),
            ),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (detail) async {
          setState(() => _dragging = false);

          final paths = detail.files
              .map((f) => f.path)
              .where((path) => path.isNotEmpty)
              .toList();

          if (paths.isNotEmpty) {
            await _import(paths);
          }
        },
        child: Stack(
          children: [
            Column(
              children: [
                if (root != null) _Breadcrumb(root: root, dir: _dir),
                _DeferredStatsCards(dir: _dir),
                _FilterBar(),
                Expanded(
                  child: listing.value == null
                      ? listing.when(
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (e, _) =>
                              Center(child: Text(strings.genericError)),
                          data: (entries) => _buildEntries(
                            entries: entries,
                            filter: filter,
                            sort: sort,
                            viewMode: viewMode,
                          ),
                        )
                      : _buildEntries(
                          entries: listing.value!,
                          filter: filter,
                          sort: sort,
                          viewMode: viewMode,
                        ),
                ),
              ],
            ),
            if (_dragging) _DropOverlay(label: strings.dropToImport),
          ],
        ),
      ),
    );
  }

  void _back(BuildContext context) {
    _clearSelection();
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  Widget _buildEntries({
    required List<LibraryEntry> entries,
    required EntryKind? filter,
    required SortOption sort,
    required ViewMode viewMode,
  }) {
    final visible = filter == null
        ? sortEntries(entries, sort)
        : entriesForFilter(entries, _dir, filter);
    _visible = visible;

    if (visible.isEmpty) {
      return _EmptyBrowse(dropping: _dragging);
    }

    return _EntryView(
      dir: _dir,
      entries: visible,
      viewMode: viewMode,
      selected: _selected,
      selecting: _selecting,
      onToggle: _toggleSelect,
      onStartSelection: _startSelection,
    );
  }

  Future<void> _showAddSheet(BuildContext context) async {
    final strings = ref.read(appStringsProvider);

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(strings.newFolder),
              onTap: () {
                Navigator.pop(sheetContext);

                _createFolder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: Text(strings.newNote),
              onTap: () {
                Navigator.pop(sheetContext);

                context.push(newNoteRoute(_dir));
              },
            ),
            ListTile(
              leading: const Icon(Icons.table_chart_outlined),
              title: Text(strings.newTable),
              onTap: () {
                Navigator.pop(sheetContext);

                _createTable();
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: Text(strings.importFiles),
              onTap: () {
                Navigator.pop(sheetContext);

                _pickAndImport();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createFolder() async {
    final strings = ref.read(appStringsProvider);

    final name = await promptForName(
      context,
      title: strings.newFolderTitle,
      label: strings.folderNameLabel,
      confirmLabel: strings.create,
      cancelLabel: strings.cancel,
    );

    if (name == null || name.trim().isEmpty) return;

    try {
      await ref.read(libraryControllerProvider).createFolder(_dir, name.trim());

      if (mounted) _snack(strings.folderCreated(name.trim()));
    } catch (_) {
      if (mounted) _snack(strings.genericError);
    }
  }

  /// Creates an empty table (three columns, one row) and opens it for editing.
  Future<void> _createTable() async {
    final strings = ref.read(appStringsProvider);

    final name = await promptForName(
      context,
      title: strings.newTable,
      label: strings.tableNameLabel,
      confirmLabel: strings.create,
      cancelLabel: strings.cancel,
    );

    if (name == null || name.trim().isEmpty) return;

    const uuid = Uuid();
    final columns = [
      for (var i = 1; i <= 3; i++)
        TableColumnDef(id: uuid.v4(), title: '${strings.columnName} $i'),
    ];
    final table = TableDocument(columns: columns, rows: [
      TableRowData(id: uuid.v4(), cells: {for (final c in columns) c.id: ''}),
    ]);

    try {
      final path = await ref
          .read(libraryControllerProvider)
          .createTable(_dir, name: name.trim(), table: table);

      if (mounted) unawaited(context.push(tableRoute(path)));
    } catch (_) {
      if (mounted) _snack(strings.genericError);
    }
  }

  Future<void> _pickAndImport() async {
    final strings = ref.read(appStringsProvider);

    final result = await AppFilePicker.pickForImport(
      context,
      title: strings.importFiles,
    );

    if (result.paths.isNotEmpty) {
      await _import(result.paths, move: result.move);
    }
  }

  Future<void> _import(List<String> paths, {bool move = false}) async {
    final strings = ref.read(appStringsProvider);

    try {
      final failed = await ref
          .read(libraryControllerProvider)
          .importPaths(_dir, paths, move: move);

      if (mounted) {
        final ok = paths.length - failed.length;
        _snack(move
            ? strings.moveInReport(ok, failed.length)
            : strings.importReport(ok, failed.length));
      }
    } catch (_) {
      if (mounted) _snack(strings.genericError);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SortMenu extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);

    String label(SortOption o) => switch (o) {
          SortOption.nameAsc => strings.sortNameAsc,
          SortOption.nameDesc => strings.sortNameDesc,
          SortOption.newest => strings.sortNewest,
          SortOption.oldest => strings.sortOldest,
          SortOption.sizeAsc => strings.sortSizeAsc,
          SortOption.sizeDesc => strings.sortSizeDesc,
        };

    return PopupMenuButton<SortOption>(
      tooltip: strings.sortBy,
      icon: const Icon(Icons.sort),
      onSelected: (o) => ref.read(browseSortProvider.notifier).state = o,
      itemBuilder: (context) => [
        for (final o in SortOption.values)
          PopupMenuItem(value: o, child: Text(label(o))),
      ],
    );
  }
}

/// Dynamic stat cards for the current folder (recursive: folder + subfolders).

class _DeferredStatsCards extends ConsumerStatefulWidget {
  const _DeferredStatsCards({required this.dir});

  final String dir;

  @override
  ConsumerState<_DeferredStatsCards> createState() =>
      _DeferredStatsCardsState();
}

class _DeferredStatsCardsState extends ConsumerState<_DeferredStatsCards> {
  Timer? _timer;
  bool _loadStats = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _loadStats = true);
    });
  }

  @override
  void didUpdateWidget(covariant _DeferredStatsCards oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dir == widget.dir) return;
    _timer?.cancel();
    _loadStats = false;
    _timer = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _loadStats = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);

    final stats =
        _loadStats ? ref.watch(dirStatsProvider(widget.dir)).value : null;

    final items = <(IconData, String, int?)>[
      (Icons.folder_outlined, strings.folders, stats?.folders),
      (Icons.image_outlined, strings.images, stats?.images),
      (Icons.videocam_outlined, strings.videos, stats?.videos),
      (Icons.notes_outlined, strings.notes, stats?.notes),
      (Icons.table_chart_outlined, strings.tables, stats?.tables),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          for (final (icon, label, value) in items)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    child: Column(
                      children: [
                        Icon(icon,
                            size: 20,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(height: 4),
                        Text(
                          value?.toString() ?? '—',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterBar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);

    final current = ref.watch(browseFilterProvider);

    final options = <(EntryKind?, String)>[
      (null, strings.all),
      (EntryKind.folder, strings.folders),
      (EntryKind.image, strings.images),
      (EntryKind.video, strings.videos),
      (EntryKind.note, strings.notes),
      (EntryKind.table, strings.tables),
    ];

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final (kind, label) in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(label),
                selected: current == kind,
                onSelected: (_) {
                  if (current != kind) {
                    ref.read(browseFilterProvider.notifier).state = kind;
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Breadcrumb extends ConsumerWidget {
  const _Breadcrumb({required this.root, required this.dir});

  final String root;

  final String dir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);

    // Build the chain from root down to the current directory.

    final crumbs = <(String, String)>[(strings.library, root)];

    final rel = p.relative(dir, from: root);

    if (rel != '.') {
      var acc = root;

      for (final seg in p.split(rel)) {
        acc = p.join(acc, seg);

        crumbs.add((seg, acc));
      }
    }

    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: crumbs.length,
        itemBuilder: (context, i) {
          final (label, path) = crumbs[i];

          final isLast = i == crumbs.length - 1;

          return Row(
            children: [
              if (i > 0)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2),
                  child: Icon(Icons.chevron_right, size: 18),
                ),
              TextButton(
                onPressed: isLast ? null : () => context.go(browseRoute(path)),
                child: Text(label),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EntryView extends ConsumerWidget {
  const _EntryView({
    required this.dir,
    required this.entries,
    required this.viewMode,
    required this.selected,
    required this.selecting,
    required this.onToggle,
    required this.onStartSelection,
  });

  final String dir;

  final List<LibraryEntry> entries;

  final ViewMode viewMode;

  final Set<String> selected;

  final bool selecting;

  final void Function(String path) onToggle;

  final void Function(String path) onStartSelection;

  void _tap(BuildContext context, WidgetRef ref, LibraryEntry e) {
    if (selecting) {
      onToggle(e.path);
    } else {
      _open(context, ref, e);
    }
  }

  void _longPress(LibraryEntry e) {
    if (selecting) {
      onToggle(e.path);
    } else {
      onStartSelection(e.path);
    }
  }

  void _open(BuildContext context, WidgetRef ref, LibraryEntry e) {
    if (e.isFolder) {
      ref.read(selectedEntriesProvider.notifier).state = <String>{};
      context.push(folderRoute(e));
    } else if (e.isNote) {
      context.push(noteRoute(e.path));
    } else if (e.isTable) {
      context.push(tableRoute(e.path));
    } else {
      context.push(previewRoute(e.path));
    }
  }

  /// Index folders show what they gather ("Toutes les notes"), not their name.
  String _title(LibraryEntry e, AppStrings strings) => switch (indexKindOf(e)) {
        EntryKind.note => strings.indexAllNotes,
        EntryKind.image => strings.indexAllImages,
        _ => e.displayName,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final compact =
        MediaQuery.sizeOf(context).width < AppConstants.desktopBreakpoint;
    final bottomPadding = AppConstants.defaultPadding +
        MediaQuery.paddingOf(context).bottom +
        (selecting ? 12 : 112);
    final contentPadding = EdgeInsets.fromLTRB(
      AppConstants.defaultPadding,
      AppConstants.defaultPadding,
      AppConstants.defaultPadding,
      bottomPadding,
    );

    if (viewMode == ViewMode.list) {
      return ListView.builder(
        padding: contentPadding,
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final e = entries[i];

          final isSelected = selected.contains(e.path);

          return Card(
            child: ListTile(
              contentPadding: const EdgeInsetsDirectional.only(
                start: 12,
                end: 4,
              ),
              selected: isSelected,
              leading: selecting && !compact
                  ? Checkbox(
                      value: isSelected,
                      onChanged: (_) => onToggle(e.path),
                    )
                  : _SelectableEntryThumb(
                      entry: e,
                      selected: isSelected,
                      selecting: selecting,
                    ),
              title: Text(_title(e, strings)),
              subtitle: indexKindOf(e) != null
                  ? Text(e.name)
                  : e.isFolder
                      ? _tagsLine(e)
                      : _fileSubtitle(e),
              trailing: selecting
                  ? null
                  : _EntryTrailingActions(
                      dir: dir,
                      entry: e,
                      onSelect: () => onStartSelection(e.path),
                    ),
              onTap: () => _tap(context, ref, e),
              onLongPress: () => _longPress(e),
            ),
          );
        },
      );
    }

    final columns = compact ? 2 : 4;

    return GridView.builder(
      padding: contentPadding,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1,
      ),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];

        final isSelected = selected.contains(e.path);

        return Card(
          clipBehavior: Clip.antiAlias,
          shape: isSelected
              ? RoundedRectangleBorder(
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(12),
                )
              : null,
          child: InkWell(
            onTap: () => _tap(context, ref, e),
            onLongPress: () => _longPress(e),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _EntryThumb(entry: e, fill: true),
                      if (selecting && !compact)
                        Positioned(
                          top: 4,
                          left: 4,
                          child: Checkbox(
                            value: isSelected,
                            onChanged: (_) => onToggle(e.path),
                          ),
                        ),
                      if (selecting && compact && isSelected)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Icon(
                            Icons.check_circle,
                            color: Theme.of(context).colorScheme.primary,
                            shadows: const [Shadow(blurRadius: 4)],
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 0, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _title(e, strings),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (!selecting)
                        _EntryTrailingActions(
                          dir: dir,
                          entry: e,
                          dense: true,
                          onSelect: () => onStartSelection(e.path),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget? _tagsLine(LibraryEntry e) =>
      e.tags.isEmpty ? null : _TagBadges(tags: e.tags);

  Widget _fileSubtitle(LibraryEntry e) {
    final kb = e.size / 1024;

    final size = kb < 1024
        ? '${kb.toStringAsFixed(0)} Ko'
        : '${(kb / 1024).toStringAsFixed(1)} Mo';

    if (e.tags.isEmpty) {
      return Text(size, maxLines: 1, overflow: TextOverflow.ellipsis);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(size, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        _TagBadges(tags: e.tags),
      ],
    );
  }
}

class _TagBadges extends StatelessWidget {
  const _TagBadges({required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final tag in tags)
          Container(
            constraints: const BoxConstraints(maxWidth: 120),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: scheme.secondary.withValues(alpha: 0.20),
              ),
            ),
            child: Text(
              tag,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
      ],
    );
  }
}

/// A thumbnail for an entry: real image preview for images, an icon otherwise.

class _EntryThumb extends StatelessWidget {
  const _EntryThumb({required this.entry, this.size, this.fill = false});

  final LibraryEntry entry;

  final double? size;

  final bool fill;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;

    final index = indexKindOf(entry);
    if (index != null) {
      return _IndexFolderThumb(
          images: index == EntryKind.image, size: size, fill: fill);
    }

    if (entry.isImage && canRenderThumbnail(entry.name)) {
      final image = Image.file(
        File(entry.path),
        fit: BoxFit.cover,
        width: fill ? double.infinity : size,
        height: fill ? double.infinity : size,
        gaplessPlayback: true,
        cacheWidth: fill ? 400 : 96,
        errorBuilder: (_, __, ___) =>
            Icon(Icons.broken_image_outlined, color: color, size: size ?? 40),
      );

      if (fill) return image;

      return ClipRRect(borderRadius: BorderRadius.circular(6), child: image);
    }

    final icon = Icon(_iconFor(entry.kind),
        color: color, size: fill ? 40 : (size ?? 24));

    if (fill) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(child: icon),
      );
    }

    return icon;
  }
}

/// The coloured "Pro" look of an `index.note` / `index.img` folder.
class _IndexFolderThumb extends StatelessWidget {
  const _IndexFolderThumb({required this.images, this.size, this.fill = false});

  final bool images;
  final double? size;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final colors = images
        ? const [Color(0xFFEC4899), Color(0xFF8B5CF6)] // pink -> violet
        : const [Color(0xFFF59E0B), Color(0xFFEA580C)]; // amber -> orange
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: colors,
    );
    final icon =
        images ? Icons.photo_library_rounded : Icons.collections_bookmark;

    if (!fill) {
      final side = size ?? 24;
      return Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(side * 0.22),
        ),
        child: Icon(icon, color: Colors.white, size: side * 0.6),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: Stack(
        children: [
          Center(child: Icon(icon, color: Colors.white, size: 44)),
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'PRO',
                style: TextStyle(
                  color: colors.last,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectableEntryThumb extends StatelessWidget {
  const _SelectableEntryThumb({
    required this.entry,
    required this.selected,
    required this.selecting,
  });

  final LibraryEntry entry;
  final bool selected;
  final bool selecting;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(child: _EntryThumb(entry: entry, size: 40)),
          if (selecting && selected)
            Positioned(
              right: -2,
              top: -2,
              child: Icon(
                Icons.check_circle,
                size: 18,
                color: scheme.primary,
                shadows: const [Shadow(blurRadius: 4)],
              ),
            ),
        ],
      ),
    );
  }
}

/// Runs the one-at-a-time Deganeo flow and reports what was saved.
Future<void> _runDeganeo(
  BuildContext context,
  WidgetRef ref,
  List<String> paths,
  String dir,
) async {
  final strings = ref.read(appStringsProvider);
  final outcome = await showDeganeoCleanFlow(
    context,
    paths: paths,
    parentDir: dir,
  );
  if (outcome == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(strings.deganeoSummary(outcome.replaced, outcome.copied)),
    ));
}

class _EntryTrailingActions extends ConsumerWidget {
  const _EntryTrailingActions({
    required this.dir,
    required this.entry,
    required this.onSelect,
    this.dense = false,
  });

  final String dir;

  final LibraryEntry entry;

  final VoidCallback onSelect;

  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final starSize = dense ? 15.0 : 18.0;
    final menuSize = dense ? 30.0 : 36.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (entry.isFavorite)
          Padding(
            padding: EdgeInsetsDirectional.only(end: dense ? 0 : 2),
            child: Icon(
              Icons.star,
              size: starSize,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        if (entry.kind == EntryKind.image)
          SizedBox.square(
            dimension: menuSize,
            child: IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: 'Deganeo',
              icon: DeganeoIcon(size: dense ? 18 : 22),
              onPressed: () => _runDeganeo(context, ref, [entry.path], dir),
            ),
          ),
        SizedBox.square(
          dimension: menuSize,
          child: _EntryMenu(
            dir: dir,
            entry: entry,
            dense: dense,
            onSelect: onSelect,
          ),
        ),
      ],
    );
  }
}

class _EntryMenu extends ConsumerWidget {
  const _EntryMenu({
    required this.dir,
    required this.entry,
    required this.onSelect,
    this.dense = false,
  });

  final String dir;

  final LibraryEntry entry;

  /// Enters selection mode with this entry selected.
  final VoidCallback onSelect;

  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final ctrl = ref.read(libraryControllerProvider);

    Future<void> act(String value) async {
      try {
        switch (value) {
          case 'select':
            onSelect();

          case 'favorite':
            await ctrl.setFavorite(entry.path, !entry.isFavorite,
                parentDir: dir);

          case 'tags':
            if (!context.mounted) return;
            final tags = await _promptTags(context, strings, entry.tags);
            if (tags != null) {
              await ctrl.setTags(entry.path, tags, parentDir: dir);
            }

          case 'rename':
            if (!context.mounted) return;
            final name = await promptForName(
              context,
              title: strings.renameTitle,
              label: strings.nameLabel,
              confirmLabel: strings.save,
              cancelLabel: strings.cancel,
              initialValue: entry.displayName,
            );
            if (name != null && name.trim().isNotEmpty) {
              await ctrl.rename(entry.path, name.trim(), parentDir: dir);
            }

          case 'move':
            if (!context.mounted) return;
            final dests = await AppFilePicker.pick(
              context,
              mode: PickMode.directory,
              title: strings.chooseDestination,
            );
            if (dests.isNotEmpty && !p.equals(dests.first, dir)) {
              await ctrl.move(entry.path, dests.first, parentDir: dir);
            }

          case 'duplicate':
            await ctrl.duplicate(entry.path, parentDir: dir);

          case 'delete':
            if (!context.mounted) return;
            final ok = await confirmDelete(context, strings);
            if (ok == true) {
              await ctrl.moveToTrash(entry.path, parentDir: dir);
            }
        }
      } catch (_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(strings.genericError)));
      }
    }

    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          onPressed: () => act('select'),
          child: Text(strings.selectAction),
        ),
        const Divider(height: 1),
        MenuItemButton(
          onPressed: () => act('favorite'),
          leadingIcon: Icon(
            entry.isFavorite ? Icons.star : Icons.star_border,
            size: 18,
          ),
          child: Text(entry.isFavorite
              ? strings.removeFromFavorites
              : strings.addToFavorites),
        ),
        MenuItemButton(
          onPressed: () => act('tags'),
          leadingIcon: const Icon(Icons.label_outline, size: 18),
          child: Text(strings.editTags),
        ),
        MenuItemButton(
          onPressed: () => act('rename'),
          leadingIcon: const Icon(Icons.drive_file_rename_outline, size: 18),
          child: Text(strings.rename),
        ),
        MenuItemButton(
          onPressed: () => act('move'),
          leadingIcon: const Icon(Icons.drive_file_move_outline, size: 18),
          child: Text(strings.move),
        ),
        MenuItemButton(
          onPressed: () => act('duplicate'),
          leadingIcon: const Icon(Icons.copy_outlined, size: 18),
          child: Text(strings.duplicate),
        ),
        const Divider(height: 1),
        MenuItemButton(
          onPressed: () => act('delete'),
          leadingIcon: Icon(
            Icons.delete_outline,
            size: 18,
            color: Theme.of(context).colorScheme.error,
          ),
          style: MenuItemButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(strings.delete),
        ),
      ],
      builder: (context, menuCtrl, _) => IconButton(
        icon: Icon(Icons.more_vert, size: dense ? 18 : 24),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        tooltip: 'Options',
        onPressed: () {
          if (menuCtrl.isOpen) {
            menuCtrl.close();
          } else {
            menuCtrl.open();
          }
        },
      ),
    );
  }
}

class _EmptyBrowse extends ConsumerWidget {
  const _EmptyBrowse({required this.dropping});

  final bool dropping;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);

    return EmptyState(
      icon: dropping ? Icons.file_download_outlined : Icons.inbox_outlined,
      title: strings.emptyFolderTitle,
      message: dropping ? strings.dropToImport : strings.emptyFolderMessage,
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;

    return IgnorePointer(
      child: Container(
        color: color.withValues(alpha: 0.08),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color, width: 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.file_download_outlined, color: color),
                const SizedBox(width: 8),
                Text(label),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _iconFor(EntryKind kind) {
  switch (kind) {
    case EntryKind.folder:
      return Icons.folder_outlined;

    case EntryKind.note:
      return Icons.description_outlined;

    case EntryKind.image:
      return Icons.image_outlined;

    case EntryKind.video:
      return Icons.videocam_outlined;

    case EntryKind.table:
      return Icons.table_chart_outlined;

    case EntryKind.other:
      return Icons.insert_drive_file_outlined;
  }
}

/// Shared text-input dialog (folder creation, rename).

Future<String?> promptForName(
  BuildContext context, {
  required String title,
  required String label,
  required String confirmLabel,
  required String cancelLabel,
  String? initialValue,
}) {
  return showTextPromptDialog(
    context,
    title: title,
    label: label,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
    initialValue: initialValue,
  );
}

/// Comma-separated tag editor. Returns the parsed list, or null on cancel.

Future<List<String>?> _promptTags(
    BuildContext context, AppStrings strings, List<String> current) {
  final controller = TextEditingController(text: current.join(', '));

  return showAppDialog<List<String>>(
    context,
    builder: (context) => AppDialog(
      title: strings.editTags,
      content: AppTextField(
        controller: controller,
        autofocus: true,
        label: strings.tags,
        hint: strings.tagsHint,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: () {
            final tags = controller.text
                .split(',')
                .map((t) => t.trim().replaceFirst(RegExp(r'^#+'), '').trim())
                .where((t) => t.isNotEmpty)
                .toList();

            Navigator.pop(context, tags);
          },
          child: Text(strings.save),
        ),
      ],
    ),
  );
}

Future<bool?> confirmDelete(BuildContext context, AppStrings strings) {
  return showConfirmDialog(
    context,
    title: strings.deleteTitle,
    message: strings.deleteMessage,
    confirmLabel: strings.delete,
    cancelLabel: strings.cancel,
    destructive: true,
  );
}
