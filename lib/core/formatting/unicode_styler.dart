import 'package:meta/meta.dart';

/// Inline character styles that can combine on a run of text.
@immutable
class InlineStyle {
  const InlineStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.code = false,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool code;

  static const none = InlineStyle();

  bool get isEmpty => !bold && !italic && !underline && !strike && !code;

  InlineStyle copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    bool? code,
  }) =>
      InlineStyle(
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        underline: underline ?? this.underline,
        strike: strike ?? this.strike,
        code: code ?? this.code,
      );

  @override
  bool operator ==(Object other) =>
      other is InlineStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.strike == strike &&
      other.code == code;

  @override
  int get hashCode => Object.hash(bold, italic, underline, strike, code);

  @override
  String toString() => 'InlineStyle(${[
        if (bold) 'bold',
        if (italic) 'italic',
        if (underline) 'underline',
        if (strike) 'strike',
        if (code) 'code',
      ].join('+')})';
}

/// The Unicode "alphabet" a base ASCII letter/digit is mapped into.
enum UnicodeAlphabet { normal, bold, italic, boldItalic, monospace }

/// Bidirectional engine that converts styled text to visually-formatted Unicode
/// and back. The styled characters are *native text* — no markup — so they paste
/// into any plain-text field (social networks, messaging, SMS, web) keeping their
/// look.
///
/// Design rules:
///  * One deterministic alphabet per run: code > bold+italic > bold > italic >
///    normal. Strike and underline are independent overlays applied with
///    combining marks (U+0336 / U+0332).
///  * Accents are preserved: precomposed Latin letters are decomposed to a base
///    letter + combining mark(s); the base is styled, the marks are kept.
///  * Nothing is ever dropped: characters without an equivalent (emoji, `œ`,
///    `€`, punctuation, non-Latin scripts) are emitted unchanged.
///  * [plainify] and [detectStyle] make styling reversible, so the toolbar can
///    toggle a style off and re-styling is idempotent (no mark accumulation).
class UnicodeStyler {
  const UnicodeStyler();

  // U+0336 (long stroke overlay) gives a continuous strikethrough (rendered
  // centred by the note font, see AppConstants.noteFontFamily). U+0335 (short
  // stroke) is still recognised for notes saved during an earlier build.
  static const int combiningStrike = 0x0336;
  static const int _legacyStrike = 0x0335;
  static const int combiningUnderline = 0x0332; // low line

  // --- Forward: plain -> styled ---------------------------------------------

  /// Transforms already-plain [input] according to [style]. To restyle text that
  /// may already be styled, call [plainify] first (see [restyle]).
  String transform(String input, InlineStyle style) {
    if (input.isEmpty) return input;
    final alphabet = alphabetFor(style);
    final strike = style.strike;
    final underline = style.underline;

    if (alphabet == UnicodeAlphabet.normal && !strike && !underline) {
      return input;
    }

    final sb = StringBuffer();
    for (final rune in input.runes) {
      if (rune == 0x0A) {
        sb.writeCharCode(rune); // newline: never styled/overlaid
        continue;
      }
      final decomposition = _decompose[rune];
      if (decomposition != null) {
        sb.write(_mapCodePoint(decomposition.base, alphabet));
        for (final mark in decomposition.marks) {
          sb.writeCharCode(mark);
        }
      } else {
        sb.write(_mapCodePoint(rune, alphabet));
      }
      if (strike) sb.writeCharCode(combiningStrike);
      if (underline) sb.writeCharCode(combiningUnderline);
    }
    return sb.toString();
  }

  /// Convenience: strip any existing styling from [input], then apply [style].
  /// This is what the toolbar uses so toggling and combining are deterministic.
  String restyle(String input, InlineStyle style) =>
      transform(plainify(input), style);

  UnicodeAlphabet alphabetFor(InlineStyle s) {
    if (s.code) return UnicodeAlphabet.monospace;
    if (s.bold && s.italic) return UnicodeAlphabet.boldItalic;
    if (s.bold) return UnicodeAlphabet.bold;
    if (s.italic) return UnicodeAlphabet.italic;
    return UnicodeAlphabet.normal;
  }

  // --- Reverse: styled -> plain ---------------------------------------------

  /// Removes all styling: styled letters/digits map back to ASCII and the
  /// strike/underline overlays are removed. Accent combining marks are kept, so
  /// `𝐞́` becomes `e` + combining acute (still displays as `é`).
  String plainify(String input) {
    if (input.isEmpty) return input;
    final sb = StringBuffer();
    for (final rune in input.runes) {
      if (rune == combiningStrike ||
          rune == _legacyStrike ||
          rune == combiningUnderline) {
        continue;
      }
      sb.writeCharCode(_reverseChar[rune] ?? rune);
    }
    return sb.toString();
  }

  /// Detects the dominant style of [input]: the alphabet of the first styled
  /// letter, plus whichever overlays appear anywhere. Used by the toolbar to
  /// decide whether a button toggles a style on or off.
  InlineStyle detectStyle(String input) {
    var bold = false, italic = false, code = false;
    for (final rune in input.runes) {
      final alphabet = _reverseAlphabet[rune];
      if (alphabet == null) continue;
      switch (alphabet) {
        case UnicodeAlphabet.bold:
          bold = true;
        case UnicodeAlphabet.italic:
          italic = true;
        case UnicodeAlphabet.boldItalic:
          bold = true;
          italic = true;
        case UnicodeAlphabet.monospace:
          code = true;
        case UnicodeAlphabet.normal:
          break;
      }
      break; // first styled letter sets the alphabet
    }
    final runes = input.runes;
    return InlineStyle(
      bold: bold,
      italic: italic,
      code: code,
      strike: runes.any((r) => r == combiningStrike || r == _legacyStrike),
      underline: runes.contains(combiningUnderline),
    );
  }

  // --- Internals -------------------------------------------------------------

  String _mapCodePoint(int cp, UnicodeAlphabet alphabet) {
    if (alphabet == UnicodeAlphabet.normal) return String.fromCharCode(cp);
    if (cp >= 0x41 && cp <= 0x5A) {
      return String.fromCharCode(_upperBase[alphabet]! + (cp - 0x41));
    }
    if (cp >= 0x61 && cp <= 0x7A) {
      final exception = _lowerExceptions[alphabet]?[cp];
      if (exception != null) return String.fromCharCode(exception);
      return String.fromCharCode(_lowerBase[alphabet]! + (cp - 0x61));
    }
    if (cp >= 0x30 && cp <= 0x39) {
      final base = _digitBase[alphabet];
      if (base == null) return String.fromCharCode(cp);
      return String.fromCharCode(base + (cp - 0x30));
    }
    return String.fromCharCode(cp);
  }

  // Bold and bold-italic use the sans-serif alphabets (𝗕, 𝘽): a clean bold
  // that reads like the app font. The older serif ones (𝐁, 𝑩) stay readable
  // through [_legacyUpperBase] so notes saved before keep toggling off.
  static const Map<UnicodeAlphabet, int> _upperBase = {
    UnicodeAlphabet.bold: 0x1D5D4,
    UnicodeAlphabet.italic: 0x1D434,
    UnicodeAlphabet.boldItalic: 0x1D63C,
    UnicodeAlphabet.monospace: 0x1D670,
  };

  static const Map<UnicodeAlphabet, int> _lowerBase = {
    UnicodeAlphabet.bold: 0x1D5EE,
    UnicodeAlphabet.italic: 0x1D44E,
    UnicodeAlphabet.boldItalic: 0x1D656,
    UnicodeAlphabet.monospace: 0x1D68A,
  };

  static const Map<UnicodeAlphabet, int?> _digitBase = {
    UnicodeAlphabet.bold: 0x1D7EC,
    UnicodeAlphabet.italic: null,
    UnicodeAlphabet.boldItalic: 0x1D7EC,
    UnicodeAlphabet.monospace: 0x1D7F6,
  };

  // Serif bold alphabets written by earlier builds: (upper, lower, digits).
  static const Map<UnicodeAlphabet, (int, int, int)> _legacyBases = {
    UnicodeAlphabet.bold: (0x1D400, 0x1D41A, 0x1D7CE),
    UnicodeAlphabet.boldItalic: (0x1D468, 0x1D482, 0x1D7CE),
  };

  static const Map<UnicodeAlphabet, Map<int, int>> _lowerExceptions = {
    UnicodeAlphabet.italic: {0x68: 0x210E}, // italic small h
  };

  // Reverse lookup tables, built once from the forward ranges.
  static final Map<int, int> _reverseChar = _buildReverseChar();
  static final Map<int, UnicodeAlphabet> _reverseAlphabet =
      _buildReverseAlphabet();

  static Map<int, int> _buildReverseChar() {
    final map = <int, int>{};
    for (final a in _upperBase.keys) {
      for (var i = 0; i < 26; i++) {
        map[_upperBase[a]! + i] = 0x41 + i;
        map[_lowerBase[a]! + i] = 0x61 + i;
      }
      final digits = _digitBase[a];
      if (digits != null) {
        for (var i = 0; i < 10; i++) {
          map[digits + i] = 0x30 + i;
        }
      }
    }
    _legacyBases.forEach((_, b) {
      final (upper, lower, digits) = b;
      for (var i = 0; i < 26; i++) {
        map[upper + i] = 0x41 + i;
        map[lower + i] = 0x61 + i;
      }
      for (var i = 0; i < 10; i++) {
        map[digits + i] = 0x30 + i;
      }
    });
    // Exceptions (styled -> ascii).
    _lowerExceptions.forEach((_, ex) {
      ex.forEach((ascii, styled) => map[styled] = ascii);
    });
    return map;
  }

  static Map<int, UnicodeAlphabet> _buildReverseAlphabet() {
    final map = <int, UnicodeAlphabet>{};
    for (final a in _upperBase.keys) {
      for (var i = 0; i < 26; i++) {
        map[_upperBase[a]! + i] = a;
        map[_lowerBase[a]! + i] = a;
      }
    }
    _legacyBases.forEach((a, b) {
      final (upper, lower, _) = b;
      for (var i = 0; i < 26; i++) {
        map[upper + i] = a;
        map[lower + i] = a;
      }
    });
    _lowerExceptions.forEach((a, ex) {
      ex.forEach((_, styled) => map[styled] = a);
    });
    return map;
  }

  // --- Precomposed Latin letter decomposition (base + combining marks) -------
  static const int _grave = 0x0300;
  static const int _acute = 0x0301;
  static const int _circ = 0x0302;
  static const int _tilde = 0x0303;
  static const int _diaer = 0x0308;
  static const int _ring = 0x030A;
  static const int _cedilla = 0x0327;

  static const Map<int, _Decomp> _decompose = {
    0xC0: _Decomp(0x41, [_grave]),
    0xC1: _Decomp(0x41, [_acute]),
    0xC2: _Decomp(0x41, [_circ]),
    0xC3: _Decomp(0x41, [_tilde]),
    0xC4: _Decomp(0x41, [_diaer]),
    0xC5: _Decomp(0x41, [_ring]),
    0xC7: _Decomp(0x43, [_cedilla]),
    0xC8: _Decomp(0x45, [_grave]),
    0xC9: _Decomp(0x45, [_acute]),
    0xCA: _Decomp(0x45, [_circ]),
    0xCB: _Decomp(0x45, [_diaer]),
    0xCC: _Decomp(0x49, [_grave]),
    0xCD: _Decomp(0x49, [_acute]),
    0xCE: _Decomp(0x49, [_circ]),
    0xCF: _Decomp(0x49, [_diaer]),
    0xD1: _Decomp(0x4E, [_tilde]),
    0xD2: _Decomp(0x4F, [_grave]),
    0xD3: _Decomp(0x4F, [_acute]),
    0xD4: _Decomp(0x4F, [_circ]),
    0xD5: _Decomp(0x4F, [_tilde]),
    0xD6: _Decomp(0x4F, [_diaer]),
    0xD9: _Decomp(0x55, [_grave]),
    0xDA: _Decomp(0x55, [_acute]),
    0xDB: _Decomp(0x55, [_circ]),
    0xDC: _Decomp(0x55, [_diaer]),
    0xDD: _Decomp(0x59, [_acute]),
    0xE0: _Decomp(0x61, [_grave]),
    0xE1: _Decomp(0x61, [_acute]),
    0xE2: _Decomp(0x61, [_circ]),
    0xE3: _Decomp(0x61, [_tilde]),
    0xE4: _Decomp(0x61, [_diaer]),
    0xE5: _Decomp(0x61, [_ring]),
    0xE7: _Decomp(0x63, [_cedilla]),
    0xE8: _Decomp(0x65, [_grave]),
    0xE9: _Decomp(0x65, [_acute]),
    0xEA: _Decomp(0x65, [_circ]),
    0xEB: _Decomp(0x65, [_diaer]),
    0xEC: _Decomp(0x69, [_grave]),
    0xED: _Decomp(0x69, [_acute]),
    0xEE: _Decomp(0x69, [_circ]),
    0xEF: _Decomp(0x69, [_diaer]),
    0xF1: _Decomp(0x6E, [_tilde]),
    0xF2: _Decomp(0x6F, [_grave]),
    0xF3: _Decomp(0x6F, [_acute]),
    0xF4: _Decomp(0x6F, [_circ]),
    0xF5: _Decomp(0x6F, [_tilde]),
    0xF6: _Decomp(0x6F, [_diaer]),
    0xF9: _Decomp(0x75, [_grave]),
    0xFA: _Decomp(0x75, [_acute]),
    0xFB: _Decomp(0x75, [_circ]),
    0xFC: _Decomp(0x75, [_diaer]),
    0xFD: _Decomp(0x79, [_acute]),
    0xFF: _Decomp(0x79, [_diaer]),
  };
}

class _Decomp {
  const _Decomp(this.base, this.marks);
  final int base;
  final List<int> marks;
}
