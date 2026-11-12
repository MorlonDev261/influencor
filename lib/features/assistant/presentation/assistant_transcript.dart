import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../core/l10n/app_strings.dart';
import '../../library/domain/library_entry.dart';
import '../application/assistant_providers.dart';
import '../../../core/services/content_share_ui.dart';
import '../../library/application/library_providers.dart';
import '../application/tools/app_tools.dart';
import 'rich/chat_image.dart';
import 'rich/markdown_blocks.dart';
import 'rich/rich_common.dart';
import 'rich/rich_message.dart';

export 'rich/rich_message.dart' show RichMessage, PathChip, CodeBlock;

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
    bool picture(String f) => switch (kindForFile(f)) {
          EntryKind.image || EntryKind.video => true,
          _ => false,
        };
    final pictures = [
      for (final f in attachments)
        if (picture(f)) f
    ];
    final others = [
      for (final f in attachments)
        if (!picture(f)) f
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6, left: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Pictures and videos show as pictures, other files as tiles.
          if (pictures.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(
                  bottom: text.isEmpty && others.isEmpty ? 0 : 6),
              child: ChatImageGallery(
                sources: [for (final f in pictures) ChatImageSource.file(f)],
                alignEnd: true,
                maxWidth: 380,
                maxHeight: 300,
              ),
            ),
          if (others.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: text.isEmpty ? 0 : 6),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final path in others) AttachmentTile(path: path),
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

/// A question from the agent, with its choices as buttons (or chips to tick
/// and a confirm button when several can be picked). Once answered, the
/// choice stays visible and the buttons are disabled.
class QuestionCard extends ConsumerStatefulWidget {
  const QuestionCard({required this.item, required this.onAnswer, super.key});

  final ChatItem item;
  final ValueChanged<String> onAnswer;

  @override
  ConsumerState<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends ConsumerState<QuestionCard> {
  final _picked = <String>{};

  /// The choices of an answered multiple-choice question.
  static List<String>? _answers(String? answer) {
    if (answer == null || !answer.trimLeft().startsWith('[')) return null;
    try {
      final v = jsonDecode(answer);
      return v is List ? [for (final e in v) '$e'] : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final item = widget.item;
    final scheme = Theme.of(context).colorScheme;
    final pending = item.streaming && item.answer == null;
    final answer = item.answer;
    final answers = item.multiple ? _answers(answer) : null;
    bool chosen(String o) => answers?.contains(o) ?? o == answer;
    return _CardFrame(
      pending: pending,
      icon: Icons.help_outline,
      title: item.text,
      children: [
        if (item.options.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in item.options)
                if (item.multiple && pending)
                  FilterChip(
                    key: ValueKey('assistant-option-$option'),
                    label: Text(option),
                    selected: _picked.contains(option),
                    onSelected: (v) => setState(
                        () => v ? _picked.add(option) : _picked.remove(option)),
                  )
                else if (chosen(option))
                  Chip(
                    avatar:
                        Icon(Icons.check, size: 18, color: scheme.onPrimary),
                    label: Text(option),
                    labelStyle: TextStyle(
                        color: scheme.onPrimary, fontWeight: FontWeight.w600),
                    backgroundColor: scheme.primary,
                    side: BorderSide.none,
                  )
                else
                  OutlinedButton(
                    key: ValueKey('assistant-option-$option'),
                    onPressed: pending ? () => widget.onAnswer(option) : null,
                    child: Text(option),
                  ),
            ],
          ),
          if (item.multiple && pending) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('assistant-confirm-choices'),
              onPressed: _picked.isEmpty
                  ? null
                  : () => widget.onAnswer(jsonEncode([
                        for (final o in item.options)
                          if (_picked.contains(o)) o,
                      ])),
              icon: const Icon(Icons.check, size: 18),
              label: Text(strings.richConfirm),
            ),
          ],
        ],
        if (answer != null && answers == null && !item.options.contains(answer))
          _TypedAnswer(answer: answer),
      ],
    );
  }
}

class _TypedAnswer extends StatelessWidget {
  const _TypedAnswer({required this.answer});

  final String answer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text('↳ $answer',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// The frame of a question or form: highlighted while it waits.
class _CardFrame extends StatelessWidget {
  const _CardFrame({
    required this.pending,
    required this.icon,
    required this.title,
    required this.children,
  });

  final bool pending;
  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          ...children,
        ],
      ),
    );
  }
}

/// A form from the agent (`ask_form`): text, number, date (with a calendar),
/// single or multiple choice, yes/no. Sent as one JSON answer; once sent,
/// the values stay visible.
class FormCard extends ConsumerStatefulWidget {
  const FormCard({required this.item, required this.onAnswer, super.key});

  final ChatItem item;
  final ValueChanged<String> onAnswer;

  @override
  ConsumerState<FormCard> createState() => _FormCardState();
}

class _FormCardState extends ConsumerState<FormCard> {
  final _values = <String, Object?>{};
  final _controllers = <String, TextEditingController>{};
  final _missing = <String>{};

  List<Map<String, dynamic>> get _fields => widget.item.fields;

  @override
  void initState() {
    super.initState();
    for (final f in _fields) {
      final name = '${f['name']}';
      final type = '${f['type'] ?? 'text'}';
      final def = f['default'];
      switch (type) {
        case 'bool':
          _values[name] = def == true || '$def' == 'true';
        case 'multichoice':
          _values[name] = <String>[
            if (def != null)
              for (final e in '$def'.split(','))
                if (e.trim().isNotEmpty) e.trim(),
          ];
        case 'choice' || 'date':
          _values[name] = def?.toString();
        default:
          _controllers[name] =
              TextEditingController(text: def?.toString() ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final out = <String, Object?>{};
    _missing.clear();
    for (final f in _fields) {
      final name = '${f['name']}';
      final type = '${f['type'] ?? 'text'}';
      Object? v = _controllers[name]?.text.trim() ?? _values[name];
      if (type == 'number' && v is String && v.isNotEmpty) {
        v = toNumber(v) ?? v;
      }
      final empty =
          v == null || (v is String && v.isEmpty) || (v is List && v.isEmpty);
      if (f['required'] == true && empty) _missing.add(name);
      out[name] = empty ? null : v;
    }
    if (_missing.isNotEmpty) {
      setState(() {});
      return;
    }
    widget.onAnswer(jsonEncode(out));
  }

  Future<void> _pickDate(String name) async {
    final current = DateTime.tryParse('${_values[name]}') ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _values[name] = picked.toIso8601String().substring(0, 10));
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;
    final item = widget.item;
    final pending = item.streaming && item.answer == null;

    if (!pending) {
      Map<String, dynamic>? sent;
      try {
        final v = jsonDecode(item.answer ?? '');
        if (v is Map) sent = v.cast<String, dynamic>();
      } catch (_) {}
      return _CardFrame(
        pending: false,
        icon: Icons.assignment_outlined,
        title: item.text,
        children: [
          if (sent != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final f in _fields)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text.rich(TextSpan(children: [
                        TextSpan(
                          text: '${f['label'] ?? f['name']} : ',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        TextSpan(
                          text: _show(sent[f['name']], strings),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ])),
                    ),
                ],
              ),
            )
          else if (item.answer != null)
            _TypedAnswer(answer: item.answer!),
        ],
      );
    }

    return _CardFrame(
      pending: true,
      icon: Icons.assignment_outlined,
      title: item.text,
      children: [
        const SizedBox(height: 6),
        for (final f in _fields) _field(f, strings, scheme),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const ValueKey('assistant-form-submit'),
            onPressed: _submit,
            icon: const Icon(Icons.send, size: 18),
            label: Text(strings.richSubmit),
          ),
        ),
      ],
    );
  }

  String _show(Object? v, AppStrings strings) => switch (v) {
        null => '—',
        true => strings.richYes,
        false => strings.richNo,
        List() => v.join(', '),
        _ => '$v',
      };

  Widget _field(
      Map<String, dynamic> f, AppStrings strings, ColorScheme scheme) {
    final name = '${f['name']}';
    final label = '${f['label'] ?? name}${f['required'] == true ? ' *' : ''}';
    final type = '${f['type'] ?? 'text'}';
    final hint = f['hint']?.toString();
    final rawOptions = f['options'];
    final options = [
      if (rawOptions is List)
        for (final o in rawOptions) '$o',
    ];
    final error = _missing.contains(name) ? strings.richRequired : null;
    final key = ValueKey('assistant-field-$name');
    Widget labelled(Widget child) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              child,
              if (error != null)
                Text(error,
                    style: TextStyle(color: scheme.error, fontSize: 12)),
            ],
          ),
        );
    switch (type) {
      case 'bool':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(
                child:
                    Text(label, style: Theme.of(context).textTheme.labelLarge),
              ),
              Switch(
                key: key,
                value: _values[name] == true,
                onChanged: (v) => setState(() => _values[name] = v),
              ),
            ],
          ),
        );
      case 'choice':
        return labelled(Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final o in options)
              ChoiceChip(
                key: ValueKey('assistant-field-$name-$o'),
                label: Text(o),
                selected: _values[name] == o,
                onSelected: (_) => setState(() => _values[name] = o),
              ),
          ],
        ));
      case 'multichoice':
        final picked = _values[name] as List<String>;
        return labelled(Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final o in options)
              FilterChip(
                key: ValueKey('assistant-field-$name-$o'),
                label: Text(o),
                selected: picked.contains(o),
                onSelected: (v) =>
                    setState(() => v ? picked.add(o) : picked.remove(o)),
              ),
          ],
        ));
      case 'date':
        return labelled(OutlinedButton.icon(
          key: key,
          onPressed: () => _pickDate(name),
          icon: const Icon(Icons.event_outlined, size: 18),
          label: Text(_values[name]?.toString() ?? strings.richPickDate),
        ));
      default:
        return labelled(TextField(
          key: key,
          controller: _controllers[name],
          minLines: type == 'multiline' ? 3 : 1,
          maxLines: type == 'multiline' ? 6 : 1,
          keyboardType: type == 'number'
              ? const TextInputType.numberWithOptions(
                  decimal: true, signed: true)
              : null,
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            filled: true,
            fillColor: scheme.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ));
    }
  }
}

/// The assistant's answer: plain text across the whole width, with a
/// blinking cursor while tokens arrive; once done, small buttons to copy it
/// (Markdown or plain text), save it as a note or share it.
class AssistantMessage extends ConsumerWidget {
  const AssistantMessage({required this.item, super.key});

  final ChatItem item;

  Future<void> _saveNote(BuildContext context, WidgetRef ref) async {
    final strings = ref.read(appStringsProvider);
    final heading = parseMarkdown(item.text).whereType<MdHeading>().firstOrNull;
    var title = heading != null
        ? plainInline(heading.text)
        : markdownToPlainText(item.text).split('\n').first;
    title = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    if (title.length > 60) title = title.substring(0, 60).trim();
    if (title.isEmpty) title = '${strings.assistant} ${stamp()}';
    try {
      final dir = await deganyExportDir(ref);
      final path = await ref
          .read(libraryControllerProvider)
          .createNote(dir, title: title, content: item.text);
      if (!context.mounted) return;
      showChatSnack(
        context,
        strings.richSavedIn('$deganyExportFolder/${p.basename(path)}'),
        action: SnackBarAction(
          label: strings.richOpen,
          onPressed: () async {
            final route = await routeForPath(path);
            if (context.mounted) unawaited(context.push(route));
          },
        ),
      );
    } on StateError {
      if (context.mounted) showChatSnack(context, strings.needWorkspace);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;
    void copy(String text) {
      Clipboard.setData(ClipboardData(text: text));
      _snack(context, strings.copiedToClipboard);
    }

    return GestureDetector(
      onLongPress: () => copy(item.text),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: double.infinity,
              child: RichMessage(
                text: item.text,
                color: scheme.onSurface,
                streaming: item.streaming,
              ),
            ),
            if (!item.streaming && item.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    TinyIconButton(
                      key: const ValueKey('degany-copy-markdown'),
                      icon: Icons.copy_rounded,
                      tooltip: strings.richCopyMarkdown,
                      onPressed: () => copy(item.text),
                    ),
                    TinyIconButton(
                      key: const ValueKey('degany-copy-text'),
                      icon: Icons.notes,
                      tooltip: strings.richCopyText,
                      onPressed: () => copy(markdownToPlainText(item.text)),
                    ),
                    TinyIconButton(
                      key: const ValueKey('degany-save-note'),
                      icon: Icons.note_add_outlined,
                      tooltip: strings.richSaveNote,
                      onPressed: () => _saveNote(context, ref),
                    ),
                    TinyIconButton(
                      key: const ValueKey('degany-share'),
                      icon: Icons.share_outlined,
                      tooltip: strings.share,
                      onPressed: () => contentShareService.shareContent(
                        text: markdownToPlainText(item.text),
                        localMediaPaths: const [],
                      ),
                    ),
                  ],
                ),
              ),
          ],
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
