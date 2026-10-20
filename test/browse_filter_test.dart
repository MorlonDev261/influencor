import 'package:influencor/features/library/application/browse_filtering.dart';
import 'package:influencor/features/library/domain/library_entry.dart';
import 'package:influencor/shared/enums/enums.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Builds a fake recursive listing (paths only) the way
/// LibraryRepository.listAllUnder would: a folder entry per directory and a
/// file entry per file, all with absolute paths. Paths are built with
/// [p.join] so the separators match the host platform (Windows uses `\`),
/// exactly like the real filesystem-derived paths the code operates on.
LibraryEntry _folder(String path) => LibraryEntry(
      path: path,
      name: p.basename(path),
      kind: EntryKind.folder,
      size: 0,
      modified: DateTime(2020),
    );

LibraryEntry _file(String path) => LibraryEntry(
      path: path,
      name: p.basename(path),
      kind: kindForFile(p.basename(path)),
      size: 1,
      modified: DateTime(2020),
    );

List<String> _paths(List<LibraryEntry> entries) =>
    entries.map((e) => e.path).toList();

void main() {
  // Base directory the browser is viewing. Everything below is built relative
  // to it with p.join so the test is portable across platforms.
  final dir = p.join('workspace', 'root');
  String at(List<String> segments) => p.joinAll([dir, ...segments]);

  group('entriesForFilter (image)', () {
    test('shows direct files first, then containing folders by proximity', () {
      // dir/
      //   Dossier 1/                              (no image)
      //   Dossier 2/sous1/soussous/img.jpg        (image, depth 4)
      //   Dossier 3/sous1/img.jpg                 (image, depth 3)
      //   fichier img 1.jpg                        (image, depth 1)
      //   fichier img 2.jpg                        (image, depth 1)
      final recursive = <LibraryEntry>[
        _folder(at(['Dossier 1'])),
        _folder(at(['Dossier 2'])),
        _folder(at(['Dossier 2', 'sous1'])),
        _folder(at(['Dossier 2', 'sous1', 'soussous'])),
        _file(at(['Dossier 2', 'sous1', 'soussous', 'img.jpg'])),
        _folder(at(['Dossier 3'])),
        _folder(at(['Dossier 3', 'sous1'])),
        _file(at(['Dossier 3', 'sous1', 'img.jpg'])),
        _file(at(['fichier img 1.jpg'])),
        _file(at(['fichier img 2.jpg'])),
      ];

      final result = entriesForFilter(recursive, dir, EntryKind.image);

      expect(_paths(result), [
        at(['fichier img 1.jpg']),
        at(['fichier img 2.jpg']),
        at(['Dossier 3']), // nearest match at depth 3
        at(['Dossier 2']), // nearest match at depth 4
      ]);
    });

    test('omits folders that contain no match', () {
      final recursive = <LibraryEntry>[
        _folder(at(['Empty'])),
        _folder(at(['Empty', 'deeper'])),
        _file(at(['Empty', 'deeper', 'notes.md'])),
        _folder(at(['HasImage'])),
        _file(at(['HasImage', 'pic.png'])),
      ];

      final result = entriesForFilter(recursive, dir, EntryKind.image);

      expect(_paths(result), [
        at(['HasImage'])
      ]);
    });

    test('uses the shallowest match to rank a folder', () {
      // Folder A holds one shallow and one deep image; ranking uses the shallow
      // one, so it beats folder B whose only match is deeper.
      final recursive = <LibraryEntry>[
        _folder(at(['A'])),
        _file(at(['A', 'near.png'])), // depth 2
        _folder(at(['A', 'deep'])),
        _file(at(['A', 'deep', 'far.png'])), // depth 3
        _folder(at(['B'])),
        _folder(at(['B', 'x'])),
        _file(at(['B', 'x', 'only.png'])), // depth 3
      ];

      final result = entriesForFilter(recursive, dir, EntryKind.image);

      expect(_paths(result), [
        at(['A']),
        at(['B'])
      ]);
    });

    test('surfaces the direct child for media attached to a note deeper down',
        () {
      // Note attachments live in a hidden `.attachments` folder that is never
      // itself a listed folder entry; the match must still surface Dossier.
      final recursive = <LibraryEntry>[
        _folder(at(['Dossier'])),
        _folder(at(['Dossier', 'sub'])),
        _file(at(['Dossier', 'sub', '.attachments', 'pic.jpg'])),
      ];

      final result = entriesForFilter(recursive, dir, EntryKind.image);

      expect(_paths(result), [
        at(['Dossier'])
      ]);
    });

    test('skips the current folder\'s own hidden attachments', () {
      final recursive = <LibraryEntry>[
        _file(at(['.attachments', 'pic.jpg'])),
        _folder(at(['Real'])),
        _file(at(['Real', 'pic.png'])),
      ];

      final result = entriesForFilter(recursive, dir, EntryKind.image);

      // Only the folder with a real, browsable image — the current folder's own
      // hidden attachment is not a surfaceable entry.
      expect(_paths(result), [
        at(['Real'])
      ]);
    });
  });

  group('entriesForFilter (folder)', () {
    test('lists the direct sub-folders by name', () {
      final recursive = <LibraryEntry>[
        _folder(at(['Beta'])),
        _folder(at(['Alpha'])),
        _folder(at(['Alpha', 'nested'])), // not a direct child
        _file(at(['loose.png'])),
      ];

      final result = entriesForFilter(recursive, dir, EntryKind.folder);

      expect(_paths(result), [
        at(['Alpha']),
        at(['Beta'])
      ]);
    });
  });

  group('sortEntries', () {
    test('puts folders first, then sorts by name ascending', () {
      final entries = <LibraryEntry>[
        _file(at(['b.png'])),
        _folder(at(['Zeta'])),
        _file(at(['a.png'])),
        _folder(at(['Alpha'])),
      ];

      final result = sortEntries(entries, SortOption.nameAsc);

      expect(_paths(result), [
        at(['Alpha']),
        at(['Zeta']),
        at(['a.png']),
        at(['b.png']),
      ]);
    });
  });

  group('index folders (index.note / index.img)', () {
    test('only folders with the exact name (any case) are index folders', () {
      expect(indexKindOf(_folder(at(['index.note']))), EntryKind.note);
      expect(indexKindOf(_folder(at(['INDEX.IMG']))), EntryKind.image);
      expect(indexKindOf(_folder(at(['index.notes']))), isNull);
      expect(indexKindOf(_folder(at(['Mes notes']))), isNull);
      // A note titled "index.note" is a file, not the Pro folder.
      expect(indexKindOf(_file(at(['index.note.md']))), isNull);
    });

    test('gathers every match however deep, nothing else', () {
      final recursive = [
        _folder(at(['index.note'])),
        _file(at(['a.md'])),
        _folder(at(['A'])),
        _folder(at(['A', 'B'])),
        _folder(at(['A', 'B', 'C'])),
        _file(at(['A', 'B', 'C', 'deep.md'])),
        _file(at(['A', 'photo.png'])),
        _file(at(['A', 'B', 'mid.md'])),
      ];
      expect(
          _paths(indexedEntries(recursive, EntryKind.note, SortOption.nameAsc)),
          [
            at(['a.md']),
            at(['A', 'B', 'C', 'deep.md']),
            at(['A', 'B', 'mid.md']),
          ]);
      expect(
          _paths(
              indexedEntries(recursive, EntryKind.image, SortOption.nameAsc)),
          [
            at(['A', 'photo.png'])
          ]);
    });
  });
}
