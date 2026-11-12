import 'package:flutter/material.dart';

// A small LaTeX renderer for the formulas Degany writes ($…$, $$…$$):
// fractions, roots, exponents and indices, big operators, Greek letters and
// the usual symbols. Not a full TeX engine, but readable math with no
// package; anything it does not know shows as written.

sealed class _Node {
  const _Node();
}

class _Text extends _Node {
  const _Text(this.text, {this.upright = false});
  final String text;
  final bool upright;
}

class _Group extends _Node {
  const _Group(this.children);
  final List<_Node> children;
}

class _Frac extends _Node {
  const _Frac(this.num, this.den);
  final _Node num, den;
}

class _Sqrt extends _Node {
  const _Sqrt(this.body, this.index);
  final _Node body;
  final _Node? index;
}

class _Scripts extends _Node {
  const _Scripts(this.base, {this.sup, this.sub});
  final _Node base;
  final _Node? sup, sub;
}

class _Big extends _Node {
  const _Big(this.symbol);
  final String symbol;
}

class _Break extends _Node {
  const _Break();
}

const _symbols = {
  'alpha': 'α',
  'beta': 'β',
  'gamma': 'γ',
  'delta': 'δ',
  'epsilon': 'ε',
  'varepsilon': 'ε',
  'zeta': 'ζ',
  'eta': 'η',
  'theta': 'θ',
  'iota': 'ι',
  'kappa': 'κ',
  'lambda': 'λ',
  'mu': 'μ',
  'nu': 'ν',
  'xi': 'ξ',
  'pi': 'π',
  'rho': 'ρ',
  'sigma': 'σ',
  'tau': 'τ',
  'upsilon': 'υ',
  'phi': 'φ',
  'varphi': 'φ',
  'chi': 'χ',
  'psi': 'ψ',
  'omega': 'ω',
  'Gamma': 'Γ',
  'Delta': 'Δ',
  'Theta': 'Θ',
  'Lambda': 'Λ',
  'Xi': 'Ξ',
  'Pi': 'Π',
  'Sigma': 'Σ',
  'Phi': 'Φ',
  'Psi': 'Ψ',
  'Omega': 'Ω',
  'times': '×',
  'cdot': '·',
  'div': '÷',
  'pm': '±',
  'mp': '∓',
  'leq': '≤',
  'le': '≤',
  'geq': '≥',
  'ge': '≥',
  'neq': '≠',
  'ne': '≠',
  'approx': '≈',
  'equiv': '≡',
  'sim': '∼',
  'propto': '∝',
  'infty': '∞',
  'partial': '∂',
  'nabla': '∇',
  'to': '→',
  'rightarrow': '→',
  'leftarrow': '←',
  'Rightarrow': '⇒',
  'Leftarrow': '⇐',
  'Leftrightarrow': '⇔',
  'leftrightarrow': '↔',
  'implies': '⇒',
  'iff': '⇔',
  'mapsto': '↦',
  'in': '∈',
  'notin': '∉',
  'ni': '∋',
  'subset': '⊂',
  'subseteq': '⊆',
  'supset': '⊃',
  'supseteq': '⊇',
  'cup': '∪',
  'cap': '∩',
  'emptyset': '∅',
  'varnothing': '∅',
  'forall': '∀',
  'exists': '∃',
  'neg': '¬',
  'lnot': '¬',
  'land': '∧',
  'wedge': '∧',
  'lor': '∨',
  'vee': '∨',
  'circ': '∘',
  'degree': '°',
  'ldots': '…',
  'cdots': '⋯',
  'dots': '…',
  'vdots': '⋮',
  'prime': '′',
  'angle': '∠',
  'perp': '⊥',
  'parallel': '∥',
  'star': '⋆',
  'ast': '∗',
  'langle': '⟨',
  'rangle': '⟩',
  'lfloor': '⌊',
  'rfloor': '⌋',
  'lceil': '⌈',
  'rceil': '⌉',
  'mid': '∣',
  'vert': '|',
  'Vert': '‖',
  'quad': ' ',
  'qquad': '  ',
  ',': ' ',
  ';': ' ',
  ':': ' ',
  '!': '',
  ' ': ' ',
  '%': '%',
  r'$': r'$',
  '{': '{',
  '}': '}',
  '_': '_',
  '&': '&',
  '#': '#',
  'backslash': '\\',
  'euro': '€',
  'checkmark': '✓',
};

const _bigOps = {
  'sum': '∑',
  'prod': '∏',
  'int': '∫',
  'iint': '∬',
  'oint': '∮',
  'bigcup': '⋃',
  'bigcap': '⋂',
  'coprod': '∐',
};

const _functions = {
  'sin',
  'cos',
  'tan',
  'cot',
  'sec',
  'csc',
  'arcsin',
  'arccos',
  'arctan',
  'sinh',
  'cosh',
  'tanh',
  'log',
  'ln',
  'lg',
  'exp',
  'lim',
  'max',
  'min',
  'sup',
  'inf',
  'det',
  'dim',
  'gcd',
  'deg',
  'arg',
  'mod',
  'Pr',
};

const _blackboard = {
  'N': 'ℕ',
  'Z': 'ℤ',
  'Q': 'ℚ',
  'R': 'ℝ',
  'C': 'ℂ',
  'P': 'ℙ',
  'H': 'ℍ',
};

const _ignored = {
  'left',
  'right',
  'big',
  'Big',
  'bigg',
  'Bigg',
  'bigl',
  'bigr',
  'Bigl',
  'Bigr',
  'displaystyle',
  'textstyle',
  'limits',
  'nolimits',
  'middle',
};

class _Parser {
  _Parser(this.s);

  final String s;
  var i = 0;

  bool get done => i >= s.length;

  List<_Node> parseList({String? until}) {
    final out = <_Node>[];
    while (!done) {
      final c = s[i];
      if (until != null && c == until) {
        i++;
        return out;
      }
      if (c == '^' || c == '_') {
        i++;
        final arg = _atom();
        final base = out.isEmpty ? const _Text('') : out.removeLast();
        if (base is _Scripts &&
            (c == '^' ? base.sup == null : base.sub == null)) {
          out.add(c == '^'
              ? _Scripts(base.base, sup: arg, sub: base.sub)
              : _Scripts(base.base, sup: base.sup, sub: arg));
        } else {
          out.add(
              c == '^' ? _Scripts(base, sup: arg) : _Scripts(base, sub: arg));
        }
        continue;
      }
      out.add(_atom(inList: true));
    }
    return out;
  }

  _Node _atom({bool inList = false}) {
    if (done) return const _Text('');
    final c = s[i];
    if (c == '{') {
      i++;
      return _Group(parseList(until: '}'));
    }
    if (c == '\\') return _command();
    if (c == '&') {
      i++;
      return const _Text('  ');
    }
    if (c == '~') {
      i++;
      return const _Text(' ');
    }
    if (inList) {
      // A run of letters or digits reads as one piece.
      final start = i;
      if (RegExp(r'[0-9.,]').hasMatch(c)) {
        while (!done && RegExp(r'[0-9.,]').hasMatch(s[i])) {
          i++;
        }
        return _Text(s.substring(start, i), upright: true);
      }
    }
    i++;
    if (c == ' ') return const _Text(' ');
    final upright = !RegExp(r'[A-Za-z]').hasMatch(c);
    const spaced = {'=', '+', '<', '>', '−', '-'};
    if (spaced.contains(c)) {
      return _Text(' ${c == '-' ? '−' : c} ', upright: true);
    }
    return _Text(c, upright: upright);
  }

  String _name() {
    i++; // backslash
    if (done) return '';
    final start = i;
    if (!RegExp(r'[A-Za-z]').hasMatch(s[i])) {
      i++;
      return s.substring(start, i);
    }
    while (!done && RegExp(r'[A-Za-z]').hasMatch(s[i])) {
      i++;
    }
    return s.substring(start, i);
  }

  String _rawGroup() {
    while (!done && s[i] == ' ') {
      i++;
    }
    if (done) return '';
    if (s[i] != '{') return s[i++];
    var depth = 0;
    final start = i + 1;
    while (!done) {
      if (s[i] == '{') depth++;
      if (s[i] == '}') {
        depth--;
        if (depth == 0) {
          i++;
          return s.substring(start, i - 1);
        }
      }
      i++;
    }
    return s.substring(start);
  }

  _Node _arg() {
    while (!done && s[i] == ' ') {
      i++;
    }
    return _atom();
  }

  _Node _command() {
    final name = _name();
    if (name == '\\') return const _Break();
    if (_ignored.contains(name)) {
      // \left( → just the bracket.
      if (!done && (name == 'left' || name == 'right' || name == 'middle')) {
        if (s[i] == '.') {
          i++;
          return const _Text('');
        }
        if (s[i] == '\\') return _command();
        return _Text(s[i++], upright: true);
      }
      return const _Text('');
    }
    switch (name) {
      case 'frac' || 'dfrac' || 'tfrac' || 'cfrac':
        final n = _arg();
        final d = _arg();
        return _Frac(n, d);
      case 'binom':
        final n = _arg();
        final k = _arg();
        return _Group([
          const _Text('(', upright: true),
          _Frac(n, k),
          const _Text(')', upright: true),
        ]);
      case 'sqrt':
        _Node? index;
        if (!done && s[i] == '[') {
          i++;
          index = _Group(parseList(until: ']'));
        }
        return _Sqrt(_arg(), index);
      case 'text' ||
            'textrm' ||
            'mathrm' ||
            'operatorname' ||
            'textbf' ||
            'mathbf' ||
            'textit' ||
            'mathit' ||
            'mbox':
        return _Text(_rawGroup(),
            upright: name != 'textit' && name != 'mathit');
      case 'mathbb':
        final g = _rawGroup();
        return _Text(g.split('').map((c) => _blackboard[c] ?? c).join(),
            upright: true);
      case 'overline' ||
            'bar' ||
            'hat' ||
            'vec' ||
            'tilde' ||
            'dot' ||
            'underline' ||
            'mathcal' ||
            'boldsymbol' ||
            'pmb':
        return _arg();
    }
    if (_bigOps[name] case final op?) return _Big(op);
    if (_functions.contains(name)) return _Text(name, upright: true);
    if (_symbols[name] case final sym?) {
      const spaced = {
        '×',
        '·',
        '÷',
        '±',
        '∓',
        '≤',
        '≥',
        '≠',
        '≈',
        '≡',
        '→',
        '⇒',
        '⇔',
        '∈',
        '∉',
        '⊂',
        '⊆',
        '∪',
        '∩',
        '↔',
        '←',
        '⇐',
        '∼',
        '∝'
      };
      return _Text(spaced.contains(sym) ? ' $sym ' : sym, upright: true);
    }
    return _Text('\\$name', upright: true);
  }
}

/// Inline spans for [tex], in [style].
InlineSpan mathSpan(String tex, TextStyle style, {Color? color}) {
  final nodes = _Parser(tex.trim()).parseList();
  return TextSpan(children: _spans(nodes, style), style: style);
}

List<InlineSpan> _spans(List<_Node> nodes, TextStyle style) => [
      for (final n in nodes) ..._span(n, style),
    ];

TextStyle _smaller(TextStyle style, [double factor = 0.72]) =>
    style.copyWith(fontSize: (style.fontSize ?? 16) * factor);

Widget _rich(List<InlineSpan> spans, TextStyle style) =>
    Text.rich(TextSpan(children: spans, style: style), softWrap: false);

List<InlineSpan> _span(_Node n, TextStyle style) {
  switch (n) {
    case _Text(:final text, :final upright):
      if (text.isEmpty) return const [];
      return [
        TextSpan(
          text: text,
          style: upright ? style : style.copyWith(fontStyle: FontStyle.italic),
        ),
      ];
    case _Group(:final children):
      return _spans(children, style);
    case _Break():
      return const [TextSpan(text: '\n')];
    case _Big(:final symbol):
      return [
        TextSpan(
          text: symbol,
          style: style.copyWith(fontSize: (style.fontSize ?? 16) * 1.35),
        ),
      ];
    case _Frac(:final num, :final den):
      final inner = _smaller(style, 0.85);
      return [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: _rich(_span(num, inner), inner)),
                  Container(
                    height: 1.1,
                    margin: const EdgeInsets.symmetric(vertical: 1.5),
                    color: style.color,
                  ),
                  Center(child: _rich(_span(den, inner), inner)),
                ],
              ),
            ),
          ),
        ),
      ];
    case _Sqrt(:final body, :final index):
      final size = style.fontSize ?? 16;
      return [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (index != null)
                Padding(
                  padding: EdgeInsets.only(bottom: size * 0.5),
                  child: _rich(
                      _span(index, _smaller(style, 0.6)), _smaller(style, 0.6)),
                ),
              Text('√', style: style.copyWith(fontSize: size * 1.15)),
              Container(
                padding: const EdgeInsets.only(top: 2, left: 1, right: 2),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                        color: style.color ?? Colors.black, width: 1.1),
                  ),
                ),
                child: _rich(_span(body, style), style),
              ),
            ],
          ),
        ),
      ];
    case _Scripts(:final base, :final sup, :final sub):
      final small = _smaller(style);
      final baseSpans = _span(base, style);
      if (sup != null && sub != null) {
        return [
          ...baseSpans,
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _rich(_span(sup, small), small),
                _rich(_span(sub, small), small),
              ],
            ),
          ),
        ];
      }
      return [
        ...baseSpans,
        WidgetSpan(
          alignment: sup != null
              ? PlaceholderAlignment.top
              : PlaceholderAlignment.bottom,
          child: Transform.translate(
            offset:
                Offset(0, (style.fontSize ?? 16) * (sup != null ? -0.3 : 0.25)),
            child: _rich(_span(sup ?? sub!, small), small),
          ),
        ),
      ];
  }
}

/// A formula on its own line, centred, scrolling sideways when too wide.
class MathBlock extends StatelessWidget {
  const MathBlock({required this.tex, super.key});

  final String tex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
      fontSize: 18,
      color: theme.colorScheme.onSurface,
      fontFamilyFallback: const ['Cambria Math', 'STIX Two Math', 'serif'],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text.rich(mathSpan(tex, style), textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
