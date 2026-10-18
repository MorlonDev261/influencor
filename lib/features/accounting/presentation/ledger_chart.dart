import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/l10n/app_strings.dart';
import '../domain/ledger_entry.dart';
import '../domain/ledger_series.dart';
import 'ledger_format.dart';

/// Credit (green) and debit (red) curves over time, drawn with a
/// [CustomPainter] — no chart package for two lines. Renders nothing when
/// there are no entries.
class LedgerChartCard extends StatelessWidget {
  const LedgerChartCard({
    super.key,
    required this.entries,
    required this.strings,
    this.from,
    this.to,
    this.height = 180,
  });

  final List<LedgerEntry> entries;
  final AppStrings strings;

  /// Period to cover (widened to include every entry).
  final DateTime? from;
  final DateTime? to;
  final double height;

  @override
  Widget build(BuildContext context) {
    final series = buildLedgerSeries(entries, from: from, to: to);
    if (series == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final credit = series.buckets.fold<int>(0, (s, b) => s + b.credit);
    final debit = series.buckets.fold<int>(0, (s, b) => s + b.debit);
    final step = switch (series.step) {
      SeriesStep.day => strings.perDay,
      SeriesStep.week => strings.perWeek,
      SeriesStep.month => strings.perMonth,
    };

    // Text.rich so labels wrap instead of overflowing on narrow phones.
    Widget legend(Color color, String label, String value) => Text.rich(
          TextSpan(children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
            TextSpan(text: '$label  '),
            TextSpan(
              text: value,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ]),
          style: theme.textTheme.labelMedium,
        );

    return Container(
      key: const ValueKey('ledger-chart'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: '${strings.ledgerTrend}  ',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text: step,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ]),
              ),
              legend(
                  scheme.ledgerCredit, strings.credit, '+${formatAr(credit)}'),
              legend(scheme.ledgerDebit, strings.debit, '-${formatAr(debit)}'),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: height,
            child: Semantics(
              label:
                  strings.ledgerChartLabel(formatAr(credit), formatAr(debit)),
              child: _LedgerChart(series: series, strings: strings),
            ),
          ),
        ],
      ),
    );
  }
}

class _LedgerChart extends StatefulWidget {
  const _LedgerChart({required this.series, required this.strings});

  final LedgerSeries series;
  final AppStrings strings;

  @override
  State<_LedgerChart> createState() => _LedgerChartState();
}

class _LedgerChartState extends State<_LedgerChart> {
  final _geometry = _ChartGeometry();
  int? _active;

  void _point(Offset local) {
    final i = _geometry.indexAt(local.dx, widget.series.buckets.length);
    if (i != _active) setState(() => _active = i);
  }

  void _clear() {
    if (_active != null) setState(() => _active = null);
  }

  @override
  void didUpdateWidget(_LedgerChart old) {
    super.didUpdateWidget(old);
    if (_active != null && _active! >= widget.series.buckets.length) {
      _active = null;
    }
  }

  String _bucketTitle(DateTime d) {
    final s = widget.strings;
    return switch (widget.series.step) {
      SeriesStep.day => formatDate(d),
      SeriesStep.week => s.weekOf(formatDate(d)),
      SeriesStep.month => '${d.month.toString().padLeft(2, '0')}/${d.year}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final decimal = widget.strings.locale.languageCode == 'en' ? '.' : ',';
    return MouseRegion(
      onHover: (e) => _point(e.localPosition),
      onExit: (_) => _clear(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _point(d.localPosition),
        onHorizontalDragUpdate: (d) => _point(d.localPosition),
        onHorizontalDragEnd: (_) => _clear(),
        child: CustomPaint(
          size: Size.infinite,
          painter: _ChartPainter(
            series: widget.series,
            geometry: _geometry,
            active: _active,
            credit: scheme.ledgerCredit,
            debit: scheme.ledgerDebit,
            grid: scheme.outlineVariant.withValues(alpha: 0.6),
            surface: scheme.surfaceContainerLow,
            tooltipBg: scheme.inverseSurface,
            labelStyle: (theme.textTheme.labelSmall ?? const TextStyle())
                .copyWith(color: scheme.onSurfaceVariant, fontSize: 10.5),
            tooltipStyle: (theme.textTheme.labelMedium ?? const TextStyle())
                .copyWith(color: scheme.onInverseSurface),
            axisLabel: (v) => formatCompact(v, decimal: decimal),
            xLabel: (d) => widget.series.step == SeriesStep.month
                ? '${d.month.toString().padLeft(2, '0')}/${d.year % 100}'
                : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}',
            tooltipTitle: _bucketTitle,
            creditLabel: widget.strings.credit,
            debitLabel: widget.strings.debit,
          ),
        ),
      ),
    );
  }
}

/// Plot area of the last paint, so pointer positions map to buckets.
class _ChartGeometry {
  Rect plot = Rect.zero;

  double xOf(int i, int n) =>
      n <= 1 ? plot.center.dx : plot.left + plot.width * i / (n - 1);

  int? indexAt(double dx, int n) {
    if (n == 0 || plot.isEmpty) return null;
    if (n == 1) return 0;
    final t = ((dx - plot.left) / plot.width).clamp(0.0, 1.0);
    return (t * (n - 1)).round();
  }
}

/// A round step (1, 2, 2.5 or 5 × 10^k) giving about [ticks] grid lines.
int _niceStep(int max, int ticks) {
  final raw = math.max(1, max) / ticks;
  final magnitude =
      math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (m * magnitude >= raw) return math.max(1, (m * magnitude).round());
  }
  return (10 * magnitude).round();
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.series,
    required this.geometry,
    required this.active,
    required this.credit,
    required this.debit,
    required this.grid,
    required this.surface,
    required this.tooltipBg,
    required this.labelStyle,
    required this.tooltipStyle,
    required this.axisLabel,
    required this.xLabel,
    required this.tooltipTitle,
    required this.creditLabel,
    required this.debitLabel,
  });

  final LedgerSeries series;
  final _ChartGeometry geometry;
  final int? active;
  final Color credit, debit, grid, surface, tooltipBg;
  final TextStyle labelStyle, tooltipStyle;
  final String Function(int value) axisLabel;
  final String Function(DateTime d) xLabel;
  final String Function(DateTime d) tooltipTitle;
  final String creditLabel, debitLabel;

  TextPainter _text(String s, TextStyle style) => TextPainter(
      text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)
    ..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final buckets = series.buckets;
    final n = buckets.length;
    final step = _niceStep(series.maxValue, 3);
    final top = math.max(step, (series.maxValue / step).ceil() * step);

    final yLabels = [
      for (var v = 0; v <= top; v += step) (v, _text(axisLabel(v), labelStyle)),
    ];
    final left = yLabels.fold<double>(0, (m, l) => math.max(m, l.$2.width)) + 8;
    const bottom = 20.0, topPad = 6.0, right = 6.0;
    final plot =
        Rect.fromLTRB(left, topPad, size.width - right, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    geometry.plot = plot;

    double yOf(int v) => plot.bottom - plot.height * v / top;

    // Grid and y labels.
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final (v, label) in yLabels) {
      final y = yOf(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      label.paint(canvas, Offset(left - 8 - label.width, y - label.height / 2));
    }

    // X labels, spaced so they never overlap.
    final sample = _text(xLabel(buckets.first.start), labelStyle).width + 14;
    final maxLabels = math.max(1, (plot.width / sample).floor());
    final stride = math.max(1, (n / maxLabels).ceil());
    for (var i = 0; i < n; i += stride) {
      final label = _text(xLabel(buckets[i].start), labelStyle);
      final x = (geometry.xOf(i, n) - label.width / 2)
          .clamp(0.0, size.width - label.width);
      label.paint(canvas, Offset(x, plot.bottom + 5));
    }

    void curve(int Function(SeriesBucket b) value, Color color) {
      final points = [
        for (var i = 0; i < n; i++)
          Offset(geometry.xOf(i, n), yOf(value(buckets[i]))),
      ];
      if (n > 1) {
        final line = Path()..moveTo(points.first.dx, points.first.dy);
        for (final p in points.skip(1)) {
          line.lineTo(p.dx, p.dy);
        }
        final area = Path.from(line)
          ..lineTo(points.last.dx, plot.bottom)
          ..lineTo(points.first.dx, plot.bottom)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color.withValues(alpha: 0.22),
                color.withValues(alpha: 0)
              ],
            ).createShader(plot),
        );
        canvas.drawPath(
          line,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round,
        );
      }
      // Dots on active days, when there is room for them.
      if (n <= 45) {
        final dot = Paint()..color = color;
        for (var i = 0; i < n; i++) {
          if (value(buckets[i]) > 0 || n == 1) {
            canvas.drawCircle(points[i], n == 1 ? 4 : 2.6, dot);
          }
        }
      }
    }

    curve((b) => b.debit, debit);
    curve((b) => b.credit, credit);

    final i = active;
    if (i == null || i >= n) return;
    final b = buckets[i];
    final x = geometry.xOf(i, n);
    canvas.drawLine(
      Offset(x, plot.top),
      Offset(x, plot.bottom),
      Paint()
        ..color = tooltipBg.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );
    for (final (v, color) in [(b.debit, debit), (b.credit, credit)]) {
      final c = Offset(x, yOf(v));
      canvas.drawCircle(c, 5.5, Paint()..color = surface);
      canvas.drawCircle(c, 4, Paint()..color = color);
    }

    // Tooltip: bucket title, then one line per curve.
    final bold = tooltipStyle.copyWith(fontWeight: FontWeight.w700);
    final lines = [
      _text(tooltipTitle(b.start), bold),
      _text('$creditLabel  +${formatAr(b.credit)}', tooltipStyle),
      _text('$debitLabel  -${formatAr(b.debit)}', tooltipStyle),
    ];
    const pad = 8.0, gap = 2.0, swatch = 8.0;
    final width = lines.fold<double>(0, (m, l) => math.max(m, l.width)) +
        pad * 2 +
        swatch +
        6;
    final height = lines.fold<double>(0, (s, l) => s + l.height) +
        gap * (lines.length - 1) +
        pad * 2;
    var bx = x + 12;
    if (bx + width > size.width) bx = x - 12 - width;
    bx = bx.clamp(0.0, math.max(0.0, size.width - width));
    final box = Rect.fromLTWH(bx, plot.top, width, height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(8)),
      Paint()..color = tooltipBg.withValues(alpha: 0.94),
    );
    var y = box.top + pad;
    for (var k = 0; k < lines.length; k++) {
      final l = lines[k];
      var lx = box.left + pad;
      if (k > 0) {
        canvas.drawCircle(
          Offset(lx + swatch / 2, y + l.height / 2),
          swatch / 2,
          Paint()..color = k == 1 ? credit : debit,
        );
        lx += swatch + 6;
      }
      l.paint(canvas, Offset(lx, y));
      y += l.height + gap;
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.series != series ||
      old.active != active ||
      old.credit != credit ||
      old.debit != debit ||
      old.grid != grid ||
      old.tooltipBg != tooltipBg ||
      old.labelStyle != labelStyle;
}
