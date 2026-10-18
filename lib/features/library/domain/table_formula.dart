import 'dart:math' as math;

import 'table_document.dart';

/// Spreadsheet-like formulas for [TableDocument], Excel style:
///
/// * a cell whose text starts with `=` is a formula for that cell only:
///   `=A1+B1`, `=SOMME(B1:B5)`, `=C2*10%`;
/// * a column title holding `=` gives a formula applied to every cell of the
///   column: `Bénéfice =C-B` (a bare column letter means "same row").
///
/// Columns are lettered A, B, C… and rows numbered from 1, in file order.
/// `C:C` is the whole column C. Function arguments are separated by `;`
/// (`,` also works when it can't be read as a decimal comma).
abstract final class TableFormula {
  static const errRef = '#REF!';
  static const errDiv0 = '#DIV/0!';
  static const errValue = '#VALEUR!';
  static const errName = '#NOM?';
  static const errCircular = '#CIRC!';
  static const errNum = '#NUM!';
  static const errSyntax = '#ERREUR!';

  static const _errors = [
    errRef,
    errDiv0,
    errValue,
    errName,
    errCircular,
    errNum,
    errSyntax,
  ];

  /// `0 → A`, `25 → Z`, `26 → AA`.
  static String columnLetters(int index) {
    var n = index + 1;
    var letters = '';
    while (n > 0) {
      final r = (n - 1) % 26;
      letters = String.fromCharCode(65 + r) + letters;
      n = (n - 1) ~/ 26;
    }
    return letters;
  }

  /// `A → 0`, `aa → 26`.
  static int columnIndex(String letters) {
    var n = 0;
    for (final unit in letters.toUpperCase().codeUnits) {
      n = n * 26 + (unit - 64);
    }
    return n - 1;
  }

  /// Splits a column title into its label and its column formula, if any:
  /// `[Bénéfice =C-B]` → label `Bénéfice`, formula `C-B`, hidden.
  static ColumnHeader parseHeader(String title) {
    var text = title.trim();
    final hidden = TableDocument.isBracketColumnTitle(text);
    if (hidden) text = text.substring(1, text.length - 1).trim();
    final eq = text.indexOf('=');
    if (eq < 0) return ColumnHeader(label: text, hidden: hidden);
    final formula = text.substring(eq + 1).trim();
    final label = text.substring(0, eq).trim();
    if (formula.isEmpty) {
      return ColumnHeader(label: label.isEmpty ? text : label, hidden: hidden);
    }
    return ColumnHeader(
      label: label.isEmpty ? '=$formula' : label,
      formula: formula,
      hidden: hidden,
    );
  }

  /// The formula of a cell (`=A1+B1` → `A1+B1`), or null for a plain value.
  static String? cellFormula(String raw) {
    final text = raw.trim();
    if (text.length < 2 || !text.startsWith('=')) return null;
    return text.substring(1).trim();
  }

  /// Reads a number the way people type it: `1 500`, `12,5`, `1.250,75`,
  /// `15 %`, `Ar 2000`, `3 kg`. Null when the text is not a number.
  static double? parseNumber(String input) {
    var s = input.replaceAll(RegExp(r'[\s  ]'), '');
    if (s.isEmpty) return null;
    var percent = false;
    if (s.endsWith('%')) {
      percent = true;
      s = s.substring(0, s.length - 1);
    }
    // Currency or unit around the number: "Ar2000", "3kg", "12€".
    s = s.replaceAll(RegExp(r'^[^\d+\-.,]+|[^\d.,]+$'), '');
    if (!RegExp(r'^[+-]?[\d.,]*\d[\d.,]*$').hasMatch(s)) return null;
    final lastComma = s.lastIndexOf(',');
    final lastDot = s.lastIndexOf('.');
    if (lastComma >= 0 && lastDot >= 0) {
      // Both: the last one is the decimal separator.
      final decimal = lastComma > lastDot ? ',' : '.';
      final thousands = decimal == ',' ? '.' : ',';
      s = s.replaceAll(thousands, '').replaceAll(decimal, '.');
    } else if (lastComma >= 0) {
      s = ','.allMatches(s).length == 1
          ? s.replaceAll(',', '.')
          : s.replaceAll(',', '');
    } else if (lastDot >= 0 && '.'.allMatches(s).length > 1) {
      s = s.replaceAll('.', '');
    }
    final value = double.tryParse(s);
    if (value == null) return null;
    return percent ? value / 100 : value;
  }

  /// `1500.0 → 1500`, `12.5 → 12,5`, `1/3 → 0,3333` (up to 2 decimals from 1
  /// up, 4 below).
  static String formatNumber(double value, {String decimalSeparator = ','}) {
    if (value.isNaN || value.isInfinite) return errNum;
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 1e-9) {
      return rounded == 0 ? '0' : rounded.toStringAsFixed(0);
    }
    var text = value.toStringAsFixed(value.abs() >= 1 ? 2 : 4);
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
    if (text == '-0' || text.isEmpty) return '0';
    return text.replaceAll('.', decimalSeparator);
  }

  /// Rewrites one formula after columns / rows moved or were deleted.
  /// [columnMap] / [rowMap] give each old index its new one (null: deleted,
  /// which turns the reference into `#REF!`).
  static String remapFormula(
    String formula,
    List<int?> columnMap,
    List<int?> rowMap,
  ) {
    final List<_Token> tokens;
    try {
      tokens = _Lexer(formula).tokenize();
    } catch (_) {
      return formula;
    }
    // (start, end, text) edits, applied from the end.
    final edits = <(int, int, String)>[];
    for (var i = 0; i < tokens.length; i++) {
      final ref = tokens[i].ref;
      if (ref == null) continue;
      final isRange = i + 2 < tokens.length &&
          tokens[i + 1].kind == _Kind.colon &&
          tokens[i + 2].ref != null;
      if (!isRange) {
        final text = _remapRef(ref, ref, columnMap, rowMap);
        if (text != null) edits.add((tokens[i].start, tokens[i].end, text));
        continue;
      }
      // A range: a deleted first / last row (or column) shrinks it, like a
      // spreadsheet; it only breaks when nothing of it is left.
      final other = tokens[i + 2].ref!;
      final from = _remapRef(ref, other, columnMap, rowMap);
      final to = _remapRef(other, ref, columnMap, rowMap);
      if (from == errRef || to == errRef) {
        edits.add((tokens[i].start, tokens[i + 2].end, errRef));
      } else {
        if (from != null) edits.add((tokens[i].start, tokens[i].end, from));
        if (to != null) {
          edits.add((tokens[i + 2].start, tokens[i + 2].end, to));
        }
      }
      i += 2;
    }
    var result = formula;
    for (final (start, end, text) in edits.reversed) {
      result = result.replaceRange(start, end, text);
    }
    return result;
  }

  /// New text of [ref], or null to leave it as typed (outside the table).
  /// In a range, a deleted endpoint moves towards [toward] (the other end)
  /// to the nearest cell still there.
  static String? _remapRef(
    _Ref ref,
    _Ref toward,
    List<int?> columnMap,
    List<int?> rowMap,
  ) {
    if (ref.column >= columnMap.length ||
        (ref.row != null && ref.row! >= rowMap.length)) {
      return null;
    }
    int? survivor(List<int?> map, int from, int to) {
      final step = to >= from ? 1 : -1;
      for (var i = from; i >= 0 && i < map.length; i += step) {
        if (map[i] != null) return map[i];
        if (i == to) break;
      }
      return null;
    }

    final column = survivor(columnMap, ref.column, toward.column);
    final row = ref.row == null
        ? null
        : survivor(rowMap, ref.row!, toward.row ?? ref.row!);
    if (column == null || (ref.row != null && row == null)) return errRef;
    return '${ref.columnAbsolute ? r'$' : ''}'
        '${columnLetters(column)}'
        '${ref.rowAbsolute ? r'$' : ''}'
        '${row == null ? '' : row + 1}';
  }

  /// [after] is [before] with columns / rows moved, deleted or inserted
  /// (matched by id). Returns [after] with every formula rewritten so it
  /// still points at the same cells, like a spreadsheet does.
  static TableDocument rewriteReferences(
    TableDocument before,
    TableDocument after,
  ) {
    final newColumn = {
      for (final (i, c) in after.columns.indexed) c.id: i,
    };
    final newRow = {for (final (i, r) in after.rows.indexed) r.id: i};
    final columnMap = [for (final c in before.columns) newColumn[c.id]];
    final rowMap = [for (final r in before.rows) newRow[r.id]];
    var unchanged = true;
    for (final (i, target) in columnMap.indexed) {
      if (target != i) unchanged = false;
    }
    for (final (i, target) in rowMap.indexed) {
      if (target != i) unchanged = false;
    }
    if (unchanged) return after;

    String remap(String formula) => remapFormula(formula, columnMap, rowMap);
    return TableDocument(
      columns: [
        for (final c in after.columns)
          TableColumnDef(
            id: c.id,
            title: _remapHeader(c.title, remap),
            type: c.type,
          ),
      ],
      rows: [
        for (final r in after.rows)
          TableRowData(
            id: r.id,
            cells: {
              for (final entry in r.cells.entries)
                entry.key: switch (cellFormula(entry.value)) {
                  final formula? => '=${remap(formula)}',
                  null => entry.value,
                },
            },
          ),
      ],
    );
  }

  static String _remapHeader(String title, String Function(String) remap) {
    if (parseHeader(title).formula == null) return title;
    final eq = title.indexOf('=');
    final bracketed = TableDocument.isBracketColumnTitle(title);
    final end = bracketed ? title.lastIndexOf(']') : title.length;
    final formula = title.substring(eq + 1, end);
    return title.replaceRange(eq + 1, end, remap(formula));
  }
}

class ColumnHeader {
  const ColumnHeader({
    required this.label,
    required this.hidden,
    this.formula,
  });

  final String label;
  final String? formula;
  final bool hidden;

  /// What the header shows: the label, in brackets for a hidden column.
  String get display => hidden ? '[$label]' : label;
}

/// The value of a cell once its formula (if any) is computed.
sealed class CellValue {
  const CellValue();
}

class NumberValue extends CellValue {
  const NumberValue(this.value);
  final double value;
}

class TextValue extends CellValue {
  const TextValue(this.value);
  final String value;
}

class ErrorValue extends CellValue {
  const ErrorValue(this.code);
  final String code;
}

/// Computes every cell of a table, with memoisation and cycle detection.
class TableEvaluator {
  TableEvaluator(this.table, {this.decimalSeparator = ','})
      : headers = [
          for (final c in table.columns) TableFormula.parseHeader(c.title),
        ];

  final TableDocument table;
  final String decimalSeparator;
  final List<ColumnHeader> headers;

  final _cache = <int, CellValue>{};
  final _visiting = <int>{};
  final _parsed = <String, _Node>{};

  int get _columnCount => table.columns.length;

  bool hasColumnFormula(int column) =>
      column >= 0 && column < headers.length && headers[column].formula != null;

  /// Whether the cell's value comes from a formula (its own or its column's).
  bool isComputed(int row, int column) =>
      hasColumnFormula(column) ||
      TableFormula.cellFormula(_raw(row, column)) != null;

  bool get hasFormulas {
    if (headers.any((h) => h.formula != null)) return true;
    return table.rows.any(
      (r) => r.cells.values.any((v) => TableFormula.cellFormula(v) != null),
    );
  }

  String _raw(int row, int column) =>
      table.rows[row].cells[table.columns[column].id] ?? '';

  /// Formulas nested deeper than this (a cell using a cell using a cell…)
  /// give #NUM! instead of overflowing the stack.
  static const _maxDepth = 400;

  var _warmed = 0;
  var _warming = false;

  CellValue valueAt(int row, int column) {
    if (row < 0 ||
        row >= table.rows.length ||
        column < 0 ||
        column >= _columnCount) {
      return const ErrorValue(TableFormula.errRef);
    }
    final key = row * _columnCount + column;
    final cached = _cache[key];
    if (cached != null) return cached;
    if (_visiting.isEmpty && !_warming) {
      // Compute the cells before this one first, in order: a running total
      // (A2 = A1+1, A3 = A2+1…) then never nests deeply.
      _warming = true;
      try {
        while (_warmed < key) {
          final k = _warmed++;
          _cell(k ~/ _columnCount, k % _columnCount);
        }
      } finally {
        _warming = false;
      }
    }
    return _cell(row, column);
  }

  CellValue _cell(int row, int column) {
    final key = row * _columnCount + column;
    final cached = _cache[key];
    if (cached != null) return cached;
    if (_visiting.contains(key)) {
      return const ErrorValue(TableFormula.errCircular);
    }
    if (_visiting.length >= _maxDepth) {
      return const ErrorValue(TableFormula.errNum);
    }
    _visiting.add(key);
    try {
      final CellValue value;
      try {
        value = _compute(row, column);
      } on StackOverflowError {
        return const ErrorValue(TableFormula.errNum);
      }
      _cache[key] = value;
      return value;
    } finally {
      _visiting.remove(key);
    }
  }

  /// The text a cell shows: its value, or the result of its formula.
  String displayAt(int row, int column) => _text(valueAt(row, column));

  /// Evaluates a formula outside the table cells, as if typed in [row].
  CellValue evaluate(String formula, {int row = 0}) {
    try {
      return _scalar(_eval(_parse(formula), row));
    } on StackOverflowError {
      return const ErrorValue(TableFormula.errNum);
    }
  }

  /// Every numeric result goes through here: infinity / NaN become #NUM!.
  CellValue _num(double value) => value.isFinite
      ? NumberValue(value)
      : const ErrorValue(TableFormula.errNum);

  CellValue _compute(int row, int column) {
    final raw = _raw(row, column);
    final formula = headers[column].formula ?? TableFormula.cellFormula(raw);
    if (formula == null) return TextValue(raw);
    return _scalar(_eval(_parse(formula), row));
  }

  _Node _parse(String formula) => _parsed.putIfAbsent(formula, () {
        try {
          return _Parser(_Lexer(formula).tokenize()).parse();
        } catch (_) {
          // _SyntaxError, or a stack overflow on absurdly nested input.
          return const _ErrorNode(TableFormula.errSyntax);
        }
      });

  String _text(CellValue value) => switch (value) {
        NumberValue(:final value) =>
          TableFormula.formatNumber(value, decimalSeparator: decimalSeparator),
        TextValue(:final value) => value,
        ErrorValue(:final code) => code,
      };

  CellValue _scalar(Object value) => switch (value) {
        final CellValue v => v,
        // A bare range (`=A1:A3`) has no single value.
        _ => const ErrorValue(TableFormula.errValue),
      };

  /// Number for arithmetic: empty is 0, text must read as a number.
  Object _number(CellValue value) => switch (value) {
        NumberValue(:final value) => value,
        TextValue(:final value) when value.trim().isEmpty => 0.0,
        TextValue(:final value) => TableFormula.parseNumber(value) ??
            const ErrorValue(TableFormula.errValue),
        ErrorValue() => value,
      };

  Object _eval(_Node node, int row) {
    switch (node) {
      case _NumberNode(:final value):
        return _num(value);
      case _TextNode(:final value):
        return TextValue(value);
      case _ErrorNode(:final code):
        return ErrorValue(code);
      case _RefNode(:final ref):
        final target = ref.row ?? row;
        // Rows past the end read as empty, like an empty sheet: the table
        // can grow into them.
        if (target >= table.rows.length && ref.column < _columnCount) {
          return const TextValue('');
        }
        return valueAt(target, ref.column);
      case _RangeNode(:final from, :final to):
        return _range(from, to, row);
      case _UnaryNode(:final op, :final operand):
        final value = _number(_scalar(_eval(operand, row)));
        if (value is ErrorValue) return value;
        final n = value as double;
        return _num(op == '-' ? -n : n);
      case _PercentNode(:final operand):
        final value = _number(_scalar(_eval(operand, row)));
        if (value is ErrorValue) return value;
        return _num((value as double) / 100);
      case _BinaryNode(:final op, :final left, :final right):
        return _binary(
            op, _scalar(_eval(left, row)), _scalar(_eval(right, row)));
      case _CallNode(:final name, :final args):
        return _call(name, args, row);
    }
  }

  Object _range(_Ref from, _Ref to, int row) {
    final c1 = math.min(from.column, to.column);
    final c2 = math.max(from.column, to.column);
    // `C:C` (or a bare letter on one side): the whole column.
    final wholeColumns = from.row == null || to.row == null;
    final r1 = wholeColumns ? 0 : math.min(from.row!, to.row!);
    // Rows past the end are empty: `SOMME(B1:B100)` leaves room to grow.
    final r2 = wholeColumns
        ? table.rows.length - 1
        : math.min(math.max(from.row!, to.row!), table.rows.length - 1);
    if (c2 >= _columnCount) return const ErrorValue(TableFormula.errRef);
    return _Range([
      for (var r = r1; r <= r2; r++)
        for (var c = c1; c <= c2; c++) valueAt(r, c),
    ]);
  }

  CellValue _binary(String op, CellValue left, CellValue right) {
    if (left is ErrorValue) return left;
    if (right is ErrorValue) return right;
    if (op == '&') return TextValue(_text(left) + _text(right));
    if (const {'=', '<>', '<', '>', '<=', '>='}.contains(op)) {
      return _compare(op, left, right);
    }
    final a = _number(left);
    if (a is ErrorValue) return a;
    final b = _number(right);
    if (b is ErrorValue) return b;
    final x = a as double;
    final y = b as double;
    switch (op) {
      case '+':
        return _num(x + y);
      case '-':
        return _num(x - y);
      case '*':
        return _num(x * y);
      case '/':
        return y == 0 ? const ErrorValue(TableFormula.errDiv0) : _num(x / y);
      case '^':
        final result = math.pow(x, y).toDouble();
        return result.isFinite
            ? _num(result)
            : const ErrorValue(TableFormula.errNum);
    }
    return const ErrorValue(TableFormula.errSyntax);
  }

  CellValue _compare(String op, CellValue left, CellValue right) {
    final a = _number(left);
    final b = _number(right);
    final int order;
    if (a is double && b is double) {
      order = a.compareTo(b);
    } else {
      order = _text(left).toLowerCase().compareTo(_text(right).toLowerCase());
    }
    final result = switch (op) {
      '=' => order == 0,
      '<>' => order != 0,
      '<' => order < 0,
      '>' => order > 0,
      '<=' => order <= 0,
      _ => order >= 0,
    };
    return _num(result ? 1 : 0);
  }

  /// Numbers of the arguments, Excel style: in a range, text and empty cells
  /// are skipped; a direct argument must be a number.
  Object _numbers(List<_Node> args, int row) {
    final numbers = <double>[];
    for (final arg in args) {
      final value = _eval(arg, row);
      if (value is _Range) {
        for (final cell in value.cells) {
          switch (cell) {
            case ErrorValue():
              return cell;
            case NumberValue(:final value):
              numbers.add(value);
            case TextValue(:final value):
              final n = TableFormula.parseNumber(value);
              if (n != null) numbers.add(n);
          }
        }
      } else {
        final n = _number(value as CellValue);
        if (n is ErrorValue) return n;
        numbers.add(n as double);
      }
    }
    return numbers;
  }

  Object _single(List<_Node> args, int row, int index) {
    if (index >= args.length) return const ErrorValue(TableFormula.errValue);
    return _number(_scalar(_eval(args[index], row)));
  }

  bool _truthy(CellValue value) => switch (value) {
        NumberValue(:final value) => value != 0,
        TextValue(:final value) => switch (value.trim().toUpperCase()) {
            'VRAI' || 'TRUE' => true,
            '' || 'FAUX' || 'FALSE' => false,
            final other => (TableFormula.parseNumber(other) ?? 1) != 0,
          },
        ErrorValue() => false,
      };

  CellValue _call(String name, List<_Node> args, int row) {
    switch (name) {
      case 'SI':
      case 'IF':
        if (args.length < 2 || args.length > 3) {
          return const ErrorValue(TableFormula.errValue);
        }
        final condition = _scalar(_eval(args[0], row));
        if (condition is ErrorValue) return condition;
        if (_truthy(condition)) return _scalar(_eval(args[1], row));
        return args.length == 3
            ? _scalar(_eval(args[2], row))
            : const NumberValue(0);
      case 'ET':
      case 'AND':
      case 'OU':
      case 'OR':
        if (args.isEmpty) return const ErrorValue(TableFormula.errValue);
        final values = <bool>[];
        for (final arg in args) {
          final value = _scalar(_eval(arg, row));
          if (value is ErrorValue) return value;
          values.add(_truthy(value));
        }
        final all = name == 'ET' || name == 'AND';
        return _num(
            (all ? values.every((v) => v) : values.any((v) => v)) ? 1 : 0);
      case 'NON':
      case 'NOT':
        if (args.length != 1) return const ErrorValue(TableFormula.errValue);
        final value = _scalar(_eval(args[0], row));
        if (value is ErrorValue) return value;
        return _num(_truthy(value) ? 0 : 1);
      case 'NBVAL':
      case 'COUNTA':
        var count = 0;
        for (final arg in args) {
          final value = _eval(arg, row);
          final cells = value is _Range ? value.cells : [value as CellValue];
          for (final cell in cells) {
            if (cell is! TextValue || cell.value.trim().isNotEmpty) count++;
          }
        }
        return _num(count.toDouble());
    }

    final double Function(List<double>)? aggregate = switch (name) {
      'SOMME' || 'SUM' => (List<double> n) => n.fold(0.0, (a, b) => a + b),
      'PRODUIT' || 'PRODUCT' => (List<double> n) =>
          n.isEmpty ? 0.0 : n.fold(1.0, (a, b) => a * b),
      'MOYENNE' || 'AVERAGE' => (List<double> n) =>
          n.isEmpty ? double.nan : n.fold(0.0, (a, b) => a + b) / n.length,
      'MIN' => (List<double> n) => n.isEmpty ? 0.0 : n.reduce(math.min),
      'MAX' => (List<double> n) => n.isEmpty ? 0.0 : n.reduce(math.max),
      'NB' || 'COUNT' => (List<double> n) => n.length.toDouble(),
      _ => null,
    };
    if (aggregate != null) {
      if (args.isEmpty) return const ErrorValue(TableFormula.errValue);
      final numbers = _numbers(args, row);
      if (numbers is ErrorValue) return numbers;
      final result = aggregate(numbers as List<double>);
      if (result.isNaN) return const ErrorValue(TableFormula.errDiv0);
      return _num(result);
    }

    final arity = switch (name) {
      'ABS' || 'RACINE' || 'SQRT' || 'ENT' || 'INT' => (1, 1),
      'ARRONDI' || 'ROUND' => (1, 2),
      'MOD' => (2, 2),
      _ => null,
    };
    if (arity == null) return const ErrorValue(TableFormula.errName);
    if (args.length < arity.$1 || args.length > arity.$2) {
      return const ErrorValue(TableFormula.errValue);
    }
    final x = _single(args, row, 0);
    if (x is ErrorValue) return x;
    final n = x as double;
    switch (name) {
      case 'ABS':
        return _num(n.abs());
      case 'RACINE':
      case 'SQRT':
        return n < 0
            ? const ErrorValue(TableFormula.errNum)
            : _num(math.sqrt(n));
      case 'ENT':
      case 'INT':
        return _num(n.floorToDouble());
      case 'ARRONDI':
      case 'ROUND':
        var digits = 0.0;
        if (args.length > 1) {
          final d = _single(args, row, 1);
          if (d is ErrorValue) return d;
          digits = d as double;
        }
        final factor = math.pow(10, digits.clamp(-15, 15).round()).toDouble();
        return _num((n * factor).roundToDouble() / factor);
      case 'MOD':
        final d = _single(args, row, 1);
        if (d is ErrorValue) return d;
        final y = d as double;
        if (y == 0) return const ErrorValue(TableFormula.errDiv0);
        return _num(n - y * (n / y).floorToDouble());
    }
    return const ErrorValue(TableFormula.errName);
  }
}

class _Range {
  const _Range(this.cells);
  final List<CellValue> cells;
}

// ── Lexer ────────────────────────────────────────────────────────────────

class _SyntaxError implements Exception {
  const _SyntaxError();
}

/// A cell reference: column + optional row (null: same row / whole column).
class _Ref {
  const _Ref({
    required this.column,
    required this.row,
    this.columnAbsolute = false,
    this.rowAbsolute = false,
  });

  final int column;
  final int? row;
  final bool columnAbsolute;
  final bool rowAbsolute;
}

enum _Kind { number, text, ref, function, error, op, open, close, sep, colon }

class _Token {
  const _Token(this.kind, this.text, this.start, this.end,
      {this.number, this.ref});

  final _Kind kind;
  final String text;
  final int start;
  final int end;
  final double? number;
  final _Ref? ref;
}

class _Lexer {
  _Lexer(this.source);

  final String source;
  static const _maxRows = 1000000;
  static final _refPattern = RegExp(r'^(\$?)([A-Za-z]{1,3})(\$?)(\d*)$');
  static final _word = RegExp(r'[A-Za-z0-9_.$]');
  static final _digit = RegExp(r'\d');

  List<_Token> tokenize() {
    final tokens = <_Token>[];
    var i = 0;
    while (i < source.length) {
      final c = source[i];
      if (c.trim().isEmpty) {
        i++;
        continue;
      }
      final start = i;
      if (_digit.hasMatch(c) ||
          (c == '.' &&
              i + 1 < source.length &&
              _digit.hasMatch(source[i + 1]))) {
        while (i < source.length && _digit.hasMatch(source[i])) {
          i++;
        }
        // One decimal separator, `.` or `,`, when digits follow it.
        if (i + 1 < source.length &&
            (source[i] == '.' || source[i] == ',') &&
            _digit.hasMatch(source[i + 1])) {
          i++;
          while (i < source.length && _digit.hasMatch(source[i])) {
            i++;
          }
        }
        final text = source.substring(start, i);
        final number = double.parse(text.replaceAll(',', '.'));
        tokens.add(number.isFinite
            ? _Token(_Kind.number, text, start, i, number: number)
            : _Token(_Kind.error, TableFormula.errNum, start, i));
        continue;
      }
      if (c == '"') {
        i++;
        final buffer = StringBuffer();
        while (true) {
          if (i >= source.length) throw const _SyntaxError();
          if (source[i] == '"') {
            if (i + 1 < source.length && source[i + 1] == '"') {
              buffer.write('"');
              i += 2;
              continue;
            }
            i++;
            break;
          }
          buffer.write(source[i]);
          i++;
        }
        tokens.add(_Token(_Kind.text, buffer.toString(), start, i));
        continue;
      }
      if (c == '#') {
        final code = TableFormula._errors.firstWhere(
          (e) => source.startsWith(e, i),
          orElse: () => throw const _SyntaxError(),
        );
        i += code.length;
        tokens.add(_Token(_Kind.error, code, start, i));
        continue;
      }
      if (RegExp(r'[A-Za-z_$]').hasMatch(c)) {
        while (i < source.length && _word.hasMatch(source[i])) {
          i++;
        }
        final word = source.substring(start, i);
        var next = i;
        while (next < source.length && source[next].trim().isEmpty) {
          next++;
        }
        if (next < source.length && source[next] == '(') {
          tokens.add(_Token(_Kind.function, word.toUpperCase(), start, i));
          continue;
        }
        final match = _refPattern.firstMatch(word);
        if (match == null) {
          // Unknown name: shown as #NOM? rather than a syntax error.
          tokens.add(_Token(_Kind.error, TableFormula.errName, start, i));
          continue;
        }
        final digits = match.group(4)!;
        // Past a million rows the number is a typo, not a cell.
        final parsed = digits.isEmpty ? null : int.tryParse(digits);
        final row = parsed == null ? null : parsed - 1;
        if (digits.isNotEmpty && (row == null || row < 0 || row >= _maxRows)) {
          tokens.add(_Token(_Kind.error, TableFormula.errRef, start, i));
          continue;
        }
        tokens.add(_Token(
          _Kind.ref,
          word,
          start,
          i,
          ref: _Ref(
            column: TableFormula.columnIndex(match.group(2)!),
            row: row,
            columnAbsolute: match.group(1)!.isNotEmpty,
            rowAbsolute: match.group(3)!.isNotEmpty,
          ),
        ));
        continue;
      }
      final two = i + 1 < source.length ? source.substring(i, i + 2) : '';
      if (two == '<=' || two == '>=' || two == '<>') {
        tokens.add(_Token(_Kind.op, two, start, i + 2));
        i += 2;
        continue;
      }
      final kind = switch (c) {
        '+' ||
        '-' ||
        '*' ||
        '/' ||
        '^' ||
        '%' ||
        '&' ||
        '=' ||
        '<' ||
        '>' =>
          _Kind.op,
        '(' => _Kind.open,
        ')' => _Kind.close,
        ';' || ',' => _Kind.sep,
        ':' => _Kind.colon,
        _ => throw const _SyntaxError(),
      };
      tokens.add(_Token(kind, c, start, i + 1));
      i++;
    }
    return tokens;
  }
}

// ── Parser ───────────────────────────────────────────────────────────────

sealed class _Node {
  const _Node();
}

class _NumberNode extends _Node {
  const _NumberNode(this.value);
  final double value;
}

class _TextNode extends _Node {
  const _TextNode(this.value);
  final String value;
}

class _ErrorNode extends _Node {
  const _ErrorNode(this.code);
  final String code;
}

class _RefNode extends _Node {
  const _RefNode(this.ref);
  final _Ref ref;
}

class _RangeNode extends _Node {
  const _RangeNode(this.from, this.to);
  final _Ref from;
  final _Ref to;
}

class _UnaryNode extends _Node {
  const _UnaryNode(this.op, this.operand);
  final String op;
  final _Node operand;
}

class _PercentNode extends _Node {
  const _PercentNode(this.operand);
  final _Node operand;
}

class _BinaryNode extends _Node {
  const _BinaryNode(this.op, this.left, this.right);
  final String op;
  final _Node left;
  final _Node right;
}

class _CallNode extends _Node {
  const _CallNode(this.name, this.args);
  final String name;
  final List<_Node> args;
}

/// Precedence, low to high: comparison, `&`, `+ -`, `* /`, `^`, unary,
/// `%`.
class _Parser {
  _Parser(this.tokens);

  final List<_Token> tokens;
  var _i = 0;

  _Token? get _peek => _i < tokens.length ? tokens[_i] : null;

  bool _isOp(Set<String> ops) {
    final t = _peek;
    return t != null && t.kind == _Kind.op && ops.contains(t.text);
  }

  _Token _take() {
    final t = _peek;
    if (t == null) throw const _SyntaxError();
    _i++;
    return t;
  }

  void _expect(_Kind kind) {
    if (_take().kind != kind) throw const _SyntaxError();
  }

  _Node parse() {
    if (tokens.isEmpty) throw const _SyntaxError();
    final node = _comparison();
    if (_peek != null) throw const _SyntaxError();
    return node;
  }

  _Node _comparison() {
    var node = _concat();
    while (_isOp(const {'=', '<>', '<', '>', '<=', '>='})) {
      final op = _take().text;
      node = _BinaryNode(op, node, _concat());
    }
    return node;
  }

  _Node _concat() {
    var node = _additive();
    while (_isOp(const {'&'})) {
      _take();
      node = _BinaryNode('&', node, _additive());
    }
    return node;
  }

  _Node _additive() {
    var node = _term();
    while (_isOp(const {'+', '-'})) {
      final op = _take().text;
      node = _BinaryNode(op, node, _term());
    }
    return node;
  }

  _Node _term() {
    var node = _power();
    while (_isOp(const {'*', '/'})) {
      final op = _take().text;
      node = _BinaryNode(op, node, _power());
    }
    return node;
  }

  _Node _power() {
    var node = _unary();
    while (_isOp(const {'^'})) {
      _take();
      node = _BinaryNode('^', node, _unary());
    }
    return node;
  }

  _Node _unary() {
    if (_isOp(const {'-', '+'})) {
      final op = _take().text;
      return _UnaryNode(op, _unary());
    }
    var node = _primary();
    while (_isOp(const {'%'})) {
      _take();
      node = _PercentNode(node);
    }
    return node;
  }

  _Node _primary() {
    final t = _take();
    switch (t.kind) {
      case _Kind.number:
        return _NumberNode(t.number!);
      case _Kind.text:
        return _TextNode(t.text);
      case _Kind.error:
        _skipRangeEnd();
        return _ErrorNode(t.text);
      case _Kind.ref:
        if (_peek?.kind == _Kind.colon) {
          _take();
          final end = _take();
          if (end.kind == _Kind.error) return _ErrorNode(end.text);
          if (end.kind != _Kind.ref) throw const _SyntaxError();
          return _RangeNode(t.ref!, end.ref!);
        }
        return _RefNode(t.ref!);
      case _Kind.function:
        _expect(_Kind.open);
        final args = <_Node>[];
        if (_peek?.kind != _Kind.close) {
          args.add(_comparison());
          while (_peek?.kind == _Kind.sep) {
            _take();
            args.add(_comparison());
          }
        }
        _expect(_Kind.close);
        return _CallNode(t.text, args);
      case _Kind.open:
        final node = _comparison();
        _expect(_Kind.close);
        return node;
      default:
        throw const _SyntaxError();
    }
  }

  /// `#REF!:B3` (a range whose start was deleted) stays one error.
  void _skipRangeEnd() {
    if (_peek?.kind != _Kind.colon) return;
    _take();
    final end = _take();
    if (end.kind != _Kind.ref && end.kind != _Kind.error) {
      throw const _SyntaxError();
    }
  }
}
