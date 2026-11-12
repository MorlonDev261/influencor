import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_strings.dart';

enum _ItemAction { edit, delete }

/// Vertical "⋮" button of a list item, offering Edit and Delete.
class ItemMenuButton extends ConsumerWidget {
  const ItemMenuButton({
    required this.onEdit,
    required this.onDelete,
    super.key,
  });

  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStringsProvider);
    final error = Theme.of(context).colorScheme.error;
    return PopupMenuButton<_ItemAction>(
      tooltip: s.moreActions,
      icon: const Icon(Icons.more_vert),
      onSelected: (a) => a == _ItemAction.edit ? onEdit() : onDelete(),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _ItemAction.edit,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.edit_outlined),
            title: Text(s.edit),
          ),
        ),
        PopupMenuItem(
          value: _ItemAction.delete,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            iconColor: error,
            textColor: error,
            leading: const Icon(Icons.delete_outline),
            title: Text(s.delete),
          ),
        ),
      ],
    );
  }
}
