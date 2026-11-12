import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../../core/l10n/app_strings.dart';
import '../../../../core/services/content_share_ui.dart';
import '../../application/tools/app_tools.dart';
import 'rich_common.dart';

// Charts Degany draws from a ```chart block:
//
//   {"type": "bar", "title": "Ventes", "unit": "Ar",
//    "labels": ["Jan", "Fév"], "series": [{"name": "2026", "data": [5, 8]}]}
//
// Types: line, bar, hbar, area, pie, donut, scatter, sparkline; "stacked"
// for bars and areas. Drawn with a CustomPainter, like the accounting chart.

enum ChartKind { line, bar, hbar, area, pie, donut, scatter, sparkline }

class ChartSeries {
  const ChartSeries({
    required this.name,
    this.values = const [],
    this.points = const [],
    this.color,
  });

  final String name;
  final List<double?> values;

  /// Scatter: (x, y) pairs.
  final List<Offset> points;
  final Color? color;
}

class ChartSpec {
  const ChartSpec({
    required this.kind,
    required this.labels,
    required this.series,
    this.title,
    this.subtitle,
    this.unit,
    this.xLabel,
    this.yLabel,
    this.stacked = false,
    this.sliceColors = const [],
  });

  final ChartKind kind;
  final String? title, subtitle, unit, xLabel, yLabel;
  final bool stacked;
  final List<String> labels;
  final List<ChartSeries> series;

  /// Pie / donut: colours given per slice.
  final List<Color?> sliceColors;

  bool get isPie => kind == ChartKind.pie || kind == ChartKind.donut;

  static ChartKind? _kind(Object? raw) => switch ('$raw'.toLowerCase().trim()) {
        'line' || 'lines' || 'curve' => ChartKind.line,
        'bar' ||
        'bars' ||
        'column' ||
        'columns' ||
        'histogram' =>
          ChartKind.bar,
        'hbar' ||
        'barh' ||
        'horizontal_bar' ||
        'horizontalbar' ||
        'horizontal' =>
          ChartKind.hbar,
        'area' => ChartKind.area,
        'pie' => ChartKind.pie,
        'donut' || 'doughnut' || 'ring' => ChartKind.donut,
        'scatter' || 'points' || 'dots' => ChartKind.scatter,
        'sparkline' || 'spark' => ChartKind.sparkline,
        _ => null,
      };

  static String? _str(Object? v) =>
      v == null || '$v'.trim().isEmpty ? null : '$v'.trim();

  /// Reads the block's JSON; null when it holds nothing to draw.
  static ChartSpec? parse(Object? json) {
    if (json is List) json = <String, Object?>{'data': json};
    if (json is! Map) return null;
    final kind =
        _kind(json['type'] ?? json['kind'] ?? json['chart']) ?? ChartKind.bar;
    final rawLabels = json['labels'] ?? json['categories'] ?? json['x'];
    var labels = [
      if (rawLabels is List)
        for (final l in rawLabels) '$l',
    ];
    final series = <ChartSeries>[];
    final sliceColors = <Color?>[];

    List<double?> numbers(Object? raw) => [
          if (raw is List)
            for (final v in raw) toNumber(v is Map ? v['value'] ?? v['y'] : v),
        ];

    List<Offset> points(Object? raw) => [
          if (raw is List)
            for (final v in raw)
              if (v is List &&
                  v.length >= 2 &&
                  toNumber(v[0]) != null &&
                  toNumber(v[1]) != null)
                Offset(toNumber(v[0])!, toNumber(v[1])!)
              else if (v is Map &&
                  toNumber(v['x']) != null &&
                  toNumber(v['y']) != null)
                Offset(toNumber(v['x'])!, toNumber(v['y'])!),
        ];

    final rawSeries = json['series'] ?? json['datasets'];
    if (rawSeries is List) {
      for (final (k, s) in rawSeries.indexed) {
        if (s is Map) {
          final data = s['data'] ?? s['values'] ?? s['points'];
          series.add(ChartSeries(
            name: _str(s['name'] ?? s['label']) ?? 'Série ${k + 1}',
            values: kind == ChartKind.scatter ? const [] : numbers(data),
            points: kind == ChartKind.scatter ? points(data) : const [],
            color: parseColor(s['color']),
          ));
        } else if (s is List) {
          series.add(ChartSeries(name: 'Série ${k + 1}', values: numbers(s)));
        }
      }
    }
    final data = json['data'] ?? json['values'];
    if (series.isEmpty && data != null) {
      if (data is Map) {
        labels = [for (final k in data.keys) '$k'];
        series.add(ChartSeries(
            name: _str(json['name']) ?? '',
            values: numbers(data.values.toList())));
      } else if (data is List &&
          data.isNotEmpty &&
          data.first is Map &&
          kind != ChartKind.scatter) {
        labels = [
          for (final d in data)
            if (d is Map) '${d['label'] ?? d['name'] ?? d['x'] ?? ''}',
        ];
        for (final d in data) {
          if (d is Map) sliceColors.add(parseColor(d['color']));
        }
        series.add(ChartSeries(name: _str(json['name']) ?? '', values: [
          for (final d in data)
            if (d is Map) toNumber(d['value'] ?? d['y'] ?? d['count']),
        ]));
      } else if (kind == ChartKind.scatter) {
        series.add(
            ChartSeries(name: _str(json['name']) ?? '', points: points(data)));
      } else if (data is List) {
        series.add(
            ChartSeries(name: _str(json['name']) ?? '', values: numbers(data)));
      }
    }
    final hasData = series
        .any((s) => s.values.any((v) => v != null) || s.points.isNotEmpty);
    if (!hasData) return null;
    final n = series.fold<int>(0, (m, s) => math.max(m, s.values.length));
    if (kind != ChartKind.scatter && labels.length < n) {
      labels = [
        ...labels,
        for (var i = labels.length; i < n; i++) '${i + 1}',
      ];
    }
    return ChartSpec(
      kind: kind,
      labels: labels,
      series: series,
      title: _str(json['title']),
      subtitle: _str(json['subtitle'] ?? json['description']),
      unit: _str(json['unit']),
      xLabel: _str(json['x_label'] ?? json['xLabel']),
      yLabel: _str(json['y_label'] ?? json['yLabel']),
      stacked: json['stacked'] == true,
      sliceColors: sliceColors,
    );
  }

  /// The data as rows (first row: headers), for "copy" and CSV.
  List<List<String>> table(String decimal) {
    String f(double? v) =>
        v == null ? '' : formatNumber(v, decimal: decimal).replaceAll(' ', '');
    if (kind == ChartKind.scatter) {
      return [
        ['', xLabel ?? 'x', yLabel ?? 'y'],
        for (final s in series)
          for (final pt in s.points) [s.name, f(pt.dx), f(pt.dy)],
      ];
    }
    return [
      [
        '',
        for (final s in series) s.name.isEmpty ? (unit ?? 'Valeur') : s.name
      ],
      for (final (i, l) in labels.indexed)
        [
          l,
          for (final s in series) f(i < s.values.length ? s.values[i] : null),
        ],
    ];
  }
}

/// A chart in the conversation, with its legend, values on touch, and a
/// menu to save it as a picture, share it or copy its data.
class ChartBlock extends ConsumerStatefulWidget {
  const ChartBlock({required this.spec, super.key});

  final ChartSpec spec;

  @override
  ConsumerState<ChartBlock> createState() => _ChartBlockState();
}

class _ChartBlockState extends ConsumerState<ChartBlock> {
  final _boundary = GlobalKey();
  int? _active;

  Future<List<int>?> _png() async {
    final box = _boundary.currentContext?.findRenderObject();
    if (box is! RenderRepaintBoundary) return null;
    final image = await box.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  String get _name => widget.spec.title ?? 'Graphique';

  Future<void> _saveImage() async {
    final strings = ref.read(appStringsProvider);
    final bytes = await _png();
    if (bytes == null || !mounted) return;
    try {
      final path = await saveExportFile(ref,
          name: '$_name ${stamp()}', ext: 'png', bytes: bytes);
      if (!mounted) return;
      showChatSnack(
        context,
        strings.richSavedIn('$deganyExportFolder/${p.basename(path)}'),
        action: SnackBarAction(
          label: strings.richOpen,
          onPressed: () async {
            final route = await routeForPath(path);
            if (mounted) unawaited(context.push(route));
          },
        ),
      );
    } on StateError {
      if (mounted) showChatSnack(context, strings.needWorkspace);
    }
  }

  Future<void> _share() async {
    final bytes = await _png();
    if (bytes == null) return;
    final dir = await getTemporaryDirectory();
    final file = File(uniqueFilePath(dir.path, _name, 'png'));
    await file.writeAsBytes(bytes, flush: true);
    await contentShareService.shareContent(
      text: widget.spec.title,
      localMediaPaths: [file.path],
    );
  }

  void _copyData() {
    final strings = ref.read(appStringsProvider);
    final decimal = strings.locale.languageCode == 'en' ? '.' : ',';
    final rows = widget.spec.table(decimal);
    Clipboard.setData(
        ClipboardData(text: rows.map((r) => r.join('\t')).join('\n')));
    showChatSnack(context, strings.copiedToClipboard);
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final spec = widget.spec;
    final palette = chartPalette(scheme);
    final decimal = strings.locale.languageCode == 'en' ? '.' : ',';

    Color colorOf(int i) {
      if (spec.isPie) {
        return (i < spec.sliceColors.length ? spec.sliceColors[i] : null) ??
            palette[i % palette.length];
      }
      return spec.series[i].color ?? palette[i % palette.length];
    }

    final legend = <(Color, String, String?)>[
      if (spec.isPie)
        for (final (i, l) in spec.labels.indexed)
          if (i < spec.series.first.values.length)
            (colorOf(i), l, _sliceLabel(spec, i, decimal)),
      if (!spec.isPie && spec.series.length > 1)
        for (final (i, s) in spec.series.indexed) (colorOf(i), s.name, null),
    ];

    final Widget chart;
    if (spec.kind == ChartKind.sparkline) {
      chart = _Sparkline(spec: spec, color: colorOf(0), decimal: decimal);
    } else {
      final height = switch (spec.kind) {
        ChartKind.hbar => math.max(
            90.0,
            spec.labels.length *
                    (spec.stacked ? 22.0 : 8.0 + 14.0 * spec.series.length) +
                28),
        ChartKind.pie || ChartKind.donut => 190.0,
        _ => 210.0,
      };
      chart = SizedBox(
        height: height,
        child: _Interactive(
          spec: spec,
          active: _active,
          onActive: (i) {
            if (i != _active) setState(() => _active = i);
          },
          painterFor: (geometry) => _ChartPainter(
            spec: spec,
            geometry: geometry,
            active: _active,
            colorOf: colorOf,
            grid: scheme.outlineVariant.withValues(alpha: 0.6),
            axis: scheme.outline,
            surface: scheme.surfaceContainerLow,
            tooltipBg: scheme.inverseSurface,
            labelStyle: (theme.textTheme.labelSmall ?? const TextStyle())
                .copyWith(color: scheme.onSurfaceVariant, fontSize: 10.5),
            tooltipStyle: (theme.textTheme.labelMedium ?? const TextStyle())
                .copyWith(color: scheme.onInverseSurface),
            centerStyle: (theme.textTheme.titleMedium ?? const TextStyle())
                .copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700),
            decimal: decimal,
          ),
        ),
      );
    }

    return RepaintBoundary(
      key: _boundary,
      child: BlockCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BlockHeader(
              title: spec.title,
              subtitle: spec.subtitle,
              trailing: [
                PopupMenuButton<int>(
                  tooltip: strings.richMore,
                  icon: Icon(Icons.more_horiz,
                      size: 18, color: scheme.onSurfaceVariant),
                  padding: EdgeInsets.zero,
                  onSelected: (v) => switch (v) {
                    0 => _saveImage(),
                    1 => _share(),
                    _ => _copyData(),
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 0,
                        child: ListTile(
                            leading: const Icon(Icons.image_outlined),
                            title: Text(strings.richSaveImage))),
                    PopupMenuItem(
                        value: 1,
                        child: ListTile(
                            leading: const Icon(Icons.share_outlined),
                            title: Text(strings.richShare))),
                    PopupMenuItem(
                        value: 2,
                        child: ListTile(
                            leading: const Icon(Icons.copy_rounded),
                            title: Text(strings.richCopyData))),
                  ],
                ),
              ],
            ),
            if (legend.isNotEmpty && !spec.isPie)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, right: 6),
                child: _Legend(entries: legend),
              ),
            if (spec.isPie)
              LayoutBuilder(builder: (context, c) {
                final wide = c.maxWidth > 420;
                final legendView = _Legend(
                  entries: legend,
                  vertical: true,
                  active: _active,
                  onTap: (i) =>
                      setState(() => _active = _active == i ? null : i),
                );
                return wide
                    ? Row(
                        children: [
                          Expanded(flex: 5, child: chart),
                          const SizedBox(width: 12),
                          Expanded(flex: 4, child: legendView),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          chart,
                          const SizedBox(height: 10),
                          legendView
                        ],
                      );
              })
            else
              chart,
            if (spec.xLabel != null || spec.yLabel != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 6),
                child: Text(
                  [
                    if (spec.yLabel != null) '↑ ${spec.yLabel}',
                    if (spec.xLabel != null) '→ ${spec.xLabel}',
                  ].join('   '),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _sliceLabel(ChartSpec spec, int i, String decimal) {
    final values = spec.series.first.values;
    final total = values.fold<double>(0, (s, v) => s + math.max(0, v ?? 0));
    final v = values[i] ?? 0;
    final pct = total == 0 ? 0 : v / total * 100;
    return '${formatValue(v, spec.unit, decimal: decimal)} · '
        '${formatNumber(pct, maxDecimals: 1, decimal: decimal)} %';
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.entries,
    this.vertical = false,
    this.active,
    this.onTap,
  });

  final List<(Color, String, String?)> entries;
  final bool vertical;
  final int? active;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget entry(int i) {
      final (color, label, value) = entries[i];
      final dim = active != null && active != i;
      return InkWell(
        onTap: onTap == null ? null : () => onTap!(i),
        borderRadius: BorderRadius.circular(6),
        child: Opacity(
          opacity: dim ? 0.45 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
            child: Text.rich(
              TextSpan(children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                        color: color, borderRadius: BorderRadius.circular(3)),
                  ),
                ),
                TextSpan(text: label),
                if (value != null)
                  TextSpan(
                    text: '  $value',
                    style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600),
                  ),
              ]),
              style: theme.textTheme.labelMedium,
            ),
          ),
        ),
      );
    }

    if (vertical) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (var i = 0; i < entries.length; i++) entry(i)],
      );
    }
    return Wrap(
      spacing: 12,
      runSpacing: 2,
      children: [for (var i = 0; i < entries.length; i++) entry(i)],
    );
  }
}

/// Where things were drawn, so a touch maps back to a value.
class _Geometry {
  Rect plot = Rect.zero;
  int count = 0;
  Offset center = Offset.zero;
  double radius = 0;
  List<double> sliceStarts = const [];
  List<Offset> points = const [];
  List<int> pointSeries = const [];

  int? hit(ChartSpec spec, Offset at) {
    switch (spec.kind) {
      case ChartKind.pie || ChartKind.donut:
        final d = at - center;
        if (d.distance > radius + 8 || sliceStarts.isEmpty) return null;
        var a = math.atan2(d.dy, d.dx) + math.pi / 2;
        if (a < 0) a += 2 * math.pi;
        for (var i = sliceStarts.length - 1; i >= 0; i--) {
          if (a >= sliceStarts[i]) return i;
        }
        return 0;
      case ChartKind.scatter:
        int? best;
        var bestD = 28.0;
        for (final (i, pt) in points.indexed) {
          final dd = (pt - at).distance;
          if (dd < bestD) {
            bestD = dd;
            best = i;
          }
        }
        return best;
      case ChartKind.hbar:
        if (count == 0 || plot.isEmpty) return null;
        final i = ((at.dy - plot.top) / (plot.height / count)).floor();
        return i < 0 || i >= count ? null : i;
      default:
        if (count == 0 || plot.isEmpty) return null;
        final i = ((at.dx - plot.left) / (plot.width / count)).floor();
        return i.clamp(0, count - 1);
    }
  }
}

class _Interactive extends StatefulWidget {
  const _Interactive({
    required this.spec,
    required this.active,
    required this.onActive,
    required this.painterFor,
  });

  final ChartSpec spec;
  final int? active;
  final ValueChanged<int?> onActive;
  final CustomPainter Function(_Geometry geometry) painterFor;

  @override
  State<_Interactive> createState() => _InteractiveState();
}

class _InteractiveState extends State<_Interactive> {
  final _geometry = _Geometry();

  void _at(Offset local) => widget.onActive(_geometry.hit(widget.spec, local));

  @override
  Widget build(BuildContext context) => MouseRegion(
        onHover: (e) => _at(e.localPosition),
        onExit: (_) {
          if (!widget.spec.isPie) widget.onActive(null);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _at(d.localPosition),
          onHorizontalDragUpdate:
              widget.spec.isPie ? null : (d) => _at(d.localPosition),
          child: CustomPaint(
            size: Size.infinite,
            painter: widget.painterFor(_geometry),
          ),
        ),
      );
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.spec,
    required this.geometry,
    required this.active,
    required this.colorOf,
    required this.grid,
    required this.axis,
    required this.surface,
    required this.tooltipBg,
    required this.labelStyle,
    required this.tooltipStyle,
    required this.centerStyle,
    required this.decimal,
  });

  final ChartSpec spec;
  final _Geometry geometry;
  final int? active;
  final Color Function(int i) colorOf;
  final Color grid, axis, surface, tooltipBg;
  final TextStyle labelStyle, tooltipStyle, centerStyle;
  final String decimal;

  TextPainter _text(String s, TextStyle style, {double? maxWidth}) =>
      TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: maxWidth ?? double.infinity);

  String _value(double v) => formatValue(v, spec.unit, decimal: decimal);

  @override
  void paint(Canvas canvas, Size size) {
    switch (spec.kind) {
      case ChartKind.pie || ChartKind.donut:
        _pie(canvas, size);
      case ChartKind.hbar:
        _hbar(canvas, size);
      case ChartKind.scatter:
        _scatter(canvas, size);
      default:
        _axes(canvas, size);
    }
  }

  /// Lower and upper bounds of the y axis, with its grid step.
  (double, double, double) _range(Iterable<double> values,
      {bool fromZero = true}) {
    var lo = values.isEmpty ? 0.0 : values.reduce(math.min);
    var hi = values.isEmpty ? 1.0 : values.reduce(math.max);
    if (fromZero || lo < 0) {
      lo = math.min(0, lo);
    } else if (lo > (hi - lo)) {
      // Values far from zero: zoom on them (lines only).
      final step = niceStep(hi - lo, 4);
      lo = (lo / step).floor() * step;
    } else {
      lo = 0;
    }
    hi = math.max(hi, lo + 1e-9);
    final step = niceStep(hi - lo, 4);
    final top = (hi / step).ceil() * step;
    final bottom = (lo / step).floor() * step;
    return (bottom, top == bottom ? bottom + step : top, step);
  }

  void _axes(Canvas canvas, Size size) {
    final n = spec.labels.length;
    final series = spec.series;
    final bars = spec.kind == ChartKind.bar;
    final stacked = spec.stacked && (bars || spec.kind == ChartKind.area);

    final all = <double>[];
    if (stacked) {
      for (var i = 0; i < n; i++) {
        var pos = 0.0, neg = 0.0;
        for (final s in series) {
          final v = i < s.values.length ? s.values[i] ?? 0 : 0.0;
          v >= 0 ? pos += v : neg += v;
        }
        all
          ..add(pos)
          ..add(neg);
      }
    } else {
      for (final s in series) {
        all.addAll(s.values.whereType<double>());
      }
    }
    final (lo, hi, step) = _range(all, fromZero: spec.kind != ChartKind.line);

    final yLabels = <(double, TextPainter)>[];
    for (var v = lo; v <= hi + step / 2; v += step) {
      yLabels
          .add((v, _text(formatCompactValue(v, decimal: decimal), labelStyle)));
    }
    final left = yLabels.fold<double>(0, (m, l) => math.max(m, l.$2.width)) + 8;
    const bottom = 20.0, top = 6.0, right = 6.0;
    final plot =
        Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0 || n == 0) return;
    geometry
      ..plot = plot
      ..count = n;
    double yOf(double v) => plot.bottom - plot.height * (v - lo) / (hi - lo);
    final band = plot.width / n;
    double xOf(int i) => plot.left + band * (i + 0.5);

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final (v, label) in yLabels) {
      final y = yOf(v);
      canvas.drawLine(
          Offset(plot.left, y),
          Offset(plot.right, y),
          v == 0
              ? (Paint()
                ..color = axis
                ..strokeWidth = 1)
              : gridPaint);
      label.paint(canvas, Offset(left - 8 - label.width, y - label.height / 2));
    }

    // X labels, spaced so they never overlap.
    final widest = spec.labels
        .fold<double>(0, (m, l) => math.max(m, _text(l, labelStyle).width));
    final stride = math.max(1, ((widest + 10) / band).ceil());
    for (var i = 0; i < n; i += stride) {
      final label =
          _text(spec.labels[i], labelStyle, maxWidth: band * stride - 4);
      final x = (xOf(i) - label.width / 2).clamp(0.0, size.width - label.width);
      label.paint(canvas, Offset(x, plot.bottom + 5));
    }

    if (active != null && active! < n) {
      canvas.drawRect(
        Rect.fromLTWH(plot.left + band * active!, plot.top, band, plot.height),
        Paint()..color = tooltipBg.withValues(alpha: 0.06),
      );
    }

    final zero = yOf(lo > 0 ? lo : (hi < 0 ? hi : 0));
    if (bars) {
      final groups = stacked ? 1 : series.length;
      final inner = band * 0.72;
      final barW = inner / groups;
      for (var i = 0; i < n; i++) {
        var pos = 0.0, neg = 0.0;
        for (final (k, s) in series.indexed) {
          final v = i < s.values.length ? s.values[i] : null;
          if (v == null) continue;
          final double x0, y0, y1;
          if (stacked) {
            x0 = xOf(i) - inner / 2;
            final base = v >= 0 ? pos : neg;
            y0 = yOf(base);
            y1 = yOf(base + v);
            v >= 0 ? pos += v : neg += v;
          } else {
            x0 = xOf(i) - inner / 2 + barW * k;
            y0 = zero;
            y1 = yOf(v);
          }
          final rect = Rect.fromLTRB(x0 + 1, math.min(y0, y1),
              x0 + (stacked ? inner : barW) - 1, math.max(y0, y1));
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              rect,
              topLeft: Radius.circular(v >= 0 ? 3 : 0),
              topRight: Radius.circular(v >= 0 ? 3 : 0),
              bottomLeft: Radius.circular(v < 0 ? 3 : 0),
              bottomRight: Radius.circular(v < 0 ? 3 : 0),
            ),
            Paint()
              ..color = colorOf(k)
                  .withValues(alpha: active == null || active == i ? 1 : 0.55),
          );
        }
      }
    } else {
      // Lines and areas (stacked areas add up).
      final base = List<double>.filled(n, 0);
      for (final (k, s) in series.indexed) {
        final color = colorOf(k);
        final pts = <Offset>[];
        final lows = <Offset>[];
        for (var i = 0; i < n; i++) {
          final v = i < s.values.length ? s.values[i] : null;
          if (v == null) continue;
          final from = stacked ? base[i] : 0.0;
          pts.add(Offset(xOf(i), yOf(from + v)));
          lows.add(Offset(xOf(i), stacked ? yOf(from) : zero));
          if (stacked) base[i] += v;
        }
        if (pts.isEmpty) continue;
        final line = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (final pt in pts.skip(1)) {
          line.lineTo(pt.dx, pt.dy);
        }
        if (spec.kind == ChartKind.area || series.length == 1) {
          final area = Path.from(line);
          for (final pt in lows.reversed) {
            area.lineTo(pt.dx, pt.dy);
          }
          area.close();
          canvas.drawPath(
            area,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  color.withValues(
                      alpha: spec.kind == ChartKind.area ? 0.35 : 0.18),
                  color.withValues(
                      alpha: spec.kind == ChartKind.area ? 0.12 : 0),
                ],
              ).createShader(plot),
          );
        }
        canvas.drawPath(
          line,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round,
        );
        if (n <= 40) {
          for (final pt in pts) {
            canvas.drawCircle(pt, 2.8, Paint()..color = color);
          }
        }
      }
    }

    final i = active;
    if (i == null || i >= n) return;
    final x = xOf(i);
    if (!bars) {
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom),
          Paint()..color = tooltipBg.withValues(alpha: 0.35));
    }
    final lines = <(Color?, String)>[(null, spec.labels[i])];
    for (final (k, s) in series.indexed) {
      final v = i < s.values.length ? s.values[i] : null;
      if (v == null) continue;
      lines.add(
          (colorOf(k), '${s.name.isEmpty ? '' : '${s.name}  '}${_value(v)}'));
    }
    if (stacked && series.length > 1) {
      final total = series.fold<double>(
          0, (t, s) => t + (i < s.values.length ? s.values[i] ?? 0 : 0));
      lines.add((null, 'Total  ${_value(total)}'));
    }
    _tooltip(canvas, size, Offset(x, plot.top), lines);
  }

  void _hbar(Canvas canvas, Size size) {
    final n = spec.labels.length;
    final series = spec.series;
    final stacked = spec.stacked;
    final all = <double>[];
    for (var i = 0; i < n; i++) {
      if (stacked) {
        all.add(series.fold<double>(
            0, (t, s) => t + (i < s.values.length ? s.values[i] ?? 0 : 0)));
      } else {
        for (final s in series) {
          if (i < s.values.length && s.values[i] != null) all.add(s.values[i]!);
        }
      }
    }
    final (lo, hi, _) = _range(all);
    final labelW = math.min(
        size.width * 0.38,
        spec.labels.fold<double>(
                0, (m, l) => math.max(m, _text(l, labelStyle).width)) +
            10);
    final valueW = _text(_value(hi), labelStyle).width + 8;
    final plot = Rect.fromLTRB(labelW, 4, size.width - valueW, size.height - 4);
    if (plot.width <= 0 || n == 0) return;
    geometry
      ..plot = plot
      ..count = n;
    double xOf(double v) => plot.left + plot.width * (v - lo) / (hi - lo);
    final band = plot.height / n;
    final groups = stacked ? 1 : series.length;
    final inner = band * 0.74;
    final barH = inner / groups;
    final zero = xOf(0);
    canvas.drawLine(Offset(zero, plot.top), Offset(zero, plot.bottom),
        Paint()..color = axis);
    for (var i = 0; i < n; i++) {
      final cy = plot.top + band * (i + 0.5);
      final label = _text(spec.labels[i], labelStyle, maxWidth: labelW - 10);
      label.paint(
          canvas, Offset(labelW - 8 - label.width, cy - label.height / 2));
      var acc = 0.0;
      for (final (k, s) in series.indexed) {
        final v = i < s.values.length ? s.values[i] : null;
        if (v == null) continue;
        final y0 = stacked ? cy - inner / 2 : cy - inner / 2 + barH * k;
        final from = stacked ? acc : 0.0;
        final x0 = xOf(from), x1 = xOf(from + v);
        acc += v;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(math.min(x0, x1), y0 + 1, math.max(x0, x1),
                y0 + (stacked ? inner : barH) - 1),
            const Radius.circular(3),
          ),
          Paint()
            ..color = colorOf(k)
                .withValues(alpha: active == null || active == i ? 1 : 0.55),
        );
        if (!stacked) {
          final t = _text(_value(v), labelStyle);
          t.paint(
              canvas, Offset(math.max(x0, x1) + 4, y0 + (barH - t.height) / 2));
        }
      }
      if (stacked) {
        final t = _text(_value(acc), labelStyle);
        t.paint(canvas, Offset(xOf(acc) + 4, cy - t.height / 2));
      }
    }
    final i = active;
    if (i != null && i < n && series.length > 1) {
      _tooltip(canvas, size, Offset(plot.right, plot.top + band * i), [
        (null, spec.labels[i]),
        for (final (k, s) in series.indexed)
          if (i < s.values.length && s.values[i] != null)
            (colorOf(k), '${s.name}  ${_value(s.values[i]!)}'),
      ]);
    }
  }

  void _pie(Canvas canvas, Size size) {
    final values = [
      for (final v in spec.series.first.values) math.max(0.0, v ?? 0),
    ];
    final total = values.fold<double>(0, (s, v) => s + v);
    if (total <= 0) return;
    final radius = math.min(size.width, size.height) / 2 - 8;
    final center = size.center(Offset.zero);
    final donut = spec.kind == ChartKind.donut;
    final starts = <double>[];
    var a = 0.0;
    for (final (i, v) in values.indexed) {
      final sweep = v / total * 2 * math.pi;
      starts.add(a);
      final mid = -math.pi / 2 + a + sweep / 2;
      final pop = active == i ? 6.0 : 0.0;
      final c = center + Offset(math.cos(mid), math.sin(mid)) * pop;
      final rect = Rect.fromCircle(center: c, radius: radius);
      final paint = Paint()
        ..color = colorOf(i)
            .withValues(alpha: active == null || active == i ? 1 : 0.5);
      if (donut) {
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: radius * 0.8),
          -math.pi / 2 + a,
          sweep,
          false,
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = radius * 0.4,
        );
      } else {
        canvas.drawArc(rect, -math.pi / 2 + a, sweep, true, paint);
      }
      // Separators between slices.
      if (values.length > 1 && sweep > 0) {
        canvas.drawLine(
          c +
              Offset(math.cos(-math.pi / 2 + a), math.sin(-math.pi / 2 + a)) *
                  (donut ? radius * 0.6 : 0),
          c +
              Offset(math.cos(-math.pi / 2 + a), math.sin(-math.pi / 2 + a)) *
                  radius,
          Paint()
            ..color = surface
            ..strokeWidth = 1.5,
        );
      }
      // Percentage on big enough slices (plain pie).
      if (!donut && sweep > 0.35) {
        final t = _text(
          '${formatNumber(v / total * 100, maxDecimals: 0, decimal: decimal)} %',
          labelStyle.copyWith(
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11),
        );
        final pos = c + Offset(math.cos(mid), math.sin(mid)) * radius * 0.62;
        t.paint(canvas, pos - Offset(t.width / 2, t.height / 2));
      }
      a += sweep;
    }
    geometry
      ..center = center
      ..radius = radius
      ..sliceStarts = starts;

    if (donut) {
      final i = active;
      final big = _text(
          formatCompactValue(i == null ? total : values[i], decimal: decimal) +
              (spec.unit == null || spec.unit == '%' ? '' : ' ${spec.unit}'),
          centerStyle,
          maxWidth: radius * 1.1);
      final small = _text(i == null ? 'Total' : spec.labels[i], labelStyle,
          maxWidth: radius * 1.1);
      final h = big.height + small.height;
      big.paint(canvas, center - Offset(big.width / 2, h / 2));
      small.paint(
          canvas, center + Offset(-small.width / 2, -h / 2 + big.height));
    } else if (active != null && active! < values.length) {
      final i = active!;
      _tooltip(canvas, size, center, [
        (colorOf(i), spec.labels[i]),
        (
          null,
          '${_value(values[i])} · ${formatNumber(values[i] / total * 100, maxDecimals: 1, decimal: decimal)} %'
        ),
      ]);
    }
  }

  void _scatter(Canvas canvas, Size size) {
    final all = [for (final s in spec.series) ...s.points];
    if (all.isEmpty) return;
    double minOf(Iterable<double> v) => v.reduce(math.min);
    double maxOf(Iterable<double> v) => v.reduce(math.max);
    final (ylo, yhi, ystep) = _range(all.map((p) => p.dy),
        fromZero: minOf(all.map((p) => p.dy)) <= 0);
    final xs = all.map((p) => p.dx);
    final xspan = maxOf(xs) - minOf(xs);
    final xstep = niceStep(xspan == 0 ? 1 : xspan, 5);
    final xlo = (minOf(xs) / xstep).floor() * xstep;
    var xhi = (maxOf(xs) / xstep).ceil() * xstep;
    if (xhi == xlo) xhi = xlo + xstep;

    final yLabels = <(double, TextPainter)>[
      for (var v = ylo; v <= yhi + ystep / 2; v += ystep)
        (v, _text(formatCompactValue(v, decimal: decimal), labelStyle)),
    ];
    final left = yLabels.fold<double>(0, (m, l) => math.max(m, l.$2.width)) + 8;
    final plot = Rect.fromLTRB(left, 6, size.width - 8, size.height - 20);
    if (plot.width <= 0 || plot.height <= 0) return;
    double xOf(double v) => plot.left + plot.width * (v - xlo) / (xhi - xlo);
    double yOf(double v) => plot.bottom - plot.height * (v - ylo) / (yhi - ylo);
    final gridPaint = Paint()..color = grid;
    for (final (v, label) in yLabels) {
      final y = yOf(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      label.paint(canvas, Offset(left - 8 - label.width, y - label.height / 2));
    }
    for (var v = xlo; v <= xhi + xstep / 2; v += xstep) {
      final t = _text(formatCompactValue(v, decimal: decimal), labelStyle);
      t.paint(canvas, Offset(xOf(v) - t.width / 2, plot.bottom + 5));
    }
    final pts = <Offset>[];
    final owners = <int>[];
    for (final (k, s) in spec.series.indexed) {
      for (final pt in s.points) {
        final o = Offset(xOf(pt.dx), yOf(pt.dy));
        pts.add(o);
        owners.add(k);
        canvas.drawCircle(
            o, 4.2, Paint()..color = colorOf(k).withValues(alpha: 0.8));
      }
    }
    geometry
      ..plot = plot
      ..points = pts
      ..pointSeries = owners;
    final i = active;
    if (i != null && i < pts.length) {
      final k = owners[i];
      final src = all[i];
      canvas.drawCircle(pts[i], 6.5, Paint()..color = surface);
      canvas.drawCircle(pts[i], 5, Paint()..color = colorOf(k));
      _tooltip(canvas, size, pts[i], [
        if (spec.series[k].name.isNotEmpty) (colorOf(k), spec.series[k].name),
        (
          null,
          '${spec.xLabel ?? 'x'} : ${formatNumber(src.dx, decimal: decimal)}'
        ),
        (null, '${spec.yLabel ?? 'y'} : ${_value(src.dy)}'),
      ]);
    }
  }

  void _tooltip(
      Canvas canvas, Size size, Offset anchor, List<(Color?, String)> lines) {
    final bold = tooltipStyle.copyWith(fontWeight: FontWeight.w700);
    final texts = [
      for (final (k, (color, s)) in lines.indexed)
        (
          color,
          _text(s, k == 0 ? bold : tooltipStyle, maxWidth: size.width * 0.7)
        ),
    ];
    const pad = 8.0, gap = 2.0, swatch = 8.0;
    final width = texts.fold<double>(
            0,
            (m, t) =>
                math.max(m, t.$2.width + (t.$1 == null ? 0 : swatch + 6))) +
        pad * 2;
    final height = texts.fold<double>(0, (s, t) => s + t.$2.height) +
        gap * (texts.length - 1) +
        pad * 2;
    var bx = anchor.dx + 12;
    if (bx + width > size.width) bx = anchor.dx - 12 - width;
    bx = bx.clamp(0.0, math.max(0.0, size.width - width));
    final double by =
        anchor.dy.clamp(0.0, math.max(0.0, size.height - height)).toDouble();
    final box = Rect.fromLTWH(bx, by, width, height);
    canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(8)),
        Paint()..color = tooltipBg.withValues(alpha: 0.94));
    var y = box.top + pad;
    for (final (color, t) in texts) {
      var x = box.left + pad;
      if (color != null) {
        canvas.drawCircle(Offset(x + swatch / 2, y + t.height / 2), swatch / 2,
            Paint()..color = color);
        x += swatch + 6;
      }
      t.paint(canvas, Offset(x, y));
      y += t.height + gap;
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.spec != spec ||
      old.active != active ||
      old.grid != grid ||
      old.tooltipBg != tooltipBg ||
      old.labelStyle != labelStyle;
}

/// A small trend line with its last value and change.
class _Sparkline extends StatelessWidget {
  const _Sparkline({
    required this.spec,
    required this.color,
    required this.decimal,
  });

  final ChartSpec spec;
  final Color color;
  final String decimal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final values = spec.series.first.values.whereType<double>().toList();
    final last = values.isEmpty ? 0.0 : values.last;
    final first = values.isEmpty ? 0.0 : values.first;
    final change = first == 0 ? null : (last - first) / first.abs() * 100;
    final up = (change ?? 0) >= 0;
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 44,
            child: CustomPaint(painter: SparklinePainter(values, color)),
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(formatValue(last, spec.unit, decimal: decimal),
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            if (change != null)
              Text(
                '${up ? '▲' : '▼'} ${formatNumber(change.abs(), maxDecimals: 1, decimal: decimal)} %',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: up ? const Color(0xFF16A34A) : theme.colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A bare trend line (sparkline): no axes, a dot on the last value.
class SparklinePainter extends CustomPainter {
  SparklinePainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce(math.min);
    final hi = values.reduce(math.max);
    final span = hi - lo == 0 ? 1 : hi - lo;
    Offset at(int i) => Offset(
          size.width * i / (values.length - 1),
          size.height - 3 - (size.height - 6) * (values[i] - lo) / span,
        );
    final line = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      line.lineTo(at(i).dx, at(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(at(values.length - 1), 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(SparklinePainter old) =>
      old.values != values || old.color != color;
}
