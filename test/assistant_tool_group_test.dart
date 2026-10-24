import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/core/l10n/app_strings.dart';
import 'package:influencor/features/assistant/application/assistant_providers.dart';
import 'package:influencor/features/assistant/presentation/assistant_transcript.dart';

void main() {
  final start = DateTime(2026, 10, 24, 10);
  final items = [
    ChatItem(
      kind: ChatItemKind.tool,
      text: 'Recherche',
      toolName: 'search_library',
      args: const {'query': 'prix'},
      result: '{"total": 3}',
      startedAt: start,
      endedAt: start.add(const Duration(seconds: 2)),
    ),
    const ChatItem(kind: ChatItemKind.thinking, text: 'Je lis la note.'),
    ChatItem(
      kind: ChatItemKind.tool,
      text: 'Lecture de la note',
      toolName: 'read_note',
      args: const {'path': 'a.md'},
      result: '{"content": "abc"}',
      startedAt: start.add(const Duration(seconds: 3)),
      endedAt: start.add(const Duration(seconds: 5)),
    ),
  ];

  Future<void> pump(WidgetTester tester, {required bool live}) =>
      tester.pumpWidget(ProviderScope(
        overrides: [
          appStringsProvider.overrideWithValue(const AppStrings(Locale('fr'))),
        ],
        child: MaterialApp(
          home: Scaffold(body: ToolGroup(items: items, live: live)),
        ),
      ));

  testWidgets('while working, every step shows', (tester) async {
    await pump(tester, live: true);
    expect(find.text('2 actions'), findsNothing);
    expect(find.textContaining('Recherche'), findsOneWidget);
    expect(find.textContaining('Lecture de la note'), findsOneWidget);
  });

  testWidgets('once done, the steps fold to one line and unfold on tap',
      (tester) async {
    await pump(tester, live: false);
    expect(find.textContaining('2 actions'), findsOneWidget);
    expect(find.textContaining('5.0 s'), findsOneWidget);
    expect(find.text('Recherche, Lecture de la note'), findsOneWidget);
    expect(find.byType(ToolActivity), findsNothing);

    await tester.tap(find.textContaining('2 actions'));
    await tester.pump();
    expect(find.byType(ToolActivity), findsNWidgets(2));
    expect(find.byType(ThinkingBlock), findsOneWidget);

    await tester.tap(find.textContaining('2 actions'));
    await tester.pump();
    expect(find.byType(ToolActivity), findsNothing);
  });
}
