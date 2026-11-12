import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/core/l10n/app_strings.dart';
import 'package:influencor/features/fees/application/tariff_providers.dart';
import 'package:influencor/features/fees/data/madagascar_tariffs.dart';
import 'package:influencor/features/fees/presentation/fees_screen.dart';

void main() {
  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appStringsProvider.overrideWithValue(const AppStrings(Locale('fr'))),
        currentTariffsProvider.overrideWithValue(madagascarTariffs),
      ],
      child: const MaterialApp(home: FeesScreen()),
    ));
    await tester.pump();
    // Show every control: transfer to the same operator.
    await tester.tap(find.text('Transfert'));
    await tester.pump();
  }

  double top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  testWidgets('on desktop the choices sit on one row', (tester) async {
    // The test font is much wider than the app's.
    await pump(tester, const Size(2600, 900));
    final row = top(tester, find.text('Opérateur'));
    for (final label in ['Opération', 'Vers']) {
      expect(top(tester, find.text(label)), row, reason: label);
    }
    // The fees switch sits beside the amount.
    expect(find.byType(SwitchListTile), findsNothing);
    final amount = tester.getRect(find.byType(TextField));
    expect(tester.getCenter(find.byType(Switch)).dy,
        moreOrLessEquals(amount.center.dy, epsilon: 12));
    await tester.tap(find.text('Inclure les frais dans le montant'));
    await tester.pump();
    expect(find.text('Solde disponible'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a phone they stay stacked', (tester) async {
    await pump(tester, const Size(400, 1000));
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(top(tester, find.text('Vers')),
        greaterThan(top(tester, find.text('Opérateur'))));
    expect(tester.takeException(), isNull);
  });

  testWidgets('operator logos get no dark checkmark disc', (tester) async {
    await pump(tester, const Size(400, 1000));
    final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
    expect(chips.where((c) => c.selected), hasLength(1));
    expect(chips.every((c) => c.showCheckmark == false), isTrue);
  });
}
