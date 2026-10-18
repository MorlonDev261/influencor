import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/features/accounting/data/accounting_store.dart';
import 'package:influencor/features/accounting/domain/ledger_entry.dart';
import 'package:influencor/features/tasks/data/task_store.dart';
import 'package:influencor/features/tasks/domain/task_doc.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('ledger_test'));
  tearDown(() => root.deleteSync(recursive: true));

  test('ledger persists in the workspace and balance follows direction',
      () async {
    final store = AccountingStore(root.path);
    await store.upsert(LedgerEntry(
      id: 'a',
      date: DateTime(2026, 10, 4),
      amount: 10000,
      account: LedgerAccount.mvola,
      type: LedgerType.sale,
      direction: LedgerDirection.credit,
      note: 'vente',
    ));
    await store.upsert(LedgerEntry(
      id: 'b',
      date: DateTime(2026, 10, 5),
      amount: 2500,
      account: LedgerAccount.cash,
      type: LedgerType.expense,
      direction: LedgerDirection.debit,
    ));
    final reloaded = await AccountingStore(root.path).load();
    expect(reloaded.entries.fold<int>(0, (s, e) => s + e.signedAmount), 7500);
    expect(
        File(p.join(root.path, '.clipboard', 'accounting.json')).existsSync(),
        isTrue);

    await store.remove('a');
    expect((await store.load()).entries.single.id, 'b');
  });

  test('each task is its own JSON file with text and checklist blocks',
      () async {
    final store = TaskStore(root.path);
    final task = TaskDoc(id: 't1', title: 'Guide EI', blocks: [
      TaskBlock(id: 'b1', kind: TaskBlockKind.text, text: 'Intro'),
      TaskBlock(
          id: 'b2',
          kind: TaskBlockKind.checklist,
          text: 'Étape 1',
          items: [
            ChecklistItem(id: 'i1', text: 'CIN', done: true),
            ChecklistItem(id: 'i2', text: 'Résidence'),
          ]),
    ]);
    await store.save(task);
    await store.save(TaskDoc(id: 't2', title: 'Autre'));

    final loaded = await store.load('t1');
    expect(loaded!.title, 'Guide EI');
    expect(loaded.doneItems, 1);
    expect(loaded.totalItems, 2);
    expect((await store.loadAll()).length, 2);
    expect(
        File(p.join(root.path, '.clipboard', 'tasks', 't1.json')).existsSync(),
        isTrue);

    await store.delete('t1');
    expect(await store.load('t1'), isNull);
  });
}
