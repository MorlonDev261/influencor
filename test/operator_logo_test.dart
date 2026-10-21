import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/features/fees/data/madagascar_tariffs.dart';
import 'package:influencor/features/fees/presentation/operator_logo.dart';

void main() {
  test('every built-in operator has an official logo that parses', () async {
    for (final t in madagascarTariffs) {
      final logo = OperatorLogo.logoFor(t.name);
      expect(logo, isNotNull, reason: t.name);
      final svg = await rootBundle.loadString(logo!.$1);
      final info = await vg.loadPicture(SvgStringLoader(svg), null);
      expect(info.size.isEmpty, isFalse, reason: t.name);
      info.picture.dispose();
    }
  });

  testWidgets('user-added operators fall back to their initial',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: OperatorLogo('Telma')));
    expect(find.text('T'), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
  });
  testWidgets('Orange tile is white in light mode and black in dark mode',
      (tester) async {
    Color? tile(WidgetTester t) => t
        .widget<Container>(find.descendant(
            of: find.byType(OperatorLogo), matching: find.byType(Container)))
        .color;
    for (final (brightness, color) in [
      (Brightness.light, Colors.white),
      (Brightness.dark, Colors.black),
    ]) {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const OperatorLogo('Orange Money'),
      ));
      await tester.pumpAndSettle(); // theme changes animate
      expect(tile(tester), color);
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect((svg.bytesLoader as SvgAssetLoader).theme?.currentColor,
          brightness == Brightness.dark ? Colors.white : Colors.black);
    }
  });
}
