import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:influencor/core/l10n/app_strings.dart';
import 'package:influencor/core/providers/workspace_providers.dart';
import 'package:influencor/features/assistant/presentation/assistant_transcript.dart';
import 'package:influencor/features/assistant/presentation/rich/app_blocks.dart';
import 'package:influencor/features/assistant/presentation/rich/chat_image.dart';
import 'package:influencor/features/assistant/presentation/rich/markdown_blocks.dart';
import 'package:path/path.dart' as p;

// A 1×1 transparent PNG.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

void main() {
  late Directory tmp;
  String at(String name) => p.join(tmp.path, name);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('chat_images_');
    for (final n in [
      'a.png',
      'b.png',
      for (var i = 0; i < 14; i++) 'g$i.png'
    ]) {
      File(at(n)).writeAsBytesSync(_png);
    }
    File(at('c.heic')).writeAsStringSync('x');
    File(at('doc.pdf')).writeAsStringSync('x');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('image markdown: syntax and plain text', () {
    final m = markdownImage.firstMatch('Voici ![La robe](Photos/a.png "x") !')!;
    expect(m.group(1), 'La robe');
    expect(m.group(2), 'Photos/a.png');
    expect(plainInline('![Robe](a.png) en wax'), 'Robe en wax');
  });

  test('image sources: workspace files and web images only', () {
    expect(chatImageSource('a.png', tmp.path)?.file, at('a.png'));
    expect(chatImageSource('https://x.mg/p.jpg', tmp.path)?.url?.host, 'x.mg');
    expect(chatImageSource('../../outside.png', tmp.path), isNull);
    expect(chatImageSource('c.heic', tmp.path)!.drawable, isFalse);
  });

  Future<List<Object?>> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final opened = <Object?>[];
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => Scaffold(body: SingleChildScrollView(child: child)),
      ),
      GoRoute(
        path: '/preview',
        builder: (_, state) {
          opened
            ..add(state.uri.queryParameters['path'])
            ..add(state.extra);
          return const Text('viewer');
        },
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appStringsProvider.overrideWithValue(const AppStrings(Locale('fr'))),
        workspaceRootProvider.overrideWithValue(tmp.path),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    return opened;
  }

  testWidgets('a Markdown image shows whole with its caption, and opens',
      (tester) async {
    final opened = await pump(
        tester,
        const RichMessage(
            text: 'Voici la photo :\n\n![La robe wax](a.png)',
            color: Colors.black));
    expect(find.text('Voici la photo :'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('La robe wax'), findsOneWidget);
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    expect(opened, [
      at('a.png'),
      [at('a.png')]
    ]);
  });

  testWidgets('several images: a grid; HEIC as a tile; outside as caption',
      (tester) async {
    await pump(
        tester,
        const RichMessage(
            text: '![](a.png) ![](b.png) ![](c.heic)\n\n![Secret](../x.png)',
            color: Colors.black));
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('HEIC'), findsOneWidget);
    expect(find.text('Secret'), findsOneWidget);
    expect(find.byIcon(Icons.hide_image_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a big gallery ends with "+N" and swipes through all',
      (tester) async {
    final opened = await pump(
        tester,
        GalleryBlock(json: {
          'paths': [for (var i = 0; i < 14; i++) 'g$i.png']
        }));
    expect(find.byType(Image), findsNWidgets(ChatImageGallery.maxTiles));
    expect(find.text('+3'), findsOneWidget);
    await tester.tap(find.byType(InkWell).at(1));
    await tester.pumpAndSettle();
    expect(opened.first, at('g1.png'));
    expect(opened.last, hasLength(14));
  });

  testWidgets("the user's pictures show as pictures, other files as tiles",
      (tester) async {
    await pump(
        tester,
        UserMessage(
            text: 'Regarde', attachments: [at('a.png'), at('doc.pdf')]));
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(AttachmentTile), findsOneWidget);
    expect(find.text('doc.pdf'), findsOneWidget);
  });
}
