/// Where the money sits.
enum LedgerAccount { orangeMoney, mvola, airtelMoney, cash }

/// What the operation is about.
enum LedgerType { purchase, sale, expense }

/// Money in (credit) or out (debit).
enum LedgerDirection { credit, debit }

extension LedgerAccountLabel on LedgerAccount {
  String get label => switch (this) {
        LedgerAccount.orangeMoney => 'Orange Money',
        LedgerAccount.mvola => 'MVola',
        LedgerAccount.airtelMoney => 'Airtel Money',
        LedgerAccount.cash => 'Cash',
      };
}

extension LedgerTypeDefaults on LedgerType {
  /// A sale brings money in; purchases and expenses take it out.
  LedgerDirection get defaultDirection =>
      this == LedgerType.sale ? LedgerDirection.credit : LedgerDirection.debit;
}

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.date,
    required this.amount,
    required this.account,
    required this.type,
    required this.direction,
    this.note = '',
    this.sheetId,
  });

  final String id;
  final DateTime date;

  /// Always positive (in Ariary); [direction] gives the sign.
  final int amount;
  final LedgerAccount account;
  final LedgerType type;
  final LedgerDirection direction;
  final String note;

  /// The ledger sheet holding this entry; null until the ledger assigns it
  /// (entries written before sheets existed, or freshly created ones).
  final String? sheetId;

  int get signedAmount =>
      direction == LedgerDirection.credit ? amount : -amount;

  LedgerEntry inSheet(String sheetId) => LedgerEntry(
        id: id,
        date: date,
        amount: amount,
        account: account,
        type: type,
        direction: direction,
        note: note,
        sheetId: sheetId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'amount': amount,
        'account': account.name,
        'type': type.name,
        'direction': direction.name,
        'note': note,
        if (sheetId != null) 'sheet': sheetId,
      };

  static LedgerEntry? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final date = DateTime.tryParse('${raw['date']}');
    final amount = raw['amount'];
    if (id is! String || date == null || amount is! num) return null;
    return LedgerEntry(
      id: id,
      date: date,
      amount: amount.abs().round(),
      account:
          _enumByName(LedgerAccount.values, raw['account'], LedgerAccount.cash),
      type: _enumByName(LedgerType.values, raw['type'], LedgerType.expense),
      direction: _enumByName(
          LedgerDirection.values, raw['direction'], LedgerDirection.debit),
      note: raw['note'] is String ? raw['note'] as String : '',
      sheetId: raw['sheet'] is String ? raw['sheet'] as String : null,
    );
  }
}
