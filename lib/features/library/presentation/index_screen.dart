import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../app/constants/app_constants.dart';
import '../../../app/nav.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/widgets/empty_state.dart';
import '../application/browse_filtering.dart';
import '../application/library_providers.dart';
import '../domain/library_entry.dart';

/// What an `index.note` / `index.img` folder opens: every note (or image) of
/// [dir] and of all its sub-folders, however deep, in one flat list.
class IndexScreen extends ConsumerStatefulWidget {
  const IndexScreen({required this.dir, required this.images, super.key});

  /// The folder the index folder sits in (the scope of the listing).
  final String dir;

  /// true for `index.img` (image grid), false for `index.note` (note list).
  final bool images;

  @override
  ConsumerState<IndexScreen> createState() => _IndexScreenState();
}

class _IndexScreenState extends ConsumerState<IndexScreen> {
  String get dir => widget.dir;
  bool get images => widget.images;

  @override
  void initState() {
    super.initState();
    // The recursive listing is cached and, on Android / iOS, does not watch
    // the disk: re-read it so files added from outside the app show up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(dirRecursiveProvider(dir));
    });
  }

  Future<void> _refresh() => ref.refresh(dirRecursiveProvider(dir).future);

  /// Where [e] lives, relative to [dir] ("" when right here).
  String _location(LibraryEntry e) {
    final rel = p.relative(p.dirname(e.path), from: dir);
    return rel == '.' ? '' : p.split(rel).join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final sort = ref.watch(browseSortProvider);
    final listing = ref.watch(dirRecursiveProvider(dir));
    final kind = images ? EntryKind.image : EntryKind.note;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(images ? strings.indexAllImages : strings.indexAllNotes),
            Text(
              p.basename(dir),
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: strings.refresh,
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: listing.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => Center(child: Text(strings.genericError)),
        data: (all) {
          final items = indexedEntries(all, kind, sort);
          if (items.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: constraints.maxHeight,
                    child: EmptyState(
                      icon: images
                          ? Icons.image_outlined
                          : Icons.description_outlined,
                      title: images
                          ? strings.indexAllImages
                          : strings.indexAllNotes,
                      message: strings.indexEmpty,
                    ),
                  ),
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: images
                ? _ImageGrid(items: items, location: _location)
                : _NoteList(
                    items: items, location: _location, strings: strings),
          );
        },
      ),
    );
  }
}

class _NoteList extends StatelessWidget {
  const _NoteList({
    required this.items,
    required this.location,
    required this.strings,
  });

  final List<LibraryEntry> items;
  final String Function(LibraryEntry) location;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(AppConstants.defaultPadding),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final e = items[i];
        final where = location(e);
        return Card(
          child: ListTile(
            leading: Icon(
              Icons.description_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(e.displayName),
            subtitle: Text(
              where.isEmpty ? strings.library : '${strings.inFolder} $where',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => context.push(noteRoute(e.path)),
          ),
        );
      },
    );
  }
}

class _ImageGrid extends StatelessWidget {
  const _ImageGrid({required this.items, required this.location});

  final List<LibraryEntry> items;
  final String Function(LibraryEntry) location;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact =
        MediaQuery.sizeOf(context).width < AppConstants.desktopBreakpoint;
    final paths = [for (final e in items) e.path];
    return GridView.builder(
      padding: const EdgeInsets.all(AppConstants.defaultPadding),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: compact ? 3 : 6,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final e = items[i];
        final where = location(e);
        return Tooltip(
          message: where.isEmpty ? e.name : '$where / ${e.name}',
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            // Swipe through every image of the index, not just the folder's.
            onTap: () => context.push(previewRoute(e.path), extra: paths),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: canRenderThumbnail(e.name)
                  ? Image.file(
                      File(e.path),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      cacheWidth: 300,
                      errorBuilder: (_, __, ___) => ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: const Icon(Icons.broken_image_outlined),
                      ),
                    )
                  : ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(Icons.image_outlined, color: scheme.primary),
                    ),
            ),
          ),
        );
      },
    );
  }
}
