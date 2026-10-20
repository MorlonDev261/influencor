import 'package:influencor/core/formatting/list_format.dart';
import 'package:influencor/core/formatting/note_separator.dart';
import 'package:influencor/core/formatting/note_clipboard.dart';
import 'package:influencor/core/formatting/unicode_styler.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> runes(String s) => s.runes.toList();

void main() {
  const styler = UnicodeStyler();

  group('transform: alphabets', () {
    test('bold letters and digits', () {
      expect(runes(styler.transform('A', const InlineStyle(bold: true))),
          [0x1D5D4]);
      expect(runes(styler.transform('a', const InlineStyle(bold: true))),
          [0x1D5EE]);
      expect(runes(styler.transform('0', const InlineStyle(bold: true))),
          [0x1D7EC]);
    });

    test('italic, no italic digits (fallback to plain)', () {
      expect(runes(styler.transform('A', const InlineStyle(italic: true))),
          [0x1D434]);
      expect(runes(styler.transform('5', const InlineStyle(italic: true))),
          [0x35]);
    });

    test('italic small h exception (U+210E)', () {
      expect(runes(styler.transform('h', const InlineStyle(italic: true))),
          [0x210E]);
    });

    test('bold+italic uses the bold-italic alphabet', () {
      expect(
          runes(styler.transform(
              'A', const InlineStyle(bold: true, italic: true))),
          [0x1D63C]);
    });

    test('code/monospace has priority over bold+italic', () {
      expect(
          runes(styler.transform(
              'A', const InlineStyle(code: true, bold: true, italic: true))),
          [0x1D670]);
    });
  });

  group('transform: overlays', () {
    test('strike appends U+0336 (also on spaces)', () {
      expect(runes(styler.transform('A B', const InlineStyle(strike: true))),
          [0x41, 0x0336, 0x20, 0x0336, 0x42, 0x0336]);
    });
    test('underline appends U+0332', () {
      expect(runes(styler.transform('A', const InlineStyle(underline: true))),
          [0x41, 0x0332]);
    });
    test('bold + strike', () {
      expect(
          runes(styler.transform(
              'A', const InlineStyle(bold: true, strike: true))),
          [0x1D5D4, 0x0336]);
    });

    test('legacy U+0335 strike is still detected and removable', () {
      const legacy = 'A̵B̵';
      expect(styler.detectStyle(legacy), const InlineStyle(strike: true));
      expect(styler.plainify(legacy), 'AB');
    });
  });

  group('transform: accents & international', () {
    test('é bold keeps the accent (𝐞 + combining acute)', () {
      expect(runes(styler.transform('é', const InlineStyle(bold: true))),
          [0x1D5F2, 0x0301]);
    });
    test('É bold keeps accent, ç bold keeps cedilla', () {
      expect(runes(styler.transform('É', const InlineStyle(bold: true))),
          [0x1D5D8, 0x0301]);
      expect(runes(styler.transform('ç', const InlineStyle(bold: true))),
          [0x1D5EE + 2, 0x0327]);
    });
    test('Spécial bold keeps é, no precomposed U+00E9', () {
      final out = styler.transform('Spécial', const InlineStyle(bold: true));
      expect(out.runes, contains(0x0301));
      expect(out.runes, isNot(contains(0x00E9)));
    });
  });

  group('transform: robustness', () {
    test('untransformable characters are kept', () {
      expect(styler.transform('€', const InlineStyle(bold: true)), '€');
      expect(styler.transform('%', const InlineStyle(bold: true)), '%');
      expect(styler.transform('œ', const InlineStyle(bold: true)), 'œ');
      expect(styler.transform('🔥', const InlineStyle(bold: true)), '🔥');
    });
    test('empty string returns empty', () {
      expect(styler.transform('', const InlineStyle(bold: true)), '');
    });
  });

  group('plainify: reverse mapping', () {
    test('bold letters/digits map back to ASCII', () {
      final bold = styler.transform('Prix 2026', const InlineStyle(bold: true));
      expect(styler.plainify(bold), 'Prix 2026');
    });
    test('removes strike & underline overlays', () {
      final struck =
          styler.transform('Ancien', const InlineStyle(strike: true));
      expect(styler.plainify(struck), 'Ancien');
      final underlined =
          styler.transform('OFFRE', const InlineStyle(underline: true));
      expect(styler.plainify(underlined), 'OFFRE');
    });
    test('accents survive round-trip (é stays é)', () {
      final bold = styler.transform('Spécial', const InlineStyle(bold: true));
      // plainify yields decomposed "Spe" + combining acute + "cial"
      expect(styler.plainify(bold), 'Spécial'.replaceAll('é', 'é'));
    });
    test('emoji and untransformable characters pass through', () {
      expect(styler.plainify('🔥 100% œ'), '🔥 100% œ');
    });
  });

  group('detectStyle', () {
    test('legacy serif bold is still detected and plainified', () {
      // Serif bold "Prix 2" and bold-italic "A" from builds before sans-serif.
      const legacy = '\u{1D40F}\u{1D42B}\u{1D422}\u{1D431} \u{1D7D0}';
      expect(styler.detectStyle(legacy), const InlineStyle(bold: true));
      expect(styler.plainify(legacy), 'Prix 2');
      expect(styler.detectStyle('\u{1D468}'),
          const InlineStyle(bold: true, italic: true));
    });
    test('detects bold', () {
      final s = styler.transform('X', const InlineStyle(bold: true));
      expect(styler.detectStyle(s), const InlineStyle(bold: true));
    });
    test('detects bold-italic', () {
      final s =
          styler.transform('X', const InlineStyle(bold: true, italic: true));
      expect(
          styler.detectStyle(s), const InlineStyle(bold: true, italic: true));
    });
    test('detects overlays', () {
      final s = styler.transform(
          'X', const InlineStyle(bold: true, strike: true, underline: true));
      expect(styler.detectStyle(s),
          const InlineStyle(bold: true, strike: true, underline: true));
    });
    test('plain text detects no style', () {
      expect(styler.detectStyle('Bonjour'), const InlineStyle());
    });
  });

  group('restyle: toggle & combine (toolbar behaviour)', () {
    test('applying bold twice via toggle removes it', () {
      final bold = styler.restyle('Prix', const InlineStyle(bold: true));
      final detected = styler.detectStyle(bold); // bold
      final off = styler.restyle(bold, detected.copyWith(bold: false));
      expect(off, 'Prix');
    });

    test('bold then italic yields bold-italic (combine)', () {
      final bold = styler.restyle('Prix', const InlineStyle(bold: true));
      final detected = styler.detectStyle(bold);
      final both = styler.restyle(bold, detected.copyWith(italic: true));
      expect(styler.detectStyle(both),
          const InlineStyle(bold: true, italic: true));
    });

    test('restyle is idempotent — no combining-mark accumulation', () {
      final once = styler.restyle('Ancien', const InlineStyle(strike: true));
      final twice = styler.restyle(once, const InlineStyle(strike: true));
      expect(twice, once);
      expect(once.runes.where((r) => r == 0x0336).length,
          twice.runes.where((r) => r == 0x0336).length);
    });

    test('switching bold → strike-only drops the bold alphabet', () {
      final bold = styler.restyle('Prix', const InlineStyle(bold: true));
      final struck = styler.restyle(bold, const InlineStyle(strike: true));
      expect(styler.plainify(struck), 'Prix');
      expect(styler.detectStyle(struck), const InlineStyle(strike: true));
    });
  });

  group('ListFormat', () {
    test('prefixes carry the small leading indent', () {
      expect(ListFormat.bullet, '  • ');
      expect(ListFormat.numbered(3), '  3. ');
    });

    test('bullet regex captures indent and content', () {
      final m = ListFormat.bulletRe.firstMatch('  • Produit');
      expect(m, isNotNull);
      expect(m!.group(2), 'Produit');
    });

    test('numbered regex captures number and content', () {
      final m = ListFormat.numberedRe.firstMatch('  2. Livraison');
      expect(m, isNotNull);
      expect(m!.group(2), '2');
      expect(m.group(3), 'Livraison');
    });

    test('empty item is detected (for exiting the list)', () {
      final m = ListFormat.bulletRe.firstMatch('  • ');
      expect(m, isNotNull);
      expect((m!.group(2) ?? '').trim(), isEmpty);
    });

    test('anyRe strips either kind of prefix', () {
      expect('  • a'.replaceFirst(ListFormat.anyRe, ''), 'a');
      expect('  1. b'.replaceFirst(ListFormat.anyRe, ''), 'b');
    });
  });

  group('NoteSeparator', () {
    test('default separator only splits on blank lines', () {
      expect(
        NoteSeparator.segments(
          'A line 1\nA line 2\n\nB line 1\nB line 2',
          NoteSeparator.defaultSeparator,
        ),
        ['A line 1\nA line 2', 'B line 1\nB line 2'],
      );
    });

    test('legacy single-newline default still only splits on blank lines', () {
      expect(NoteSeparator.segments('A line 1\nA line 2\n\nB', '\n'), [
        'A line 1\nA line 2',
        'B',
      ]);
    });

    test('default render preserves paragraph spacing for copy and share', () {
      expect(
        NoteSeparator.render(
          'A line 1\nA line 2\n\nB line 1\nB line 2',
          NoteSeparator.defaultSeparator,
        ),
        'A line 1\nA line 2\n\nB line 1\nB line 2',
      );
    });

    test('custom separator already present in text is the only block boundary',
        () {
      expect(
        NoteSeparator.segments('A\nline 2########B\nC', '########'),
        ['A\nline 2', 'B\nC'],
      );
    });

    test('render preserves line breaks when a custom separator is active', () {
      expect(NoteSeparator.render('A\n\nB', '########'), 'A\n\nB');
    });

    test('render keeps custom-separated copy/share content in the same form',
        () {
      expect(
        NoteSeparator.render('A\nline 2########B\nC', '########'),
        'A\nline 2########B\nC',
      );
    });

    test('normalization accepts escaped line breaks from text fields', () {
      expect(NoteSeparator.normalize(r'---\n---'), '---\n---');
    });
  });

  group('NoteClipboard', () {
    const clip = NoteClipboard();

    test('social returns the note as-is (already styled)', () {
      final content = styler.transform('OFFRE', const InlineStyle(bold: true));
      expect(clip.render(CopyMode.social, content), content);
    });

    test('plain text strips styling but keeps accents & emoji', () {
      final content =
          '${styler.transform('OFFRE', const InlineStyle(bold: true))} 🔥';
      expect(clip.render(CopyMode.plainText, content), 'OFFRE 🔥');
    });

    test('old plain notes are unchanged by both modes', () {
      const legacy = 'Une note simple.';
      expect(clip.render(CopyMode.social, legacy), legacy);
      expect(clip.render(CopyMode.plainText, legacy), legacy);
    });
  });
}
