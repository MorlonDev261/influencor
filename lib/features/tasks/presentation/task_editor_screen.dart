import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/l10n/app_strings.dart';
import '../application/task_providers.dart';
import '../data/task_store.dart';
import '../domain/task_doc.dart';

/// One task's own page: a title plus any number of text blocks and
/// checklists. Two distinct looks:
/// - the read view (default): plain text and items to tick, nothing to type;
/// - the edit mode (pencil): tinted bar "Edit task" with "Done", input boxes,
///   outlined blocks with their delete button, and the add buttons.
/// Every change is saved (debounced) to the task's JSON file.
class TaskEditorScreen extends ConsumerStatefulWidget {
  const TaskEditorScreen({
    required this.taskId,
    this.startEditing = false,
    super.key,
  });

  final String taskId;

  /// Opened from "Edit" (or a new task): fields editable straight away.
  /// Otherwise the task is shown to read and tick, with an edit button.
  final bool startEditing;

  @override
  ConsumerState<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends ConsumerState<TaskEditorScreen> {
  static const _uuid = Uuid();

  TaskStore? _store;
  TaskDoc? _task;
  bool _loaded = false;
  bool _dirty = false;
  late bool _editing = widget.startEditing;
  Timer? _debounce;
  final _titleController = TextEditingController();
  final _controllers = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _store = ref.read(taskStoreProvider);
    _load();
  }

  Future<void> _load() async {
    final task = await _store?.load(widget.taskId);
    if (!mounted) return;
    setState(() {
      _task = task;
      _loaded = true;
      _titleController.text = task?.title ?? '';
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_dirty) _flush();
    _titleController.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controller(String id, String initial) =>
      _controllers.putIfAbsent(id, () => TextEditingController(text: initial));

  void _changed() {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _flush);
  }

  void _flush() {
    final task = _task;
    if (task == null) return;
    _dirty = false;
    _store?.save(task);
  }

  void _mutate(VoidCallback change) {
    setState(change);
    _changed();
  }

  void _addBlock(TaskBlockKind kind) => _mutate(() {
        _task!.blocks.add(TaskBlock(
          id: _uuid.v4(),
          kind: kind,
          items: kind == TaskBlockKind.checklist
              ? [ChecklistItem(id: _uuid.v4())]
              : null,
        ));
      });

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final task = _task;
    final editing = _editing;

    void back() => context.canPop() ? context.pop() : context.go('/task');
    void toggle() {
      FocusScope.of(context).unfocus();
      setState(() => _editing = !_editing);
    }

    if (_loaded && task == null) {
      return Scaffold(
        appBar: AppBar(leading: BackButton(onPressed: back)),
        body: Center(child: Text(strings.noTasks)),
      );
    }

    final total = task?.totalItems ?? 0;
    final progress = total == 0
        ? null
        : PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(value: task!.doneItems / total),
          );

    // Edit mode: tinted bar with its own title and a "Done" button, so it
    // never looks like the read view.
    final appBar = editing
        ? AppBar(
            key: const ValueKey('task-edit-bar'),
            backgroundColor: scheme.secondaryContainer,
            foregroundColor: scheme.onSecondaryContainer,
            leading: BackButton(onPressed: back),
            title: Text(strings.editTask),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  key: const ValueKey('task-edit-toggle'),
                  onPressed: toggle,
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(strings.done),
                ),
              ),
            ],
            bottom: progress,
          )
        : AppBar(
            leading: BackButton(onPressed: back),
            title: Text(strings.tasks),
            actions: [
              IconButton(
                key: const ValueKey('task-edit-toggle'),
                tooltip: strings.edit,
                icon: const Icon(Icons.edit_outlined),
                onPressed: toggle,
              ),
            ],
            bottom: progress,
          );

    if (task == null) {
      return Scaffold(
        appBar: appBar,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final blocks = <Widget>[
      for (final block in task.blocks)
        if (editing)
          block.kind == TaskBlockKind.text
              ? _TextBlockEditor(
                  key: ValueKey(block.id),
                  strings: strings,
                  controller: _controller(block.id, block.text),
                  onChanged: (v) {
                    block.text = v;
                    _changed();
                  },
                  onDelete: () => _mutate(() => task.blocks.remove(block)),
                )
              : _ChecklistEditor(
                  key: ValueKey(block.id),
                  strings: strings,
                  block: block,
                  controller: _controller,
                  onChanged: _changed,
                  mutate: _mutate,
                  onAddItem: () => _mutate(
                      () => block.items.add(ChecklistItem(id: _uuid.v4()))),
                  onDelete: () => _mutate(() => task.blocks.remove(block)),
                )
        else if (block.kind == TaskBlockKind.text)
          _TextBlockView(key: ValueKey(block.id), text: block.text)
        else
          _ChecklistView(
            key: ValueKey(block.id),
            block: block,
            onToggle: (item) => _mutate(() => item.done = !item.done),
          ),
    ];
    final emptyView = !editing &&
        task.blocks.every((b) =>
            b.text.trim().isEmpty &&
            b.items.every((i) => i.text.trim().isEmpty));

    return Scaffold(
      appBar: appBar,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [
          if (editing)
            TextField(
              key: const ValueKey('task-title-field'),
              controller: _titleController,
              style: theme.textTheme.titleLarge,
              decoration: _editField(context, strings.taskTitle,
                  label: strings.taskTitle),
              onChanged: (v) {
                task.title = v;
                _changed();
              },
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                task.title.isEmpty ? strings.untitledTask : task.title,
                key: const ValueKey('task-title-view'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: task.title.isEmpty ? scheme.onSurfaceVariant : null,
                ),
              ),
            ),
          SizedBox(height: editing ? 16 : 12),
          ...blocks,
          if (emptyView)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  Icon(Icons.notes, size: 40, color: scheme.outline),
                  const SizedBox(height: 8),
                  Text(strings.emptyTask,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: toggle,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: Text(strings.edit),
                  ),
                ],
              ),
            ),
          if (editing) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _addBlock(TaskBlockKind.text),
                  icon: const Icon(Icons.notes),
                  label: Text(strings.addTextBlock),
                ),
                OutlinedButton.icon(
                  onPressed: () => _addBlock(TaskBlockKind.checklist),
                  icon: const Icon(Icons.checklist),
                  label: Text(strings.addChecklist),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Field of the edit mode: a visible, filled box, so what can be typed in
/// is obvious.
InputDecoration _editField(BuildContext context, String hint,
    {String? label, bool dense = false}) {
  final scheme = Theme.of(context).colorScheme;
  final radius = BorderRadius.circular(10);
  final none =
      OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none);
  return InputDecoration(
    hintText: hint,
    labelText: label,
    filled: true,
    fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
    isDense: dense,
    contentPadding:
        EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 10 : 14),
    border: none,
    enabledBorder: none,
    focusedBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: scheme.primary, width: 1.5),
    ),
  );
}

/// Block frame of the edit mode: outlined, with a header naming the block
/// and its delete button.
class _EditFrame extends StatelessWidget {
  const _EditFrame({
    required this.icon,
    required this.label,
    required this.deleteTooltip,
    required this.onDelete,
    required this.child,
  });

  final IconData icon;
  final String label;
  final String deleteTooltip;
  final VoidCallback onDelete;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 2, 2, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: scheme.primary)),
              ),
              IconButton(
                tooltip: deleteTooltip,
                icon: Icon(Icons.delete_outline, color: scheme.error),
                onPressed: onDelete,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _TextBlockEditor extends StatelessWidget {
  const _TextBlockEditor({
    required this.strings,
    required this.controller,
    required this.onChanged,
    required this.onDelete,
    super.key,
  });

  final AppStrings strings;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => _EditFrame(
        icon: Icons.notes,
        label: strings.addTextBlock,
        deleteTooltip: strings.deleteBlock,
        onDelete: onDelete,
        child: TextField(
          controller: controller,
          minLines: 3,
          maxLines: null,
          decoration: _editField(context, strings.textHint),
          onChanged: onChanged,
        ),
      );
}

class _ChecklistEditor extends StatelessWidget {
  const _ChecklistEditor({
    required this.strings,
    required this.block,
    required this.controller,
    required this.onChanged,
    required this.mutate,
    required this.onAddItem,
    required this.onDelete,
    super.key,
  });

  final AppStrings strings;
  final TaskBlock block;
  final TextEditingController Function(String id, String initial) controller;
  final VoidCallback onChanged;
  final void Function(VoidCallback change) mutate;
  final VoidCallback onAddItem;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _EditFrame(
      icon: Icons.checklist,
      label: strings.addChecklist,
      deleteTooltip: strings.deleteBlock,
      onDelete: onDelete,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller(block.id, block.text),
            style: theme.textTheme.titleMedium,
            decoration: _editField(context, strings.checklistTitleHint),
            onChanged: (v) {
              block.text = v;
              onChanged();
            },
          ),
          const SizedBox(height: 8),
          for (final item in block.items)
            Padding(
              key: ValueKey(item.id),
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Checkbox(
                    value: item.done,
                    onChanged: (v) => mutate(() => item.done = v ?? false),
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller(item.id, item.text),
                      decoration:
                          _editField(context, strings.itemHint, dense: true),
                      onChanged: (v) {
                        item.text = v;
                        onChanged();
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: strings.delete,
                    iconSize: 20,
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => mutate(() => block.items.remove(item)),
                  ),
                ],
              ),
            ),
          TextButton.icon(
            onPressed: onAddItem,
            icon: const Icon(Icons.add),
            label: Text(strings.addItem),
          ),
        ],
      ),
    );
  }
}

/// Read view of a text block: plain, selectable text; nothing when empty.
class _TextBlockView extends StatelessWidget {
  const _TextBlockView({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
      child: SelectableText(
        text,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5),
      ),
    );
  }
}

/// Read view of a checklist: its title and items to tick, nothing to type.
class _ChecklistView extends StatelessWidget {
  const _ChecklistView({
    required this.block,
    required this.onToggle,
    super.key,
  });

  final TaskBlock block;
  final ValueChanged<ChecklistItem> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = block.items.where((i) => i.text.trim().isNotEmpty).toList();
    final title = block.text.trim();
    if (title.isEmpty && items.isEmpty) return const SizedBox.shrink();
    final done = items.where((i) => i.done).length;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(title,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (items.isNotEmpty)
                    Text('$done/${items.length}',
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            for (final item in items)
              InkWell(
                key: ValueKey(item.id),
                onTap: () => onToggle(item),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: item.done,
                        onChanged: (_) => onToggle(item),
                      ),
                      Expanded(
                        child: Text(
                          item.text,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            decoration:
                                item.done ? TextDecoration.lineThrough : null,
                            color: item.done ? scheme.onSurfaceVariant : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
