import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/providers/workspace_providers.dart';
import '../../library/domain/library_entry.dart';
import '../application/assistant_providers.dart';
import '../application/tools/app_tools.dart';

// The conversation, drawn like a coding-agent transcript: the assistant writes
// full width (no bubble), its reasoning and its actions appear inline as they
// happen.

const _mono = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Consolas', 'Menlo', 'Roboto Mono', 'Courier New'],
);

void _snack(BuildContext context, String text) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(text)));

String _seconds(Duration d) {
  final s = d.inMilliseconds / 1000;
  return s < 10 ? '${s.toStringAsFixed(1)} s' : '${s.round()} s';
}

/// Fades its child in and out while [active] (streaming cursor, running
/// action bullet).
class Blink extends StatefulWidget {
  const Blink({required this.child, this.active = true, super.key});

  final Widget child;
  final bool active;

  @override
  State<Blink> createState() => _BlinkState();
}

class _BlinkState extends State<Blink> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant Blink old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.active && _c.isAnimating) {
      _c
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.active
      ? FadeTransition(
          opacity: Tween(begin: 0.25, end: 1.0).animate(_c),
          child: widget.child,
        )
      : widget.child;
}

/// Tap target without ink: folding an action or the reasoning shows no
/// ripple or highlight, only the change itself.
class _PlainTap extends StatelessWidget {
  const _PlainTap({required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: child,
        ),
      );
}

/// The user's message: a compact bubble on the right, with the files they
/// attached above it.
class UserMessage extends StatelessWidget {
  const UserMessage({
    required this.text,
    this.attachments = const [],
    super.key,
  });

  final String text;
  final List<String> attachments;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6, left: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (attachments.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: text.isEmpty ? 0 : 6),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final path in attachments) AttachmentTile(path: path),
                ],
              ),
            ),
          if (text.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              child: SelectableText(text),
            ),
        ],
      ),
    );
  }
}

/// An attached file: thumbnail for pictures, an icon otherwise, its name, and
/// a remove button while it is still in the composer.
class AttachmentTile extends StatelessWidget {
  const AttachmentTile({required this.path, this.onRemove, super.key});

  final String path;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = p.basename(path);
    final kind = kindForFile(path);
    final Widget preview = !kIsWeb && canRenderThumbnail(name)
        ? Image.file(
            File(path),
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            cacheWidth: 144,
            errorBuilder: (_, __, ___) => _icon(kind, scheme),
          )
        : _icon(kind, scheme);
    return Tooltip(
      message: path,
      child: Container(
        height: 60,
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox.square(dimension: 48, child: preview),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium,
              ),
            ),
            if (onRemove != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: onRemove,
                icon: const Icon(Icons.close),
              )
            else
              const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }

  static Widget _icon(EntryKind kind, ColorScheme scheme) => ColoredBox(
        color: scheme.primaryContainer,
        child: Icon(
          switch (kind) {
            EntryKind.image => Icons.image_outlined,
            EntryKind.video => Icons.movie_outlined,
            EntryKind.note => Icons.description_outlined,
            _ => Icons.insert_drive_file_outlined,
          },
          color: scheme.onPrimaryContainer,
        ),
      );
}

/// A question from the agent, with its choices as buttons. Once answered,
/// the choice stays visible and the buttons are disabled.
class QuestionCard extends StatelessWidget {
  const QuestionCard({required this.item, required this.onAnswer, super.key});

  final ChatItem item;
  final ValueChanged<String> onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pending = item.streaming && item.answer == null;
    final answer = item.answer;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: pending
            ? scheme.primaryContainer.withValues(alpha: 0.45)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: pending ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.help_outline, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.text,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (item.options.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in item.options)
                  option == answer
                      ? Chip(
                          avatar: Icon(Icons.check,
                              size: 18, color: scheme.onPrimary),
                          label: Text(option),
                          labelStyle: TextStyle(
                              color: scheme.onPrimary,
                              fontWeight: FontWeight.w600),
                          backgroundColor: scheme.primary,
                          side: BorderSide.none,
                        )
                      : OutlinedButton(
                          key: ValueKey('assistant-option-$option'),
                          onPressed: pending ? () => onAnswer(option) : null,
                          child: Text(option),
                        ),
              ],
            ),
          ],
          if (answer != null && !item.options.contains(answer)) ...[
            const SizedBox(height: 8),
            Text('↳ $answer',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

/// The assistant's answer: plain text across the whole width, with a
/// blinking cursor while tokens arrive.
class AssistantMessage extends ConsumerWidget {
  const AssistantMessage({required this.item, super.key});

  final ChatItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: item.text));
        _snack(context, ref.read(appStringsProvider).copiedToClipboard);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SizedBox(
          width: double.infinity,
          child: RichMessage(
            text: item.text,
            color: scheme.onSurface,
            streaming: item.streaming,
          ),
        ),
      ),
    );
  }
}

/// The model's reasoning: live while it thinks, then folded to one line.
class ThinkingBlock extends ConsumerStatefulWidget {
  const ThinkingBlock({required this.item, super.key});

  final ChatItem item;

  @override
  ConsumerState<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends ConsumerState<ThinkingBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final item = widget.item;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final live = item.streaming;
    final elapsed = item.elapsed;
    final header = live
        ? '${strings.thinking}…'
        : elapsed == null
            ? strings.thinking
            : '${strings.thinking} · ${_seconds(elapsed)}';
    final body = item.text.trim();
    final textStyle = theme.textTheme.bodySmall?.copyWith(
      color: muted,
      fontStyle: FontStyle.italic,
      height: 1.4,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PlainTap(
            onTap: live || body.isEmpty
                ? null
                : () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Blink(
                    active: live,
                    child: Text('✻',
                        style: TextStyle(color: theme.colorScheme.tertiary)),
                  ),
                  const SizedBox(width: 6),
                  Text(header,
                      style:
                          theme.textTheme.labelMedium?.copyWith(color: muted)),
                  if (!live && body.isNotEmpty)
                    Icon(_open ? Icons.expand_less : Icons.chevron_right,
                        size: 16, color: muted),
                ],
              ),
            ),
          ),
          if (body.isNotEmpty && (live || _open))
            Container(
              margin: const EdgeInsets.only(left: 6, top: 2, bottom: 4),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(
                    left: BorderSide(
                        color: muted.withValues(alpha: 0.35), width: 2)),
              ),
              child: live
                  // Live: the latest lines only, so the chat doesn't jump.
                  ? Text(
                      _tail(body, 6),
                      style: textStyle,
                    )
                  : SelectableText(body, style: textStyle),
            ),
        ],
      ),
    );
  }

  static String _tail(String text, int lines) {
    final all = text.split('\n');
    return all.length <= lines
        ? text
        : '…\n${all.sublist(all.length - lines).join('\n')}';
  }
}

/// A one-line digest of a tool result ("3 résultat(s)", "Créé : a.md"…),
/// in the app's language.
String toolResultSummary(ChatItem item, AppStrings strings) {
  final result = item.result;
  if (item.status == ToolStatus.running) return '';
  if (result == null || result.isEmpty) return '';
  if (item.status != ToolStatus.done) {
    // Tool errors are written for the model (in French): show the first line.
    return result.split('\n').first.replaceFirst('Erreur : ', '');
  }
  Object? data;
  try {
    data = jsonDecode(result);
  } catch (_) {
    return _clip(result.split('\n').first);
  }
  String count(Object? v) => v is List ? '${v.length}' : '$v';
  if (data is List) return strings.toolItems(data.length);
  if (data is! Map) return _clip('$data');
  final m = data;
  if (m['total'] != null) return strings.toolResults(m['total']);
  for (final (key, label) in [
    ('created', strings.toolCreated),
    ('saved', strings.toolSaved),
    ('saved_as', strings.toolSaved),
    ('renamed', strings.toolRenamed),
    ('copy', strings.toolCopy),
    ('opened', strings.toolOpened),
    ('deleted', strings.toolDeleted),
  ]) {
    if (m[key] case final v? when v is String) return '$label : $v';
  }
  if (m['moved'] != null) return strings.toolMoved(count(m['moved']));
  if (m['trashed'] != null) return strings.toolTrashed(count(m['trashed']));
  if (m['restored'] != null) return strings.toolRestored(m['restored']);
  if (m['imported'] != null) return strings.toolImported(m['imported']);
  if (m['changed'] != null) {
    return strings.toolSettingsChanged(count(m['changed']));
  }
  if (m['findings'] is List) {
    return strings.toolSensitive(m['sensitive_count'] ?? 0);
  }
  if (m['content'] is String) {
    return strings.toolCharacters((m['content'] as String).length);
  }
  if (m['row_count'] != null) return strings.toolRows(m['row_count']);
  if (m['net'] != null) return strings.toolNet(m['net']);
  if (m['plans'] is List && (m['plans'] as List).isNotEmpty) {
    final best = (m['plans'] as List).first;
    if (best is Map) {
      return strings.toolCheapest(best['operator'], best['total_fee']);
    }
  }
  if (m['added'] != null || m['updated'] != null) return 'OK';
  return strings.toolFields(m.length);
}

String _clip(String s) => s.length > 90 ? '${s.substring(0, 90)}…' : s;

/// An action, shown like a coding agent does:
///
///     ● Recherche("prix")
///       ⎿  3 résultat(s)
///
/// Tap to unfold the exact call and its full result.
class ToolActivity extends ConsumerStatefulWidget {
  const ToolActivity({required this.item, super.key});

  final ChatItem item;

  @override
  ConsumerState<ToolActivity> createState() => _ToolActivityState();
}

class _ToolActivityState extends ConsumerState<ToolActivity> {
  bool _open = false;

  static String _args(Map<String, dynamic> args, {bool full = false}) {
    final parts = <String>[];
    for (final e in args.entries) {
      final raw = e.value;
      var v = raw is String
          ? '"${raw.replaceAll('\n', ' ')}"'
          : raw is List
              ? raw.map((x) => x is String ? '"$x"' : '$x').join(', ')
              : '$raw';
      if (!full && v.length > 48) v = '${v.substring(0, 48)}…';
      parts.add(full ? '${e.key}: $v' : v);
    }
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final running = item.status == ToolStatus.running;
    final dot = switch (item.status) {
      ToolStatus.running => muted,
      ToolStatus.done => const Color(0xFF2E9E5B),
      ToolStatus.failed => scheme.error,
      ToolStatus.denied => muted,
    };
    final strings = ref.watch(appStringsProvider);
    final summary = item.status == ToolStatus.denied
        ? strings.toolDenied
        : running
            ? '…'
            : toolResultSummary(item, strings);
    final elapsed = item.elapsed;
    final base = theme.textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: _PlainTap(
        onTap: running ? null : () => setState(() => _open = !_open),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Blink(
                    active: running,
                    child:
                        Text('●', style: TextStyle(color: dot, fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: item.text,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: '(${_args(item.args)})',
                        style: _mono.copyWith(color: muted, fontSize: 12.5),
                      ),
                    ]),
                    maxLines: _open ? null : 2,
                    overflow: _open ? null : TextOverflow.ellipsis,
                    style: base,
                  ),
                ),
              ],
            ),
            if (summary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The "⎿" elbow, drawn: the glyph is missing from many
                    // fonts (Android, web).
                    Container(
                      width: 9,
                      height: 9,
                      margin: const EdgeInsets.only(left: 2, top: 2, right: 8),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: muted, width: 1.2),
                          bottom: BorderSide(color: muted, width: 1.2),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        elapsed != null &&
                                !running &&
                                elapsed.inMilliseconds >= 1000
                            ? '$summary  ·  ${_seconds(elapsed)}'
                            : summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: item.status == ToolStatus.failed
                              ? scheme.error
                              : muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_open)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(left: 22, top: 6, bottom: 4),
                padding: const EdgeInsets.all(10),
                constraints: const BoxConstraints(maxHeight: 300),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    '${item.toolName}(${_args(item.args, full: true)})'
                    '${item.result == null ? '' : '\n\n${item.result}'}',
                    style:
                        _mono.copyWith(fontSize: 12, color: scheme.onSurface),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A finished stretch of work — several actions, with the reasoning between
/// them — folded to one line, like the reasoning:
///
///     ● 4 actions · 12 s ›
///       ⎿  Recherche, Lire la note, Créer une note
///
/// Tap to unfold every step. While the agent is still on it ([live]), the
/// steps show one under the other as they happen.
class ToolGroup extends ConsumerStatefulWidget {
  const ToolGroup({required this.items, required this.live, super.key});

  /// Actions and reasoning blocks, in order.
  final List<ChatItem> items;
  final bool live;

  @override
  ConsumerState<ToolGroup> createState() => _ToolGroupState();
}

class _ToolGroupState extends ConsumerState<ToolGroup> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final steps = [
      for (final (i, item) in items.indexed)
        if (item.kind == ChatItemKind.thinking)
          ThinkingBlock(key: ValueKey('step-$i'), item: item)
        else if (!silentTools.contains(item.toolName))
          ToolActivity(key: ValueKey('step-$i'), item: item),
    ];
    if (widget.live) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: steps,
      );
    }

    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final tools = [
      for (final item in items)
        if (item.kind == ChatItemKind.tool &&
            !silentTools.contains(item.toolName))
          item,
    ];
    final failed = tools.any((t) => t.status == ToolStatus.failed);
    final allDenied = tools.every((t) => t.status == ToolStatus.denied);
    final dot = failed
        ? scheme.error
        : allDenied
            ? muted
            : const Color(0xFF2E9E5B);
    final started = items.map((i) => i.startedAt).nonNulls.firstOrNull;
    final ended = items
        .map((i) => i.endedAt)
        .nonNulls
        .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    final elapsed =
        started != null && ended != null ? ended.difference(started) : null;
    final labels = {for (final t in tools) t.text}.join(', ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PlainTap(
            onTap: () => setState(() => _open = !_open),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('●', style: TextStyle(color: dot, fontSize: 13)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                            text: strings.toolActions(tools.length),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          if (elapsed != null && elapsed.inMilliseconds >= 1000)
                            TextSpan(
                              text: '  ·  ${_seconds(elapsed)}',
                              style: TextStyle(color: muted),
                            ),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Icon(_open ? Icons.expand_less : Icons.chevron_right,
                        size: 16, color: muted),
                  ],
                ),
                if (!_open && labels.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 1),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The "⎿" elbow, drawn (see ToolActivity).
                        Container(
                          width: 9,
                          height: 9,
                          margin:
                              const EdgeInsets.only(left: 2, top: 2, right: 8),
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(color: muted, width: 1.2),
                              bottom: BorderSide(color: muted, width: 1.2),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            labels,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: muted),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (_open)
            Container(
              margin: const EdgeInsets.only(left: 6, top: 4, bottom: 2),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                      color: muted.withValues(alpha: 0.35), width: 2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: steps,
              ),
            ),
        ],
      ),
    );
  }
}

/// "✻ Je travaille… (12 s)" while the agent waits for the model or writes an
/// action; the glyph cycles like a coding agent's spinner.
class ActivityLine extends ConsumerStatefulWidget {
  const ActivityLine({required this.label, super.key});

  final String label;

  @override
  ConsumerState<ActivityLine> createState() => _ActivityLineState();
}

class _ActivityLineState extends ConsumerState<ActivityLine> {
  static const _frames = ['·', '✢', '✳', '✶', '✻', '✽', '✻', '✶', '✳', '✢'];
  final _started = DateTime.now();
  late final Timer _timer;
  var _frame = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (mounted) setState(() => _frame = (_frame + 1) % _frames.length);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secs = DateTime.now().difference(_started).inSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Text(_frames[_frame],
                style:
                    TextStyle(color: theme.colorScheme.tertiary, fontSize: 15)),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              secs >= 2 ? '${widget.label} (${secs}s)' : widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders the light Markdown the model writes (headings, bold, inline code,
/// lists, fenced code blocks), turns `[[path]]` into buttons that open the
/// item and URLs into links. Partial text (while streaming) renders fine.
class RichMessage extends ConsumerWidget {
  const RichMessage({
    required this.text,
    required this.color,
    this.streaming = false,
    super.key,
  });

  final String text;
  final Color color;
  final bool streaming;

  static final _token = RegExp(
    r'\[\[([^\]\n]+)\]\]|\*\*([^*\n]+)\*\*|`([^`\n]+)`|(https?://[^\s<>\]\)]+)',
  );

  /// ```lang … ``` — an unclosed fence (still streaming) runs to the end.
  static final _fence = RegExp(r'```([^\n`]*)\n?([\s\S]*?)(?:```|$)');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final children = <Widget>[];
    var last = 0;
    final matches = _fence.allMatches(text).toList();
    for (final (i, m) in matches.indexed) {
      if (m.start > last) {
        children
            .add(_prose(context, text.substring(last, m.start), cursor: false));
      }
      children.add(_CodeBlock(
        code: m.group(2)!.replaceFirst(RegExp(r'\n$'), ''),
        language: m.group(1)!.trim(),
        cursor: streaming && i == matches.length - 1 && m.end == text.length,
      ));
      last = m.end;
    }
    if (last < text.length || children.isEmpty) {
      children.add(_prose(context, text.substring(last), cursor: streaming));
    } else if (streaming && matches.isEmpty) {
      children.add(_prose(context, '', cursor: true));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _prose(BuildContext context, String chunk, {required bool cursor}) {
    final theme = Theme.of(context);
    final base =
        theme.textTheme.bodyLarge!.copyWith(color: color, height: 1.45);
    var trimmed = chunk.replaceFirst(RegExp(r'^\n+'), '');
    // Blank lines before a code block are the block's own margin.
    if (!cursor) trimmed = trimmed.replaceFirst(RegExp(r'\n+$'), '');
    if (trimmed.isEmpty && !cursor) return const SizedBox.shrink();
    final lines = trimmed.split('\n');
    final spans = <InlineSpan>[];
    for (final (i, rawLine) in lines.indexed) {
      var line = rawLine;
      var style = base;
      final heading = RegExp(r'^\s{0,3}(#{1,6})\s+').firstMatch(line);
      if (heading != null) {
        line = line.substring(heading.end);
        style = base.copyWith(
          fontWeight: FontWeight.w700,
          fontSize:
              (base.fontSize ?? 16) + (heading.group(1)!.length <= 2 ? 2 : 0),
        );
      }
      final bullet = RegExp(r'^(\s*)[-*•]\s+').firstMatch(line);
      if (bullet != null) {
        line = '${bullet.group(1)}  •  ${line.substring(bullet.end)}';
      }
      if (RegExp(r'^\s*(-{3,}|\*{3,})\s*$').hasMatch(line)) line = '';
      _inline(context, line, style, spans);
      if (i < lines.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    if (cursor) {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Blink(
          child: Container(
            width: 8,
            height: (base.fontSize ?? 16) * 1.1,
            margin: const EdgeInsets.only(left: 2),
            color: theme.colorScheme.primary,
          ),
        ),
      ));
    }
    return Text.rich(TextSpan(children: spans));
  }

  void _inline(BuildContext context, String line, TextStyle style,
      List<InlineSpan> out) {
    var last = 0;
    for (final m in _token.allMatches(line)) {
      if (m.start > last) {
        out.add(TextSpan(text: line.substring(last, m.start), style: style));
      }
      if (m.group(1) != null) {
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: PathChip(path: m.group(1)!.trim()),
        ));
      } else if (m.group(2) != null) {
        out.add(TextSpan(
            text: m.group(2),
            style: style.copyWith(fontWeight: FontWeight.w700)));
      } else if (m.group(3) != null) {
        out.add(TextSpan(
          text: m.group(3),
          style: style.merge(_mono).copyWith(
                fontSize: (style.fontSize ?? 16) * 0.9,
                backgroundColor: color.withValues(alpha: 0.08),
              ),
        ));
      } else {
        final url = m.group(4)!;
        out.add(TextSpan(
          text: url,
          style: style.copyWith(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () =>
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        ));
      }
      last = m.end;
    }
    if (last < line.length) {
      out.add(TextSpan(text: line.substring(last), style: style));
    }
  }
}

class _CodeBlock extends ConsumerWidget {
  const _CodeBlock({
    required this.code,
    required this.language,
    required this.cursor,
  });

  final String code;
  final String language;
  final bool cursor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 2, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(language,
                      style: _mono.copyWith(color: muted, fontSize: 12)),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  tooltip: ref.watch(appStringsProvider).copiedToClipboard,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    _snack(context,
                        ref.read(appStringsProvider).copiedToClipboard);
                  },
                  icon: Icon(Icons.copy_rounded, color: muted),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              cursor ? '$code▍' : code,
              style: _mono.copyWith(
                  fontSize: 13, color: scheme.onSurface, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// A direct link to a library item: tap opens it, long-press copies the path.
class PathChip extends ConsumerWidget {
  const PathChip({required this.path, super.key});

  /// Workspace-relative (or absolute) path written by the model.
  final String path;

  String? _absolute(String? root) {
    final raw = path.replaceAll('\\', '/');
    if (p.isAbsolute(raw) || RegExp(r'^[A-Za-z]:/').hasMatch(raw)) {
      return p.normalize(raw);
    }
    if (root == null) return null;
    return p
        .normalize(p.join(root, raw.startsWith('/') ? raw.substring(1) : raw));
  }

  IconData _icon(String abs) {
    if (FileSystemEntity.isDirectorySync(abs)) return Icons.folder_outlined;
    return switch (kindForFile(abs)) {
      EntryKind.image => Icons.image_outlined,
      EntryKind.video => Icons.movie_outlined,
      EntryKind.note => Icons.description_outlined,
      _ => p.extension(abs).toLowerCase() == '.json'
          ? Icons.table_chart_outlined
          : Icons.insert_drive_file_outlined,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;
    final abs = _absolute(ref.watch(workspaceRootProvider));
    // No local files in a browser (web build): show a plain label.
    final exists = !kIsWeb &&
        abs != null &&
        FileSystemEntity.typeSync(abs) != FileSystemEntityType.notFound;
    final label = path.isEmpty ? '/' : p.basename(path.replaceAll('\\', '/'));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: path,
        child: Material(
          color: exists ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () async {
              if (!exists) {
                _snack(context, strings.itemNotFound);
                return;
              }
              final route = await routeForPath(abs);
              if (context.mounted) unawaited(context.push(route));
            },
            onLongPress: abs == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: abs));
                    _snack(context, strings.pathCopied);
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    exists ? _icon(abs) : Icons.link_off,
                    size: 15,
                    color: exists
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: exists
                                ? scheme.onPrimaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
