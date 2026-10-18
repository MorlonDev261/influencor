import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/core/l10n/app_strings.dart';
import 'package:influencor/core/providers/edit_mode_provider.dart';
import 'package:influencor/core/providers/workspace_providers.dart';
import 'package:influencor/features/accounting/application/accounting_providers.dart';
import 'package:influencor/features/accounting/domain/ledger.dart';
import 'package:influencor/features/accounting/domain/ledger_entry.dart';
import 'package:influencor/features/accounting/presentation/accounting_screen.dart';
import 'package:influencor/features/accounting/presentation/ledger_chart.dart';

const _fr = AppStrings(Locale('fr'));

LedgerEntry _entry(String id, DateTime date, int amount,
        {LedgerDirection direction = LedgerDirection.credit}) =>
    LedgerEntry(
      id: id,
      date: date,
      amount: amount,
      account: LedgerAccount.mvola,
      type: direction == LedgerDirection.credit
          ? LedgerType.sale
          : LedgerType.expense,
      direction: direction,
    );

/// In-memory ledger, so the screen runs without touching the disk.
class _MemoryLedger extends LedgerController {
  _MemoryLedger(this.initial);

  final Ledger initial;

  @override
  Future<Ledger> build() async => initial;

  @override
  Future<void> save(LedgerEntry entry) async =>
      state = AsyncData((await future).upsert(entry));

  @override
  Future<void> remove(String id) async =>
      state = AsyncData((await future).remove(id));

  @override
  Future<LedgerSheet?> closeCurrentSheet() async {
    final ledger = await future;
    if (!ledger.canClose) return null;
    final closed = ledger.current.id;
    final next = ledger.closeCurrent(at: DateTime.now(), newSheetId: 'next');
    state = AsyncData(next);
    return next.sheetById(closed);
  }
}

class _EditOn extends EditModeNotifier {
  @override
  bool build() => true;
}

void main() {
  Future<void> pumpChart(
    WidgetTester tester,
    List<LedgerEntry> entries, {
    Brightness brightness = Brightness.light,
    double width = 400,
  }) async {
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: LedgerChartCard(entries: entries, strings: _fr),
        ),
      ),
    ));
  }

  testWidgets('no entries: no chart at all', (tester) async {
    await pumpChart(tester, const []);
    expect(find.byKey(const ValueKey('ledger-chart')), findsNothing);
  });

  testWidgets('entries: the chart shows credit and debit totals',
      (tester) async {
    await pumpChart(tester, [
      _entry('a', DateTime(2026, 10, 10), 15000),
      _entry('b', DateTime(2026, 10, 12), 4000,
          direction: LedgerDirection.debit),
    ]);
    expect(find.byKey(const ValueKey('ledger-chart')), findsOneWidget);
    expect(find.textContaining('+15 000 Ar'), findsOneWidget);
    expect(find.textContaining('-4 000 Ar'), findsOneWidget);
    expect(find.textContaining('Par jour'), findsOneWidget);

    // Touching the curve shows the tooltip without errors.
    await tester.tap(find.byKey(const ValueKey('ledger-chart')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders on a small phone in dark mode and on a wide screen',
      (tester) async {
    final entries = [
      for (var i = 0; i < 90; i++)
        _entry('e$i', DateTime(2026, 1, 1).add(Duration(days: i * 2)),
            1000 + i * 37,
            direction:
                i.isEven ? LedgerDirection.credit : LedgerDirection.debit),
    ];
    await pumpChart(tester, entries, brightness: Brightness.dark, width: 320);
    expect(find.textContaining('Par semaine'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await pumpChart(tester, entries, width: 1400);
    expect(tester.takeException(), isNull);
  });

  group('accounting screen', () {
    Future<void> pumpScreen(WidgetTester tester, Ledger ledger,
        {double width = 420}) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          appStringsProvider.overrideWithValue(_fr),
          workspaceRootProvider.overrideWithValue('/workspace'),
          editModeProvider.overrideWith(_EditOn.new),
          ledgerProvider.overrideWith(() => _MemoryLedger(ledger)),
        ],
        child: const MaterialApp(home: AccountingScreen()),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('an empty ledger shows no chart', (tester) async {
      await pumpScreen(tester, Ledger.empty());
      expect(find.byKey(const ValueKey('ledger-chart')), findsNothing);
      expect(find.text(_fr.noTransactions), findsOneWidget);
      // Nothing to close yet.
      final close = tester.widget<ButtonStyleButton>(
          find.byKey(const ValueKey('ledger-close-sheet')));
      expect(close.onPressed, isNull);
    });

    for (final width in [360.0, 1280.0]) {
      testWidgets(
          'closing the sheet starts an empty one; the closed sheet '
          'stays readable (width $width)', (tester) async {
        await pumpScreen(
          tester,
          Ledger(
            sheets: [LedgerSheet(id: 's1', start: DateTime(2026, 10, 10))],
            entries: [
              _entry('a', DateTime(2026, 10, 11), 20000),
              _entry('b', DateTime(2026, 10, 12), 5000,
                  direction: LedgerDirection.debit),
            ],
          ),
          width: width,
        );
        expect(find.byKey(const ValueKey('ledger-chart')), findsOneWidget);
        expect(find.textContaining('Depuis le 10/10/2026'), findsOneWidget);

        // Asks first; cancelling changes nothing.
        await tester.tap(find.byKey(const ValueKey('ledger-close-sheet')));
        await tester.pumpAndSettle();
        expect(find.text(_fr.closeSheetTitle), findsOneWidget);
        await tester.tap(find.text(_fr.cancel));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ledger-chart')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('ledger-close-sheet')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ledger-close-confirm')));
        await tester.pumpAndSettle();

        // New sheet: empty, no chart, balance carried over.
        expect(find.byKey(const ValueKey('ledger-chart')), findsNothing);
        expect(find.text(_fr.noTransactions), findsOneWidget);
        expect(find.text('15 000 Ar'), findsOneWidget);
        expect(find.byKey(const ValueKey('ledger-opening')), findsOneWidget);
        expect(find.byType(FloatingActionButton), findsOneWidget);

        // The closed sheet, from the history: read-only, with its chart.
        await tester.tap(find.byKey(const ValueKey('ledger-sheets')));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.lock_outline_rounded).last);
        await tester.pumpAndSettle();
        expect(find.text(_fr.sheetReadOnly), findsOneWidget);
        expect(find.textContaining('Du 10/10/2026 au '), findsOneWidget);
        expect(find.byKey(const ValueKey('ledger-chart')), findsOneWidget);
        expect(find.text(_fr.closingBalance), findsOneWidget);
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(find.byKey(const ValueKey('ledger-close-sheet')), findsNothing);

        // Its entries open read-only.
        tester
            .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
            .removeCurrentSnackBar();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(_fr.sale));
        await tester.pumpAndSettle();
        await tester.tap(find.text(_fr.sale));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ledger-dialog-edit')), findsNothing);
        await tester.tap(find.text(_fr.closeAction));
        await tester.pumpAndSettle();

        await tester.drag(find.byType(CustomScrollView), const Offset(0, 2000));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ledger-back-current')));
        await tester.pumpAndSettle();
        expect(find.text(_fr.noTransactions), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
