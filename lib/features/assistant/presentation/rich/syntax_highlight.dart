import 'package:flutter/material.dart';

// Light syntax colouring for code blocks: comments, strings, numbers,
// keywords, JSON keys and HTML tags. One tokenizer for every language —
// enough to read code at a glance, without a highlighting package.

const _keywords = {
  // C family, Dart, Java, JS/TS, Kotlin, Swift, Go, Rust, PHP
  'abstract', 'as', 'async', 'await', 'break', 'case', 'catch', 'class',
  'const', 'continue', 'default', 'defer', 'do', 'else', 'enum', 'export',
  'extends', 'extension', 'false', 'final', 'finally', 'fn', 'for',
  'function', 'func', 'fun', 'go', 'if', 'impl', 'implements', 'import',
  'in', 'interface', 'is', 'late', 'let', 'match', 'mixin', 'mod', 'mut',
  'new', 'null', 'nil', 'none', 'override', 'package', 'private',
  'protected', 'pub', 'public', 'required', 'return', 'sealed', 'static',
  'struct', 'super', 'switch', 'this', 'throw', 'throws', 'trait', 'true',
  'try', 'type', 'typeof', 'undefined', 'use', 'val', 'var', 'void',
  'when', 'where', 'while', 'with', 'yield',
  // Python, Ruby, shell
  'and', 'def', 'del', 'elif', 'end', 'except', 'from', 'global', 'lambda',
  'nonlocal', 'not', 'or', 'pass', 'raise', 'self', 'then', 'fi', 'done',
  'esac', 'echo', 'local', 'unless', 'module', 'require', 'True', 'False',
  'None',
  // SQL
  'select', 'insert', 'update', 'delete', 'into', 'values', 'set', 'join',
  'left', 'right', 'inner', 'outer', 'on', 'group', 'by', 'order',
  'having', 'limit', 'create', 'table', 'drop', 'alter', 'index', 'primary',
  'key', 'foreign', 'references', 'distinct', 'union', 'count', 'sum',
  'avg', 'min', 'max', 'like', 'between', 'exists', 'desc', 'asc',
};

const _hashComments = {
  'python',
  'py',
  'sh',
  'bash',
  'zsh',
  'shell',
  'yaml',
  'yml',
  'ruby',
  'rb',
  'r',
  'toml',
  'ini',
  'conf',
  'dockerfile',
  'makefile',
  'powershell',
  'ps1',
  'perl',
  'nginx',
  'env',
};

const _caseInsensitive = {'sql', 'mysql', 'postgresql', 'sqlite'};

/// Coloured spans for [code] written in [language].
TextSpan highlightCode(
    String code, String language, TextStyle base, ColorScheme scheme) {
  final lang = language.toLowerCase();
  final dark = scheme.brightness == Brightness.dark;
  final comment = base.copyWith(
      color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic);
  final string = base.copyWith(
      color: dark ? const Color(0xFF86EFAC) : const Color(0xFF15803D));
  final number = base.copyWith(
      color: dark ? const Color(0xFFFDBA74) : const Color(0xFFC2410C));
  final keyword = base.copyWith(
      color: dark ? const Color(0xFFC4B5FD) : const Color(0xFF7C3AED),
      fontWeight: FontWeight.w600);
  final key = base.copyWith(color: scheme.primary);
  final tag = base.copyWith(color: scheme.primary);

  if (lang.isEmpty || lang == 'text' || lang == 'txt' || lang == 'plain') {
    return TextSpan(text: code, style: base);
  }

  final hash = _hashComments.contains(lang);
  final markup = const {'html', 'xml', 'svg', 'vue'}.contains(lang);
  final json = lang == 'json' || lang == 'jsonc';
  final sqlLike = _caseInsensitive.contains(lang);
  final pattern = RegExp(
    [
      if (markup) r'(?<comment><!--[\s\S]*?(?:-->|$))',
      if (!markup) r'(?<comment>/\*[\s\S]*?(?:\*/|$)|//[^\n]*)',
      if (hash) r'(?<hash>#[^\n]*)',
      if (sqlLike) r'(?<dash>--[^\n]*)',
      '(?<string>${[
        r'"(?:[^"\\\n]|\\.)*"?',
        r"'(?:[^'\\\n]|\\.)*'?",
        r'`(?:[^`\\]|\\.)*`?',
      ].join('|')})',
      if (markup) r'(?<tag></?[A-Za-z][\w:-]*|/?>)',
      r'(?<number>\b(?:0x[0-9a-fA-F]+|\d+(?:[.,]\d+)?(?:[eE][+-]?\d+)?)\b)',
      r'(?<word>\b[A-Za-z_]\w*\b)',
    ].join('|'),
  );

  final spans = <TextSpan>[];
  var last = 0;
  for (final m in pattern.allMatches(code)) {
    if (m.start > last) {
      spans.add(TextSpan(text: code.substring(last, m.start), style: base));
    }
    final text = m.group(0)!;
    TextStyle style = base;
    String? g(String name) =>
        m.groupNames.contains(name) ? m.namedGroup(name) : null;

    if (g('comment') != null || g('hash') != null || g('dash') != null) {
      style = comment;
    } else if (g('string') != null) {
      // In JSON, a string followed by ':' is a key.
      final after = code.substring(m.end).trimLeft();
      style = json && after.startsWith(':') ? key : string;
    } else if (g('tag') != null) {
      style = tag;
    } else if (g('number') != null) {
      style = number;
    } else if (g('word') != null) {
      final w = sqlLike ? text.toLowerCase() : text;
      if (_keywords.contains(w) && !markup) style = keyword;
    }
    spans.add(TextSpan(text: text, style: style));
    last = m.end;
  }
  if (last < code.length) {
    spans.add(TextSpan(text: code.substring(last), style: base));
  }
  return TextSpan(children: spans, style: base);
}
