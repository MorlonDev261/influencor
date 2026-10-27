import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/picker/app_file_picker.dart';
import '../../../core/picker/pick_mode.dart';
import '../../../core/providers/workspace_providers.dart';
import '../../../core/widgets/app_dialog.dart';
import '../application/assistant_providers.dart';
import 'assistant_history_screen.dart';
import 'assistant_settings_screen.dart';
import 'assistant_transcript.dart';

void openAssistantSettings(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AssistantSettingsScreen()),
    );

/// The chat page of the Assistant tab: the conversation with the AI agent.
class AssistantChatPage extends ConsumerStatefulWidget {
  const AssistantChatPage({super.key});

  @override
  ConsumerState<AssistantChatPage> createState() => _AssistantChatPageState();
}

class _AssistantChatPageState extends ConsumerState<AssistantChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Files the user attached to the next message (absolute paths).
  final _attachments = <String>[];
  bool _dragging = false;
  late final AssistantChatController _chat =
      ref.read(assistantChatProvider.notifier);

  @override
  void initState() {
    super.initState();
    _chat
      ..confirmHandler = _confirm
      ..navigator = _navigate;
  }

  void _navigate(String route, {required bool push}) {
    if (!mounted) return;
    push ? context.push(route) : context.go(route);
  }

  @override
  void dispose() {
    if (_chat.confirmHandler == _confirm) _chat.confirmHandler = null;
    if (_chat.navigator == _navigate) _chat.navigator = null;
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String title, String message) async {
    if (!mounted) return false;
    final strings = ref.read(appStringsProvider);
    return showConfirmDialog(
      context,
      title: title,
      message: message,
      confirmLabel: strings.allow,
      cancelLabel: strings.deny,
      destructive: true,
      confirmKey: const ValueKey('assistant-allow'),
    );
  }

  void _send([String? text]) {
    final message = (text ?? _input.text).trim();
    final chat = ref.read(assistantChatProvider);
    if (chat.awaitingAnswer) {
      if (message.isEmpty) return;
      _input.clear();
      _chat.answer(message);
      return;
    }
    // Suggestions (text given) never carry the pending attachments.
    final files = text == null ? List.of(_attachments) : const <String>[];
    if (message.isEmpty && files.isEmpty) return;
    if (chat.busy) return;
    _input.clear();
    setState(() => _attachments.removeWhere(files.contains));
    _scrollToEnd(force: true);
    _chat.send(message, attachments: files);
  }

  /// Only files of the workspace can be attached: Degany works nowhere else.
  void _addAttachments(Iterable<String> paths) {
    final strings = ref.read(appStringsProvider);
    final root = ref.read(workspaceRootProvider);
    if (root == null) {
      _snack(strings.needWorkspace);
      return;
    }
    final fresh = <String>[];
    var outside = 0;
    for (final path in paths) {
      if (path.isEmpty || _attachments.contains(path)) continue;
      if (isInWorkspace(root, path)) {
        fresh.add(path);
      } else {
        outside++;
      }
    }
    if (outside > 0) _snack(strings.outsideWorkspace(outside));
    if (fresh.isEmpty) return;
    setState(() => _attachments.addAll(fresh));
  }

  Future<void> _pickAttachments(PickMode mode) async {
    final strings = ref.read(appStringsProvider);
    final root = ref.read(workspaceRootProvider);
    if (root == null) {
      _snack(strings.needWorkspace);
      return;
    }
    final paths = await AppFilePicker.pick(
      context,
      mode: mode,
      allowMultiple: true,
      title: strings.attach,
      root: root,
    );
    if (mounted) _addAttachments(paths);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Follows the answer while it streams, unless the user scrolled up to
  /// read something earlier.
  bool _following = true;

  bool _onScroll(ScrollNotification n) {
    if (n is UserScrollNotification || n is ScrollUpdateNotification) {
      final pos = n.metrics;
      _following = pos.maxScrollExtent - pos.pixels < 80;
    }
    return false;
  }

  void _scrollToEnd({bool force = false}) {
    if (force) _following = true;
    if (!_following) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final chat = ref.watch(assistantChatProvider);
    final config = ref.watch(assistantConfigProvider);
    ref.listen(assistantChatProvider, (_, __) => _scrollToEnd());

    final Widget body;
    if (chat.items.isEmpty) {
      body = _Welcome(
        ready: config.isReady,
        onSuggestion: _send,
        modelLabel: config.isReady
            ? '${config.provider.label} · ${config.model}'
            : null,
      );
    } else {
      final last = chat.items.last;
      // The activity line covers the silent moments: waiting for the first
      // token, the model writing an action, between two steps.
      final waiting = chat.busy &&
          !last.streaming &&
          !(last.kind == ChatItemKind.tool &&
              last.status == ToolStatus.running &&
              !silentTools.contains(last.toolName));
      final entries = _entries(chat.items);
      body = NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: entries.length + (waiting ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == entries.length) {
              return ActivityLine(
                key: ValueKey('activity-${chat.preparing}'),
                label: chat.preparing ?? strings.assistantWorking,
              );
            }
            final (start, end) = entries[i];
            if (end - start > 1) {
              return ToolGroup(
                key: ValueKey('group-$start'),
                items: chat.items.sublist(start, end),
                // Still being worked on: the last part of a running turn.
                live: chat.busy && end == chat.items.length,
              );
            }
            final item = chat.items[start];
            return switch (item.kind) {
              ChatItemKind.user =>
                UserMessage(text: item.text, attachments: item.attachments),
              ChatItemKind.question =>
                QuestionCard(item: item, onAnswer: _chat.answer),
              ChatItemKind.assistant => AssistantMessage(item: item),
              ChatItemKind.thinking => ThinkingBlock(item: item),
              // A question shows as its own card, not as an action line;
              // silent tools show nothing.
              ChatItemKind.tool
                  when item.toolName == 'ask_user' ||
                      silentTools.contains(item.toolName) =>
                const SizedBox.shrink(),
              ChatItemKind.tool => ToolActivity(item: item),
              ChatItemKind.notice => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    item.text,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                  ),
                ),
              ChatItemKind.error => _ErrorLine(
                  text: item.text,
                  onSettings: () => openAssistantSettings(context),
                ),
            };
          },
        ),
      );
    }

    final column = Column(
      key: const ValueKey('assistant-page'),
      children: [
        _ChatHeader(
          modelLabel: config.isReady ? config.model : null,
          canClear: chat.items.isNotEmpty,
          onClear: _chat.clear,
        ),
        Expanded(child: body),
        _Composer(
          controller: _input,
          hint:
              chat.awaitingAnswer ? strings.answerHint : strings.assistantHint,
          busy: chat.busy && !chat.awaitingAnswer,
          stopLabel: strings.stop,
          attachments: _attachments,
          onAttach: _pickAttachments,
          onRemoveAttachment: (path) =>
              setState(() => _attachments.remove(path)),
          onSend: _send,
          onStop: _chat.stop,
        ),
      ],
    );

    // Desktop: files dropped on the chat are attached to the next message.
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        _addAttachments([for (final f in detail.files) f.path]);
      },
      child: Stack(
        children: [
          column,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.08),
                    border: Border.all(color: scheme.primary, width: 2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child:
                      Icon(Icons.attach_file, size: 48, color: scheme.primary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The list's entries as `(start, end)` ranges of [items]: one item each,
/// except a run of two actions or more (with the reasoning between them),
/// which [ToolGroup] folds once it is done.
List<(int, int)> _entries(List<ChatItem> items) {
  bool inRun(ChatItem item) =>
      item.kind == ChatItemKind.thinking ||
      (item.kind == ChatItemKind.tool && item.toolName != 'ask_user');
  final out = <(int, int)>[];
  var i = 0;
  while (i < items.length) {
    var end = i;
    var tools = 0;
    while (end < items.length && inRun(items[end])) {
      if (items[end].kind == ChatItemKind.tool &&
          !silentTools.contains(items[end].toolName)) {
        tools++;
      }
      end++;
    }
    if (tools >= 2) {
      out.add((i, end));
      i = end;
    } else {
      out.add((i, i + 1));
      i++;
    }
  }
  return out;
}

class _ChatHeader extends ConsumerWidget {
  const _ChatHeader({
    required this.modelLabel,
    required this.canClear,
    required this.onClear,
  });

  final String? modelLabel;
  final bool canClear;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => openAssistantSettings(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome,
                        size: 16,
                        color: modelLabel == null
                            ? scheme.onSurfaceVariant
                            : scheme.primary),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        modelLabel ?? strings.assistantConnect,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('assistant-new-chat'),
            tooltip: strings.newConversation,
            onPressed: canClear ? onClear : null,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            key: const ValueKey('assistant-history'),
            tooltip: strings.chatHistory,
            onPressed: () => openChatHistory(context),
            icon: const Icon(Icons.history),
          ),
        ],
      ),
    );
  }
}

class _Welcome extends ConsumerWidget {
  const _Welcome({
    required this.ready,
    required this.onSuggestion,
    required this.modelLabel,
  });

  final bool ready;
  final ValueChanged<String> onSuggestion;
  final String? modelLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    // The build fixes the model: there is nothing for the user to connect.
    final managed = !ref.watch(deganyEnvProvider).userModels;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome,
                  size: 52,
                  color: theme.colorScheme.primary.withValues(alpha: 0.75)),
              const SizedBox(height: 16),
              Text(strings.assistant,
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                ready
                    ? strings.assistantIntro
                    : managed
                        ? strings.deganyManagedMissing
                        : strings.assistantNotConfigured,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              if (!ready && !managed)
                FilledButton.icon(
                  key: const ValueKey('assistant-connect'),
                  onPressed: () => openAssistantSettings(context),
                  icon: const Icon(Icons.link),
                  label: Text(strings.assistantConnect),
                )
              else if (ready)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final s in strings.assistantSuggestions)
                      ActionChip(
                          label: Text(s), onPressed: () => onSuggestion(s)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorLine extends ConsumerWidget {
  const _ErrorLine({required this.text, required this.onSettings});

  final String text;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
          ),
          IconButton(
            tooltip: ref.watch(appStringsProvider).assistantSettings,
            onPressed: onSettings,
            icon: Icon(Icons.tune, color: scheme.onErrorContainer),
          ),
        ],
      ),
    );
  }
}

class _Composer extends ConsumerWidget {
  const _Composer({
    required this.controller,
    required this.hint,
    required this.busy,
    required this.stopLabel,
    required this.attachments,
    required this.onAttach,
    required this.onRemoveAttachment,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final String hint;
  final bool busy;
  final String stopLabel;
  final List<String> attachments;
  final ValueChanged<PickMode> onAttach;
  final ValueChanged<String> onRemoveAttachment;
  final ValueChanged<String?> onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    final appBg = theme.scaffoldBackgroundColor;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  height: 64,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final path in attachments)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: AttachmentTile(
                            path: path,
                            onRemove: () => onRemoveAttachment(path),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                PopupMenuButton<PickMode>(
                  key: const ValueKey('assistant-attach'),
                  tooltip: strings.attach,
                  enabled: !busy,
                  icon: const Icon(Icons.attach_file),
                  onSelected: onAttach,
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: PickMode.mediaFiles,
                      child: ListTile(
                        leading: const Icon(Icons.photo_library_outlined),
                        title: Text(strings.attachMedia),
                      ),
                    ),
                    PopupMenuItem(
                      value: PickMode.files,
                      child: ListTile(
                        leading: const Icon(Icons.folder_open_outlined),
                        title: Text(strings.attachFiles),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: CallbackShortcuts(
                    // Desktop: Enter sends, Shift+Enter adds a line.
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter): () {
                        if (!busy) onSend(null);
                      },
                    },
                    child: TextField(
                      key: const ValueKey('assistant-input'),
                      controller: controller,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.send,
                      onSubmitted: busy ? null : (_) => onSend(null),
                      decoration: InputDecoration(
                        hintText: hint,
                        filled: true,
                        fillColor: appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                busy
                    ? IconButton.filledTonal(
                        key: const ValueKey('assistant-stop'),
                        tooltip: stopLabel,
                        onPressed: onStop,
                        icon: const Icon(Icons.stop_rounded),
                      )
                    : IconButton.filled(
                        key: const ValueKey('assistant-send'),
                        onPressed: () => onSend(null),
                        icon: const Icon(Icons.send),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
