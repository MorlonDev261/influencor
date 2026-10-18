import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/services/atomic_file.dart';
import '../domain/ledger.dart';
import '../domain/ledger_entry.dart';

/// Reads and writes `<root>/.clipboard/accounting.json` — the ledger lives in
/// the workspace folder, never in the app's own storage. Version 1 files (no
/// sheets) are read as one open sheet and upgraded on the next write.
class AccountingStore {
  AccountingStore(this.root);

  final String root;
  final _lock = AsyncMutex();

  File get _file => File(p.join(root, '.clipboard', 'accounting.json'));

  Future<Ledger> load() async {
    try {
      if (!await _file.exists()) return Ledger.empty();
      return Ledger.fromJson(
          jsonDecode(await _file.readAsString(encoding: utf8)));
    } catch (_) {
      return Ledger.empty();
    }
  }

  Future<Ledger> _mutate(Ledger Function(Ledger ledger) change) =>
      _lock.run(() async {
        final next = change(await load());
        await writeStringAtomic(
          _file,
          const JsonEncoder.withIndent('  ').convert(next.toJson()),
        );
        return next;
      });

  /// Inserts the entry into the open sheet, or replaces the one with the same
  /// id. Throws [LedgerSheetClosedError] for an entry of a closed sheet.
  Future<Ledger> upsert(LedgerEntry entry) =>
      _mutate((ledger) => ledger.upsert(entry));

  Future<Ledger> remove(String id) => _mutate((ledger) => ledger.remove(id));

  /// Closes the open sheet now and starts a new, empty one (balances carry
  /// over). Throws a [StateError] when the open sheet has no entries.
  Future<Ledger> closeCurrentSheet({DateTime? at}) => _mutate((ledger) => ledger
      .closeCurrent(at: at ?? DateTime.now(), newSheetId: const Uuid().v4()));
}
