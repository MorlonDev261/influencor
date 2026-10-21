import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared form inputs so every screen and dialog looks and behaves the same:
/// a visible filled background (even without focus), rounded corners and a
/// clear focus outline.

/// Single- or multi-line text input.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.helper,
    this.errorText,
    this.prefixIcon,
    this.suffixText,
    this.suffix,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.style,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.enabled = true,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final String? helper;
  final String? errorText;
  final IconData? prefixIcon;
  final String? suffixText;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final TextStyle? style;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    OutlineInputBorder border(Color? color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: color == null
              ? BorderSide.none
              : BorderSide(color: color, width: width),
        );

    return TextField(
      controller: controller,
      autofocus: autofocus,
      enabled: enabled,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      inputFormatters: inputFormatters,
      minLines: minLines,
      maxLines: maxLines,
      style: style,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        errorText: errorText,
        prefixIcon: prefixIcon == null ? null : Icon(prefixIcon),
        suffixText: suffixText,
        suffix: suffix,
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: border(null),
        enabledBorder: border(null),
        focusedBorder: border(scheme.primary, 2),
        errorBorder: border(scheme.error),
        focusedErrorBorder: border(scheme.error, 2),
      ),
    );
  }
}

/// Groups digits by thousands while typing: `1250000` becomes `1 250 000`.
/// Keeps the caret next to the digit being edited (no jump to the end).
class ThousandsFormatter extends TextInputFormatter {
  const ThousandsFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Digits before the caret, so it can be restored after regrouping.
    final caret = newValue.selection.isValid
        ? newValue.selection.extentOffset.clamp(0, newValue.text.length)
        : newValue.text.length;
    var digitsBefore =
        newValue.text.substring(0, caret).replaceAll(RegExp(r'\D'), '').length;

    var digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    // 15 digits fit exactly in every platform's integer type.
    if (digits.length > 15) digits = digits.substring(0, 15);
    if (digitsBefore > digits.length) digitsBefore = digits.length;
    if (digits.isEmpty) return const TextEditingValue();

    final text = groupThousands(int.parse(digits));
    var offset = text.length;
    var seen = 0;
    for (var i = 0; i < text.length; i++) {
      if (seen == digitsBefore) {
        offset = i;
        break;
      }
      if (text[i] != ' ') seen++;
    }
    if (digitsBefore == digits.length) offset = text.length;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

/// `1250000` -> `1 250 000`.
String groupThousands(int value) => value.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ' ',
    );

/// Whole-number amount input (Ariary by default): number keyboard, digits
/// grouped by thousands, unit shown as a suffix.
class AppAmountField extends StatelessWidget {
  const AppAmountField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.errorText,
    this.unit = 'Ar',
    this.large = false,
    this.autofocus = false,
    this.onChanged,
  });

  final TextEditingController? controller;
  final String? label;

  /// Placeholder shown while empty. Each field gives its own example.
  final String? hint;
  final String? errorText;
  final String unit;

  /// Big headline-sized text, for the main amount of a screen.
  final bool large;
  final bool autofocus;
  final ValueChanged<String>? onChanged;

  /// The number typed in [text] (spaces ignored), or null if empty/invalid.
  static int? parse(String text) =>
      int.tryParse(text.replaceAll(RegExp(r'\s'), ''));

  /// Puts [value] in [controller], formatted.
  static void setValue(TextEditingController controller, int value) {
    final text = groupThousands(value);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppTextField(
      controller: controller,
      label: label,
      hint: hint,
      errorText: errorText,
      suffixText: unit,
      autofocus: autofocus,
      keyboardType: TextInputType.number,
      inputFormatters: const [ThousandsFormatter()],
      style: large
          ? theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            )
          : null,
      onChanged: onChanged,
    );
  }
}

/// Small caption above a group of controls.
class AppSectionLabel extends StatelessWidget {
  const AppSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
}

/// One-of-many choice shown as wrapping chips.
class AppChoiceChips<T> extends StatelessWidget {
  const AppChoiceChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.avatar,
  });

  /// value -> label, in display order.
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Optional leading widget per option (e.g. a logo).
  final Widget Function(T value)? avatar;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final (value, label) in options)
            ChoiceChip(
              avatar: avatar?.call(value),
              label: Text(label),
              selected: value == selected,
              onSelected: (_) => onChanged(value),
            ),
        ],
      );
}
