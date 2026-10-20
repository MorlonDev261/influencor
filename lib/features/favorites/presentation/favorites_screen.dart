import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../app/nav.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/providers/workspace_providers.dart';
import '../../../core/widgets/empty_state.dart';
import '../../library/application/library_providers.dart';
import '../../library/domain/library_entry.dart';

/// Lists every favorite entry across the workspace.
class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  void _open(BuildContext context, LibraryEntry e) {
    if (e.isFolder) {
      context.push(folderRoute(e));
    } else if (e.isNote) {
      context.push(noteRoute(e.path));
    } else if (e.isTable) {
      context.push(tableRoute(e.path));
    } else {
      context.push(previewRoute(e.path));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final root = ref.watch(workspaceRootProvider);
    final favorites = ref.watch(favoritesProvider);
    final controller = ref.read(libraryControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text(strings.favorites)),
      body: favorites.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(strings.genericError)),
        data: (items) {
          if (items.isEmpty) {
            return EmptyState(
              icon: Icons.star_border,
              title: strings.favorites,
              message: strings.favoritesEmpty,
            );
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final e = items[i];
              final folder =
                  root == null ? '' : p.dirname(p.relative(e.path, from: root));
              return ListTile(
                leading: Icon(_iconFor(e.kind)),
                title: Text(e.displayName),
                subtitle: Text(folder == '.'
                    ? strings.library
                    : '${strings.inFolder} $folder'),
                trailing: IconButton(
                  tooltip: strings.removeFromFavorites,
                  icon: const Icon(Icons.star),
                  onPressed: () async {
                    try {
                      await controller.setFavorite(e.path, false,
                          parentDir: p.dirname(e.path));
                    } catch (_) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context)
                        ..clearSnackBars()
                        ..showSnackBar(
                            SnackBar(content: Text(strings.genericError)));
                    }
                  },
                ),
                onTap: () => _open(context, e),
              );
            },
          );
        },
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
