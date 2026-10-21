import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Operator logo shown before its name.
///
/// Built-in operators use their official logo (`assets/operators/`, see the
/// README there for sources) on their brand background; operators added by
/// the user get a badge with their initial.
class OperatorLogo extends StatelessWidget {
  const OperatorLogo(this.name, {super.key, this.size = 24});

  final String name;
  final double size;

  /// Logo asset and tile background, by a keyword of the operator name.
  /// A null background follows the theme: white in light mode, black in dark
  /// mode, with the logo's `currentColor` parts in the opposite colour.
  static const _logos = {
    'mvola': ('assets/operators/mvola.svg', Color(0xFFFFD200)),
    'orange': ('assets/operators/orangemoney.svg', null),
    'airtel': ('assets/operators/airtelmoney.svg', Color(0xFFFFFFFF)),
  };

  static (String, Color?)? logoFor(String name) {
    final key = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    for (final e in _logos.entries) {
      if (key.contains(e.key)) return e.value;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final logo = logoFor(name);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = logo == null
        ? scheme.secondaryContainer
        : logo.$2 ?? (dark ? Colors.black : Colors.white);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Container(
        width: size,
        height: size,
        color: background,
        padding: logo == null ? null : EdgeInsets.all(size * 0.08),
        alignment: Alignment.center,
        child: logo != null
            ? SvgPicture.asset(
                logo.$1,
                fit: BoxFit.contain,
                theme: SvgTheme(
                  currentColor: dark ? Colors.white : Colors.black,
                ),
              )
            : Text(
                name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
                style: TextStyle(
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w900,
                  fontSize: size * 0.55,
                  height: 1,
                ),
              ),
      ),
    );
  }
}
