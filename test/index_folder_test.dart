import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:influencor/app/nav.dart';
import 'package:influencor/core/providers/workspace_providers.dart';
import 'package:influencor/features/library/presentation/browse_screen.dart';
import 'package:influencor/features/library/presentation/index_screen.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('index_folder_test_');
    await Directory(p.join(tmp.path, 'index.note')).create();
    await Directory(p.join(tmp.path, 'Clients', 'Ana')).create(recursive: true);
    await File(p.join(tmp.path, 'Clients', 'Ana', 'Brief.md'))
        .writeAsString('x');
    await File(p.join(tmp.path, 'Racine.md')).writeAsString('y');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  testWidgets('tapping index.note lists every note below', (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/browse',
      routes: [
        GoRoute(
          path: '/browse',
          builder: (_, __) => BrowseScreen(dirPath: tmp.path),
        ),
        GoRoute(
          path: '/index',
          builder: (_, state) => IndexScreen(
            dir: state.uri.queryParameters['dir']!,
            images: state.uri.queryParameters['kind'] == 'image',
          ),
        ),
      ],
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [workspaceRootProvider.overrideWithValue(tmp.path)],
        child: MaterialApp.router(routerConfig: router),
      ));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.tap(find.text('All notes').first);
    await tester.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(find.text('Brief'), findsOneWidget);
    expect(find.text('Racine'), findsOneWidget);
  });

  test('a link to an index folder opens the gathered view', () {
    final route = Uri.parse(directoryRoute(p.join(tmp.path, 'INDEX.IMG')));
    expect(route.path, '/index');
    expect(route.queryParameters['kind'], 'image');
    expect(p.equals(route.queryParameters['dir']!, tmp.path), isTrue);
    expect(
        Uri.parse(directoryRoute(p.join(tmp.path, 'Clients'))).path, '/browse');
  });
}
