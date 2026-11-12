import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/providers/workspace_providers.dart';
import '../../../library/application/library_providers.dart';

// Shared pieces of the rich blocks Degany writes in its answers.

const monoStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Consolas', 'Menlo', 'Roboto Mono', 'Courier New'],
);

void showChatSnack(BuildContext context, String text,
    {SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), action: action));
}

/// Categorical colours for series and slices: the theme's primary first,
/// then hues that stay apart in light and dark themes.
List<Color> chartPalette(ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  return [
    scheme.primary,
    dark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A),
    dark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
    dark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
    dark ? const Color(0xFFC084FC) : const Color(0xFF9333EA),
    dark ? const Color(0xFF22D3EE) : const Color(0xFF0891B2),
    dark ? const Color(0xFFF472B6) : const Color(0xFFDB2777),
    dark ? const Color(0xFFA3E635) : const Color(0xFF65A30D),
  ];
}

/// `#RRGGBB` (or a palette name) from the model; null when not a colour.
Color? parseColor(Object? raw) {
  if (raw is! String) return null;
  var s = raw.trim().toLowerCase();
  const named = {
    'blue': Color(0xFF2563EB),
    'green': Color(0xFF16A34A),
    'red': Color(0xFFDC2626),
    'orange': Color(0xFFEA580C),
    'yellow': Color(0xFFEAB308),
    'purple': Color(0xFF9333EA),
    'pink': Color(0xFFDB2777),
    'teal': Color(0xFF0D9488),
    'gray': Color(0xFF6B7280),
    'grey': Color(0xFF6B7280),
  };
  if (named[s] case final c?) return c;
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 3) s = s.split('').map((c) => '$c$c').join();
  if (s.length != 6) return null;
  final v = int.tryParse(s, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// A number from the model: `1250`, `"1 250"`, `"12,5"`, `"30%"`.
double? toNumber(Object? raw) {
  if (raw is num) return raw.toDouble();
  if (raw is! String) return null;
  var s = raw.trim().replaceAll(RegExp(r'[\s  _]|Ar$|%$'), '');
  if (s.contains(',') && !s.contains('.')) s = s.replaceAll(',', '.');
  s = s.replaceAll(',', '');
  return double.tryParse(s);
}

String _group(String digits, String sep) =>
    digits.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => sep);

/// `1250000` → `1 250 000`, `12.5` → `12,5` (French style; `.` in English).
String formatNumber(num v, {int maxDecimals = 2, String decimal = ','}) {
  final neg = v < 0;
  final a = v.abs();
  var fixed = a.toStringAsFixed(maxDecimals);
  if (fixed.contains('.')) {
    fixed = fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }
  final parts = fixed.split('.');
  final whole = _group(parts[0], ' ');
  final out = parts.length > 1 ? '$whole$decimal${parts[1]}' : whole;
  return neg ? '-$out' : out;
}

/// A value with its unit: `1 250 000 Ar`, `45 %`, `3,5 kg`.
String formatValue(num v, String? unit, {String decimal = ','}) {
  final n = formatNumber(v, decimal: decimal);
  if (unit == null || unit.isEmpty) return n;
  if (unit == '%') return '$n %';
  if (unit == r'$') return '$unit$n';
  return '$n $unit';
}

/// Short axis label: `1,2 M`, `350 k`, `12`.
String formatCompactValue(num v, {String decimal = ','}) {
  final a = v.abs();
  String unit(double x, String s) {
    final t = x >= 10 ? x.round().toString() : formatNumber(x, maxDecimals: 1);
    return '${v < 0 ? '-' : ''}$t $s'.replaceAll('.', decimal);
  }

  if (a >= 1e9) return unit(a / 1e9, 'G');
  if (a >= 1e6) return unit(a / 1e6, 'M');
  if (a >= 1e4) return unit(a / 1e3, 'k');
  return formatNumber(v, maxDecimals: a < 10 ? 2 : 1, decimal: decimal);
}

/// A round step (1, 2, 2.5 or 5 × 10^k) giving about [ticks] grid lines.
double niceStep(double span, int ticks) {
  if (span <= 0) return 1;
  final raw = span / ticks;
  final magnitude =
      math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (m * magnitude >= raw) return m * magnitude;
  }
  return 10 * magnitude;
}

/// Decodes the JSON body of a block, tolerating what models often add
/// (trailing commas, a `json` first line). Null when it does not parse.
Object? decodeBlockJson(String code) {
  var s = code.trim();
  if (s.isEmpty) return null;
  try {
    return jsonDecode(s);
  } catch (_) {
    s = s.replaceAll(RegExp(r',\s*([}\]])'), r'$1');
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }
}

/// The absolute path of a library item named by the model, only when it is
/// inside the workspace (never `.clipboard`); null otherwise.
String? resolveWorkspacePath(String raw, String? root) {
  if (root == null || kIsWeb) return null;
  final path = raw.trim().replaceAll('\\', '/');
  final String abs;
  if (p.isAbsolute(path) || RegExp(r'^[A-Za-z]:/').hasMatch(path)) {
    abs = p.normalize(path);
  } else {
    abs = p.normalize(
        p.join(root, path.startsWith('/') ? path.substring(1) : path));
  }
  return isInWorkspace(root, abs) ? abs : null;
}

/// Name of the workspace folder where what is saved from the chat goes.
const deganyExportFolder = 'Degany';

/// The export folder (created if needed); throws [StateError] without a
/// workspace.
Future<String> deganyExportDir(WidgetRef ref) async {
  final root = ref.read(workspaceRootProvider);
  if (root == null || kIsWeb) throw StateError('no workspace');
  final dir = p.join(root, deganyExportFolder);
  await Directory(dir).create(recursive: true);
  return dir;
}

/// A file name that does not exist yet in [dir]: `name.ext`, `name (2).ext`…
String uniqueFilePath(String dir, String name, String ext) {
  final safe = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final base = safe.isEmpty ? 'Degany' : safe;
  var path = p.join(dir, '$base.$ext');
  var n = 2;
  while (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
    path = p.join(dir, '$base ($n).$ext');
    n++;
  }
  return path;
}

/// Writes a file into the export folder and refreshes the library views.
Future<String> saveExportFile(
  WidgetRef ref, {
  required String name,
  required String ext,
  required List<int> bytes,
}) async {
  final dir = await deganyExportDir(ref);
  final path = uniqueFilePath(dir, name, ext);
  await File(path).writeAsBytes(bytes, flush: true);
  refreshLibrary(ref, dir);
  return path;
}

void refreshLibrary(WidgetRef ref, String dir) {
  ref.invalidate(directoryProvider(dir));
  ref.invalidate(directoryProvider(p.dirname(dir)));
  ref.invalidate(libraryIndexProvider);
  ref.invalidate(dirStatsProvider);
  ref.invalidate(dirRecursiveProvider);
}

/// Today as `2026-11-08 14h05`, for names of saved files.
String stamp() {
  final d = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}h${two(d.minute)}';
}

/// Rows as CSV (RFC 4180, `;` separated as spreadsheets expect in French).
String toCsv(List<List<String>> rows, {String sep = ';'}) {
  String cell(String v) {
    final needs = v.contains(sep) ||
        v.contains('"') ||
        v.contains('\n') ||
        v.contains('\r');
    return needs ? '"${v.replaceAll('"', '""')}"' : v;
  }

  return rows.map((r) => r.map(cell).join(sep)).join('\r\n');
}

/// The card every rich block sits in.
class BlockCard extends StatelessWidget {
  const BlockCard({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(14, 12, 14, 12),
    this.color,
    this.borderColor,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor ?? scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

/// Title (and optional subtitle) at the top of a block, with actions on the
/// right.
class BlockHeader extends StatelessWidget {
  const BlockHeader({
    this.title,
    this.subtitle,
    this.icon,
    this.trailing = const [],
    super.key,
  });

  final String? title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if ((title ?? '').isEmpty && (subtitle ?? '').isEmpty && trailing.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 18, color: scheme.primary),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((title ?? '').isNotEmpty)
                  Text(title!,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                if ((subtitle ?? '').isNotEmpty)
                  Text(subtitle!,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

/// Small muted icon button used in block headers and under answers.
class TinyIconButton extends StatelessWidget {
  const TinyIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        visualDensity: VisualDensity.compact,
        iconSize: 17,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
}

/// Shown while the JSON of a block is still arriving.
class BlockLoading extends StatelessWidget {
  const BlockLoading({required this.label, required this.icon, super.key});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BlockCard(
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ),
    );
  }
}
