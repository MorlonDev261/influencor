import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/l10n/app_strings.dart';
import '../../../../core/providers/workspace_providers.dart';
import '../../../library/application/library_providers.dart';
import '../../../library/domain/library_entry.dart';
import '../../../library/domain/table_document.dart';
import '../../application/tools/app_tools.dart';
import 'app_blocks.dart';
import 'chart_block.dart';
import 'chat_image.dart';
import 'data_blocks.dart';
import 'diagram_block.dart';
import 'markdown_blocks.dart';
import 'math_view.dart';
import 'rich_common.dart';
import 'syntax_highlight.dart';

/// Renders the Markdown Degany writes — headings, bold, italic, strikethrough,
/// links, lists (numbered, nested, task items), quotes, tables, code with
/// colours, formulas — and the rich blocks it can add as fenced blocks:
/// charts, key figures, progress, callouts, lists, timelines, diagrams,
/// buttons, forms of the app's data (task, ledger, fees, gallery, preview,
/// Deganeo report)… `[[path]]` becomes a button that opens the item. Text
/// still streaming renders fine.
/// Parsed finished messages, so rebuilding a message (theme change,
/// scrolling back to it) doesn't parse it again. Small LRU.
final _parseCache = <String, List<MdBlock>>{};

List<MdBlock> _parsed(String text) {
  final hit = _parseCache.remove(text);
  final blocks = hit ?? parseMarkdown(text);
  _parseCache[text] = blocks;
  if (_parseCache.length > 64) _parseCache.remove(_parseCache.keys.first);
  return blocks;
}

class RichMessage extends ConsumerWidget {
  const RichMessage({
    required this.text,
    required this.color,
    this.streaming = false,
    super.key,
  });

  final String text;
  final Color color;
  final bool streaming;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks = streaming ? parseMarkdown(text) : _parsed(text);
    final children = <Widget>[];
    for (final (i, b) in blocks.indexed) {
      final last = i == blocks.length - 1;
      children.add(_Block(
        block: b,
        color: color,
        streaming: streaming && last,
        cursor: streaming && last,
      ));
    }
    final lastInline = blocks.isNotEmpty &&
        (blocks.last is MdParagraph || blocks.last is MdHeading);
    if (streaming &&
        !lastInline &&
        !(blocks.isNotEmpty && blocks.last is MdFence)) {
      children.add(Text.rich(TextSpan(children: [_cursor(context, 16)])));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

InlineSpan _cursor(BuildContext context, double size) => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _Blinking(
        child: Container(
          width: 8,
          height: size * 1.1,
          margin: const EdgeInsets.only(left: 2),
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );

class _Blinking extends StatefulWidget {
  const _Blinking({required this.child});

  final Widget child;

  @override
  State<_Blinking> createState() => _BlinkingState();
}

class _BlinkingState extends State<_Blinking>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.25, end: 1.0).animate(_c),
        child: widget.child,
      );
}

class _Block extends ConsumerWidget {
  const _Block({
    required this.block,
    required this.color,
    this.streaming = false,
    this.cursor = false,
    this.depth = 0,
  });

  final MdBlock block;
  final Color color;
  final bool streaming;
  final bool cursor;
  final int depth;

  TextStyle _base(BuildContext context) => Theme.of(context)
      .textTheme
      .bodyLarge!
      .copyWith(color: color, height: 1.45);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = _base(context);
    final scheme = Theme.of(context).colorScheme;
    switch (block) {
      case MdParagraph(:final text) when markdownImage.hasMatch(text):
        // Pictures of a paragraph show full width, under its words.
        final rest = text.replaceAll(markdownImage, ' ').trim();
        return Padding(
          padding: EdgeInsets.symmetric(vertical: depth > 0 ? 2 : 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (rest.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text.rich(TextSpan(children: [
                    ...inlineSpans(context, rest, base),
                    if (cursor) _cursor(context, base.fontSize ?? 16),
                  ])),
                ),
              MarkdownImages(images: [
                for (final m in markdownImage.allMatches(text))
                  (m.group(2)!, m.group(1)!),
              ]),
            ],
          ),
        );
      case MdParagraph(:final text):
        final spans = inlineSpans(context, text, base);
        if (cursor) spans.add(_cursor(context, base.fontSize ?? 16));
        return Padding(
          padding: EdgeInsets.symmetric(vertical: depth > 0 ? 1 : 3),
          child: Text.rich(TextSpan(children: spans)),
        );
      case MdHeading(:final level, :final text):
        final size = base.fontSize ?? 16;
        final style = base.copyWith(
          fontWeight: level <= 2 ? FontWeight.w800 : FontWeight.w700,
          fontSize: size + switch (level) { 1 => 5, 2 => 3, 3 => 1, _ => 0 },
          height: 1.3,
        );
        final spans = inlineSpans(context, text, style);
        if (cursor) spans.add(_cursor(context, size));
        return Padding(
          padding: EdgeInsets.only(top: level <= 2 ? 10 : 8, bottom: 2),
          child: Text.rich(TextSpan(children: spans)),
        );
      case MdRule():
        return Divider(height: 20, color: scheme.outlineVariant);
      case MdList():
        return _list(context, block as MdList, base);
      case MdQuote(:final children):
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: scheme.outlineVariant, width: 3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, c) in children.indexed)
                _Block(
                  block: c,
                  color: scheme.onSurfaceVariant,
                  depth: depth + 1,
                  cursor: cursor && i == children.length - 1,
                ),
            ],
          ),
        );
      case MdTable(:final header, :final aligns, :final rows):
        return MarkdownTable(
          header: header,
          aligns: aligns,
          rows: rows,
          streaming: streaming,
        );
      case MdFence(:final language, :final code, :final closed):
        return richBlock(context, ref, language, code,
            closed: closed, streaming: streaming);
      case MdMath(:final tex):
        return MathBlock(tex: tex);
    }
  }

  Widget _list(BuildContext context, MdList list, TextStyle base) {
    final scheme = Theme.of(context).colorScheme;
    const bullets = ['•', '◦', '▪'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (k, item) in list.items.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: list.ordered ? 28 : 22,
                    child: item.checked != null
                        ? Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Icon(
                              item.checked!
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank,
                              size: 18,
                              color: item.checked!
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(
                              list.ordered
                                  ? '${list.start + k}.'
                                  : bullets[depth % bullets.length],
                              style: base.copyWith(
                                color: list.ordered
                                    ? scheme.onSurfaceVariant
                                    : scheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final (i, c) in item.children.indexed)
                          _Block(
                            block: c,
                            color: item.checked == true
                                ? scheme.onSurfaceVariant
                                : color,
                            depth: depth + 1,
                            streaming: streaming,
                            cursor: cursor &&
                                k == list.items.length - 1 &&
                                i == item.children.length - 1,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// --- Images ------------------------------------------------------------------

/// Markdown images (`![caption](path or URL)`), as a gallery. A path
/// outside the workspace (or a broken one) shows its caption instead.
class MarkdownImages extends ConsumerWidget {
  const MarkdownImages({
    required this.images,
    this.maxWidth = 560,
    this.maxHeight = 380,
    super.key,
  });

  /// (source, caption) pairs.
  final List<(String, String)> images;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = ref.watch(workspaceRootProvider);
    final sources = <ChatImageSource>[];
    final missing = <String>[];
    for (final (src, caption) in images) {
      final source = chatImageSource(src, root, caption: caption);
      if (source == null) {
        missing.add(caption.trim().isEmpty ? src : caption.trim());
      } else {
        sources.add(source);
      }
    }
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sources.isNotEmpty)
          ChatImageGallery(
              sources: sources, maxWidth: maxWidth, maxHeight: maxHeight),
        for (final m in missing)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.hide_image_outlined, size: 16, color: muted?.color),
            const SizedBox(width: 4),
            Flexible(child: Text(m, style: muted)),
          ]),
      ],
    );
  }
}

// --- Inline ------------------------------------------------------------------

final _inline = RegExp(
  [
    r'(?<path>\[\[(?<pathv>[^\]\n]+)\]\])',
    r'(?<img>!\[(?<imgalt>[^\]\n]*)\]\(\s*<?(?<imgsrc>[^)\s>]+)>?(?:\s+"[^"]*")?\s*\))',
    r'(?<link>\[(?<linkt>[^\]\n]+)\]\((?<linku>[^)\s]+)(?:\s+"[^"]*")?\))',
    r'(?<code>`(?<codev>[^`\n]+)`)',
    r'(?<bold>\*\*(?!\s)(?<bold1>.+?)(?<!\s)\*\*|__(?!\s)(?<bold2>.+?)(?<!\s)__)',
    r'(?<strike>~~(?!\s)(?<strikev>.+?)(?<!\s)~~)',
    r'(?<ital>(?<![\w*])\*(?!\s)(?<ital1>[^*\n]+?)(?<!\s)\*(?!\*)|(?<![\w_])_(?!\s)(?<ital2>[^_\n]+?)(?<!\s)_(?![\w_]))',
    r'(?<math>\\\((?<math1>.+?)\\\)|(?<![\w$\\])\$(?!\s)(?<math2>[^$\n]+?)(?<!\s)\$(?![\w$]))',
    r'(?<url>https?://[^\s<>\]\)]+)',
  ].join('|'),
);

/// Spans of one line (or paragraph) of inline Markdown.
List<InlineSpan> inlineSpans(
    BuildContext context, String text, TextStyle style) {
  final out = <InlineSpan>[];
  _inlineInto(context, text, style, out);
  return out;
}

void _inlineInto(
    BuildContext context, String text, TextStyle style, List<InlineSpan> out) {
  final scheme = Theme.of(context).colorScheme;
  var last = 0;
  for (final m in _inline.allMatches(text)) {
    var end = m.end;
    if (m.start > last) {
      out.add(TextSpan(text: text.substring(last, m.start), style: style));
    }
    if (m.namedGroup('imgsrc') case final src?) {
      // An image inside a line (a table cell, a heading): a small one.
      out.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: MarkdownImages(
            images: [(src, m.namedGroup('imgalt') ?? '')],
            maxWidth: 200,
            maxHeight: 140,
          ),
        ),
      ));
    } else if (m.namedGroup('pathv') case final path?) {
      out.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: PathChip(path: path.trim()),
      ));
    } else if (m.namedGroup('link') != null) {
      final label = m.namedGroup('linkt')!;
      final target = m.namedGroup('linku')!;
      final uri = Uri.tryParse(target);
      if (uri != null && uri.hasScheme) {
        out.add(TextSpan(
          text: plainInline(label),
          style: style.copyWith(
            color: scheme.primary,
            decoration: TextDecoration.underline,
            decorationColor: scheme.primary,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap =
                () => launchUrl(uri, mode: LaunchMode.externalApplication),
        ));
      } else {
        // A relative target is a library item.
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: PathChip(path: target, label: plainInline(label)),
        ));
      }
    } else if (m.namedGroup('codev') case final code?) {
      out.add(TextSpan(
        text: code,
        style: style.merge(monoStyle).copyWith(
              fontSize: (style.fontSize ?? 16) * 0.88,
              backgroundColor: scheme.onSurface.withValues(alpha: 0.07),
            ),
      ));
    } else if (m.namedGroup('bold') != null) {
      _inlineInto(context, m.namedGroup('bold1') ?? m.namedGroup('bold2')!,
          style.copyWith(fontWeight: FontWeight.w700), out);
    } else if (m.namedGroup('strikev') case final s?) {
      _inlineInto(context, s,
          style.copyWith(decoration: TextDecoration.lineThrough), out);
    } else if (m.namedGroup('ital') != null) {
      _inlineInto(context, m.namedGroup('ital1') ?? m.namedGroup('ital2')!,
          style.copyWith(fontStyle: FontStyle.italic), out);
    } else if (m.namedGroup('math') != null) {
      final tex = m.namedGroup('math1') ?? m.namedGroup('math2')!;
      if (RegExp(r'^[\d\s.,]+$').hasMatch(tex)) {
        // "$5 … 10$" is money, not math.
        out.add(TextSpan(text: m.group(0), style: style));
      } else {
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Text.rich(mathSpan(tex, style)),
        ));
      }
    } else {
      var url = m.namedGroup('url')!;
      // Trailing punctuation belongs to the sentence.
      final trail = RegExp(r'[.,;:!?]+$').firstMatch(url);
      if (trail != null) {
        url = url.substring(0, trail.start);
        end = m.start + url.length;
      }
      out.add(TextSpan(
        text: url,
        style: style.copyWith(
          color: scheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: scheme.primary,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () =>
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      ));
    }
    last = end;
  }
  if (last < text.length) {
    out.add(TextSpan(text: text.substring(last), style: style));
  }
}

// --- Rich blocks -------------------------------------------------------------

const _calloutLanguages = {
  'callout',
  'info',
  'note',
  'tip',
  'success',
  'warning',
  'error',
  'danger',
  'important',
  'caution',
};

/// The widget for a fenced block: a rich block when its language names one
/// and its content reads, the coloured code otherwise.
Widget richBlock(
  BuildContext context,
  WidgetRef ref,
  String language,
  String code, {
  bool closed = true,
  bool streaming = false,
}) {
  final strings = ref.read(appStringsProvider);
  final pending = !closed && streaming;
  Widget fallback() =>
      CodeBlock(code: code, language: language, cursor: pending);
  Widget loading(IconData icon) =>
      BlockLoading(label: strings.richPreparing, icon: icon);

  // Blocks whose JSON must be complete to draw.
  Widget json(IconData icon, bool Function(Object?) ok,
      Widget Function(Object?) build) {
    if (pending) return loading(icon);
    final value = decodeBlockJson(code);
    if (value == null || !ok(value)) return fallback();
    return build(value);
  }

  switch (language) {
    case 'chart' || 'charts':
      if (pending) return loading(Icons.insert_chart_outlined);
      final spec = ChartSpec.parse(decodeBlockJson(code));
      return spec == null ? fallback() : ChartBlock(spec: spec);
    case 'kpi' || 'stats' || 'metrics':
      return json(Icons.speed, KpiBlock.canShow, (v) => KpiBlock(json: v));
    case 'progress' || 'gauge':
      return json(Icons.linear_scale, ProgressBlock.canShow,
          (v) => ProgressBlock(json: v));
    case 'list' || 'items' || 'cards':
      return json(
          Icons.list_alt, ItemListBlock.canShow, (v) => ItemListBlock(json: v));
    case 'timeline' || 'steps':
      return json(
          Icons.timeline, TimelineBlock.canShow, (v) => TimelineBlock(json: v));
    case 'actions' || 'buttons':
      return json(Icons.smart_button, ActionsBlock.canShow,
          (v) => ActionsBlock(json: v, streaming: streaming));
    case 'suggestions' || 'followups':
      return json(Icons.subdirectory_arrow_right, SuggestionsBlock.canShow,
          (v) => SuggestionsBlock(json: v, streaming: streaming));
    case 'map' || 'places':
      return json(
          Icons.map_outlined, PlacesBlock.canShow, (v) => PlacesBlock(json: v));
    case 'task':
      return json(Icons.task_alt, (v) => TaskCardBlock.idOf(v) != null,
          (v) => TaskCardBlock(id: TaskCardBlock.idOf(v)!));
    case 'ledger' || 'accounting' || 'statement':
      if (pending) return loading(Icons.account_balance_wallet_outlined);
      return LedgerBlock(json: decodeBlockJson(code));
    case 'fees':
      return json(Icons.payments_outlined, FeesBlock.canShow,
          (v) => FeesBlock(json: v));
    case 'gallery' || 'images':
      return json(Icons.photo_library_outlined, GalleryBlock.canShow,
          (v) => GalleryBlock(json: v));
    case 'preview':
      if (pending) return loading(Icons.visibility_outlined);
      final value = decodeBlockJson(code) ?? code.trim();
      final path = PreviewBlock.pathOf(value);
      return path == null ? fallback() : PreviewBlock(path: path);
    case 'meta' || 'metadata' || 'deganeo':
      return json(Icons.cleaning_services_outlined, MetaBlock.canShow,
          (v) => MetaBlock(json: v));
    case 'mermaid' || 'diagram' || 'flowchart' || 'flow' || 'orgchart':
      if (pending) return loading(Icons.account_tree_outlined);
      final value = decodeBlockJson(code);
      final spec = (value == null ? null : DiagramSpec.fromJson(value)) ??
          DiagramSpec.fromMermaid(code);
      return spec == null ? fallback() : DiagramBlock(spec: spec);
    case 'math' || 'latex' || 'tex' || 'katex':
      return MathBlock(tex: code);
    case 'csv' || 'tsv':
      if (pending) return fallback();
      final sep = language == 'tsv' || code.contains('\t')
          ? '\t'
          : (code.split('\n').first.contains(';') ? ';' : ',');
      final rows = [
        for (final line in const LineSplitter().convert(code.trim()))
          if (line.trim().isNotEmpty) _splitCsv(line, sep),
      ];
      if (rows.length < 2) return fallback();
      return MarkdownTable(
        header: rows.first,
        aligns: List.filled(rows.first.length, MdAlign.none),
        rows: [
          for (final r in rows.skip(1))
            [
              for (var i = 0; i < rows.first.length; i++)
                i < r.length ? r[i] : ''
            ],
        ],
      );
    case 'table':
      return json(Icons.table_chart_outlined, (v) => _jsonTable(v) != null,
          (v) {
        final (header, rows) = _jsonTable(v)!;
        return MarkdownTable(
          header: header,
          aligns: List.filled(header.length, MdAlign.none),
          rows: rows,
        );
      });
  }
  if (_calloutLanguages.contains(language)) {
    if (pending && code.trim().startsWith('{')) {
      return loading(Icons.info_outline);
    }
    return CalloutBlock.fromBlock(language, code);
  }
  return fallback();
}

List<String> _splitCsv(String line, String sep) {
  final out = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      if (quoted && i + 1 < line.length && line[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (c == sep && !quoted) {
      out.add(cell.toString().trim());
      cell.clear();
    } else {
      cell.write(c);
    }
  }
  out.add(cell.toString().trim());
  return out;
}

/// `{"columns": [...], "rows": [[...]]}` or a list of objects.
(List<String>, List<List<String>>)? _jsonTable(Object? v) {
  String cell(Object? x) => x == null ? '' : '$x';
  if (v is Map && v['columns'] is List && v['rows'] is List) {
    final header = [
      for (final c in v['columns'] as List)
        cell(c is Map ? c['title'] ?? c['name'] : c)
    ];
    final rows = [
      for (final r in v['rows'] as List)
        if (r is List)
          [
            for (var i = 0; i < header.length; i++)
              i < r.length ? cell(r[i]) : ''
          ]
        else if (r is Map)
          [for (final h in header) cell(r[h])],
    ];
    return header.isEmpty ? null : (header, rows);
  }
  final list = v is Map ? v['rows'] ?? v['data'] : v;
  if (list is List && list.isNotEmpty && list.first is Map) {
    final header = <String>[];
    for (final r in list) {
      if (r is Map) {
        for (final k in r.keys) {
          if (!header.contains('$k')) header.add('$k');
        }
      }
    }
    return (
      header,
      [
        for (final r in list)
          if (r is Map) [for (final h in header) cell(r[h])],
      ]
    );
  }
  return null;
}

// --- Table -------------------------------------------------------------------

/// A table in the conversation: header, zebra rows, numbers aligned right,
/// sideways scrolling on phones; copy it, or save it as an Influencor table
/// or a CSV file.
class MarkdownTable extends ConsumerStatefulWidget {
  const MarkdownTable({
    required this.header,
    required this.aligns,
    required this.rows,
    this.streaming = false,
    super.key,
  });

  final List<String> header;
  final List<MdAlign> aligns;
  final List<List<String>> rows;
  final bool streaming;

  @override
  ConsumerState<MarkdownTable> createState() => _MarkdownTableState();
}

class _MarkdownTableState extends ConsumerState<MarkdownTable> {
  static const _shown = 40;
  var _all = false;

  List<List<String>> get _plain => [
        [for (final h in widget.header) plainInline(h)],
        for (final r in widget.rows) [for (final c in r) plainInline(c)],
      ];

  String get _markdown => [
        '| ${widget.header.join(' | ')} |',
        '|${widget.header.map((_) => ' --- ').join('|')}|',
        for (final r in widget.rows) '| ${r.join(' | ')} |',
      ].join('\n');

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    showChatSnack(context, ref.read(appStringsProvider).copiedToClipboard);
  }

  void _saved(String path) {
    final strings = ref.read(appStringsProvider);
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
  }

  Future<void> _saveTable() async {
    final strings = ref.read(appStringsProvider);
    try {
      final dir = await deganyExportDir(ref);
      const uuid = Uuid();
      final columns = [
        for (final h in _plain.first)
          TableColumnDef(id: uuid.v4(), title: h.isEmpty ? '—' : h),
      ];
      final table = TableDocument(columns: columns, rows: [
        for (final r in _plain.skip(1))
          TableRowData(id: uuid.v4(), cells: {
            for (final (i, c) in columns.indexed)
              c.id: i < r.length ? r[i] : '',
          }),
      ]);
      final path = await ref.read(libraryControllerProvider).createTable(dir,
          name: '${strings.richTableName} ${stamp()}', table: table);
      if (mounted) _saved(path);
    } on StateError {
      if (mounted) showChatSnack(context, strings.needWorkspace);
    }
  }

  Future<void> _saveCsv() async {
    final strings = ref.read(appStringsProvider);
    try {
      // BOM so spreadsheets read the accents right.
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(toCsv(_plain))];
      final path = await saveExportFile(ref,
          name: '${strings.richTableName} ${stamp()}',
          ext: 'csv',
          bytes: bytes);
      if (mounted) _saved(path);
    } on StateError {
      if (mounted) showChatSnack(context, strings.needWorkspace);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.textTheme.bodyMedium!.copyWith(height: 1.35);
    final n = widget.header.length;

    // A column of numbers (amounts, counts, %) aligns right.
    final numeric = [
      for (var c = 0; c < n; c++)
        widget.rows.isNotEmpty &&
            widget.rows.every((r) {
              final v = plainInline(r[c]).trim();
              return v.isEmpty ||
                  RegExp(r'^[-+]?[\d\s  .,]+\s*(Ar|%|€|\$|k|M)?$').hasMatch(v);
            }) &&
            widget.rows.any((r) => r[c].trim().isNotEmpty),
    ];
    TextAlign alignOf(int c) => switch (widget.aligns[c]) {
          MdAlign.center => TextAlign.center,
          MdAlign.right => TextAlign.right,
          MdAlign.left => TextAlign.left,
          MdAlign.none => numeric[c] ? TextAlign.right : TextAlign.left,
        };

    final rows = _all ? widget.rows : widget.rows.take(_shown).toList();
    Widget cell(String text, int c, {bool head = false}) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text.rich(
              TextSpan(
                children: inlineSpans(
                  context,
                  text,
                  head ? base.copyWith(fontWeight: FontWeight.w700) : base,
                ),
              ),
              textAlign: alignOf(c),
            ),
          ),
        );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(builder: (context, c) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: c.maxWidth),
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(flex: 1),
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  border: TableBorder(
                    horizontalInside:
                        BorderSide(color: scheme.outlineVariant, width: 0.6),
                  ),
                  children: [
                    TableRow(
                      decoration:
                          BoxDecoration(color: scheme.surfaceContainerHigh),
                      children: [
                        for (var c = 0; c < n; c++)
                          cell(widget.header[c], c, head: true),
                      ],
                    ),
                    for (final (i, r) in rows.indexed)
                      TableRow(
                        decoration: BoxDecoration(
                          color: i.isOdd
                              ? scheme.surfaceContainerLow
                              : scheme.surface,
                        ),
                        children: [for (var c = 0; c < n; c++) cell(r[c], c)],
                      ),
                  ],
                ),
              ),
            );
          }),
          if (!widget.streaming)
            Container(
              color: scheme.surfaceContainerLow,
              padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.richRows(widget.rows.length),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  if (widget.rows.length > _shown)
                    TextButton(
                      onPressed: () => setState(() => _all = !_all),
                      child: Text(
                          _all ? strings.richShowLess : strings.richShowAll),
                    ),
                  TinyIconButton(
                    icon: Icons.copy_rounded,
                    tooltip: strings.richCopyMarkdown,
                    onPressed: () => _copy(_markdown),
                  ),
                  PopupMenuButton<int>(
                    tooltip: strings.richMore,
                    icon: Icon(Icons.more_horiz,
                        size: 18, color: scheme.onSurfaceVariant),
                    onSelected: (v) {
                      switch (v) {
                        case 0:
                          _copy(_plain.map((r) => r.join('\t')).join('\n'));
                        case 1:
                          _saveTable();
                        case 2:
                          _saveCsv();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 0,
                        child: ListTile(
                          leading: const Icon(Icons.grid_on),
                          title: Text(strings.richCopyForSheet),
                        ),
                      ),
                      PopupMenuItem(
                        value: 1,
                        child: ListTile(
                          leading: const Icon(Icons.table_chart_outlined),
                          title: Text(strings.richSaveTable),
                        ),
                      ),
                      PopupMenuItem(
                        value: 2,
                        child: ListTile(
                          leading: const Icon(Icons.download_outlined),
                          title: Text(strings.richSaveCsv),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// --- Code --------------------------------------------------------------------

/// A code block: its language, a copy button, colours by token.
class CodeBlock extends ConsumerWidget {
  const CodeBlock({
    required this.code,
    required this.language,
    this.cursor = false,
    super.key,
  });

  final String code;
  final String language;
  final bool cursor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final base =
        monoStyle.copyWith(fontSize: 13, color: scheme.onSurface, height: 1.4);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 2, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(language,
                      style: monoStyle.copyWith(color: muted, fontSize: 12)),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  tooltip: ref.watch(appStringsProvider).copiedToClipboard,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    showChatSnack(context,
                        ref.read(appStringsProvider).copiedToClipboard);
                  },
                  icon: Icon(Icons.copy_rounded, color: muted),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text.rich(
              TextSpan(children: [
                highlightCode(code, language, base, scheme),
                if (cursor) TextSpan(text: '▍', style: base),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Library links -----------------------------------------------------------

/// A direct link to a library item: tap opens it, long-press copies the path.
class PathChip extends ConsumerWidget {
  const PathChip({required this.path, this.label, super.key});

  /// Workspace-relative (or absolute) path written by the model.
  final String path;

  /// Text to show instead of the file name.
  final String? label;

  String? _absolute(String? root) {
    final raw = path.replaceAll('\\', '/');
    if (p.isAbsolute(raw) || RegExp(r'^[A-Za-z]:/').hasMatch(raw)) {
      return p.normalize(raw);
    }
    if (root == null) return null;
    return p
        .normalize(p.join(root, raw.startsWith('/') ? raw.substring(1) : raw));
  }

  IconData _icon(String abs) {
    if (FileSystemEntity.isDirectorySync(abs)) return Icons.folder_outlined;
    return switch (kindForFile(abs)) {
      EntryKind.image => Icons.image_outlined,
      EntryKind.video => Icons.movie_outlined,
      EntryKind.note => Icons.description_outlined,
      _ => p.extension(abs).toLowerCase() == '.json'
          ? Icons.table_chart_outlined
          : Icons.insert_drive_file_outlined,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;
    final abs = _absolute(ref.watch(workspaceRootProvider));
    // No local files in a browser (web build): show a plain label.
    final exists = !kIsWeb &&
        abs != null &&
        FileSystemEntity.typeSync(abs) != FileSystemEntityType.notFound;
    final shown =
        label ?? (path.isEmpty ? '/' : p.basename(path.replaceAll('\\', '/')));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: path,
        child: Material(
          color: exists ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () async {
              if (!exists) {
                showChatSnack(context, strings.itemNotFound);
                return;
              }
              final route = await routeForPath(abs);
              if (context.mounted) unawaited(context.push(route));
            },
            onLongPress: abs == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: abs));
                    showChatSnack(context, strings.pathCopied);
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    exists ? _icon(abs) : Icons.link_off,
                    size: 15,
                    color: exists
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      shown,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: exists
                                ? scheme.onPrimaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
