import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/core/l10n/app_strings.dart';
import 'package:influencor/features/library/application/library_providers.dart';
import 'package:influencor/features/library/domain/table_document.dart';
import 'package:influencor/features/library/presentation/table_screen.dart';

void main() {
  group('TableDocument.isBracketColumnTitle', () {
    test('detects column names enclosed in square brackets', () {
      expect(TableDocument.isBracketColumnTitle('[Notes]'), isTrue);
      expect(TableDocument.isBracketColumnTitle('[Prix Achat]'), isTrue);
      expect(TableDocument.isBracketColumnTitle('[x]'), isTrue);
      expect(TableDocument.isBracketColumnTitle('[]'), isTrue);
      expect(TableDocument.isBracketColumnTitle('  [Secret]  '), isTrue);
    });

    test('rejects unbracketed or malformed column names', () {
      expect(TableDocument.isBracketColumnTitle('Notes'), isFalse);
      expect(TableDocument.isBracketColumnTitle('[Notes'), isFalse);
      expect(TableDocument.isBracketColumnTitle('Notes]'), isFalse);
      expect(TableDocument.isBracketColumnTitle(''), isFalse);
      expect(TableDocument.isBracketColumnTitle('['), isFalse);
      expect(TableDocument.isBracketColumnTitle(']'), isFalse);
    });

    test('TableColumnDef.isBracketed delegates to helper', () {
      const col1 = TableColumnDef(id: '1', title: '[Cache]');
      const col2 = TableColumnDef(id: '2', title: 'Visible');
      expect(col1.isBracketed, isTrue);
      expect(col2.isBracketed, isFalse);
    });
  });

  group('TableScreen hidden columns toggle and edit controls', () {
    testWidgets(
        'no plus button in view mode, long press edit toggles hidden columns',
        (tester) async {
      const path = '/workspace/test.table';
      final testTable = TableDocument(
        columns: const [
          TableColumnDef(id: 'c1', title: 'Nom'),
          TableColumnDef(id: 'c2', title: '[Secret]'),
        ],
        rows: const [
          TableRowData(id: 'r1', cells: {'c1': 'Jean', 'c2': '1234'}),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tableDocumentProvider(path).overrideWith((ref) => testTable),
          ],
          child: const MaterialApp(
            home: TableScreen(path: path),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // In view mode:
      // 1. Plus button must NOT be present
      expect(find.byIcon(Icons.add), findsNothing);

      // 2. Visible column is shown, bracketed hidden column is hidden
      expect(find.text('Nom'), findsOneWidget);
      expect(find.text('[Secret]'), findsNothing);

      // 3. Edit icon is present
      final editButton = find.byIcon(Icons.edit_outlined);
      expect(editButton, findsOneWidget);

      // 4. Long press on edit icon toggles hidden columns
      await tester.longPress(editButton);
      await tester.pumpAndSettle();

      // Now [Secret] should be visible
      expect(find.text('[Secret]'), findsOneWidget);
      // Plus button still not present because we are not in edit mode
      expect(find.byIcon(Icons.add), findsNothing);

      // 5. Long press again hides [Secret]
      await tester.longPress(editButton);
      await tester.pumpAndSettle();
      expect(find.text('[Secret]'), findsNothing);

      // 6. Normal tap on edit button enters edit mode
      await tester.tap(editButton);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // Edit mode is active (cancel/close icon displayed, plus button appears)
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.add), findsWidgets);
    });

    Future<void> pumpSecretTable(WidgetTester tester) async {
      const path = '/workspace/double.table';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tableDocumentProvider(path).overrideWith(
              (ref) => TableDocument(
                columns: const [
                  TableColumnDef(id: 'c1', title: 'Nom'),
                  TableColumnDef(id: 'c2', title: '[Secret]'),
                ],
                rows: const [
                  TableRowData(id: 'r1', cells: {'c1': 'Jean', 'c2': '1234'}),
                ],
              ),
            ),
          ],
          child: const MaterialApp(home: TableScreen(path: path)),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> doubleTap(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('double tap on edit toggles hidden columns, not edit mode',
        (tester) async {
      await pumpSecretTable(tester);
      final editButton = find.byIcon(Icons.edit_outlined);

      await doubleTap(tester, editButton);
      expect(find.text('[Secret]'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing, reason: 'still viewing');

      await doubleTap(tester, editButton);
      expect(find.text('[Secret]'), findsNothing);
    });

    testWidgets('in edit mode, double tap on save toggles hidden columns',
        (tester) async {
      await pumpSecretTable(tester);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('[Secret]'), findsNothing);

      final save = find.byIcon(Icons.save_outlined);
      await doubleTap(tester, save);
      expect(find.text('[Secret]'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget, reason: 'not saved');

      await doubleTap(tester, save);
      expect(find.text('[Secret]'), findsNothing);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });
  });

  group('TableScreen editing: scroll, delete, reorder, default columns', () {
    const path = '/workspace/edit.table';
    TableDocument buildTable({int columns = 3}) => TableDocument(
          columns: [
            const TableColumnDef(id: 'c1', title: 'Nom'),
            const TableColumnDef(id: 'c2', title: 'Ville'),
            const TableColumnDef(id: 'c3', title: '[Secret]'),
            for (var i = 4; i <= columns; i++)
              TableColumnDef(id: 'c$i', title: 'Col $i'),
          ],
          rows: const [
            TableRowData(id: 'r1', cells: {'c1': 'Jean', 'c2': 'Tana'}),
            TableRowData(id: 'r2', cells: {'c1': 'Rivo', 'c2': 'Tulear'}),
          ],
        );

    Future<void> pumpTable(WidgetTester tester, TableDocument table) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tableDocumentProvider(path).overrideWith((ref) => table),
            appStringsProvider
                .overrideWithValue(const AppStrings(Locale('fr'))),
          ],
          child: const MaterialApp(home: TableScreen(path: path)),
        ),
      );
      await tester.pumpAndSettle();
    }

    double headerX(WidgetTester tester, String title) =>
        tester.getTopLeft(find.text(title)).dx;

    testWidgets('a wide table scrolls horizontally on a phone', (tester) async {
      await pumpTable(tester, buildTable(columns: 8));
      final last = find.text('Col 8');
      expect(last, findsOneWidget);
      expect(tester.getTopLeft(last).dx, greaterThan(400));

      await tester.drag(find.text('Jean'), const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(last).dx, lessThan(400));
    });

    testWidgets('deleting a row and a column, with undo', (tester) async {
      await pumpTable(tester, buildTable());
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // Header delete buttons come first, then one per row.
      final deletes = find.byIcon(Icons.delete_outline);
      expect(deletes, findsNWidgets(2 + 2));

      // Delete row r1 (first row button, after the 2 header buttons).
      await tester.tap(deletes.at(2));
      await tester.pumpAndSettle();
      expect(find.text('Jean'), findsNothing);
      expect(find.text('Rivo'), findsOneWidget);

      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(find.text('Jean'), findsOneWidget);

      // Delete column "Ville".
      final deleteVille = find.byIcon(Icons.delete_outline).at(1);
      await tester.ensureVisible(deleteVille);
      await tester.pumpAndSettle();
      await tester.tap(deleteVille);
      await tester.pumpAndSettle();
      expect(find.text('Ville'), findsNothing);
      expect(find.text('Tana'), findsNothing);
    });

    testWidgets('long press on save lists columns to show by default',
        (tester) async {
      await pumpTable(tester, buildTable());
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      await tester.longPress(find.byIcon(Icons.save_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Colonnes affichées par défaut'), findsOneWidget);
      final secret = find.widgetWithText(CheckboxMenuButton, 'Secret');
      final ville = find.widgetWithText(CheckboxMenuButton, 'Ville');
      expect(tester.widget<CheckboxMenuButton>(secret).value, isFalse);
      expect(tester.widget<CheckboxMenuButton>(ville).value, isTrue);

      // Show "Secret" by default, hide "Ville": the menu stays open.
      await tester.tap(secret);
      await tester.pumpAndSettle();
      await tester.tap(ville);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxMenuButton>(secret).value, isTrue);
      expect(tester.widget<CheckboxMenuButton>(ville).value, isFalse);

      // Leave edit mode: "Secret" is now visible, "[Ville]" hidden.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('Secret'), findsOneWidget);
      expect(find.text('[Ville]'), findsNothing);
      expect(find.text('Ville'), findsNothing);
    });

    testWidgets('dragging a column handle reorders the columns',
        (tester) async {
      await pumpTable(tester, buildTable());
      expect(headerX(tester, 'Nom'), lessThan(headerX(tester, 'Ville')));

      await tester.tap(find.byIcon(Icons.edit_outlined));

      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      final handle = find.byIcon(Icons.drag_indicator).first;
      final target = tester.getCenter(find.text('Tana'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close));

      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(headerX(tester, 'Ville'), lessThan(headerX(tester, 'Nom')));
    });

    testWidgets('a dragged row makes room live, before it is dropped',
        (tester) async {
      await pumpTable(tester, buildTable());
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // No row numbers in edit mode, only the handles.
      expect(find.text('1'), findsNothing);
      expect(find.text('2'), findsNothing);

      double rowY(String text) => tester
          .getTopLeft(find.descendant(
              of: find.byType(Table), matching: find.text(text)))
          .dy;
      expect(rowY('Jean'), lessThan(rowY('Rivo')));

      // Handles: one per shown column (Nom, Ville), then one per row.
      final rivoHandle = find.byIcon(Icons.drag_indicator).at(3);
      final gesture = await tester.startGesture(tester.getCenter(rivoHandle));
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.moveBy(const Offset(0, -10));
      await tester.pump();
      await gesture.moveTo(Offset(
        tester.getCenter(rivoHandle).dx,
        rowY('Jean') + 4,
      ));
      await tester.pump();
      await tester.pump();
      // Still held: Rivo already sits above Jean.
      expect(rowY('Rivo'), lessThan(rowY('Jean')));

      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(rowY('Rivo'), lessThan(rowY('Jean')));
    });
  });
}
