import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/empty_state.dart';
import '../application/assistant_providers.dart';
import '../data/chat_store.dart';

/// Opens Degany's saved conversations; tapping one brings it back in the chat.
void openChatHistory(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AssistantHistoryScreen()),
    );

/// Degany's previous conversations, most recent first.
class AssistantHistoryScreen extends ConsumerWidget {
  const AssistantHistoryScreen({super.key});

  Future<void> _open(
      BuildContext context, WidgetRef ref, ChatSummary chat) async {
    final strings = ref.read(appStringsProvider);
    final ok = await ref.read(assistantChatProvider.notifier).open(chat.id);
    if (!context.mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(strings.chatOpenFailed)));
      ref.invalidate(chatHistoryProvider);
    }
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, ChatSummary chat) async {
    final strings = ref.read(appStringsProvider);
    final ok = await showConfirmDialog(
      context,
      title: strings.chatDelete,
      message: strings.chatDeleteConfirm,
      confirmLabel: strings.delete,
      cancelLabel: strings.cancel,
      destructive: true,
    );
    if (ok) await ref.read(assistantChatProvider.notifier).delete(chat.id);
  }

  String _when(AppStrings strings, DateTime date) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final day = DateTime(date.year, date.month, date.day);
    final today = DateTime(now.year, now.month, now.day);
    final time = '${two(date.hour)}:${two(date.minute)}';
    if (day == today) return time;
    if (day == today.subtract(const Duration(days: 1))) {
      return '${strings.yesterday} $time';
    }
    return '${two(date.day)}/${two(date.month)}/${date.year}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final chats = ref.watch(chatHistoryProvider);
    ref.watch(assistantChatProvider); // the current one may change
    final current = ref.read(assistantChatProvider.notifier).currentChatId;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(strings.chatHistory)),
      body: chats.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => Center(child: Text(strings.genericError)),
        data: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.history,
              title: strings.chatHistory,
              message: strings.chatHistoryEmpty,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final chat = list[i];
              final isCurrent = chat.id == current;
              return ListTile(
                key: ValueKey('chat-${chat.id}'),
                leading: Icon(
                  isCurrent ? Icons.chat : Icons.chat_bubble_outline,
                  color: isCurrent ? scheme.primary : null,
                ),
                title: Text(
                  chat.title.isEmpty ? strings.chatUntitled : chat.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(isCurrent
                    ? '${strings.chatCurrent} · ${_when(strings, chat.updatedAt)}'
                    : _when(strings, chat.updatedAt)),
                selected: isCurrent,
                onTap: () => _open(context, ref, chat),
                trailing: IconButton(
                  tooltip: strings.chatDelete,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(context, ref, chat),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
