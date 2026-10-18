import 'ledger_entry.dart';

/// One accounting period. Exactly one sheet is open (the last one); closing it
/// freezes its entries and starts a new sheet at the same instant.
class LedgerSheet {
  const LedgerSheet({required this.id, required this.start, this.end});

  final String id;
  final DateTime start;

  /// When the sheet was closed; null for the open (current) sheet.
  final DateTime? end;

  bool get isOpen => end == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'start': start.toIso8601String(),
        if (end != null) 'end': end!.toIso8601String(),
      };

  static LedgerSheet? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final start = DateTime.tryParse('${raw['start']}');
    if (id is! String || id.isEmpty || start == null) return null;
    return LedgerSheet(
      id: id,
      start: start,
      end: raw['end'] == null ? null : DateTime.tryParse('${raw['end']}'),
    );
  }
}

/// Totals of one sheet. Balances are real money sitting in the accounts, so a
/// new sheet carries the previous closing balance over as its opening balance.
class LedgerSheetTotals {
  const LedgerSheetTotals({
    required this.opening,
    required this.closing,
    required this.credit,
    required this.debit,
    required this.count,
  });

  final Map<LedgerAccount, int> opening;
  final Map<LedgerAccount, int> closing;

  /// Money in / out during the sheet (positive amounts).
  final int credit;
  final int debit;
  final int count;

  int get openingTotal => opening.values.fold(0, (s, v) => s + v);
  int get closingTotal => closing.values.fold(0, (s, v) => s + v);
  int get net => credit - debit;
}

/// Thrown when changing an entry of a closed (read-only) sheet.
class LedgerSheetClosedError extends StateError {
  LedgerSheetClosedError(String entryId)
      : super('Entry $entryId belongs to a closed sheet');
}

/// The whole ledger: its sheets (oldest first, the last one open) and every
/// entry (newest first), each assigned to a sheet.
class Ledger {
  Ledger._(this.sheets, this.entries);

  /// Id of the sheet holding entries written before sheets existed.
  static const initialSheetId = 'initial';

  /// Builds a consistent ledger: sorts, repairs the open-sheet invariant and
  /// assigns orphan entries (no or unknown sheet) to the open sheet.
  factory Ledger({
    required List<LedgerSheet> sheets,
    required List<LedgerEntry> entries,
    DateTime? now,
  }) {
    // Same start (closed at its very start): the closed sheet comes first.
    final list = [...sheets]..sort((a, b) {
        final byStart = a.start.compareTo(b.start);
        if (byStart != 0) return byStart;
        return (a.end ?? DateTime(9999)).compareTo(b.end ?? DateTime(9999));
      });
    if (list.isEmpty) {
      DateTime? first;
      for (final e in entries) {
        if (first == null || e.date.isBefore(first)) first = e.date;
      }
      list.add(LedgerSheet(
          id: initialSheetId, start: first ?? now ?? DateTime.now()));
    }
    for (var i = 0; i < list.length - 1; i++) {
      if (list[i].isOpen) {
        list[i] = LedgerSheet(
            id: list[i].id, start: list[i].start, end: list[i + 1].start);
      }
    }
    if (!list.last.isOpen) {
      final end = list.last.end!;
      list.add(
          LedgerSheet(id: 'open-${end.millisecondsSinceEpoch}', start: end));
    }
    final ids = {for (final s in list) s.id};
    final open = list.last.id;
    final assigned = [
      for (final e in entries) ids.contains(e.sheetId) ? e : e.inSheet(open),
    ]..sort((a, b) => b.date.compareTo(a.date));
    return Ledger._(List.unmodifiable(list), List.unmodifiable(assigned));
  }

  factory Ledger.empty({DateTime? now}) =>
      Ledger(sheets: const [], entries: const [], now: now);

  /// Reads the stored JSON. Version 1 (a bare `entries` list) becomes a single
  /// open sheet starting at the oldest entry, so nothing is lost.
  factory Ledger.fromJson(Object? data, {DateTime? now}) {
    final map = data is Map ? data : const {};
    final rawEntries = map['entries'];
    final rawSheets = map['sheets'];
    return Ledger(
      now: now,
      sheets: [
        if (rawSheets is List)
          for (final raw in rawSheets)
            if (LedgerSheet.tryFromJson(raw) case final s?) s,
      ],
      entries: [
        if (rawEntries is List)
          for (final raw in rawEntries)
            if (LedgerEntry.tryFromJson(raw) case final e?) e,
      ],
    );
  }

  /// Version 2 keeps a flat `entries` list (each tagged with its sheet), so
  /// older app versions still read every entry and the overall balance.
  Map<String, dynamic> toJson() => {
        'version': 2,
        'sheets': [for (final s in sheets) s.toJson()],
        'entries': [for (final e in entries) e.toJson()],
      };

  final List<LedgerSheet> sheets;
  final List<LedgerEntry> entries;

  LedgerSheet get current => sheets.last;

  LedgerSheet? sheetById(String? id) {
    for (final s in sheets) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Entries of [sheetId], newest first.
  List<LedgerEntry> entriesOf(String sheetId) => [
        for (final e in entries)
          if (e.sheetId == sheetId) e
      ];

  List<LedgerEntry> get currentEntries => entriesOf(current.id);

  bool isClosedEntry(LedgerEntry e) => sheetById(e.sheetId)?.isOpen == false;

  /// A sheet can be closed once something happened in it.
  bool get canClose => entries.any((e) => e.sheetId == current.id);

  LedgerSheetTotals totalsOf(String sheetId) {
    final index = sheets.indexWhere((s) => s.id == sheetId);
    final before = {for (final s in sheets.take(index)) s.id};
    final opening = {for (final a in LedgerAccount.values) a: 0};
    final closing = {for (final a in LedgerAccount.values) a: 0};
    var credit = 0, debit = 0, count = 0;
    for (final e in entries) {
      if (before.contains(e.sheetId)) {
        opening[e.account] = opening[e.account]! + e.signedAmount;
      } else if (e.sheetId == sheetId) {
        closing[e.account] = closing[e.account]! + e.signedAmount;
        count++;
        if (e.direction == LedgerDirection.credit) {
          credit += e.amount;
        } else {
          debit += e.amount;
        }
      }
    }
    for (final a in LedgerAccount.values) {
      closing[a] = closing[a]! + opening[a]!;
    }
    return LedgerSheetTotals(
      opening: opening,
      closing: closing,
      credit: credit,
      debit: debit,
      count: count,
    );
  }

  /// Inserts the entry into the open sheet, or replaces the one with the same
  /// id where it is. Entries of closed sheets are read-only.
  Ledger upsert(LedgerEntry entry) {
    final i = entries.indexWhere((e) => e.id == entry.id);
    if (i < 0) {
      return Ledger._from(this, [...entries, entry.inSheet(current.id)]);
    }
    final old = entries[i];
    if (isClosedEntry(old)) throw LedgerSheetClosedError(old.id);
    return Ledger._from(this, [...entries]..[i] = entry.inSheet(old.sheetId!));
  }

  Ledger remove(String id) {
    final old = entries.where((e) => e.id == id).firstOrNull;
    if (old == null) return this;
    if (isClosedEntry(old)) throw LedgerSheetClosedError(old.id);
    return Ledger._from(this, [...entries]..remove(old));
  }

  /// Closes the open sheet at [at] and opens [newSheetId] at the same instant.
  Ledger closeCurrent({required DateTime at, required String newSheetId}) {
    if (!canClose) throw StateError('The current sheet is empty');
    final open = current;
    final end = at.isBefore(open.start) ? open.start : at;
    return Ledger(
      sheets: [
        ...sheets.take(sheets.length - 1),
        LedgerSheet(id: open.id, start: open.start, end: end),
        LedgerSheet(id: newSheetId, start: end),
      ],
      entries: entries,
    );
  }

  static Ledger _from(Ledger base, List<LedgerEntry> entries) =>
      Ledger(sheets: base.sheets, entries: entries);
}
