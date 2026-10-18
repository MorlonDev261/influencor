import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/features/accounting/data/accounting_store.dart';
import 'package:influencor/features/accounting/domain/ledger.dart';
import 'package:influencor/features/accounting/domain/ledger_entry.dart';
import 'package:influencor/features/accounting/domain/ledger_series.dart';
import 'package:path/path.dart' as p;

LedgerEntry _entry(
  String id,
  DateTime date,
  int amount, {
  LedgerDirection direction = LedgerDirection.credit,
  LedgerAccount account = LedgerAccount.cash,
}) =>
    LedgerEntry(
      id: id,
      date: date,
      amount: amount,
      account: account,
      type: direction == LedgerDirection.credit
          ? LedgerType.sale
          : LedgerType.expense,
      direction: direction,
    );

void main() {
  group('migration', () {
    late Directory root;
    late File file;

    setUp(() {
      root = Directory.systemTemp.createTempSync('ledger_sheets');
      file = File(p.join(root.path, '.clipboard', 'accounting.json'))
        ..createSync(recursive: true);
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('a version 1 file becomes one open sheet without losing entries',
        () async {
      file.writeAsStringSync(jsonEncode({
        'version': 1,
        'entries': [
          _entry('a', DateTime(2026, 10, 10, 9), 10000).toJson(),
          _entry('b', DateTime(2026, 10, 12), 2500,
                  direction: LedgerDirection.debit)
              .toJson(),
        ],
      }));

      final ledger = await AccountingStore(root.path).load();
      expect(ledger.sheets, hasLength(1));
      expect(ledger.current.id, Ledger.initialSheetId);
      expect(ledger.current.isOpen, isTrue);
      expect(ledger.current.start, DateTime(2026, 10, 10, 9));
      expect(ledger.currentEntries.map((e) => e.id), ['b', 'a']);
      expect(ledger.totalsOf(ledger.current.id).closingTotal, 7500);
    });

    test(
        'the next write upgrades to version 2 and old readers still see '
        'every entry', () async {
      file.writeAsStringSync(jsonEncode({
        'version': 1,
        'entries': [_entry('a', DateTime(2026, 10, 10), 10000).toJson()],
      }));
      final store = AccountingStore(root.path);
      await store.upsert(_entry('b', DateTime(2026, 10, 11), 500));
      await store.closeCurrentSheet(at: DateTime(2026, 10, 18, 15));
      await store.upsert(_entry('c', DateTime(2026, 10, 18, 16), 300,
          direction: LedgerDirection.debit));

      final json = jsonDecode(file.readAsStringSync()) as Map;
      expect(json['version'], 2);
      expect(json['sheets'], hasLength(2));
      // What a version 1 reader does: sum the flat entry list.
      final v1 = [
        for (final raw in json['entries'] as List) LedgerEntry.tryFromJson(raw)!
      ];
      expect(v1.map((e) => e.id).toSet(), {'a', 'b', 'c'});
      expect(v1.fold<int>(0, (s, e) => s + e.signedAmount), 10200);

      final reloaded = await AccountingStore(root.path).load();
      expect(reloaded.sheets.first.id, Ledger.initialSheetId);
      expect(reloaded.entriesOf(Ledger.initialSheetId).map((e) => e.id),
          ['b', 'a']);
      expect(reloaded.currentEntries.single.id, 'c');
    });

    test('a missing or broken file is an empty open sheet', () async {
      file.writeAsStringSync('{not json');
      final ledger = await AccountingStore(root.path).load();
      expect(ledger.entries, isEmpty);
      expect(ledger.sheets.single.isOpen, isTrue);
      expect(ledger.canClose, isFalse);
    });
  });

  group('closing a sheet', () {
    final start = DateTime(2026, 10, 10);
    final closeAt = DateTime(2026, 10, 18, 15, 30);

    Ledger sample() => Ledger(
          sheets: [LedgerSheet(id: 's1', start: start)],
          entries: [
            _entry('a', DateTime(2026, 10, 11), 20000,
                account: LedgerAccount.mvola),
            _entry('b', DateTime(2026, 10, 12), 5000,
                direction: LedgerDirection.debit),
          ],
        );

    test('freezes the period and opens a new empty sheet at the same instant',
        () {
      final ledger = sample().closeCurrent(at: closeAt, newSheetId: 's2');
      final closed = ledger.sheetById('s1')!;
      expect(closed.start, start);
      expect(closed.end, closeAt);
      expect(ledger.current.id, 's2');
      expect(ledger.current.start, closeAt);
      expect(ledger.current.isOpen, isTrue);
      expect(ledger.currentEntries, isEmpty);
      expect(ledger.canClose, isFalse);
      expect(ledger.entriesOf('s1'), hasLength(2));
    });

    test('carries the closing balance over, account by account', () {
      var ledger = sample().closeCurrent(at: closeAt, newSheetId: 's2');
      final old = ledger.totalsOf('s1');
      expect(old.credit, 20000);
      expect(old.debit, 5000);
      expect(old.openingTotal, 0);
      expect(old.closingTotal, 15000);

      ledger = ledger.upsert(_entry('c', DateTime(2026, 10, 19), 1000,
          direction: LedgerDirection.debit, account: LedgerAccount.mvola));
      final now = ledger.totalsOf('s2');
      expect(now.opening[LedgerAccount.mvola], 20000);
      expect(now.opening[LedgerAccount.cash], -5000);
      expect(now.credit, 0);
      expect(now.debit, 1000);
      expect(now.closing[LedgerAccount.mvola], 19000);
      expect(now.closingTotal, 14000);
      expect(ledger.entries.fold<int>(0, (s, e) => s + e.signedAmount),
          now.closingTotal);
    });

    test(
        'entries of a closed sheet are read-only, new ones go to the open '
        'sheet', () {
      final ledger = sample().closeCurrent(at: closeAt, newSheetId: 's2');
      final a = ledger.entries.firstWhere((e) => e.id == 'a');
      expect(ledger.isClosedEntry(a), isTrue);
      expect(() => ledger.upsert(a), throwsA(isA<LedgerSheetClosedError>()));
      expect(() => ledger.remove('a'), throwsA(isA<LedgerSheetClosedError>()));

      // Even back-dated, a new entry lands in the open sheet.
      final next = ledger.upsert(_entry('d', DateTime(2026, 10, 1), 700));
      expect(next.entries.firstWhere((e) => e.id == 'd').sheetId, 's2');
      final edited = next.upsert(_entry('d', DateTime(2026, 10, 1), 900));
      expect(edited.totalsOf('s2').credit, 900);
      expect(edited.remove('d').currentEntries, isEmpty);
    });

    test('an empty sheet cannot be closed', () {
      final ledger = Ledger.empty(now: start);
      expect(() => ledger.closeCurrent(at: closeAt, newSheetId: 'x'),
          throwsStateError);
    });

    test('closing right at the start keeps the closed sheet first', () {
      final ledger = Ledger(
        sheets: [LedgerSheet(id: 's1', start: closeAt)],
        entries: [_entry('a', closeAt, 100)],
      ).closeCurrent(at: closeAt, newSheetId: 's2');
      expect(ledger.sheets.map((s) => s.id), ['s1', 's2']);
      expect(ledger.current.id, 's2');
      // Round trip through JSON keeps the same order.
      final again = Ledger.fromJson(jsonDecode(jsonEncode(ledger.toJson())));
      expect(again.sheets.map((s) => s.id), ['s1', 's2']);
      expect(again.current.id, 's2');
    });

    test('a damaged sheet list is repaired: one open sheet, at the end', () {
      final ledger = Ledger(
        sheets: [
          LedgerSheet(id: 'b', start: DateTime(2026, 2, 1)),
          LedgerSheet(
              id: 'c', start: DateTime(2026, 3, 1), end: DateTime(2026, 4, 1)),
          LedgerSheet(id: 'a', start: DateTime(2026, 1, 1)),
        ],
        entries: [
          _entry('x', DateTime(2026, 5, 1), 1).inSheet('unknown'),
          _entry('y', DateTime(2026, 1, 5), 1).inSheet('a'),
        ],
      );
      expect(ledger.sheets.map((s) => s.id).take(3), ['a', 'b', 'c']);
      expect(ledger.sheets.where((s) => s.isOpen), hasLength(1));
      expect(ledger.sheetById('a')!.end, DateTime(2026, 2, 1));
      expect(ledger.current.start, DateTime(2026, 4, 1));
      expect(ledger.currentEntries.single.id, 'x');
    });
  });

  group('chart series', () {
    test('one point per day, quiet days at zero', () {
      final series = buildLedgerSeries([
        _entry('a', DateTime(2026, 10, 10, 9), 1000),
        _entry('b', DateTime(2026, 10, 10, 18), 500),
        _entry('c', DateTime(2026, 10, 12), 300,
            direction: LedgerDirection.debit),
      ], to: DateTime(2026, 10, 13))!;
      expect(series.step, SeriesStep.day);
      expect(series.buckets.map((b) => b.start.day), [10, 11, 12, 13]);
      expect(series.buckets.map((b) => b.credit), [1500, 0, 0, 0]);
      expect(series.buckets.map((b) => b.debit), [0, 0, 300, 0]);
      expect(series.maxValue, 1500);
    });

    test('long periods switch to weeks starting on Monday', () {
      final series = buildLedgerSeries([
        _entry('a', DateTime(2026, 1, 7), 1000), // Wednesday
        _entry('b', DateTime(2026, 1, 9), 1000),
        _entry('c', DateTime(2026, 6, 1), 200,
            direction: LedgerDirection.debit),
      ])!;
      expect(series.step, SeriesStep.week);
      expect(series.buckets.first.start, DateTime(2026, 1, 5));
      expect(series.buckets.first.credit, 2000);
      expect(series.buckets.every((b) => b.start.weekday == DateTime.monday),
          isTrue);
      expect(series.buckets.last.debit, 200);
    });

    test('no entries, no series', () {
      expect(buildLedgerSeries(const []), isNull);
    });
  });
}
