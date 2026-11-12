import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/core/providers/workspace_providers.dart';
import 'package:influencor/features/assistant/application/agent_tool.dart';
import 'package:influencor/features/assistant/application/tools/library_tools.dart';
import 'package:influencor/features/library/presentation/index_screen.dart';
import 'package:path/path.dart' as p;

// A 1×1 transparent PNG.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

void main() {
  late Directory tmp;
  late String clients;

  Future<void> file(List<String> parts, [List<int>? bytes]) async {
    final f = File(p.joinAll([tmp.path, ...parts]));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes ?? utf8.encode('x'));
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('index_scope_test_');
    clients = p.join(tmp.path, 'Clients');
    await Directory(p.join(clients, 'index.img')).create(recursive: true);
    await Directory(p.join(clients, 'Index.Note')).create();
    await file(['Clients', 'Ana', 'photo.png'], _png);
    await file(['Clients', 'Ana', 'Shoot', 'scan.HEIC']); // not decodable
    await file(['Clients', 'Ana', 'Brief.md']);
    await file(['Clients', 'clip.mov']); // a video, not an image
    await file(['Clients', 'Ana', '.attachments', 'joint.png'], _png);
    await file(['Autres', 'ailleurs.png'], _png); // outside the scope
    await file(['Autres', 'ailleurs.md']);
    await file(['.clipboard', 'trash', 'jeté.png'], _png); // in the trash
    await file(['Clients', '.cache', 'cache.png'], _png); // hidden folder
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('Degany list_folder on an index folder', () {
    Future<List<String>> listed(String folder) async {
      final container = ProviderContainer(
          overrides: [workspaceRootProvider.overrideWithValue(tmp.path)]);
      addTearDown(container.dispose);
      final ctxProvider = Provider(
          (ref) => AgentToolContext(ref: ref, confirm: (_, __) async => true));
      final tool = libraryTools().firstWhere((t) => t.name == 'list_folder');
      final out = await tool.run(
        ToolArgs({'path': folder}),
        container.read(ctxProvider),
      ) as Map;
      return [
        for (final e in out['entries'] as List) (e as Map)['path'] as String
      ]..sort();
    }

    test('index.img: images of its folder only, any depth', () async {
      expect(await listed('Clients/index.img'), [
        'Clients/Ana/.attachments/joint.png',
        'Clients/Ana/Shoot/scan.HEIC',
        'Clients/Ana/photo.png',
      ]);
    });

    test('index.note (any case): notes of its folder only', () async {
      expect(await listed('Clients/Index.Note'), ['Clients/Ana/Brief.md']);
    });
  });

  testWidgets('index.img shows the grid of its folder, HEIC included',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [workspaceRootProvider.overrideWithValue(tmp.path)],
        child: MaterialApp(home: IndexScreen(dir: clients, images: true)),
      ));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    final tips = [
      for (final t in tester.widgetList<Tooltip>(find.descendant(
          of: find.byType(GridView), matching: find.byType(Tooltip))))
        t.message
    ];
    expect(tips, hasLength(3));
    expect(tips, contains('Ana / photo.png'));
    expect(tips, contains('Ana / Shoot / scan.HEIC'));
    // A note's hidden attachments folder is named, not shown as ".attachments".
    expect(tips, contains('Ana / Attachments / joint.png'));
    expect(tips.any((t) => t!.contains('.attachments')), isFalse);
    expect(tips.any((t) => t!.contains('ailleurs')), isFalse);
    expect(tips.any((t) => t!.contains('jeté')), isFalse);
    expect(tips.any((t) => t!.contains('cache')), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('index.note lists only the notes of its folder', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [workspaceRootProvider.overrideWithValue(tmp.path)],
        child: MaterialApp(home: IndexScreen(dir: clients, images: false)),
      ));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(find.text('Brief'), findsOneWidget);
    expect(find.text('ailleurs'), findsNothing);
  });
}
