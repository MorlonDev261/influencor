import 'package:path/path.dart' as p;

import '../../../shared/enums/enums.dart';
import '../domain/library_entry.dart';

/// Pure, UI-independent logic for the library browser's kind filters and
/// sorting. It lives outside the widget layer so it can be unit-tested without
/// a filesystem or a widget tree.

/// Builds the browser's view for a kind [filter] from the recursive listing of
/// [dir] (the folder plus all its sub-folders, as produced by
/// `LibraryRepository.listAllUnder`). Nothing that lives inside a sub-folder is
/// shown directly. Instead:
///   * matching files that live right in [dir] are shown as themselves, and
///   * for a match nested anywhere below, the *direct* sub-folder of [dir] that
///     leads to it is surfaced once (a match in `Dossier/a/b/img` surfaces
///     `Dossier`), so the user drills into that folder to reach it.
///
/// Results are ordered by proximity — the shallowest (closest) match first — so
/// matching files right here (depth 1) come before folders, and a folder whose
/// nearest match is closer ranks above one whose match sits deeper. Folders
/// with no match are omitted. Under the folder filter the direct sub-folders
/// are simply listed by name.
List<LibraryEntry> entriesForFilter(
    List<LibraryEntry> recursive, String dir, EntryKind filter) {
  if (filter == EntryKind.folder) {
    final folders = recursive
        .where((e) => e.isFolder && p.equals(p.dirname(e.path), dir))
        .toList();
    return sortEntries(folders, SortOption.nameAsc);
  }

  // Direct children of `dir`, indexed by path: the level we surface results at.
  final directChildren = <String, LibraryEntry>{
    for (final e in recursive)
      if (p.equals(p.dirname(e.path), dir)) e.path: e,
  };

  // Map each match to the direct child of `dir` that leads to it, keeping the
  // shallowest match depth per child (1 = a matching file right here, 2 =
  // directly inside a sub-folder, and so on).
  final bestDepth = <String, int>{};
  for (final e in recursive) {
    if (e.kind != filter) continue;
    final segments = p.split(p.relative(e.path, from: dir));
    if (segments.isEmpty) continue;
    final childPath = p.join(dir, segments.first);
    // Only surface it if the leading segment is a real, browsable direct child
    // (skips e.g. media in this folder's own hidden `.attachments`).
    if (!directChildren.containsKey(childPath)) continue;
    final depth = segments.length;
    bestDepth.update(childPath, (d) => depth < d ? depth : d,
        ifAbsent: () => depth);
  }

  final scored = [
    for (final entry in bestDepth.entries)
      (directChildren[entry.key]!, entry.value),
  ];
  scored.sort((a, b) {
    final byDepth = a.$2.compareTo(b.$2); // shallowest (closest) match first
    if (byDepth != 0) return byDepth;
    return a.$1.displayName
        .toLowerCase()
        .compareTo(b.$1.displayName.toLowerCase());
  });
  return [for (final s in scored) s.$1];
}

/// Every entry of [kind] in a recursive listing (see `indexKindOf`): the flat
/// view an `index.note` / `index.img` folder opens, however deep each item is.
List<LibraryEntry> indexedEntries(
        List<LibraryEntry> recursive, EntryKind kind, SortOption sort) =>
    sortEntries([
      for (final e in recursive)
        if (e.kind == kind) e
    ], sort);

/// Sorts entries with folders first, then by the chosen [sort] option.
List<LibraryEntry> sortEntries(List<LibraryEntry> entries, SortOption sort) {
  final sorted = [...entries];
  int name(LibraryEntry a, LibraryEntry b) =>
      a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  sorted.sort((a, b) {
    if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
    switch (sort) {
      case SortOption.nameAsc:
        return name(a, b);
      case SortOption.nameDesc:
        return name(b, a);
      case SortOption.newest:
        return b.modified.compareTo(a.modified);
      case SortOption.oldest:
        return a.modified.compareTo(b.modified);
      case SortOption.sizeAsc:
        return a.size.compareTo(b.size);
      case SortOption.sizeDesc:
        return b.size.compareTo(a.size);
    }
  });
  return sorted;
}
