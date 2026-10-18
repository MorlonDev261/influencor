import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/workspace_providers.dart';
import '../data/accounting_store.dart';
import '../domain/ledger.dart';
import '../domain/ledger_entry.dart';

final accountingStoreProvider = Provider<AccountingStore?>((ref) {
  final root = ref.watch(workspaceRootProvider);
  return root == null ? null : AccountingStore(root);
});

/// The ledger: its sheets and entries (newest first).
class LedgerController extends AsyncNotifier<Ledger> {
  @override
  Future<Ledger> build() async {
    final store = ref.watch(accountingStoreProvider);
    if (store == null) return Ledger.empty();
    return store.load();
  }

  /// Adds the entry to the open sheet or updates it in place. Throws
  /// [LedgerSheetClosedError] for an entry of a closed sheet.
  Future<void> save(LedgerEntry entry) async {
    final store = ref.read(accountingStoreProvider);
    if (store == null) return;
    state = AsyncData(await store.upsert(entry));
  }

  Future<void> remove(String id) async {
    final store = ref.read(accountingStoreProvider);
    if (store == null) return;
    state = AsyncData(await store.remove(id));
  }

  /// Closes the open sheet now and opens a new one; returns the closed sheet.
  /// Does nothing (null) when the open sheet has no entries yet.
  Future<LedgerSheet?> closeCurrentSheet() async {
    final store = ref.read(accountingStoreProvider);
    if (store == null) return null;
    final ledger = await future;
    if (!ledger.canClose) return null;
    final closed = ledger.current.id;
    final next = await store.closeCurrentSheet();
    state = AsyncData(next);
    return next.sheetById(closed);
  }
}

final ledgerProvider =
    AsyncNotifierProvider<LedgerController, Ledger>(LedgerController.new);
