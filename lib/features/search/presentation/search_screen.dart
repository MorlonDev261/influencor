import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../app/constants/app_constants.dart';
import '../../../app/nav.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/providers/workspace_providers.dart';
import '../../../core/widgets/empty_state.dart';
import '../../library/application/library_providers.dart';
import '../../library/domain/library_entry.dart';
import '../application/entry_search.dart';

/// Global search over the whole workspace (names + tags), with a kind filter
/// and a 300 ms debounce.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({this.initialQuery, super.key});

  /// Optional query to pre-fill the field with (e.g. from the header search).
  final String? initialQuery;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  EntryKind? _filter;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuery?.trim() ?? '';
    if (initial.isNotEmpty) {
      _controller.text = initial;
      _query = initial;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(AppConstants.searchDebounce, () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  void _open(LibraryEntry e, List<LibraryEntry> results) {
    if (e.isFolder) {
      context.push(folderRoute(e));
    } else if (e.isNote) {
      context.push(noteRoute(e.path));
    } else if (e.isTable) {
      context.push(tableRoute(e.path));
    } else {
      context.push(
        previewRoute(e.path),
        extra: [
          for (final r in results)
            if (!r.isFolder && !r.isNote && !r.isTable) r.path,
        ],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final root = ref.watch(workspaceRootProvider);
    final index = ref.watch(libraryIndexProvider);

    return Scaffold(
      appBar: AppBar(title: Text(strings.search)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: strings.searchHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          _FilterBar(
            current: _filter,
            onChanged: (k) => setState(() => _filter = k),
          ),
          Expanded(
            child: index.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(strings.genericError)),
              data: (all) {
                final results = all
                    .where((e) => _filter == null || e.kind == _filter)
                    .where((e) => entryMatchesQuery(e, _query))
                    .toList();
                if (_query.isEmpty && _filter == null) {
                  return EmptyState(
                    icon: Icons.search,
                    title: strings.search,
                    message: strings.searchPrompt,
                  );
                }
                if (results.isEmpty) {
                  return EmptyState(
                    icon: Icons.search_off,
                    title: strings.noResults,
                    message: strings.searchHint,
                  );
                }
                return ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    0,
                    0,
                    0,
                    MediaQuery.paddingOf(context).bottom + 88,
                  ),
                  itemCount: results.length,
                  itemBuilder: (context, i) {
                    final e = results[i];
                    final folder = root == null
                        ? ''
                        : p.dirname(p.relative(e.path, from: root));
                    return ListTile(
                      leading: Icon(_iconFor(e.kind)),
                      title: Text(e.displayName),
                      subtitle: Text(folder == '.'
                          ? strings.library
                          : '${strings.inFolder} $folder'),
                      trailing: e.isFavorite
                          ? const Icon(Icons.star, size: 16)
                          : null,
                      onTap: () => _open(e, results),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.current, required this.onChanged});

  final EntryKind? current;
  final ValueChanged<EntryKind?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
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
                onSelected: (_) => onChanged(kind),
              ),
            ),
        ],
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
