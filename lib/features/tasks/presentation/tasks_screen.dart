import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/widgets/app_dialog.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/providers/workspace_providers.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/item_menu.dart';
import '../application/task_providers.dart';
import '../domain/task_doc.dart';

/// The task's own page; [edit] opens it ready to change.
String taskEditRoute(String id, {bool edit = false}) => Uri(
      path: '/task/edit',
      queryParameters: {'id': id, if (edit) 'edit': '1'},
    ).toString();

class TasksScreen extends ConsumerWidget {
  const TasksScreen({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref, String id,
      {bool edit = false}) async {
    await context.push(taskEditRoute(id, edit: edit));
    ref.invalidate(taskListProvider);
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final store = ref.read(taskStoreProvider);
    if (store == null) return;
    final task = TaskDoc(id: const Uuid().v4());
    await store.save(task);
    if (context.mounted) await _open(context, ref, task.id, edit: true);
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, TaskDoc task) async {
    final strings = ref.read(appStringsProvider);
    final ok = await showConfirmDialog(
      context,
      title: strings.deleteTaskQuestion,
      message: task.title.isEmpty ? strings.untitledTask : task.title,
      confirmLabel: strings.delete,
      cancelLabel: strings.cancel,
      destructive: true,
    );
    if (!ok) return;
    await ref.read(taskStoreProvider)?.delete(task.id);
    ref.invalidate(taskListProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final hasWorkspace = ref.watch(workspaceRootProvider) != null;
    final tasks = ref.watch(taskListProvider).value ?? const <TaskDoc>[];
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/menu')),
        title: Text(strings.tasks),
      ),
      floatingActionButton: hasWorkspace
          ? FloatingActionButton.extended(
              onPressed: () => _create(context, ref),
              icon: const Icon(Icons.add),
              label: Text(strings.newTask),
            )
          : null,
      body: !hasWorkspace
          ? EmptyState(
              icon: Icons.folder_off_outlined,
              title: strings.needWorkspace,
            )
          : tasks.isEmpty
              ? EmptyState(
                  icon: Icons.checklist_rtl_outlined,
                  title: strings.noTasks,
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                  itemCount: tasks.length,
                  itemBuilder: (context, i) {
                    final t = tasks[i];
                    final total = t.totalItems;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _open(context, ref, t.id),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t.title.isEmpty
                                          ? strings.untitledTask
                                          : t.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleMedium,
                                    ),
                                    if (total > 0) ...[
                                      const SizedBox(height: 8),
                                      LinearProgressIndicator(
                                        value: t.doneItems / total,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${t.doneItems}/$total',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              ItemMenuButton(
                                onEdit: () =>
                                    _open(context, ref, t.id, edit: true),
                                onDelete: () => _delete(context, ref, t),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
