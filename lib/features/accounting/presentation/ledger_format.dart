import 'package:flutter/material.dart';

String formatAr(int value) {
  final digits = value.abs().toString();
  final grouped = digits.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ' ',
  );
  return '${value < 0 ? '-' : ''}$grouped Ar';
}

String formatDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

String formatTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Short axis label: 1 500 000 → "1,5M", 25 000 → "25k".
String formatCompact(int value, {String decimal = ','}) {
  final a = value.abs();
  String unit(double x, String suffix) {
    final s = x >= 10
        ? x.round().toString()
        : x.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
    return '${value < 0 ? '-' : ''}${s.replaceAll('.', decimal)}$suffix';
  }

  if (a >= 1000000000) return unit(a / 1000000000, 'G');
  if (a >= 1000000) return unit(a / 1000000, 'M');
  if (a >= 1000) return unit(a / 1000, 'k');
  return '$value';
}

/// Money in is green, money out is red, in both light and dark themes.
extension LedgerColors on ColorScheme {
  bool get _dark => brightness == Brightness.dark;
  Color get ledgerCredit =>
      _dark ? Colors.green.shade400 : Colors.green.shade700;
  Color get ledgerDebit => _dark ? Colors.red.shade300 : Colors.red.shade700;
}
