import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/l10n/app_strings.dart';
import '../../../../core/providers/workspace_providers.dart';
import '../../../library/domain/library_entry.dart';
import '../../application/assistant_providers.dart';
import '../../application/tools/app_tools.dart';
import 'chart_block.dart';
import 'rich_common.dart';
import 'rich_message.dart';

// Cards Degany writes as ```kpi, ```progress, ```callout, ```list,
// ```timeline, ```actions, ```suggestions and ```map blocks.

String? _s(Object? v) => v == null || '$v'.trim().isEmpty ? null : '$v'.trim();

/// The list a block holds: the JSON itself, or its `items` (or [key]).
List<Map<String, dynamic>> blockItems(Object? json, {String key = 'items'}) {
  final raw = json is Map ? json[key] ?? json['items'] ?? json['data'] : json;
  if (raw is Map) return [raw.cast<String, dynamic>()];
  return [
    if (raw is List)
      for (final e in raw)
        if (e is Map)
          e.cast<String, dynamic>()
        else if (e != null)
          {'label': '$e', 'title': '$e'},
  ];
}

String? blockTitle(Object? json) => json is Map ? _s(json['title']) : null;

const _icons = <String, IconData>{
  'task': Icons.task_alt,
  'check': Icons.check_circle_outline,
  'done': Icons.check_circle_outline,
  'note': Icons.description_outlined,
  'image': Icons.image_outlined,
  'photo': Icons.image_outlined,
  'video': Icons.movie_outlined,
  'folder': Icons.folder_outlined,
  'table': Icons.table_chart_outlined,
  'money': Icons.payments_outlined,
  'cash': Icons.payments_outlined,
  'wallet': Icons.account_balance_wallet_outlined,
  'sale': Icons.trending_up,
  'up': Icons.trending_up,
  'down': Icons.trending_down,
  'expense': Icons.trending_down,
  'cart': Icons.shopping_cart_outlined,
  'user': Icons.person_outline,
  'client': Icons.person_outline,
  'people': Icons.groups_outlined,
  'calendar': Icons.event_outlined,
  'date': Icons.event_outlined,
  'time': Icons.schedule,
  'star': Icons.star_outline,
  'heart': Icons.favorite_border,
  'warning': Icons.warning_amber_rounded,
  'info': Icons.info_outline,
  'error': Icons.error_outline,
  'phone': Icons.phone_outlined,
  'location': Icons.place_outlined,
  'place': Icons.place_outlined,
  'link': Icons.link,
  'web': Icons.public,
  'chart': Icons.insert_chart_outlined,
  'mail': Icons.mail_outline,
  'message': Icons.chat_bubble_outline,
  'tag': Icons.sell_outlined,
  'idea': Icons.lightbulb_outline,
  'tip': Icons.lightbulb_outline,
  'lock': Icons.lock_outline,
  'settings': Icons.settings_outlined,
  'share': Icons.share_outlined,
  'post': Icons.campaign_outlined,
  'facebook': Icons.thumb_up_alt_outlined,
  'gift': Icons.card_giftcard,
  'delivery': Icons.local_shipping_outlined,
  'product': Icons.inventory_2_outlined,
  'send': Icons.send_outlined,
  'add': Icons.add_circle_outline,
  'edit': Icons.edit_outlined,
  'delete': Icons.delete_outline,
  'save': Icons.save_outlined,
  'search': Icons.search,
  'clean': Icons.cleaning_services_outlined,
};

IconData? iconNamed(Object? name) =>
    name == null ? null : _icons['$name'.toLowerCase().trim()];

String _decimal(WidgetRef ref) =>
    ref.watch(appStringsProvider).locale.languageCode == 'en' ? '.' : ',';

const _good = Color(0xFF16A34A);

// --- KPI ---------------------------------------------------------------------

/// A row of key figures: value, change (▲ 12 %) and an optional trend line.
class KpiBlock extends ConsumerWidget {
  const KpiBlock({required this.json, super.key});

  final Object? json;

  static bool canShow(Object? json) => blockItems(json).isNotEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = blockItems(json);
    final decimal = _decimal(ref);
    final palette = chartPalette(scheme);
    final title = blockTitle(json);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
          LayoutBuilder(builder: (context, c) {
            final cols =
                math.max(1, math.min(items.length, (c.maxWidth / 165).floor()));
            final width = (c.maxWidth - (cols - 1) * 8) / cols;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (i, item) in items.indexed)
                  SizedBox(
                    width: width,
                    child: _KpiTile(
                      item: item,
                      decimal: decimal,
                      color: parseColor(item['color']) ??
                          palette[i % palette.length],
                    ),
                  ),
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({
    required this.item,
    required this.decimal,
    required this.color,
  });

  final Map<String, dynamic> item;
  final String decimal;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unit = _s(item['unit']);
    final raw = item['value'];
    final number = toNumber(raw);
    final value = number != null && raw is! String
        ? formatValue(number, unit, decimal: decimal)
        : (number != null && RegExp(r'^[\d\s.,-]+$').hasMatch('$raw'.trim())
            ? formatValue(number, unit, decimal: decimal)
            : '${raw ?? '—'}${unit != null && raw is! String ? ' $unit' : ''}');
    final change = toNumber(item['change'] ?? item['delta']);
    final lowerIsBetter = '${item['good'] ?? item['better']}' == 'down';
    final positive = (change ?? 0) >= 0;
    final good = lowerIsBetter ? !positive : positive;
    final trend = [
      if (item['trend'] case final List<dynamic> t)
        for (final v in t)
          if (toNumber(v) case final n?) n,
    ];
    final icon = iconNamed(item['icon']);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  _s(item['label'] ?? item['title'] ?? item['name']) ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
          ),
          if (change != null || _s(item['hint'] ?? item['caption']) != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text.rich(
                TextSpan(children: [
                  if (change != null)
                    TextSpan(
                      text:
                          '${positive ? '▲' : '▼'} ${formatNumber(change.abs(), maxDecimals: 1, decimal: decimal)} %  ',
                      style: TextStyle(
                        color: good ? _good : scheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (_s(item['hint'] ?? item['caption']) case final h?)
                    TextSpan(
                        text: h,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                ]),
                style: theme.textTheme.labelSmall,
              ),
            ),
          if (trend.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SizedBox(
                height: 28,
                width: double.infinity,
                child: CustomPaint(painter: SparklinePainter(trend, color)),
              ),
            ),
        ],
      ),
    );
  }
}

// --- Progress ----------------------------------------------------------------

/// Progress bars or gauges: value against a target or a maximum.
class ProgressBlock extends ConsumerWidget {
  const ProgressBlock({required this.json, super.key});

  final Object? json;

  static bool canShow(Object? json) =>
      blockItems(json).any((i) => toNumber(i['value']) != null);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final decimal = _decimal(ref);
    final items = [
      for (final i in blockItems(json))
        if (toNumber(i['value']) != null) i,
    ];
    final gauge = json is Map &&
        '${(json as Map)['style'] ?? (json as Map)['type']}' == 'gauge';
    final palette = chartPalette(scheme);

    Widget bar(int k, Map<String, dynamic> item) {
      final value = toNumber(item['value'])!;
      final max =
          toNumber(item['max'] ?? item['target'] ?? item['goal']) ?? 100;
      final unit = _s(item['unit']);
      final ratio = max == 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
      final over = max != 0 && value > max;
      final color = parseColor(item['color']) ??
          (over && '${item['good']}' == 'down'
              ? scheme.error
              : palette[k % palette.length]);
      final pct = max == 0 ? 0 : value / max * 100;
      final label = _s(item['label'] ?? item['title']) ?? '';
      if (gauge) {
        return SizedBox(
          width: 150,
          child: Column(
            children: [
              SizedBox(
                height: 80,
                width: 140,
                child: CustomPaint(
                  painter: _GaugePainter(
                    ratio: ratio,
                    color: color,
                    track: scheme.surfaceContainerHighest,
                  ),
                  child: Align(
                    alignment: const Alignment(0, 0.85),
                    child: Text(
                      '${formatNumber(pct, maxDecimals: 0, decimal: decimal)} %',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium),
              Text(
                '${formatValue(value, unit, decimal: decimal)} / ${formatValue(max, unit, decimal: decimal)}',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text(label,
                        style: theme.textTheme.labelLarge
                            ?.copyWith(fontWeight: FontWeight.w600))),
                Text(
                  '${formatValue(value, unit, decimal: decimal)} / ${formatValue(max, unit, decimal: decimal)}'
                  '  ·  ${formatNumber(pct, maxDecimals: 0, decimal: decimal)} %',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 9,
                color: color,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ],
        ),
      );
    }

    return BlockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BlockHeader(title: blockTitle(json)),
          if (gauge)
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [for (final (k, i) in items.indexed) bar(k, i)],
            )
          else
            for (final (k, i) in items.indexed) bar(k, i),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.ratio,
    required this.color,
    required this.track,
  });

  final double ratio;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width / 2, size.height) - 8;
    final rect = Rect.fromCircle(
        center: Offset(size.width / 2, size.height - 4), radius: r);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, math.pi, math.pi, false, stroke..color = track);
    if (ratio > 0) {
      canvas.drawArc(
          rect, math.pi, math.pi * ratio, false, stroke..color = color);
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.ratio != ratio || old.color != color;
}

// --- Callout -----------------------------------------------------------------

enum CalloutKind { info, success, warning, error, tip }

CalloutKind calloutKind(String? name) => switch (name?.toLowerCase().trim()) {
      'success' || 'ok' || 'done' || 'check' => CalloutKind.success,
      'warning' || 'warn' || 'caution' || 'attention' => CalloutKind.warning,
      'error' || 'danger' || 'alert' || 'important' => CalloutKind.error,
      'tip' || 'idea' || 'hint' => CalloutKind.tip,
      _ => CalloutKind.info,
    };

/// A coloured note: info, success, warning, error or tip.
class CalloutBlock extends StatelessWidget {
  const CalloutBlock({
    required this.kind,
    required this.text,
    this.title,
    super.key,
  });

  final CalloutKind kind;
  final String? title;
  final String text;

  /// From a block: JSON `{type, title, text}` or plain text (the block's
  /// language then gives the kind).
  static CalloutBlock fromBlock(String language, String code) {
    final json = decodeBlockJson(code);
    if (json is Map) {
      return CalloutBlock(
        kind: calloutKind(_s(json['type'] ?? json['kind']) ?? language),
        title: _s(json['title']),
        text: _s(json['text'] ?? json['message'] ?? json['body']) ?? '',
      );
    }
    return CalloutBlock(kind: calloutKind(language), text: code.trim());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final (Color accent, IconData icon) = switch (kind) {
      CalloutKind.info => (theme.colorScheme.primary, Icons.info_outline),
      CalloutKind.success => (
          dark ? const Color(0xFF4ADE80) : _good,
          Icons.check_circle_outline
        ),
      CalloutKind.warning => (
          dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
          Icons.warning_amber_rounded
        ),
      CalloutKind.error => (theme.colorScheme.error, Icons.error_outline),
      CalloutKind.tip => (
          dark ? const Color(0xFFC084FC) : const Color(0xFF7C3AED),
          Icons.lightbulb_outline
        ),
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: dark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: accent, width: 4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(title!,
                        style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700, color: accent)),
                  ),
                if (text.isNotEmpty)
                  RichMessage(text: text, color: theme.colorScheme.onSurface),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Rich list ---------------------------------------------------------------

/// Items with icon, title, subtitle, value and badge; tapping one opens the
/// library item or link it points to.
class ItemListBlock extends ConsumerWidget {
  const ItemListBlock({required this.json, super.key});

  final Object? json;

  static bool canShow(Object? json) => blockItems(json).isNotEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = blockItems(json);
    final root = ref.watch(workspaceRootProvider);
    return BlockCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (blockTitle(json) case final t?)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
              child: Text(t,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
          for (final (k, item) in items.indexed) ...[
            if (k > 0)
              Divider(height: 1, indent: 56, color: scheme.outlineVariant),
            _ItemTile(item: item, root: root),
          ],
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, required this.root});

  final Map<String, dynamic> item;
  final String? root;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final path = _s(item['path']);
    final abs = path == null ? null : resolveWorkspacePath(path, root);
    final url = _s(item['url'] ?? item['link']);
    final color = parseColor(item['color']) ?? scheme.primary;
    final image = _s(item['image']);
    final imageAbs = image == null ? null : resolveWorkspacePath(image, root);
    Widget leading;
    if (imageAbs != null && !kIsWeb && canRenderThumbnail(imageAbs)) {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(File(imageAbs),
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            cacheWidth: 120,
            errorBuilder: (_, __, ___) =>
                Icon(Icons.image_outlined, color: color)),
      );
    } else {
      var icon = iconNamed(item['icon']);
      if (icon == null && abs != null) {
        icon = switch (kindForFile(abs)) {
          EntryKind.image => Icons.image_outlined,
          EntryKind.video => Icons.movie_outlined,
          EntryKind.note => Icons.description_outlined,
          EntryKind.table => Icons.table_chart_outlined,
          _ => FileSystemEntity.isDirectorySync(abs)
              ? Icons.folder_outlined
              : Icons.insert_drive_file_outlined,
        };
      }
      leading = Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon ?? Icons.circle,
            size: icon == null ? 8 : 20, color: color),
      );
    }
    final badge = _s(item['badge'] ?? item['status']);
    final value = _s(item['value']);
    VoidCallback? onTap;
    if (abs != null &&
        FileSystemEntity.typeSync(abs) != FileSystemEntityType.notFound) {
      onTap = () async {
        final route = await routeForPath(abs);
        if (context.mounted) unawaited(context.push(route));
      };
    } else if (url != null && Uri.tryParse(url)?.hasScheme == true) {
      onTap =
          () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _s(item['title'] ?? item['label'] ?? item['name']) ?? '',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (_s(item['subtitle'] ??
                          item['text'] ??
                          item['description'])
                      case final sub?)
                    Text(sub,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (badge != null)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(badge,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: color, fontWeight: FontWeight.w700)),
              ),
            if (value != null)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(value,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
            if (onTap != null)
              Icon(Icons.chevron_right,
                  size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

// --- Timeline ----------------------------------------------------------------

/// Steps in order, with their date and state (done, current, to do).
class TimelineBlock extends StatelessWidget {
  const TimelineBlock({required this.json, super.key});

  final Object? json;

  static bool canShow(Object? json) => blockItems(json).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = blockItems(json);
    return BlockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BlockHeader(title: blockTitle(json)),
          for (final (k, item) in items.indexed)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 24,
                    child: Column(
                      children: [
                        _dot(scheme, '${item['status'] ?? ''}'),
                        if (k < items.length - 1)
                          Expanded(
                            child: Container(
                              width: 2,
                              color: scheme.outlineVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_s(item['date'] ?? item['time']) case final d?)
                            Text(d,
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w700)),
                          Text(
                            _s(item['title'] ?? item['label']) ?? '',
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          if (_s(item['text'] ?? item['description'])
                              case final t?)
                            Text(t,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _dot(ColorScheme scheme, String status) {
    final s = status.toLowerCase();
    final done = s == 'done' || s == 'completed' || s == 'ok';
    final current =
        s == 'current' || s == 'active' || s == 'doing' || s == 'in_progress';
    return Container(
      width: 18,
      height: 18,
      margin: const EdgeInsets.only(top: 1),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? scheme.primary : scheme.surface,
        border: Border.all(
          color: done || current ? scheme.primary : scheme.outline,
          width: current ? 4 : 2,
        ),
      ),
      child: done ? Icon(Icons.check, size: 12, color: scheme.onPrimary) : null,
    );
  }
}

// --- Actions & suggestions ---------------------------------------------------

/// Sends [message] to Degany as if the user wrote it (or as the answer to a
/// pending question). Returns false when it is busy.
bool sendToDegany(BuildContext context, WidgetRef ref, String message) {
  final chat = ref.read(assistantChatProvider);
  if (chat.busy && !chat.awaitingAnswer) {
    showChatSnack(context, ref.read(appStringsProvider).richBusy);
    return false;
  }
  unawaited(ref.read(assistantChatProvider.notifier).send(message));
  return true;
}

/// Buttons under an answer ("Créer la tâche", "Enregistrer en note"…): a tap
/// sends their message to Degany.
class ActionsBlock extends ConsumerWidget {
  const ActionsBlock({
    required this.json,
    required this.streaming,
    super.key,
  });

  final Object? json;
  final bool streaming;

  static bool canShow(Object? json) =>
      blockItems(json, key: 'actions').isNotEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(assistantChatProvider.select((c) => c.busy));
    final items = blockItems(json, key: 'actions');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (k, a) in items.indexed)
            _button(
              context,
              ref,
              label: _s(a['label'] ?? a['title']) ?? '',
              message: _s(a['message'] ?? a['prompt'] ?? a['label']) ?? '',
              icon: iconNamed(a['icon']),
              primary: a['primary'] == true || (k == 0 && a['primary'] == null),
              enabled: !busy && !streaming,
            ),
        ],
      ),
    );
  }

  Widget _button(
    BuildContext context,
    WidgetRef ref, {
    required String label,
    required String message,
    required IconData? icon,
    required bool primary,
    required bool enabled,
  }) {
    final onPressed = enabled && message.isNotEmpty
        ? () => sendToDegany(context, ref, message)
        : null;
    final key = ValueKey('degany-action-$label');
    final text = Text(label);
    if (primary) {
      return icon == null
          ? FilledButton.tonal(key: key, onPressed: onPressed, child: text)
          : FilledButton.tonalIcon(
              key: key,
              onPressed: onPressed,
              icon: Icon(icon, size: 18),
              label: text);
    }
    return icon == null
        ? OutlinedButton(key: key, onPressed: onPressed, child: text)
        : OutlinedButton.icon(
            key: key,
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: text);
  }
}

/// Follow-up questions the user can send with one tap.
class SuggestionsBlock extends ConsumerWidget {
  const SuggestionsBlock({
    required this.json,
    required this.streaming,
    super.key,
  });

  final Object? json;
  final bool streaming;

  static List<String> _items(Object? json) => [
        for (final i in blockItems(json, key: 'suggestions'))
          if (_s(i['label'] ?? i['text'] ?? i['title']) case final t?) t,
      ];

  static bool canShow(Object? json) => _items(json).isNotEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(assistantChatProvider.select((c) => c.busy));
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final s in _items(json))
            ActionChip(
              key: ValueKey('degany-suggestion-$s'),
              avatar: Icon(Icons.subdirectory_arrow_right,
                  size: 16, color: scheme.primary),
              label: Text(s),
              onPressed: busy || streaming
                  ? null
                  : () => sendToDegany(context, ref, s),
            ),
        ],
      ),
    );
  }
}

// --- Map ---------------------------------------------------------------------

/// Places with a button opening them in a map (OpenStreetMap, in the
/// browser or the map app): no map tiles inside the app.
class PlacesBlock extends ConsumerWidget {
  const PlacesBlock({required this.json, super.key});

  final Object? json;

  static List<Map<String, dynamic>> _places(Object? json) =>
      blockItems(json, key: 'places');

  static bool canShow(Object? json) => _places(json).isNotEmpty;

  static Uri _uri(Map<String, dynamic> place) {
    final lat = toNumber(place['lat'] ?? place['latitude']);
    final lng = toNumber(place['lng'] ?? place['lon'] ?? place['longitude']);
    if (lat != null && lng != null) {
      return Uri.https('www.openstreetmap.org', '/', {
        'mlat': '$lat',
        'mlon': '$lng',
      }).replace(fragment: 'map=16/$lat/$lng');
    }
    final q = _s(place['address']) ?? _s(place['name']) ?? '';
    return Uri.https('www.openstreetmap.org', '/search', {'query': q});
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final places = _places(json);
    return BlockCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
            child: Row(
              children: [
                Icon(Icons.map_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(blockTitle(json) ?? strings.richPlaces,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          for (final place in places)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
              child: Row(
                children: [
                  Icon(Icons.place, color: scheme.error, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _s(place['name'] ?? place['title']) ??
                              _s(place['address']) ??
                              '',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        if (_s(place['name']) != null &&
                            _s(place['address'] ?? place['note']) != null)
                          Text(_s(place['address'] ?? place['note'])!,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => launchUrl(_uri(place),
                        mode: LaunchMode.externalApplication),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(strings.richOpenMap),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
