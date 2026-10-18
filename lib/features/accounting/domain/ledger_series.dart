import 'dart:math' as math;

import 'ledger_entry.dart';

/// Width of one point of the credit / debit chart.
enum SeriesStep { day, week, month }

class SeriesBucket {
  const SeriesBucket(this.start, {this.credit = 0, this.debit = 0});

  /// First day of the bucket (local midnight).
  final DateTime start;
  final int credit;
  final int debit;
}

class LedgerSeries {
  const LedgerSeries(this.step, this.buckets);

  final SeriesStep step;
  final List<SeriesBucket> buckets;

  int get maxValue =>
      buckets.fold(0, (m, b) => math.max(m, math.max(b.credit, b.debit)));
}

/// Up to this many days the chart has one point per day, then per week, and
/// per month past [seriesMaxWeeks] weeks so the curve stays readable.
const seriesMaxDays = 62;
const seriesMaxWeeks = 62;

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _bucketStart(DateTime d, SeriesStep step) => switch (step) {
      SeriesStep.day => _day(d),
      SeriesStep.week => DateTime(d.year, d.month, d.day - (d.weekday - 1)),
      SeriesStep.month => DateTime(d.year, d.month),
    };

DateTime _next(DateTime d, SeriesStep step) => switch (step) {
      SeriesStep.day => DateTime(d.year, d.month, d.day + 1),
      SeriesStep.week => DateTime(d.year, d.month, d.day + 7),
      SeriesStep.month => DateTime(d.year, d.month + 1),
    };

/// Sums credits and debits per day / week / month over [from]..[to] (both
/// widened to include every entry). Empty buckets stay at zero so the curves
/// drop on quiet days. Returns null when there is nothing to draw.
LedgerSeries? buildLedgerSeries(
  List<LedgerEntry> entries, {
  DateTime? from,
  DateTime? to,
}) {
  if (entries.isEmpty) return null;
  var first = from ?? entries.first.date, last = to ?? entries.first.date;
  for (final e in entries) {
    if (e.date.isBefore(first)) first = e.date;
    if (e.date.isAfter(last)) last = e.date;
  }
  first = _day(first);
  last = _day(last);
  // Calendar days, immune to daylight-saving shifts.
  final days = DateTime.utc(last.year, last.month, last.day)
          .difference(DateTime.utc(first.year, first.month, first.day))
          .inDays +
      1;
  final step = days <= seriesMaxDays
      ? SeriesStep.day
      : (days <= seriesMaxWeeks * 7 ? SeriesStep.week : SeriesStep.month);

  final credit = <DateTime, int>{}, debit = <DateTime, int>{};
  for (final e in entries) {
    final key = _bucketStart(e.date, step);
    final sums = e.direction == LedgerDirection.credit ? credit : debit;
    sums[key] = (sums[key] ?? 0) + e.amount;
  }
  final buckets = <SeriesBucket>[];
  for (var d = _bucketStart(first, step);
      !d.isAfter(last);
      d = _next(d, step)) {
    buckets.add(SeriesBucket(d, credit: credit[d] ?? 0, debit: debit[d] ?? 0));
  }
  return LedgerSeries(step, buckets);
}
