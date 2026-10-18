import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/features/library/domain/table_document.dart';
import 'package:influencor/features/library/domain/table_formula.dart';

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

/// Value shown by a one-cell formula in a table with a few numbers.
String show(String formula) {
  final t = table([
    'A',
    'B'
  ], [
    ['10', 'texte'],
    ['0', ''],
    [formula, ''],
  ]);
  return TableEvaluator(t).displayAt(2, 0);
}

void main() {
  test('syntax errors', () {
    for (final f in [
      '=1+',
      '=(1',
      '=1)',
      '=SOMME(',
      '=SOMME(1;',
      '==1',
      '=1 2',
      '="abc',
      '=#abc',
      '=1:2',
      '=A1:',
      '=*3',
      '=@',
    ]) {
      expect(show(f), TableFormula.errSyntax, reason: f);
    }
  });

  test('value, division, name and circular errors', () {
    expect(show('=A1/A2'), TableFormula.errDiv0);
    expect(show('=A1/B2'), TableFormula.errDiv0); // empty cell = 0
    expect(show('=A1+B1'), TableFormula.errValue); // text
    expect(show('=A1:A2'), TableFormula.errValue); // bare range
    expect(show('=FOO(1)'), TableFormula.errName);
    expect(show('=Prix*2'), TableFormula.errName);
    expect(show('=A3+1'), TableFormula.errCircular);
    expect(show('=RACINE(-1)'), TableFormula.errNum);
    expect(show('=MOYENNE(B1:B2)'), TableFormula.errDiv0);
    expect(show('=MOD(5;0)'), TableFormula.errDiv0);
  });

  test('errors propagate and SI only evaluates the chosen branch', () {
    expect(show('=(A1/A2)+1'), TableFormula.errDiv0);
    expect(show('=SOMME(A1;A1/A2)'), TableFormula.errDiv0);
    expect(show('=SI(A1>5;1;A1/A2)'), '1');
    expect(show('=SI(A1/A2;1;2)'), TableFormula.errDiv0);
  });

  test('wrong number of arguments', () {
    expect(show('=ABS()'), TableFormula.errValue);
    expect(show('=ABS(1;2)'), TableFormula.errValue);
    expect(show('=MOD(5)'), TableFormula.errValue);
    expect(show('=ARRONDI(1;2;3)'), TableFormula.errValue);
    expect(show('=SI(1)'), TableFormula.errValue);
  });

  test('never throws on hostile input', () {
    for (final f in [
      '=A99999999999999999999999',
      '=1e400',
      '=10^400-10^400',
      '=999999999999999999999999999999*999999999999999999999999999999^20',
      '=ARRONDI(1;10^400-10^400)',
      '=${'(' * 5000}1${')' * 5000}',
      '=ZZZ1+AAAA',
    ]) {
      expect(() => show(f), returnsNormally, reason: f);
      expect(show(f), startsWith('#'), reason: f);
    }
  });

  test('a long chain of formulas does not overflow the stack', () {
    final rows = [
      ['1'],
      for (var i = 2; i <= 5000; i++) ['=A${i - 1}+1'],
    ];
    final e = TableEvaluator(table(['A'], rows));
    expect(() => e.displayAt(4999, 0), returnsNormally);
  });

  test('rows beyond the table read as empty, like an empty sheet', () {
    expect(show('=A50+1'), '1');
    expect(show('=SOMME(B1:B100)'), '0');
    expect(show('=ARRONDI(1,25;400)'), '1,25');
  });

  test('a header formula pointing at its own column is circular', () {
    final t = table([
      'A',
      'Total =B+1'
    ], [
      ['1', ''],
    ]);
    expect(TableEvaluator(t).displayAt(0, 1), TableFormula.errCircular);
  });

  test('deleting the first or last row of a range shrinks it', () {
    final before = table([
      'A'
    ], [
      ['1'],
      ['2'],
      ['3'],
      ['=SOMME(A1:A3)'],
    ]);
    final withoutFirst = TableDocument(
      columns: before.columns,
      rows: before.rows.skip(1).toList(),
    );
    final after = TableFormula.rewriteReferences(before, withoutFirst);
    expect(after.rows.last.cells['c0'], '=SOMME(A1:A2)');
    expect(TableEvaluator(after).displayAt(2, 0), '5');

    final withoutLast = TableDocument(
      columns: before.columns,
      rows: [before.rows[0], before.rows[1], before.rows[3]],
    );
    final after2 = TableFormula.rewriteReferences(before, withoutLast);
    expect(after2.rows.last.cells['c0'], '=SOMME(A1:A2)');

    final allGone = TableDocument(
      columns: before.columns,
      rows: [before.rows[3]],
    );
    final after3 = TableFormula.rewriteReferences(before, allGone);
    expect(TableEvaluator(after3).displayAt(0, 0), TableFormula.errRef);
  });
}
