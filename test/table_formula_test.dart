import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/features/library/domain/table_document.dart';
import 'package:influencor/features/library/domain/table_formula.dart';

/// Builds a table from rows of raw cell texts; column ids are c0, c1…
TableDocument table(List<String> titles, List<List<String>> rows) =>
    TableDocument(
      columns: [
        for (final (i, t) in titles.indexed)
          TableColumnDef(id: 'c$i', title: t),
      ],
      rows: [
        for (final (r, values) in rows.indexed)
          TableRowData(id: 'r$r', cells: {
            for (final (i, v) in values.indexed) 'c$i': v,
          }),
      ],
    );

void main() {
  group('helpers', () {
    test('column letters', () {
      expect(TableFormula.columnLetters(0), 'A');
      expect(TableFormula.columnLetters(25), 'Z');
      expect(TableFormula.columnLetters(26), 'AA');
      expect(TableFormula.columnIndex('ab'), 27);
    });

    test('parseNumber reads typed numbers', () {
      expect(TableFormula.parseNumber('1 500'), 1500);
      expect(TableFormula.parseNumber('12,5'), 12.5);
      expect(TableFormula.parseNumber('1.250,75'), 1250.75);
      expect(TableFormula.parseNumber('1,250.75'), 1250.75);
      expect(TableFormula.parseNumber('15 %'), 0.15);
      expect(TableFormula.parseNumber('Ar 2000'), 2000);
      expect(TableFormula.parseNumber('3 kg'), 3);
      expect(TableFormula.parseNumber('-4'), -4);
      expect(TableFormula.parseNumber('Jean'), isNull);
      expect(TableFormula.parseNumber('2026-10-18'), isNull);
      expect(TableFormula.parseNumber(''), isNull);
    });

    test('formatNumber', () {
      expect(TableFormula.formatNumber(1500), '1500');
      expect(TableFormula.formatNumber(12.5), '12,5');
      expect(TableFormula.formatNumber(12.5, decimalSeparator: '.'), '12.5');
      expect(TableFormula.formatNumber(1 / 3), '0,3333');
      expect(TableFormula.formatNumber(10 / 3), '3,33');
    });

    test('parseHeader splits label and column formula', () {
      final h = TableFormula.parseHeader('Bénéfice =C-B');
      expect(h.label, 'Bénéfice');
      expect(h.formula, 'C-B');
      expect(h.hidden, isFalse);

      final hidden = TableFormula.parseHeader('[Marge = C/B]');
      expect(hidden.label, 'Marge');
      expect(hidden.formula, 'C/B');
      expect(hidden.display, '[Marge]');

      expect(TableFormula.parseHeader('Prix').formula, isNull);
      expect(TableFormula.parseHeader('Total =').formula, isNull);
    });
  });

  group('cell formulas', () {
    final t = table(
      ['Nom', 'Achat', 'Vente', 'Note'],
      [
        ['Riz', '1 000', '1 500', '=C1-B1'],
        ['Huile', '2000', '2600', '=SOMME(B1:C2)'],
        ['Sucre', '500', '', '=MOYENNE(B1:B3)'],
        ['x', '=B1*2', '=B4/0', '=A1+1'],
        ['y', '=C5', '=B5', '=SI(C1>B1;"gain";"perte")'],
        ['z', '=10%*B2', '=ARRONDI(10/3;1)', '=MAX(B1:B3)+MIN(B1:B3)'],
      ],
    );
    final e = TableEvaluator(t);

    test('arithmetic and references', () {
      expect(e.displayAt(0, 3), '500');
      expect(e.displayAt(3, 1), '2000');
      expect(e.displayAt(5, 1), '200');
    });

    test('functions', () {
      expect(e.displayAt(1, 3), '7100');
      expect(e.displayAt(2, 3), '1166,67');
      // Whole column: text skipped, but the circular B5 makes it an error.
      expect(e.evaluate('SOMME(A:A)'), isA<NumberValue>());
      expect(e.evaluate('SOMME(B:B)'), isA<ErrorValue>());
      expect(e.displayAt(4, 3), 'gain');
      expect(e.displayAt(5, 2), '3,3');
      expect(e.displayAt(5, 3), '2500');
    });

    test('errors', () {
      expect(e.displayAt(3, 2), TableFormula.errDiv0);
      expect(e.displayAt(3, 3), TableFormula.errValue);
      expect(e.displayAt(4, 1), TableFormula.errCircular);
      expect(
          TableEvaluator(table([
            'A'
          ], [
            ['=FOO(1)']
          ])).displayAt(0, 0),
          TableFormula.errName);
      expect(
          TableEvaluator(table([
            'A'
          ], [
            ['=1+']
          ])).displayAt(0, 0),
          TableFormula.errSyntax);
      expect(
          TableEvaluator(table([
            'A'
          ], [
            ['=Z9']
          ])).displayAt(0, 0),
          TableFormula.errRef);
    });

    test('operator precedence', () {
      final p = TableEvaluator(table([
        'A'
      ], [
        ['=2+3*4'],
        ['=(2+3)*4'],
        ['=2^3^2'],
        ['=-2^2'],
        ['=1,5*2'],
      ]));
      expect(p.displayAt(0, 0), '14');
      expect(p.displayAt(1, 0), '20');
      expect(p.displayAt(2, 0), '64');
      expect(p.displayAt(3, 0), '4');
      expect(p.displayAt(4, 0), '3');
    });
  });

  group('column formulas', () {
    test('a header formula applies to every row, bare letters = same row', () {
      final t = table(
        ['Produit', 'Achat', 'Vente', 'Bénéfice =C-B'],
        [
          ['Riz', '1000', '1500', ''],
          ['Huile', '2000', '2600', 'ignored'],
        ],
      );
      final e = TableEvaluator(t);
      expect(e.hasColumnFormula(3), isTrue);
      expect(e.displayAt(0, 3), '500');
      expect(e.displayAt(1, 3), '600');
    });

    test('cells can sum a formula column', () {
      final t = table(
        ['Achat', 'Vente', 'Bénéfice =B-A', 'Total'],
        [
          ['10', '15', '', '=SOMME(C:C)'],
          ['20', '26', '', ''],
        ],
      );
      expect(TableEvaluator(t).displayAt(0, 3), '11');
    });
  });

  group('rewriteReferences', () {
    test('moving a column keeps formulas on the same cells', () {
      final before = table(
        ['A', 'B', 'Somme =A+B'],
        [
          ['1', '2', ''],
          ['=A1*10', '3', ''],
        ],
      );
      // Move column B (index 1) to the front.
      final moved = TableDocument(
        columns: [before.columns[1], before.columns[0], before.columns[2]],
        rows: before.rows,
      );
      final after = TableFormula.rewriteReferences(before, moved);
      expect(after.columns[2].title, 'Somme =B+A');
      expect(after.rows[1].cells['c0'], '=B1*10');
      final e = TableEvaluator(after);
      expect(e.displayAt(0, 2), '3');
      expect(e.displayAt(1, 1), '10');
    });

    test('deleting a referenced row gives #REF!', () {
      final before = table([
        'A'
      ], [
        ['5'],
        ['7'],
        ['=A1+A2'],
        ['=SOMME(A1:A2)'],
      ]);
      final deleted = TableDocument(
        columns: before.columns,
        rows: [before.rows[1], before.rows[2], before.rows[3]],
      );
      final after = TableFormula.rewriteReferences(before, deleted);
      expect(after.rows[1].cells['c0'], '=#REF!+A1');
      // A range shrinks instead of breaking.
      expect(after.rows[2].cells['c0'], '=SOMME(A1:A1)');
      final e = TableEvaluator(after);
      expect(e.displayAt(1, 0), TableFormula.errRef);
      expect(e.displayAt(2, 0), '7');
    });

    test('appending rows or columns changes nothing', () {
      final before = table([
        'A'
      ], [
        ['=A2'],
        ['1'],
      ]);
      final after = TableDocument(
        columns: before.columns,
        rows: [
          ...before.rows,
          const TableRowData(id: 'new', cells: {'c0': ''}),
        ],
      );
      expect(identical(TableFormula.rewriteReferences(before, after), after),
          isTrue);
    });
  });
}
