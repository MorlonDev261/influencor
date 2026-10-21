/// Mobile-money fee model and the "split or send directly?" optimiser.
///
/// Fees are bracket based (a fixed fee per amount range), so a fee is not
/// proportional to the amount: splitting 26 000 Ar into 25 000 + 1 000 can be
/// cheaper than paying the next bracket. [FeeOptimizer] finds the cheapest
/// way to cover an amount with one or several operations.
library;

enum FeeKind { withdraw, transfer }

class FeeBracket {
  const FeeBracket(this.min, this.max, this.fee);

  final int min;
  final int max;
  final int fee;

  Map<String, dynamic> toJson() => {'min': min, 'max': max, 'fee': fee};

  static FeeBracket? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final min = raw['min'], max = raw['max'], fee = raw['fee'];
    if (min is! int || max is! int || fee is! int) return null;
    if (min < 0 || max < min || fee < 0) return null;
    return FeeBracket(min, max, fee);
  }
}

/// Where a transfer goes: same operator, or one of the other two.
enum TransferTarget { same, other }

class OperatorTariff {
  const OperatorTariff({
    required this.name,
    required this.withdraw,
    required this.transfer,
    this.transferOther,
    this.transferApp,
    this.official = true,
  });

  final String name;
  final List<FeeBracket> withdraw;

  /// Transfer to the same operator.
  final List<FeeBracket> transfer;

  /// Transfer to another operator; falls back to [transfer] when the operator
  /// publishes no separate grid.
  final List<FeeBracket>? transferOther;

  /// Cheaper same-operator transfer done from the app (Orange: −50 %).
  final List<FeeBracket>? transferApp;

  /// False when the grid is an estimate, not published by the operator.
  final bool official;

  OperatorTariff copyWith({
    String? name,
    List<FeeBracket>? withdraw,
    List<FeeBracket>? transfer,
    List<FeeBracket>? transferOther,
    List<FeeBracket>? transferApp,
    bool? official,
  }) =>
      OperatorTariff(
        name: name ?? this.name,
        withdraw: withdraw ?? this.withdraw,
        transfer: transfer ?? this.transfer,
        // An empty grid means "not published": treat it as absent.
        transferOther: _orNull(transferOther ?? this.transferOther),
        transferApp: _orNull(transferApp ?? this.transferApp),
        official: official ?? this.official,
      );

  static List<FeeBracket>? _orNull(List<FeeBracket>? l) =>
      l == null || l.isEmpty ? null : l;

  Map<String, dynamic> toJson() => {
        'name': name,
        'official': official,
        'withdraw': [for (final b in withdraw) b.toJson()],
        'transfer': [for (final b in transfer) b.toJson()],
        if (transferOther != null)
          'transferOther': [for (final b in transferOther!) b.toJson()],
        if (transferApp != null)
          'transferApp': [for (final b in transferApp!) b.toJson()],
      };

  static List<FeeBracket> _grid(Object? raw) => raw is List
      ? [
          for (final r in raw)
            if (FeeBracket.tryFromJson(r) case final b?) b,
        ]
      : const [];

  static OperatorTariff? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) return null;
    return OperatorTariff(
      name: name.trim(),
      official: raw['official'] == true,
      withdraw: _grid(raw['withdraw']),
      transfer: _grid(raw['transfer']),
      transferOther: _orNull(_grid(raw['transferOther'])),
      transferApp: _orNull(_grid(raw['transferApp'])),
    );
  }

  List<FeeBracket> bracketsFor(
    FeeKind kind, [
    TransferTarget target = TransferTarget.same,
    bool app = false,
  ]) {
    if (kind == FeeKind.withdraw) return withdraw;
    if (target == TransferTarget.other) return transferOther ?? transfer;
    return app ? (transferApp ?? transfer) : transfer;
  }
}

/// [count] identical operations of [amount], each costing [fee].
///
/// Grouping keeps huge amounts cheap to represent: a billion Ariary is a few
/// hundred identical operations, never a list of a million parts.
class FeePart {
  const FeePart(this.amount, this.fee, [this.count = 1]);

  final int amount;
  final int fee;
  final int count;

  int get totalAmount => amount * count;
  int get totalFee => fee * count;
}

class FeePlan {
  const FeePlan({
    required this.operator,
    required this.kind,
    required this.parts,
    required this.directFee,
  });

  final String operator;
  final FeeKind kind;

  /// Cheapest split. One operation in total means "direct" is optimal.
  final List<FeePart> parts;

  /// Fee of a single operation, or null when one operation can't carry the
  /// whole amount.
  final int? directFee;

  int get totalFee => parts.fold(0, (s, p) => s + p.totalFee);
  int get amount => parts.fold(0, (s, p) => s + p.totalAmount);
  int get operationCount => parts.fold(0, (s, p) => s + p.count);
  bool get isSplit => operationCount > 1;
  int get savings => directFee == null ? 0 : directFee! - totalFee;
}

/// Finds the cheapest way to pay an amount with one or several operations.
///
/// - Up to `maxParts × largest bracket` the search is exhaustive and exact.
/// - Beyond that there is no upper limit: most of the amount is covered with
///   repeated operations of the most cost-efficient bracket (lowest fee per
///   Ariary) and the remainder is solved exactly.
class FeeOptimizer {
  const FeeOptimizer({this.maxParts = 12});

  /// Operations considered by the exhaustive search.
  final int maxParts;

  /// Fee of one operation for [amount], or null if outside every bracket.
  static int? directFee(List<FeeBracket> brackets, int amount) {
    for (final b in brackets) {
      if (amount >= b.min && amount <= b.max) return b.fee;
    }
    return null;
  }

  /// Cheapest plan for [amount] (any size), or null when the tariff can't
  /// pay it (below its smallest operation, or no remainder fits).
  FeePlan? plan(
    OperatorTariff tariff,
    FeeKind kind,
    int amount, {
    TransferTarget target = TransferTarget.same,
    bool app = false,
  }) {
    final brackets = [...tariff.bracketsFor(kind, target, app)]
      ..sort((a, b) => b.min.compareTo(a.min)); // largest first
    if (brackets.isEmpty || amount < brackets.last.min) return null;

    final largest = brackets.map((b) => b.max).reduce((a, b) => a > b ? a : b);
    final parts = amount <= largest * maxParts
        ? _exact(brackets, amount)
        : _bulk(brackets, amount, largest);
    if (parts == null) return null;

    return FeePlan(
      operator: tariff.name,
      kind: kind,
      parts: parts,
      directFee: directFee(brackets, amount),
    );
  }

  /// Fees included: [budget] (e.g. the whole balance) must pay the amount
  /// *and* its fees. Returns the cheapest plan for the largest amount that
  /// still fits, or null when not even the smallest operation fits.
  FeePlan? planWithin(
    OperatorTariff tariff,
    FeeKind kind,
    int budget, {
    TransferTarget target = TransferTarget.same,
    bool app = false,
  }) {
    FeePlan? fits(int amount) {
      final p = plan(tariff, kind, amount, target: target, app: app);
      return p != null && amount + p.totalFee <= budget ? p : null;
    }

    final brackets = tariff.bracketsFor(kind, target, app);
    if (brackets.isEmpty) return null;
    final smallest = brackets.map((b) => b.min).reduce((a, b) => a < b ? a : b);
    final whole = fits(budget);
    if (whole != null) return whole;

    var lo = smallest < 1 ? 1 : smallest;
    if (lo >= budget) return null;
    var best = fits(lo);
    if (best == null) return null;

    // Fees grow with the amount, so the largest fitting amount is found by
    // bisection between a fitting [lo] and a non-fitting [hi].
    var hi = budget;
    while (hi - lo > 1) {
      final mid = lo + (hi - lo) ~/ 2;
      final p = fits(mid);
      if (p != null) {
        lo = mid;
        best = p;
      } else {
        hi = mid;
      }
    }

    // Fees are steps: a larger amount paying the same fee may still fit.
    final retry = budget - best!.totalFee;
    if (retry > lo) return fits(retry) ?? best;
    return best;
  }

  /// Exhaustive search over multisets of brackets (≤ [maxParts] operations).
  List<FeePart>? _exact(List<FeeBracket> brackets, int amount) {
    if (amount <= 0) return const [];
    if (amount < brackets.last.min) return null;

    // maxHi[i]: largest bracket max among brackets i.. (the smaller ones).
    final maxHi = List<int>.filled(brackets.length + 1, 0);
    for (var i = brackets.length - 1; i >= 0; i--) {
      maxHi[i] =
          brackets[i].max > maxHi[i + 1] ? brackets[i].max : maxHi[i + 1];
    }

    // Seed with the direct fee: any better plan must beat it.
    var bestCost = 1 << 62;
    var bestPicks = <int>[];
    final direct = directFee(brackets, amount);
    if (direct != null) {
      bestCost = direct;
      bestPicks = [
        brackets.indexWhere((b) => amount >= b.min && amount <= b.max)
      ];
    }

    final counts = List<int>.filled(brackets.length, 0);
    var found = false;

    // A multiset of brackets can carry [amount] iff
    // sum(min) <= amount <= sum(max). Walk brackets from the largest down,
    // choosing how many operations use each one.
    void search(int i, int parts, int sumMin, int sumMax, int cost) {
      if (sumMax >= amount && sumMin <= amount && parts > 0) {
        if (cost < bestCost || (cost == bestCost && parts < bestPicks.length)) {
          bestCost = cost;
          bestPicks = [
            for (var k = 0; k < brackets.length; k++)
              for (var c = 0; c < counts[k]; c++) k,
          ];
          found = true;
        }
      }
      if (i >= brackets.length || parts >= maxParts) return;
      // Even filling every remaining slot with the biggest reachable bracket
      // can't cover the amount.
      if (sumMax + (maxParts - parts) * maxHi[i] < amount) return;
      final b = brackets[i];
      // Fewest-uses first keeps cheap plans found early for pruning.
      for (var c = 0; parts + c <= maxParts; c++) {
        final nMin = sumMin + c * b.min;
        if (nMin > amount) break;
        final nCost = cost + c * b.fee;
        if (nCost > bestCost) break;
        counts[i] = c;
        search(i + 1, parts + c, nMin, sumMax + c * b.max, nCost);
      }
      counts[i] = 0;
    }

    search(0, 0, 0, 0, 0);
    if (!found && direct == null) return null;

    // Spread the amount over the chosen brackets: start at each minimum, then
    // fill the remainder up to each maximum.
    final amounts = [for (final i in bestPicks) brackets[i].min];
    var remaining = amount - amounts.fold<int>(0, (s, a) => s + a);
    for (var k = 0; k < amounts.length && remaining > 0; k++) {
      final room = brackets[bestPicks[k]].max - amounts[k];
      final add = remaining < room ? remaining : room;
      amounts[k] += add;
      remaining -= add;
    }

    return _group([
      for (var k = 0; k < amounts.length; k++)
        FeePart(amounts[k], brackets[bestPicks[k]].fee),
    ]);
  }

  /// Amounts too big for the exhaustive search: repeat the most efficient
  /// bracket and solve the remainder exactly.
  List<FeePart>? _bulk(List<FeeBracket> brackets, int amount, int largest) {
    // Lowest fee per Ariary when the operation is filled to its maximum.
    var star = brackets.first;
    for (final b in brackets) {
      final lhs = b.fee * star.max, rhs = star.fee * b.max;
      if (lhs < rhs || (lhs == rhs && b.max > star.max)) star = b;
    }

    // Leave a remainder of at most two "largest" operations, then try a few
    // fewer repetitions in case the remainder fits a cheaper bracket better.
    final window = largest * 2;
    final first =
        amount <= window ? 0 : (amount - window + star.max - 1) ~/ star.max;
    List<FeePart>? best;
    var bestCost = 1 << 62;
    for (var m = first; m <= first + 8 && m * star.max <= amount; m++) {
      final rest = amount - m * star.max;
      final tail = rest == 0 ? const <FeePart>[] : _exact(brackets, rest);
      if (tail == null) continue;
      final parts = _group([
        if (m > 0) FeePart(star.max, star.fee, m),
        ...tail,
      ]);
      final cost = parts.fold<int>(0, (s, p) => s + p.totalFee);
      if (cost < bestCost) {
        bestCost = cost;
        best = parts;
      }
    }
    return best;
  }

  /// Merges identical operations and sorts by amount, largest first.
  List<FeePart> _group(List<FeePart> parts) {
    final byKey = <(int, int), int>{};
    for (final p in parts) {
      byKey[(p.amount, p.fee)] = (byKey[(p.amount, p.fee)] ?? 0) + p.count;
    }
    return [
      for (final e in byKey.entries) FeePart(e.key.$1, e.key.$2, e.value),
    ]..sort((a, b) => b.amount.compareTo(a.amount));
  }

  /// Plans for every operator, cheapest first.
  List<FeePlan> compare(
    List<OperatorTariff> tariffs,
    FeeKind kind,
    int amount, {
    TransferTarget target = TransferTarget.same,
  }) {
    final plans = [
      for (final t in tariffs) plan(t, kind, amount, target: target),
    ].whereType<FeePlan>().toList()
      ..sort((a, b) => a.totalFee.compareTo(b.totalFee));
    return plans;
  }
}
