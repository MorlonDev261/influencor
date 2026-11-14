import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:influencor/core/l10n/app_strings.dart';
import 'package:influencor/core/providers/workspace_providers.dart';
import 'package:influencor/features/accounting/application/accounting_providers.dart';
import 'package:influencor/features/accounting/domain/ledger.dart';
import 'package:influencor/features/accounting/domain/ledger_entry.dart';
import 'package:influencor/features/accounting/presentation/accounting_screen.dart';
import 'package:influencor/features/tasks/application/task_providers.dart';
import 'package:influencor/features/tasks/data/task_store.dart';
import 'package:influencor/features/tasks/domain/task_doc.dart';
import 'package:influencor/features/tasks/presentation/task_editor_screen.dart';
import 'package:influencor/features/tasks/presentation/tasks_screen.dart';

const _fr = AppStrings(Locale('fr'));

/// Tasks kept in memory, so the screens never touch the disk.
class _MemoryTasks extends TaskStore {
  _MemoryTasks(List<TaskDoc> tasks)
      : tasks = {for (final t in tasks) t.id: t},
        super('/workspace');

  final Map<String, TaskDoc> tasks;

  @override
  Future<TaskDoc?> load(String id) async => tasks[id];
  @override
  Future<List<TaskDoc>> loadAll() async => tasks.values.toList();
  @override
  Future<void> save(TaskDoc task) async => tasks[task.id] = task;
  @override
  Future<void> delete(String id) async => tasks.remove(id);
}

class _MemoryLedger extends LedgerController {
  _MemoryLedger(this.initial);
  final Ledger initial;

  @override
  Future<Ledger> build() async => initial;
  @override
  Future<void> save(LedgerEntry entry) async =>
      state = AsyncData((await future).upsert(entry));
  @override
  Future<void> remove(String id) async =>
      state = AsyncData((await future).remove(id));
}

void main() {
  group('tasks', () {
    late _MemoryTasks store;

    Future<void> pump(WidgetTester tester) async {
      store = _MemoryTasks([
        TaskDoc(id: 't1', title: 'Shooting robe', blocks: [
          TaskBlock(
            id: 'b1',
            kind: TaskBlockKind.checklist,
            text: 'Matériel',
            items: [ChecklistItem(id: 'i1', text: 'Trépied')],
          ),
        ]),
      ]);
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (_, __) => const TasksScreen()),
        GoRoute(
          path: '/task/edit',
          builder: (_, state) => TaskEditorScreen(
            taskId: state.uri.queryParameters['id']!,
            startEditing: state.uri.queryParameters['edit'] == '1',
          ),
        ),
      ]);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          appStringsProvider.overrideWithValue(_fr),
          workspaceRootProvider.overrideWithValue('/workspace'),
          taskStoreProvider.overrideWithValue(store),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();
    }

    void expectView() {
      expect(find.byKey(const ValueKey('task-title-view')), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const ValueKey('task-edit-bar')), findsNothing);
      expect(find.text(_fr.addChecklist), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    }

    void expectEdit() {
      expect(find.byKey(const ValueKey('task-edit-bar')), findsOneWidget);
      expect(find.text(_fr.editTask), findsOneWidget);
      expect(find.byKey(const ValueKey('task-title-field')), findsOneWidget);
      expect(find.text(_fr.addItem), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    }

    testWidgets('no edit toggle on the list; the add button is there',
        (tester) async {
      await pump(tester);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.text(_fr.newTask), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    });

    testWidgets('tapping a task opens it to read, with an edit button',
        (tester) async {
      await pump(tester);
      await tester.tap(find.text('Shooting robe'));
      await tester.pumpAndSettle();
      expectView();
      // Items can be ticked in the read view.
      await tester.tap(find.text('Trépied'));
      await tester.pump();
      expect(store.tasks['t1']!.blocks.first.items.first.done, isTrue);

      await tester.tap(find.byKey(const ValueKey('task-edit-toggle')));
      await tester.pump();
      expectEdit();
      await tester.tap(find.text(_fr.done));
      await tester.pump();
      expectView();
    });

    testWidgets('⋮ › Modifier opens it ready to edit', (tester) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_fr.edit));
      await tester.pumpAndSettle();
      expectEdit();
    });

    testWidgets('⋮ › Supprimer asks, then deletes', (tester) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_fr.delete));
      await tester.pumpAndSettle();
      expect(find.text(_fr.deleteTaskQuestion), findsOneWidget);
      await tester.tap(find.text(_fr.delete).last);
      await tester.pumpAndSettle();
      expect(store.tasks, isEmpty);
      expect(find.text('Shooting robe'), findsNothing);
    });
  });

  group('accounting', () {
    final entry = LedgerEntry(
      id: 'e1',
      date: DateTime(2026, 11, 2),
      amount: 25000,
      account: LedgerAccount.mvola,
      type: LedgerType.sale,
      direction: LedgerDirection.credit,
      note: 'Robe wax',
    );

    Future<ProviderContainer> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          appStringsProvider.overrideWithValue(_fr),
          workspaceRootProvider.overrideWithValue('/workspace'),
          ledgerProvider.overrideWith(() => _MemoryLedger(Ledger(
                sheets: [LedgerSheet(id: 's1', start: DateTime(2026, 11, 1))],
                entries: [entry],
              ))),
        ],
        child: const MaterialApp(home: AccountingScreen()),
      ));
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(
          tester.element(find.byType(AccountingScreen)));
    }

    testWidgets('add and close buttons show without any edit toggle',
        (tester) async {
      await pump(tester);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byKey(const ValueKey('ledger-close-sheet')), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
    });

    testWidgets('tapping an entry shows it, with an edit button',
        (tester) async {
      await pump(tester);
      await tester.tap(find.text('Robe wax'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ledger-dialog-edit')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('ledger-detail-amount')), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('⋮ › Modifier opens the form', (tester) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_fr.edit));
      await tester.pumpAndSettle();
      expect(find.text(_fr.editTransaction), findsOneWidget);
    });

    testWidgets('⋮ › Supprimer asks, then deletes', (tester) async {
      final container = await pump(tester);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_fr.delete));
      await tester.pumpAndSettle();
      expect(find.text(_fr.deleteTransactionQuestion), findsOneWidget);
      await tester.tap(find.text(_fr.delete).last);
      await tester.pumpAndSettle();
      expect(container.read(ledgerProvider).value!.entries, isEmpty);
      expect(find.text(_fr.noTransactions), findsOneWidget);
    });
  });
}
