import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/core/l10n/app_strings.dart';
import 'package:influencor/core/providers/workspace_providers.dart';
import 'package:influencor/features/assistant/application/assistant_providers.dart';
import 'package:influencor/features/assistant/data/chat_store.dart';
import 'package:influencor/features/assistant/presentation/assistant_transcript.dart';
import 'package:influencor/features/assistant/presentation/rich/chart_block.dart';
import 'package:influencor/features/assistant/presentation/rich/diagram_block.dart';
import 'package:influencor/features/assistant/presentation/rich/markdown_blocks.dart';
import 'package:influencor/features/assistant/presentation/rich/rich_common.dart';
import 'package:influencor/features/assistant/presentation/rich/rich_message.dart'
    show MarkdownTable;

void main() {
  group('markdown blocks', () {
    test('tables, with alignment and short rows padded', () {
      final blocks = parseMarkdown('Voici :\n\n'
          '| Produit | Prix |\n'
          '| :--- | ---: |\n'
          '| Savon | 2 500 Ar |\n'
          '| Huile |\n');
      expect(blocks.first, isA<MdParagraph>());
      final table = blocks[1] as MdTable;
      expect(table.header, ['Produit', 'Prix']);
      expect(table.aligns, [MdAlign.left, MdAlign.right]);
      expect(table.rows, [
        ['Savon', '2 500 Ar'],
        ['Huile', ''],
      ]);
    });

    test('escaped pipes and code stay in their cell', () {
      expect(splitTableRow(r'| a \| b | `x|y` |'), ['a | b', '`x|y`']);
    });

    test('nested, numbered and task lists', () {
      final blocks = parseMarkdown('3. Un\n'
          '   - sous a\n'
          '   - sous b\n'
          '4. Deux\n\n'
          '- [x] fait\n'
          '- [ ] à faire\n');
      final ordered = blocks[0] as MdList;
      expect(ordered.ordered, isTrue);
      expect(ordered.start, 3);
      expect(ordered.items, hasLength(2));
      final nested = ordered.items.first.children[1] as MdList;
      expect(nested.items, hasLength(2));
      final tasks = blocks[1] as MdList;
      expect([for (final i in tasks.items) i.checked], [true, false]);
    });

    test('quotes, rules, headings and display math', () {
      final blocks = parseMarkdown('# Titre\n'
          '> cité\n> encore\n\n'
          '---\n'
          r'$$\frac{a}{b}$$'
          '\n');
      expect(blocks[0], isA<MdHeading>());
      final quote = blocks[1] as MdQuote;
      expect((quote.children.single as MdParagraph).text, 'cité\nencore');
      expect(blocks[2], isA<MdRule>());
      expect((blocks[3] as MdMath).tex, r'\frac{a}{b}');
    });

    test('a fence still streaming is open', () {
      final blocks = parseMarkdown('Texte\n```chart\n{"type": "bar"');
      final fence = blocks.last as MdFence;
      expect(fence.language, 'chart');
      expect(fence.closed, isFalse);
      expect(
          (parseMarkdown('```json\n{}\n```').single as MdFence).closed, isTrue);
    });

    test('plain text drops the marks', () {
      expect(
        markdownToPlainText('## Bilan\n\n**Ventes** : [voir](https://x.mg) '
            'et [[Clients/Ana/brief.md]]\n\n- a\n- b'),
        'Bilan\nVentes : voir et brief.md\n• a\n• b',
      );
    });
  });

  group('numbers', () {
    test('model numbers in any form', () {
      expect(toNumber('1 250 000'), 1250000);
      expect(toNumber('12,5'), 12.5);
      expect(toNumber('30%'), 30);
      expect(toNumber(7), 7);
      expect(toNumber('abc'), isNull);
    });

    test('formatting', () {
      expect(formatValue(1250000, 'Ar'), '1\u202f250\u202f000 Ar');
      expect(formatValue(12.5, '%'), '12,5 %');
      expect(formatCompactValue(1200000), '1,2 M');
      expect(
          toCsv([
            ['a;b', 'c"d'],
            ['1', '2'],
          ]),
          '"a;b";"c""d"\r\n1;2');
    });
  });

  group('charts', () {
    test('series, labels and types', () {
      final spec = ChartSpec.parse({
        'type': 'bar',
        'title': 'Ventes',
        'labels': ['Jan', 'Fév'],
        'series': [
          {
            'name': '2026',
            'data': [5, '8']
          },
        ],
      })!;
      expect(spec.kind, ChartKind.bar);
      expect(spec.series.single.values, [5, 8]);
      expect(spec.table(','), [
        ['', '2026'],
        ['Jan', '5'],
        ['Fév', '8'],
      ]);
    });

    test('pie from label/value objects, scatter from points', () {
      final pie = ChartSpec.parse({
        'type': 'donut',
        'data': [
          {'label': 'MVola', 'value': 40, 'color': '#ff0000'},
          {'label': 'Cash', 'value': 60},
        ],
      })!;
      expect(pie.labels, ['MVola', 'Cash']);
      expect(pie.sliceColors.first, const Color(0xFFFF0000));
      final scatter = ChartSpec.parse({
        'type': 'scatter',
        'series': [
          {
            'name': 'Posts',
            'points': [
              [1, 2],
              {'x': 3, 'y': 4},
            ],
          },
        ],
      })!;
      expect(scatter.series.single.points, hasLength(2));
    });

    test('nothing to draw', () {
      expect(ChartSpec.parse({'type': 'line'}), isNull);
      expect(ChartSpec.parse('x'), isNull);
    });
  });

  test('mermaid flowchart', () {
    final spec = DiagramSpec.fromMermaid('graph LR\n'
        'A[Idée] --> B{Validé ?}\n'
        'B -->|oui| C(Publier)\n'
        'B -- non --> A')!;
    expect(spec.horizontal, isTrue);
    expect(
        [for (final n in spec.nodes) n.label], ['Idée', 'Validé ?', 'Publier']);
    expect(spec.nodes[1].shape, NodeShape.diamond);
    expect([for (final e in spec.edges) e.label], [null, 'oui', 'non']);
    expect(DiagramSpec.fromMermaid('sequenceDiagram\nA->>B: hi'), isNull);
  });

  group('widgets', () {
    late Directory chatDir;
    setUp(() => chatDir = Directory.systemTemp.createTempSync('rich_chat_'));
    tearDown(() => chatDir.deleteSync(recursive: true));

    Widget app(Widget child, {ProviderContainer? container}) {
      final scope = MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );
      return container == null
          ? ProviderScope(overrides: _overrides(chatDir), child: scope)
          : UncontrolledProviderScope(container: container, child: scope);
    }

    testWidgets('every kind of block renders', (tester) async {
      tester.view.physicalSize = const Size(1000, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const text = '''
# Bilan de novembre

Les **ventes** montent *bien* (~~10~~ 12 %), voir [le site](https://example.mg) et `code`. Formule : \$x^2 + \\frac{1}{2}\$.

1. Premier
   - détail
2. Second

- [x] Fait
- [ ] À faire

> Une citation

| Produit | Prix |
| --- | --- |
| Savon | 2500 |

```chart
{"type": "line", "title": "Courbe", "labels": ["A", "B", "C"], "series": [{"name": "S1", "data": [1, 3, 2]}, {"name": "S2", "data": [2, 1, 4]}]}
```

```chart
{"type": "pie", "title": "Parts", "data": [{"label": "MVola", "value": 40}, {"label": "Cash", "value": 60}]}
```

```chart
{"type": "hbar", "title": "Horizontal", "labels": ["A", "B"], "series": [{"name": "S", "data": [3, 5]}]}
```

```chart
{"type": "scatter", "title": "Nuage", "series": [{"name": "P", "points": [[1, 2], [3, 4]]}]}
```

```chart
{"type": "sparkline", "title": "Tendance", "data": [1, 2, 3, 5]}
```

```kpi
[{"label": "Ventes", "value": 1250000, "unit": "Ar", "change": 12, "trend": [1, 2, 3]}]
```

```progress
{"title": "Objectifs", "items": [{"label": "Mois", "value": 75, "max": 100}]}
```

```progress
{"style": "gauge", "items": [{"label": "Jauge", "value": 30, "max": 100}]}
```

```warning
Attention au **solde**.
```

```list
{"title": "Clients", "items": [{"title": "Ana", "subtitle": "VIP", "badge": "Nouveau", "icon": "user"}]}
```

```timeline
{"items": [{"date": "12/11", "title": "Tournage", "status": "done"}, {"title": "Montage", "status": "current"}]}
```

```mermaid
graph TD
A[Idée] --> B(Publier)
```

```fees
{"amount": 200000, "options": [{"label": "MVola", "fee": 2500}, {"label": "Orange", "fee": 3000}]}
```

```meta
{"file": "photo.jpg", "groups": [{"title": "GPS", "rows": [["Latitude", "-18.9"]]}]}
```

```map
{"places": [{"name": "Analakely", "lat": -18.9, "lng": 47.5}]}
```

```csv
a;b
1;2
```

```math
\\sqrt{x} = \\sum_{i=1}^{n} i
```

```task
{"id": "inexistante"}
```

```ledger
{"title": "Relevé"}
```

```actions
[{"label": "Créer la tâche", "message": "Crée la tâche"}]
```

```suggestions
["Et le mois dernier ?"]
```

```dart
void main() => print('ok'); // commentaire
```
''';
      await tester
          .pumpWidget(app(const RichMessage(text: text, color: Colors.black)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final s in [
        'Bilan de novembre',
        'Courbe',
        'Parts',
        'Horizontal',
        'Nuage',
        'Objectifs',
        'Clients',
        'Tournage',
        'Analakely',
        'Créer la tâche',
        'Et le mois dernier ?',
        'Relevé',
      ]) {
        expect(find.textContaining(s, findRichText: true), findsWidgets,
            reason: s);
      }
      expect(find.textContaining('1\u202f250\u202f000 Ar', findRichText: true),
          findsOneWidget);
      expect(find.text('Moins cher'), findsOneWidget);
      expect(find.byType(MarkdownTable), findsNWidgets(2));
      expect(find.byType(ChartBlock), findsNWidgets(5));
      expect(find.byType(CodeBlock), findsOneWidget);
    });

    testWidgets('a block still streaming waits, a broken one shows as code',
        (tester) async {
      await tester.pumpWidget(app(const RichMessage(
        text: 'Je calcule :\n```chart\n{"type": "bar", "data": [1,',
        color: Colors.black,
        streaming: true,
      )));
      expect(find.text('Préparation…'), findsOneWidget);
      await tester.pumpWidget(app(const RichMessage(
        text: '```chart\n{pas du json}\n```',
        color: Colors.black,
      )));
      expect(find.byType(CodeBlock), findsOneWidget);
    });

    testWidgets('an action button sends its message to Degany', (tester) async {
      final c = ProviderContainer(overrides: _overrides(chatDir));
      addTearDown(c.dispose);
      await tester.pumpWidget(app(
        const RichMessage(
          text:
              '```actions\n[{"label": "Résumer", "message": "Résume la note"}]\n```',
          color: Colors.black,
        ),
        container: c,
      ));
      await tester.tap(find.text('Résumer'));
      await tester.pump();
      final items = c.read(assistantChatProvider).items;
      expect(items.first.kind, ChatItemKind.user);
      expect(items.first.text, 'Résume la note');
    });

    testWidgets('multiple choice question sends the ticked choices',
        (tester) async {
      String? sent;
      await tester.pumpWidget(app(QuestionCard(
        item: const ChatItem(
          kind: ChatItemKind.question,
          text: 'Quels réseaux ?',
          options: ['Facebook', 'TikTok', 'Instagram'],
          multiple: true,
          streaming: true,
        ),
        onAnswer: (a) => sent = a,
      )));
      await tester.tap(find.text('Instagram'));
      await tester.tap(find.text('Facebook'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('assistant-confirm-choices')));
      expect(jsonDecode(sent!), ['Facebook', 'Instagram']);
    });

    testWidgets('form checks required fields, then sends the values',
        (tester) async {
      String? sent;
      const item = ChatItem(
        kind: ChatItemKind.question,
        text: 'Commande',
        streaming: true,
        fields: [
          {'name': 'client', 'label': 'Client', 'required': true},
          {'name': 'amount', 'label': 'Montant', 'type': 'number'},
          {
            'name': 'account',
            'label': 'Compte',
            'type': 'choice',
            'options': ['MVola', 'Cash'],
          },
          {'name': 'paid', 'label': 'Payé', 'type': 'bool'},
        ],
      );
      await tester
          .pumpWidget(app(FormCard(item: item, onAnswer: (a) => sent = a)));
      await tester.tap(find.byKey(const ValueKey('assistant-form-submit')));
      await tester.pump();
      expect(sent, isNull);
      expect(find.text('Obligatoire'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('assistant-field-client')), 'Ana');
      await tester.enterText(
          find.byKey(const ValueKey('assistant-field-amount')), '45 000');
      await tester.tap(find.text('MVola'));
      await tester.tap(find.byKey(const ValueKey('assistant-field-paid')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('assistant-form-submit')));
      expect(jsonDecode(sent!), {
        'client': 'Ana',
        'amount': 45000,
        'account': 'MVola',
        'paid': true,
      });
    });
  });
}

List<Override> _overrides(Directory chatDir) => [
      appStringsProvider.overrideWithValue(const AppStrings(Locale('fr'))),
      workspaceRootProvider.overrideWithValue(null),
      chatStoreProvider
          .overrideWithValue(ChatStore(directory: () async => chatDir)),
    ];
