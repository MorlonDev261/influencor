// Block structure of the Markdown Degany writes: paragraphs, headings, rules,
// lists (ordered, nested, task items), quotes, tables, fenced blocks and
// display math. Pure Dart, so it is tested without widgets; text still
// streaming (an unclosed fence, a table without its rows yet) parses fine.

sealed class MdBlock {
  const MdBlock();
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);

  /// Inline Markdown; may hold line breaks.
  final String text;
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);

  final int level;
  final String text;
}

class MdRule extends MdBlock {
  const MdRule();
}

class MdListItem {
  const MdListItem(this.children, {this.checked});

  final List<MdBlock> children;

  /// Task item: `[x]` (true) or `[ ]` (false); null for a plain item.
  final bool? checked;
}

class MdList extends MdBlock {
  const MdList({
    required this.ordered,
    required this.items,
    this.start = 1,
  });

  final bool ordered;
  final int start;
  final List<MdListItem> items;
}

class MdQuote extends MdBlock {
  const MdQuote(this.children);

  final List<MdBlock> children;
}

enum MdAlign { left, center, right, none }

class MdTable extends MdBlock {
  const MdTable({
    required this.header,
    required this.aligns,
    required this.rows,
  });

  final List<String> header;
  final List<MdAlign> aligns;
  final List<List<String>> rows;
}

class MdFence extends MdBlock {
  const MdFence(this.language, this.code, {this.closed = true});

  /// The info string, lower-cased (`chart`, `dart`, `json`…); may be empty.
  final String language;
  final String code;

  /// False while the closing ``` has not arrived yet (streaming).
  final bool closed;
}

class MdMath extends MdBlock {
  const MdMath(this.tex, {this.closed = true});

  final String tex;
  final bool closed;
}

final _fenceOpen = RegExp(r'^\s{0,3}(`{3,}|~{3,})\s*([^`\s]*)[^`]*$');
final _heading = RegExp(r'^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$');
final _rule = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final _listMarker = RegExp(r'^(\s*)([-*+•]|(\d{1,9})[.)])(\s+|$)(.*)$');
final _task = RegExp(r'^\[([ xX])\]\s+');
final _quote = RegExp(r'^\s{0,3}>\s?');
final _tableSep = RegExp(r'^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$');

int _indent(String line) {
  var n = 0;
  for (final c in line.runes) {
    if (c == 0x20) {
      n++;
    } else if (c == 0x09) {
      n += 4;
    } else {
      break;
    }
  }
  return n;
}

String _dedent(String line, int by) {
  var i = 0;
  var n = 0;
  while (i < line.length && n < by) {
    if (line[i] == ' ') {
      n++;
    } else if (line[i] == '\t') {
      n += 4;
    } else {
      break;
    }
    i++;
  }
  return line.substring(i);
}

/// Cells of a table row: `| a | b |` → `[a, b]` (escaped `\|` kept).
List<String> splitTableRow(String line) {
  var s = line.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|') && !s.endsWith(r'\|')) s = s.substring(0, s.length - 1);
  final cells = <String>[];
  final cell = StringBuffer();
  var code = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '\\' && i + 1 < s.length && s[i + 1] == '|') {
      cell.write('|');
      i++;
    } else if (c == '`') {
      code = !code;
      cell.write(c);
    } else if (c == '|' && !code) {
      cells.add(cell.toString().trim());
      cell.clear();
    } else {
      cell.write(c);
    }
  }
  cells.add(cell.toString().trim());
  return cells;
}

bool _isTableRow(String line) => line.contains('|') && line.trim().isNotEmpty;

MdAlign _align(String cell) {
  final c = cell.trim();
  final left = c.startsWith(':');
  final right = c.endsWith(':');
  if (left && right) return MdAlign.center;
  if (right) return MdAlign.right;
  if (left) return MdAlign.left;
  return MdAlign.none;
}

/// Parses [text] into blocks.
List<MdBlock> parseMarkdown(String text) =>
    _parse(text.replaceAll('\r\n', '\n').split('\n'));

bool _startsBlock(List<String> lines, int i) {
  final line = lines[i];
  if (line.trim().isEmpty) return true;
  if (_fenceOpen.hasMatch(line)) return true;
  if (_heading.hasMatch(line)) return true;
  if (_rule.hasMatch(line)) return true;
  if (_quote.hasMatch(line)) return true;
  if (line.trim().startsWith(r'$$') || line.trim() == r'\[') return true;
  final m = _listMarker.firstMatch(line);
  if (m != null && m.group(5)!.trim().isNotEmpty) return true;
  if (_isTableRow(line) &&
      i + 1 < lines.length &&
      _tableSep.hasMatch(lines[i + 1])) {
    return true;
  }
  return false;
}

List<MdBlock> _parse(List<String> lines) {
  final blocks = <MdBlock>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    // Fenced block (```lang … ```), possibly still open.
    final fence = _fenceOpen.firstMatch(line);
    if (fence != null) {
      final marker = fence.group(1)!;
      final indent = _indent(line);
      final body = <String>[];
      var closed = false;
      i++;
      while (i < lines.length) {
        final l = lines[i];
        final t = l.trim();
        if (t.startsWith(marker[0] * marker.length) &&
            t.replaceAll(marker[0], '').isEmpty) {
          closed = true;
          i++;
          break;
        }
        body.add(_dedent(l, indent));
        i++;
      }
      blocks.add(MdFence(
        fence.group(2)!.toLowerCase(),
        body.join('\n'),
        closed: closed,
      ));
      continue;
    }

    // Display math: $$ … $$ or \[ … \].
    final t = line.trim();
    if (t.startsWith(r'$$') || t == r'\[') {
      final close = t.startsWith(r'$$') ? r'$$' : r'\]';
      final rest = t.substring(2);
      if (close == r'$$' && rest.endsWith(r'$$') && rest.length >= 2) {
        blocks.add(MdMath(rest.substring(0, rest.length - 2).trim()));
        i++;
        continue;
      }
      final body = <String>[if (rest.trim().isNotEmpty) rest];
      var closed = false;
      i++;
      while (i < lines.length) {
        final l = lines[i].trim();
        if (l.endsWith(close)) {
          final head = l.substring(0, l.length - close.length);
          if (head.trim().isNotEmpty) body.add(head);
          closed = true;
          i++;
          break;
        }
        body.add(lines[i]);
        i++;
      }
      blocks.add(MdMath(body.join('\n').trim(), closed: closed));
      continue;
    }

    final heading = _heading.firstMatch(line);
    if (heading != null) {
      blocks.add(MdHeading(heading.group(1)!.length, heading.group(2)!));
      i++;
      continue;
    }

    if (_rule.hasMatch(line)) {
      blocks.add(const MdRule());
      i++;
      continue;
    }

    if (_quote.hasMatch(line)) {
      final body = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        final l = lines[i];
        final q = _quote.firstMatch(l);
        if (q == null && body.isNotEmpty && _startsBlock(lines, i)) break;
        body.add(q == null ? l : l.substring(q.end));
        i++;
      }
      blocks.add(MdQuote(_parse(body)));
      continue;
    }

    if (_isTableRow(line) &&
        i + 1 < lines.length &&
        _tableSep.hasMatch(lines[i + 1])) {
      final header = splitTableRow(line);
      final aligns = [for (final c in splitTableRow(lines[i + 1])) _align(c)];
      i += 2;
      final rows = <List<String>>[];
      while (i < lines.length && _isTableRow(lines[i])) {
        final cells = splitTableRow(lines[i]);
        rows.add([
          for (var k = 0; k < header.length; k++)
            k < cells.length ? cells[k] : '',
        ]);
        i++;
      }
      blocks.add(MdTable(
        header: header,
        aligns: [
          for (var k = 0; k < header.length; k++)
            k < aligns.length ? aligns[k] : MdAlign.none,
        ],
        rows: rows,
      ));
      continue;
    }

    final marker = _listMarker.firstMatch(line);
    if (marker != null && marker.group(5)!.trim().isNotEmpty) {
      i = _parseList(lines, i, blocks);
      continue;
    }

    // Paragraph: until a blank line or another kind of block.
    final para = <String>[line.trimLeft()];
    i++;
    while (i < lines.length && !_startsBlock(lines, i)) {
      para.add(lines[i].trimLeft());
      i++;
    }
    blocks.add(MdParagraph(para.join('\n')));
  }
  return blocks;
}

/// Parses the list starting at [start] into [out]; returns the next line.
int _parseList(List<String> lines, int start, List<MdBlock> out) {
  final first = _listMarker.firstMatch(lines[start])!;
  final baseIndent = _indent(lines[start]);
  final ordered = first.group(3) != null;
  final items = <MdListItem>[];
  var i = start;
  while (i < lines.length) {
    final m = _listMarker.firstMatch(lines[i]);
    if (m == null ||
        _indent(lines[i]) != baseIndent ||
        (m.group(3) != null) != ordered ||
        m.group(5)!.trim().isEmpty) {
      break;
    }
    // Where the item's text starts: its continuation lines line up there.
    final contentIndent = baseIndent + m.group(2)!.length + 1;
    final body = <String>[m.group(5)!];
    i++;
    while (i < lines.length) {
      final l = lines[i];
      if (l.trim().isEmpty) {
        // A blank line continues the item only if indented text follows.
        final next = i + 1 < lines.length ? lines[i + 1] : '';
        if (next.trim().isNotEmpty && _indent(next) > baseIndent) {
          body.add('');
          i++;
          continue;
        }
        break;
      }
      final indent = _indent(l);
      if (indent > baseIndent) {
        body.add(_dedent(l, contentIndent.clamp(0, indent)));
        i++;
        continue;
      }
      // Lazy continuation: plain text right under the item.
      if (!_startsBlock(lines, i)) {
        body.add(l.trimLeft());
        i++;
        continue;
      }
      break;
    }
    bool? checked;
    final task = _task.firstMatch(body.first);
    if (task != null) {
      checked = task.group(1) != ' ';
      body[0] = body.first.substring(task.end);
    }
    items.add(MdListItem(_parse(body), checked: checked));
  }
  out.add(MdList(
    ordered: ordered,
    start: ordered ? int.tryParse(first.group(3)!) ?? 1 : 1,
    items: items,
  ));
  return i;
}

/// Plain text of a Markdown answer: what "copy as text" and sharing give.
String markdownToPlainText(String text) {
  final out = <String>[];
  void walk(List<MdBlock> blocks, String indent) {
    for (final b in blocks) {
      switch (b) {
        case MdParagraph(:final text):
          out.add('$indent${plainInline(text)}');
        case MdHeading(:final text):
          out.add('$indent${plainInline(text)}');
        case MdRule():
          out.add('');
        case MdList(:final ordered, :final start, :final items):
          for (final (k, item) in items.indexed) {
            final mark = item.checked == null
                ? (ordered ? '${start + k}.' : '•')
                : (item.checked! ? '☑' : '☐');
            final before = out.length;
            walk(item.children, '$indent   ');
            if (out.length > before) {
              out[before] = '$indent$mark ${out[before].trimLeft()}';
            }
          }
        case MdQuote(:final children):
          walk(children, '$indent  ');
        case MdTable(:final header, :final rows):
          out.add('$indent${header.map(plainInline).join('\t')}');
          for (final r in rows) {
            out.add('$indent${r.map(plainInline).join('\t')}');
          }
        case MdFence(:final code):
          out.add(code);
        case MdMath(:final tex):
          out.add(tex);
      }
    }
  }

  walk(parseMarkdown(text), '');
  return out.join('\n').trim();
}

/// Inline Markdown without its marks: `**a** [b](u) [[c/d.md]]` → `a b d.md`.
String plainInline(String text) => text
    .replaceAllMapped(RegExp(r'!\[([^\]\n]*)\]\([^)\n]*\)'), (m) => m.group(1)!)
    .replaceAllMapped(
        RegExp(r'\[\[([^\]\n]+)\]\]'), (m) => m.group(1)!.split('/').last)
    .replaceAllMapped(
        RegExp(r'\[([^\]\n]+)\]\(([^)\s]+)\)'), (m) => m.group(1)!)
    .replaceAllMapped(RegExp(r'(\*\*|__|~~)(.+?)\1'), (m) => m.group(2)!)
    .replaceAllMapped(
        RegExp(r'(?<![\w*])\*(?!\s)([^*\n]+?)\*(?!\*)'), (m) => m.group(1)!)
    .replaceAllMapped(
        RegExp(r'(?<![\w_])_(?!\s)([^_\n]+?)_(?![\w_])'), (m) => m.group(1)!)
    .replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m.group(1)!);
