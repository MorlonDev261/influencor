import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'rich_common.dart';

// Flow charts and org charts from a ```mermaid block (`graph TD` /
// `flowchart LR` subset) or a ```diagram JSON block:
//
//   {"direction": "TB", "nodes": [{"id": "a", "label": "Idée"}],
//    "edges": [{"from": "a", "to": "b", "label": "oui"}]}
//
// Laid out in layers (longest path), drawn with a CustomPainter.

enum NodeShape { box, round, diamond, circle }

class DiagramNode {
  DiagramNode(this.id, this.label, [this.shape = NodeShape.box]);

  final String id;
  String label;
  NodeShape shape;
}

class DiagramEdge {
  const DiagramEdge(this.from, this.to, {this.label, this.dashed = false});

  final String from, to;
  final String? label;
  final bool dashed;
}

class DiagramSpec {
  DiagramSpec({
    required this.nodes,
    required this.edges,
    this.horizontal = false,
    this.title,
  });

  final List<DiagramNode> nodes;
  final List<DiagramEdge> edges;
  final bool horizontal;
  final String? title;

  static DiagramSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    final nodes = <String, DiagramNode>{};
    final rawNodes = json['nodes'];
    if (rawNodes is List) {
      for (final n in rawNodes) {
        if (n is Map && n['id'] != null) {
          final id = '${n['id']}';
          nodes[id] = DiagramNode(
              id,
              '${n['label'] ?? id}',
              switch ('${n['shape']}') {
                'round' || 'rounded' => NodeShape.round,
                'diamond' || 'decision' => NodeShape.diamond,
                'circle' => NodeShape.circle,
                _ => NodeShape.box,
              });
        } else if (n is String) {
          nodes[n] = DiagramNode(n, n);
        }
      }
    }
    final edges = <DiagramEdge>[];
    final rawEdges = json['edges'] ?? json['links'];
    if (rawEdges is List) {
      for (final e in rawEdges) {
        if (e is Map && e['from'] != null && e['to'] != null) {
          final from = '${e['from']}', to = '${e['to']}';
          nodes.putIfAbsent(from, () => DiagramNode(from, from));
          nodes.putIfAbsent(to, () => DiagramNode(to, to));
          edges.add(DiagramEdge(from, to,
              label: e['label'] == null ? null : '${e['label']}',
              dashed: e['dashed'] == true));
        }
      }
    }
    if (nodes.isEmpty) return null;
    final dir = '${json['direction'] ?? 'TB'}'.toUpperCase();
    return DiagramSpec(
      nodes: nodes.values.toList(),
      edges: edges,
      horizontal: dir == 'LR' || dir == 'RL',
      title: json['title'] == null ? null : '${json['title']}',
    );
  }

  static final _nodeRef = RegExp(
      r'^\s*([A-Za-z0-9_À-ÿ]+)\s*(\(\[(.*?)\]\)|\(\((.*?)\)\)|\[(.*?)\]|\((.*?)\)|\{(.*?)\})?');
  static final _arrow = RegExp(
      r'^\s*(-->|---|-\.->|-\.-|==>|===|--\s*(.*?)\s*-->|-->\|(.*?)\||---\|(.*?)\||==>\|(.*?)\|)\s*(?:\|(.*?)\|)?');

  /// The `graph` / `flowchart` part of Mermaid; null for other diagrams.
  static DiagramSpec? fromMermaid(String code) {
    final lines = code
        .split(RegExp(r'[\n;]'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('%%'))
        .toList();
    if (lines.isEmpty) return null;
    final head =
        RegExp(r'^(graph|flowchart)\s*(TB|TD|BT|LR|RL)?', caseSensitive: false)
            .firstMatch(lines.first);
    if (head == null) return null;
    final dir = (head.group(2) ?? 'TD').toUpperCase();
    final nodes = <String, DiagramNode>{};
    final edges = <DiagramEdge>[];

    String? readNode(String s, void Function(int) consumed) {
      final m = _nodeRef.firstMatch(s);
      if (m == null || m.group(1)!.isEmpty) return null;
      final id = m.group(1)!;
      final label =
          m.group(3) ?? m.group(4) ?? m.group(5) ?? m.group(6) ?? m.group(7);
      final shape = m.group(4) != null
          ? NodeShape.circle
          : m.group(7) != null
              ? NodeShape.diamond
              : (m.group(6) != null || m.group(3) != null)
                  ? NodeShape.round
                  : NodeShape.box;
      final node = nodes.putIfAbsent(id, () => DiagramNode(id, id));
      if (label != null) {
        node
          ..label = label.replaceAll('"', '').replaceAll('<br>', '\n')
          ..shape = shape;
      }
      consumed(m.end);
      return id;
    }

    for (final line in lines.skip(1)) {
      if (RegExp(r'^(classDef|class|style|linkStyle|click|subgraph|end)\b')
          .hasMatch(line)) {
        continue;
      }
      var rest = line;
      final first = readNode(rest, (n) => rest = rest.substring(n));
      if (first == null) continue;
      var from = first;
      while (true) {
        final a = _arrow.firstMatch(rest);
        if (a == null) break;
        final label =
            a.group(2) ?? a.group(3) ?? a.group(4) ?? a.group(5) ?? a.group(6);
        final dashed = a.group(1)!.contains('.');
        rest = rest.substring(a.end);
        final to = readNode(rest, (n) => rest = rest.substring(n));
        if (to == null) break;
        edges.add(DiagramEdge(from, to,
            label: label == null || label.trim().isEmpty ? null : label.trim(),
            dashed: dashed));
        from = to;
      }
    }
    if (nodes.isEmpty) return null;
    return DiagramSpec(
      nodes: nodes.values.toList(),
      edges: edges,
      horizontal: dir == 'LR' || dir == 'RL',
    );
  }
}

class _Layout {
  _Layout(this.rects, this.size);

  final Map<String, Rect> rects;
  final Size size;
}

_Layout _layout(DiagramSpec spec, TextStyle style) {
  const maxW = 150.0, padX = 12.0, padY = 8.0;
  final sizes = <String, Size>{};
  for (final n in spec.nodes) {
    final tp = TextPainter(
      text: TextSpan(text: n.label, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 4,
      ellipsis: '…',
    )..layout(maxWidth: maxW);
    var w = tp.width + padX * 2, h = tp.height + padY * 2;
    if (n.shape == NodeShape.diamond) {
      w *= 1.5;
      h *= 1.6;
    }
    if (n.shape == NodeShape.circle) w = h = math.max(w, h);
    sizes[n.id] = Size(math.max(w, 56), math.max(h, 34));
  }

  // Layers: longest path from the roots, ignoring edges that close a cycle.
  final out = <String, List<String>>{for (final n in spec.nodes) n.id: []};
  for (final e in spec.edges) {
    out[e.from]?.add(e.to);
  }
  final layer = <String, int>{for (final n in spec.nodes) n.id: 0};
  final state = <String, int>{};
  final order = <String>[];
  void visit(String id) {
    if (state[id] == 2) return;
    if (state[id] == 1) return; // back edge
    state[id] = 1;
    for (final t in out[id] ?? const <String>[]) {
      visit(t);
    }
    state[id] = 2;
    order.add(id);
  }

  for (final n in spec.nodes) {
    visit(n.id);
  }
  final rank = {for (final (i, id) in order.reversed.indexed) id: i};
  for (final id in order.reversed) {
    for (final t in out[id] ?? const <String>[]) {
      if ((rank[t] ?? 0) > (rank[id] ?? 0)) {
        layer[t] = math.max(layer[t]!, layer[id]! + 1);
      }
    }
  }
  final layers = <int, List<String>>{};
  for (final n in spec.nodes) {
    layers.putIfAbsent(layer[n.id]!, () => []).add(n.id);
  }
  // One pass of barycentre ordering keeps children under their parents.
  final keys = layers.keys.toList()..sort();
  final pos = <String, double>{};
  for (final k in keys) {
    final ids = layers[k]!;
    if (k > 0) {
      double bary(String id) {
        final parents = [
          for (final e in spec.edges)
            if (e.to == id && pos[e.from] != null) pos[e.from]!,
        ];
        return parents.isEmpty
            ? double.infinity
            : parents.reduce((a, b) => a + b) / parents.length;
      }

      ids.sort((a, b) => bary(a).compareTo(bary(b)));
    }
    for (final (i, id) in ids.indexed) {
      pos[id] = i.toDouble();
    }
  }

  const gapAlong = 52.0, gapAcross = 22.0;
  final rects = <String, Rect>{};
  // Size of each layer across the flow, to centre them.
  double across(String id) =>
      spec.horizontal ? sizes[id]!.height : sizes[id]!.width;
  double along(String id) =>
      spec.horizontal ? sizes[id]!.width : sizes[id]!.height;
  final widths = {
    for (final k in keys)
      k: layers[k]!.fold<double>(0, (s, id) => s + across(id)) +
          gapAcross * (layers[k]!.length - 1),
  };
  final maxAcross = widths.values.fold<double>(0, math.max);
  var cursor = 0.0;
  for (final k in keys) {
    final depth = layers[k]!.fold<double>(0, (m, id) => math.max(m, along(id)));
    var a = (maxAcross - widths[k]!) / 2;
    for (final id in layers[k]!) {
      final s = sizes[id]!;
      final offAlong = cursor + (depth - along(id)) / 2;
      rects[id] = spec.horizontal
          ? Rect.fromLTWH(offAlong, a, s.width, s.height)
          : Rect.fromLTWH(a, offAlong, s.width, s.height);
      a += across(id) + gapAcross;
    }
    cursor += depth + gapAlong;
  }
  final total = cursor - gapAlong;
  return _Layout(
    rects,
    spec.horizontal ? Size(total, maxAcross) : Size(maxAcross, total),
  );
}

/// A diagram in the conversation, scrolling when bigger than the screen.
class DiagramBlock extends StatelessWidget {
  const DiagramBlock({required this.spec, super.key});

  final DiagramSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = (theme.textTheme.labelMedium ?? const TextStyle())
        .copyWith(color: scheme.onSurface);
    final layout = _layout(spec, style);
    const pad = 12.0;
    final size =
        Size(layout.size.width + pad * 2, layout.size.height + pad * 2);
    return BlockCard(
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (spec.title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: BlockHeader(title: spec.title),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 520),
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: LayoutBuilder(builder: (context, c) {
                  final width = math.max(
                      size.width, c.maxWidth.isFinite ? c.maxWidth : 0);
                  return CustomPaint(
                    size: Size(width.toDouble(), size.height),
                    painter: _DiagramPainter(
                      spec: spec,
                      layout: layout,
                      offset: Offset(pad + (width - size.width) / 2, pad),
                      style: style,
                      edgeLabel: style.copyWith(
                          fontSize: 10.5, color: scheme.onSurfaceVariant),
                      fill: scheme.primaryContainer,
                      decision: scheme.tertiaryContainer,
                      stroke: scheme.primary,
                      line: scheme.outline,
                      surface: scheme.surfaceContainerLow,
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagramPainter extends CustomPainter {
  _DiagramPainter({
    required this.spec,
    required this.layout,
    required this.offset,
    required this.style,
    required this.edgeLabel,
    required this.fill,
    required this.decision,
    required this.stroke,
    required this.line,
    required this.surface,
  });

  final DiagramSpec spec;
  final _Layout layout;
  final Offset offset;
  final TextStyle style, edgeLabel;
  final Color fill, decision, stroke, line, surface;

  /// Where the segment from the centre of [r] towards [to] leaves it.
  Offset _border(Rect r, Offset to, NodeShape shape) {
    final c = r.center;
    final d = to - c;
    if (d.distance == 0) return c;
    if (shape == NodeShape.circle) {
      return c + d / d.distance * (r.width / 2);
    }
    if (shape == NodeShape.diamond) {
      final t = 1 / (d.dx.abs() / (r.width / 2) + d.dy.abs() / (r.height / 2));
      return c + d * t;
    }
    final sx = d.dx == 0 ? double.infinity : (r.width / 2) / d.dx.abs();
    final sy = d.dy == 0 ? double.infinity : (r.height / 2) / d.dy.abs();
    return c + d * math.min(sx, sy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(offset.dx, offset.dy);
    final rects = layout.rects;
    final shapes = {for (final n in spec.nodes) n.id: n.shape};
    final linePaint = Paint()
      ..color = line
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    for (final e in spec.edges) {
      final a = rects[e.from], b = rects[e.to];
      if (a == null || b == null) continue;
      final p1 = _border(a, b.center, shapes[e.from]!);
      final p2 = _border(b, a.center, shapes[e.to]!);
      if (e.dashed) {
        final d = p2 - p1;
        final len = d.distance;
        for (var t = 0.0; t < len; t += 8) {
          canvas.drawLine(p1 + d * (t / len),
              p1 + d * (math.min(t + 4, len) / len), linePaint);
        }
      } else {
        canvas.drawLine(p1, p2, linePaint);
      }
      // Arrow head.
      final dir = (p2 - p1) / math.max(1, (p2 - p1).distance);
      final normal = Offset(-dir.dy, dir.dx);
      final head = Path()
        ..moveTo(p2.dx, p2.dy)
        ..lineTo((p2 - dir * 8 + normal * 4).dx, (p2 - dir * 8 + normal * 4).dy)
        ..lineTo((p2 - dir * 8 - normal * 4).dx, (p2 - dir * 8 - normal * 4).dy)
        ..close();
      canvas.drawPath(head, Paint()..color = line);
      if (e.label != null) {
        final tp = TextPainter(
          text: TextSpan(text: e.label, style: edgeLabel),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 120);
        final mid = (p1 + p2) / 2;
        final box = Rect.fromCenter(
            center: mid, width: tp.width + 8, height: tp.height + 4);
        canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(4)),
            Paint()..color = surface);
        tp.paint(canvas, box.topLeft + const Offset(4, 2));
      }
    }

    for (final n in spec.nodes) {
      final r = rects[n.id];
      if (r == null) continue;
      final paintFill = Paint()
        ..color = n.shape == NodeShape.diamond ? decision : fill;
      final paintStroke = Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      switch (n.shape) {
        case NodeShape.box || NodeShape.round:
          final rr = RRect.fromRectAndRadius(r,
              Radius.circular(n.shape == NodeShape.round ? r.height / 2 : 8));
          canvas
            ..drawRRect(rr, paintFill)
            ..drawRRect(rr, paintStroke);
        case NodeShape.circle:
          canvas
            ..drawOval(r, paintFill)
            ..drawOval(r, paintStroke);
        case NodeShape.diamond:
          final path = Path()
            ..moveTo(r.center.dx, r.top)
            ..lineTo(r.right, r.center.dy)
            ..lineTo(r.center.dx, r.bottom)
            ..lineTo(r.left, r.center.dy)
            ..close();
          canvas
            ..drawPath(path, paintFill)
            ..drawPath(path, paintStroke);
      }
      final tp = TextPainter(
        text: TextSpan(text: n.label, style: style),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 4,
        ellipsis: '…',
      )..layout(
          maxWidth:
              n.shape == NodeShape.diamond ? r.width / 1.5 : r.width - 16);
      tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_DiagramPainter old) =>
      old.spec != spec || old.fill != fill || old.style != style;
}
