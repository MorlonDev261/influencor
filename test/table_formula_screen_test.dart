import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/core/l10n/app_strings.dart';
import 'package:influencor/features/library/application/library_providers.dart';
import 'package:influencor/features/library/domain/table_document.dart';
import 'package:influencor/features/library/presentation/table_screen.dart';

void main() {
  const path = '/workspace/formulas.table';

  Future<void> pumpTable(WidgetTester tester, TableDocument table) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tableDocumentProvider(path).overrideWith((ref) => table),
          appStringsProvider.overrideWithValue(const AppStrings(Locale('fr'))),
        ],
        child: const MaterialApp(home: TableScreen(path: path)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a header formula fills its whole column', (tester) async {
    await pumpTable(
      tester,
      const TableDocument(
        columns: [
          TableColumnDef(id: 'p', title: 'Produit'),
          TableColumnDef(id: 'a', title: 'Achat'),
          TableColumnDef(id: 'v', title: 'Vente'),
          TableColumnDef(id: 'b', title: 'Bénéfice =C-B'),
          TableColumnDef(id: 't', title: 'Total'),
        ],
        rows: [
          TableRowData(id: 'r1', cells: {
            'p': 'Riz',
            'a': '1000',
            'v': '1500',
            't': '=SOMME(D:D)',
          }),
          TableRowData(
              id: 'r2', cells: {'p': 'Huile', 'a': '2000', 'v': '2600'}),
        ],
      ),
    );

    expect(find.text('Bénéfice'), findsOneWidget);
    expect(find.text('Bénéfice =C-B'), findsNothing);
    expect(find.text('500'), findsOneWidget);
    expect(find.text('600'), findsOneWidget);
    expect(find.text('1100'), findsOneWidget);
    expect(find.text('=SOMME(D:D)'), findsNothing);
  });

  testWidgets('tapping cells while typing a formula inserts references',
      (tester) async {
    await pumpTable(
      tester,
      const TableDocument(
        columns: [
          TableColumnDef(id: 'p', title: 'Produit'),
          TableColumnDef(id: 'a', title: 'Achat'),
          TableColumnDef(id: 'v', title: 'Vente'),
          TableColumnDef(id: 'n', title: 'Note'),
        ],
        rows: [
          TableRowData(id: 'r1', cells: {
            'p': 'Riz',
            'a': '1000',
            'v': '1500',
            'n': '',
          }),
        ],
      ),
    );
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    // 4 header fields, then the row's cells: Note is the 8th field.
    final note = find.byType(TextField).at(7);
    await tester.tap(note);
    await tester.enterText(note, '=');
    await tester.pumpAndSettle();
    expect(find.text('Touchez une case pour l’ajouter à la formule'),
        findsOneWidget);

    await tester.tap(find.text('1500'));
    await tester.pump();
    TextField field() => tester.widget<TextField>(note);
    expect(field().controller!.text, '=C1');

    await tester.enterText(note, '=C1-');
    await tester.pump();
    await tester.tap(find.text('1000'));
    await tester.pumpAndSettle();
    expect(field().controller!.text, '=C1-B1');
    // Live result under the formula.
    expect(find.text('= 500'), findsOneWidget);

    await tester.tap(find.text('Terminé'));
    await tester.pumpAndSettle();
    expect(find.text('Touchez une case pour l’ajouter à la formule'),
        findsNothing);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('500'), findsOneWidget);
  });

  testWidgets('a header formula picks column letters', (tester) async {
    await pumpTable(
      tester,
      const TableDocument(
        columns: [
          TableColumnDef(id: 'a', title: 'Achat'),
          TableColumnDef(id: 'v', title: 'Vente'),
          TableColumnDef(id: 'm', title: 'Marge'),
        ],
        rows: [
          TableRowData(id: 'r1', cells: {'a': '10', 'v': '25', 'm': ''}),
          TableRowData(id: 'r2', cells: {'a': '4', 'v': '5', 'm': ''}),
        ],
      ),
    );
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    final marge = find.byType(TextField).at(2);
    await tester.tap(marge);
    await tester.enterText(marge, 'Marge =');
    await tester.pumpAndSettle();
    await tester.tap(find.text('25'));
    await tester.pump();
    await tester.enterText(marge, 'Marge =B-');
    await tester.pump();
    await tester.tap(find.text('4'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(marge).controller!.text, 'Marge =B-A');

    await tester.tap(find.text('Terminé'));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Marge'), findsOneWidget);
    expect(find.text('15'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });
}
