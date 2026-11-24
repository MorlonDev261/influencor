import 'dart:io';

import 'package:influencor/features/library/data/library_repository.dart';
import 'package:influencor/features/library/data/metadata_store.dart';
import 'package:influencor/features/library/data/trash_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workspace;
  late Directory outside;
  late LibraryRepository repo;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('clipboard_import_ws_');
    outside = await Directory.systemTemp.createTemp('clipboard_import_src_');
    repo = LibraryRepository(
      root: workspace.path,
      metadata: MetadataStore(workspace.path),
      trash: TrashStore(workspace.path),
    );
  });

  tearDown(() async {
    for (final dir in [workspace, outside]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  test('importPaths copies a file into the destination', () async {
    final src = File(p.join(outside.path, 'photo.jpg'))
      ..writeAsBytesSync([1, 2, 3]);

    final failed = await repo.importPaths(workspace.path, [src.path]);

    expect(failed, isEmpty);
    final copy = File(p.join(workspace.path, 'photo.jpg'));
    expect(await copy.exists(), isTrue);
    expect(await copy.readAsBytes(), [1, 2, 3]);
    // Source untouched — import copies, it doesn't move.
    expect(await src.exists(), isTrue);
  });

  test('importPaths copies a whole folder recursively', () async {
    final srcDir = Directory(p.join(outside.path, 'album'))..createSync();
    File(p.join(srcDir.path, 'a.png')).writeAsBytesSync([1]);
    final nested = Directory(p.join(srcDir.path, 'nested'))..createSync();
    File(p.join(nested.path, 'b.png')).writeAsBytesSync([2]);

    final failed = await repo.importPaths(workspace.path, [srcDir.path]);

    expect(failed, isEmpty);
    expect(
        await File(p.join(workspace.path, 'album', 'a.png')).exists(), isTrue);
    expect(
        await File(p.join(workspace.path, 'album', 'nested', 'b.png')).exists(),
        isTrue);
  });

  test('importPaths converts txt files to md and avoids collisions', () async {
    File(p.join(workspace.path, 'doc.md')).writeAsStringSync('existing');
    final src = File(p.join(outside.path, 'doc.txt'))
      ..writeAsStringSync('incoming');

    final failed = await repo.importPaths(workspace.path, [src.path]);

    expect(failed, isEmpty);
    expect(await File(p.join(workspace.path, 'doc.md')).readAsString(),
        'existing');
    expect(await File(p.join(workspace.path, 'doc (1).md')).readAsString(),
        'incoming');
  });

  test('importPaths reports missing sources as failed without throwing',
      () async {
    final missing = p.join(outside.path, 'does_not_exist.txt');

    final failed = await repo.importPaths(workspace.path, [missing]);

    expect(failed, [missing]);
  });

  test('importPaths with move deletes the source file after copying', () async {
    final src = File(p.join(outside.path, 'photo.jpg'))
      ..writeAsBytesSync([1, 2, 3]);

    final failed =
        await repo.importPaths(workspace.path, [src.path], move: true);

    expect(failed, isEmpty);
    expect(await File(p.join(workspace.path, 'photo.jpg')).readAsBytes(),
        [1, 2, 3]);
    expect(await src.exists(), isFalse);
  });

  test('importPaths with move deletes the source folder after copying',
      () async {
    final srcDir = Directory(p.join(outside.path, 'album'))..createSync();
    File(p.join(srcDir.path, 'a.png')).writeAsBytesSync([1]);

    final failed =
        await repo.importPaths(workspace.path, [srcDir.path], move: true);

    expect(failed, isEmpty);
    expect(
        await File(p.join(workspace.path, 'album', 'a.png')).exists(), isTrue);
    expect(await srcDir.exists(), isFalse);
  });

  test('importPaths imports several files in one call, skipping failures',
      () async {
    final ok1 = File(p.join(outside.path, 'one.txt'))..writeAsStringSync('1');
    final ok2 = File(p.join(outside.path, 'two.txt'))..writeAsStringSync('2');
    final missing = p.join(outside.path, 'missing.txt');

    final failed = await repo.importPaths(
      workspace.path,
      [ok1.path, missing, ok2.path],
    );

    expect(failed, [missing]);
    expect(await File(p.join(workspace.path, 'one.md')).exists(), isTrue);
    expect(await File(p.join(workspace.path, 'two.md')).exists(), isTrue);
  });

  test('importPaths imports compatible table json and generic json files',
      () async {
    final table = File(p.join(outside.path, 'table.json'))
      ..writeAsStringSync('''
{
  "type": "influencor.table",
  "version": 1,
  "columns": [{"id": "name", "title": "Name", "type": "text"}],
  "rows": [{"id": "row-1", "cells": {"name": "Ada"}}]
}
''');
    final invalid = File(p.join(outside.path, 'data.json'))
      ..writeAsStringSync('{"hello": "world"}');

    final failed =
        await repo.importPaths(workspace.path, [table.path, invalid.path]);

    expect(failed, isEmpty);
    expect(await File(p.join(workspace.path, 'table.json')).exists(), isTrue);
    expect(await File(p.join(workspace.path, 'data.json')).exists(), isTrue);
  });

  test('importPaths copies folders recursively including generic files',
      () async {
    final srcDir = Directory(p.join(outside.path, 'mixed'))..createSync();
    File(p.join(srcDir.path, 'ignored.pdf')).writeAsBytesSync([9]);
    final deep = Directory(p.join(srcDir.path, 'a', 'b'))
      ..createSync(recursive: true);
    File(p.join(deep.path, 'note.txt')).writeAsStringSync('hello');

    final failed = await repo.importPaths(workspace.path, [srcDir.path]);

    expect(failed, isEmpty);
    expect(await File(p.join(workspace.path, 'mixed', 'ignored.pdf')).exists(),
        isTrue);
    expect(
      await File(p.join(workspace.path, 'mixed', 'a', 'b', 'note.md')).exists(),
      isTrue,
    );
  });

  group('storeCleanedIn (Deganeo folder for files from outside)', () {
    late File source;
    late File cleaned;
    late String deganeo;

    setUp(() {
      source = File(p.join(outside.path, 'IMG_1.jpg'))..writeAsBytesSync([9]);
      cleaned = File(p.join(outside.path, 'tmp_clean.jpg'))
        ..writeAsBytesSync([1, 2]);
      deganeo = p.join(workspace.path, 'Deganeo');
    });

    test('a copy is saved as name_clean in a created Deganeo folder', () async {
      final out = await repo.storeCleanedIn(deganeo, source.path, cleaned.path);

      expect(out, p.join(deganeo, 'IMG_1_clean.jpg'));
      expect(await File(out).readAsBytes(), [1, 2]);
      expect(await source.readAsBytes(), [9]); // original untouched
    });

    test('replace keeps the name and never overwrites', () async {
      final first = await repo
          .storeCleanedIn(deganeo, source.path, cleaned.path, keepName: true);
      final second = await repo
          .storeCleanedIn(deganeo, source.path, cleaned.path, keepName: true);

      expect(first, p.join(deganeo, 'IMG_1.jpg'));
      expect(second, isNot(first));
      expect(p.dirname(second), deganeo);
      expect(await File(first).exists(), isTrue);
      expect(await source.readAsBytes(), [9]); // original untouched
    });
  });
}
