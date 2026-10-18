import 'package:uuid/uuid.dart';

import '../../../accounting/application/accounting_providers.dart';
import '../../../accounting/domain/ledger.dart';
import '../../../accounting/domain/ledger_entry.dart';
import '../../../fees/application/tariff_providers.dart';
import '../../../fees/domain/mobile_money_fees.dart';
import '../../../search/application/entry_search.dart';
import '../../../tasks/application/task_providers.dart';
import '../../../tasks/data/task_store.dart';
import '../../../tasks/domain/task_doc.dart';
import '../agent_tool.dart';

const _uuid = Uuid();

// --- Tasks -------------------------------------------------------------------

TaskStore _tasks(AgentToolContext ctx) {
  ctx.root; // friendly error without a workspace
  return ctx.ref.read(taskStoreProvider)!;
}

Future<TaskDoc> _task(AgentToolContext ctx, String id) async {
  final task = await _tasks(ctx).load(id);
  if (task == null) throw ToolError('Tâche introuvable : $id');
  return task;
}

Map<String, Object?> _taskJson(TaskDoc t, {bool full = false}) => {
      'id': t.id,
      'title': t.title,
      'done': t.doneItems,
      'total': t.totalItems,
      'updated': t.updatedAt.toIso8601String(),
      if (full)
        'blocks': [
          for (final b in t.blocks)
            b.kind == TaskBlockKind.text
                ? {'type': 'text', 'text': b.text}
                : {
                    'type': 'checklist',
                    'title': b.text,
                    'items': [
                      for (final i in b.items)
                        {'id': i.id, 'text': i.text, 'done': i.done},
                    ],
                  },
        ],
    };

/// Finds checklist items by id or by (accent-insensitive) text.
Iterable<ChecklistItem> _items(TaskDoc t, List<String> keys) sync* {
  for (final b in t.blocks) {
    for (final i in b.items) {
      if (keys.any((k) =>
          k == i.id ||
          foldForSearch(k.trim()) == foldForSearch(i.text.trim()))) {
        yield i;
      }
    }
  }
}

// --- Accounting --------------------------------------------------------------

T? _enum<T extends Enum>(List<T> values, String? name) {
  if (name == null) return null;
  final n = name.replaceAll(RegExp(r'[\s_-]'), '').toLowerCase();
  for (final v in values) {
    if (v.name.toLowerCase() == n) return v;
  }
  throw ToolError('Valeur inconnue : $name (attendu : '
      '${values.map((v) => v.name).join(', ')})');
}

DateTime? _date(String? s) {
  if (s == null) return null;
  final d = DateTime.tryParse(s.trim());
  if (d == null) throw ToolError('Date invalide : $s (format AAAA-MM-JJ)');
  return d;
}

Map<String, Object?> _ledgerJson(LedgerEntry e) => {
      'id': e.id,
      'date': e.date.toIso8601String().substring(0, 10),
      'amount': e.amount,
      'signed_amount': e.signedAmount,
      'account': e.account.name,
      'type': e.type.name,
      'direction': e.direction.name,
      if (e.note.isNotEmpty) 'note': e.note,
    };

Future<Ledger> _ledger(AgentToolContext ctx) async {
  ctx.root;
  return ctx.ref.read(ledgerProvider.future);
}

Map<String, Object?> _sheetJson(Ledger ledger, LedgerSheet s) {
  final t = ledger.totalsOf(s.id);
  return {
    'id': s.id,
    'status': s.isOpen ? 'open' : 'closed',
    'start': s.start.toIso8601String(),
    if (s.end != null) 'end': s.end!.toIso8601String(),
    'entries': t.count,
    'total_credit': t.credit,
    'total_debit': t.debit,
    'opening_balance': t.openingTotal,
    'closing_balance': t.closingTotal,
  };
}

/// The sheet asked for: the open one by default, `all` for none.
LedgerSheet? _sheet(Ledger ledger, ToolArgs a) {
  final id = a.optStr('sheet')?.trim();
  if (id == null || id.isEmpty || id == 'current') return ledger.current;
  if (id == 'all') return null;
  final sheet = ledger.sheetById(id);
  if (sheet == null) throw ToolError('Feuille introuvable : $id');
  return sheet;
}

LedgerEntry _editable(Ledger ledger, String id) {
  final old = ledger.entries.where((e) => e.id == id).firstOrNull;
  if (old == null) throw ToolError('Opération introuvable : $id');
  if (ledger.isClosedEntry(old)) {
    throw ToolError('Opération $id dans une feuille clôturée (lecture seule).');
  }
  return old;
}

Iterable<LedgerEntry> _filter(List<LedgerEntry> all, ToolArgs a) {
  final from = _date(a.optStr('from'));
  final to = _date(a.optStr('to'));
  final account = _enum(LedgerAccount.values, a.optStr('account'));
  final type = _enum(LedgerType.values, a.optStr('type'));
  final q = a.optStr('query');
  return all.where((e) =>
      (from == null || !e.date.isBefore(from)) &&
      (to == null || e.date.isBefore(to.add(const Duration(days: 1)))) &&
      (account == null || e.account == account) &&
      (type == null || e.type == type) &&
      (q == null || foldForSearch(e.note).contains(foldForSearch(q))));
}

final _accounts = [for (final v in LedgerAccount.values) v.name];
final _types = [for (final v in LedgerType.values) v.name];

final _ledgerFilters = {
  'from': sStr('Date de début incluse (AAAA-MM-JJ).'),
  'to': sStr('Date de fin incluse (AAAA-MM-JJ).'),
  'account': sStr('Compte.', values: _accounts),
  'type': sStr('Type.', values: _types),
  'query': sStr('Texte recherché dans la note.'),
  'sheet': sStr('Feuille comptable : "current" (défaut, la feuille en cours), '
      '"all" (toutes) ou un id de list_ledger_sheets.'),
};

// --- Fees --------------------------------------------------------------------

Map<String, Object?> _planJson(FeePlan plan) => {
      'operator': plan.operator,
      'total_fee': plan.totalFee,
      'direct_fee': plan.directFee,
      'operations': plan.operationCount,
      'savings_vs_direct': plan.savings,
      'split': [
        for (final part in plan.parts)
          {'amount': part.amount, 'fee': part.fee, 'count': part.count},
      ],
    };

List<AgentTool> productivityTools() => [
      // Tasks
      AgentTool(
        name: 'list_tasks',
        label: 'Tâches',
        description:
            'Liste les tâches (id, titre, progression des cases cochées).',
        run: (a, ctx) async => [
          for (final t in await _tasks(ctx).loadAll()) _taskJson(t),
        ],
      ),
      AgentTool(
        name: 'get_task',
        label: 'Lecture de la tâche',
        description: "Contenu complet d'une tâche : blocs de texte et listes à "
            'cocher (avec les ids des cases).',
        properties: {'id': sStr('Id de la tâche.')},
        required: ['id'],
        run: (a, ctx) async =>
            _taskJson(await _task(ctx, a.str('id')), full: true),
      ),
      AgentTool(
        name: 'create_task',
        label: 'Création de la tâche',
        description: 'Crée une tâche avec un texte et/ou une liste à cocher.',
        properties: {
          'title': sStr('Titre.'),
          'text': sStr('Description libre (optionnelle).'),
          'checklist_title': sStr('Titre de la liste à cocher (optionnel).'),
          'items': sStrList('Cases à cocher (optionnelles).'),
        },
        required: ['title'],
        run: (a, ctx) async {
          final task = TaskDoc(id: _uuid.v4(), title: a.str('title'), blocks: [
            if (a.optStr('text') != null)
              TaskBlock(
                  id: _uuid.v4(),
                  kind: TaskBlockKind.text,
                  text: a.str('text')),
            if (a.strings('items').isNotEmpty)
              TaskBlock(
                id: _uuid.v4(),
                kind: TaskBlockKind.checklist,
                text: a.text('checklist_title'),
                items: [
                  for (final t in a.strings('items'))
                    ChecklistItem(id: _uuid.v4(), text: t),
                ],
              ),
          ]);
          await _tasks(ctx).save(task);
          ctx.ref.invalidate(taskListProvider);
          return _taskJson(task, full: true);
        },
      ),
      AgentTool(
        name: 'update_task',
        label: 'Modification de la tâche',
        description:
            'Modifie une tâche : titre, ajout de texte, ajout de cases, '
            'cocher / décocher / retirer des cases (par id ou par texte exact).',
        properties: {
          'id': sStr('Id de la tâche.'),
          'title': sStr('Nouveau titre.'),
          'append_text': sStr('Texte ajouté dans un nouveau bloc.'),
          'add_items': sStrList('Cases ajoutées à la dernière liste.'),
          'check': sStrList('Cases à cocher (id ou texte).'),
          'uncheck': sStrList('Cases à décocher (id ou texte).'),
          'remove_items': sStrList('Cases à retirer (id ou texte).'),
        },
        required: ['id'],
        run: (a, ctx) async {
          final task = await _task(ctx, a.str('id'));
          if (a.optStr('title') != null) task.title = a.str('title');
          if (a.optStr('append_text') != null) {
            task.blocks.add(TaskBlock(
                id: _uuid.v4(),
                kind: TaskBlockKind.text,
                text: a.str('append_text')));
          }
          if (a.strings('add_items').isNotEmpty) {
            final list = task.blocks.lastWhere(
              (b) => b.kind == TaskBlockKind.checklist,
              orElse: () {
                final b =
                    TaskBlock(id: _uuid.v4(), kind: TaskBlockKind.checklist);
                task.blocks.add(b);
                return b;
              },
            );
            list.items.addAll([
              for (final t in a.strings('add_items'))
                ChecklistItem(id: _uuid.v4(), text: t),
            ]);
          }
          for (final i in _items(task, a.strings('check'))) {
            i.done = true;
          }
          for (final i in _items(task, a.strings('uncheck'))) {
            i.done = false;
          }
          final remove = _items(task, a.strings('remove_items')).toSet();
          for (final b in task.blocks) {
            b.items.removeWhere(remove.contains);
          }
          await _tasks(ctx).save(task);
          ctx.ref.invalidate(taskListProvider);
          return _taskJson(task, full: true);
        },
      ),
      AgentTool(
        name: 'delete_task',
        label: 'Suppression de la tâche',
        description: 'Supprime définitivement une tâche.',
        properties: {'id': sStr('Id de la tâche.')},
        required: ['id'],
        confirm: (a, ctx) =>
            'Supprimer définitivement la tâche ${a.str('id')} ?',
        run: (a, ctx) async {
          final task = await _task(ctx, a.str('id'));
          await _tasks(ctx).delete(task.id);
          ctx.ref.invalidate(taskListProvider);
          return {'deleted': task.title};
        },
      ),

      // Accounting
      AgentTool(
        name: 'list_transactions',
        label: 'Comptabilité',
        description: 'Liste les opérations comptables (montants en Ariary), '
            'les plus récentes d’abord, avec filtres. Par défaut : la feuille '
            'en cours seulement.',
        properties: {
          ..._ledgerFilters,
          'limit': sInt('Maximum renvoyé (défaut 100).'),
        },
        run: (a, ctx) async {
          final ledger = await _ledger(ctx);
          final sheet = _sheet(ledger, a);
          final list = _filter(
                  sheet == null ? ledger.entries : ledger.entriesOf(sheet.id),
                  a)
              .toList();
          final limit = (a.optInt('limit') ?? 100).clamp(1, 1000);
          return {
            if (sheet != null) 'sheet': _sheetJson(ledger, sheet),
            'total': list.length,
            'entries': [for (final e in list.take(limit)) _ledgerJson(e)],
          };
        },
      ),
      AgentTool(
        name: 'accounting_summary',
        label: 'Bilan comptable',
        description: 'Bilan (Ariary) de la feuille en cours par défaut : '
            'mouvements par compte, total des ventes, achats et dépenses, '
            'résultat net, et pour une feuille son solde reporté et son solde '
            'disponible par compte.',
        properties: _ledgerFilters,
        run: (a, ctx) async {
          final ledger = await _ledger(ctx);
          final sheet = _sheet(ledger, a);
          final list = _filter(
                  sheet == null ? ledger.entries : ledger.entriesOf(sheet.id),
                  a)
              .toList();
          final totals = sheet == null ? null : ledger.totalsOf(sheet.id);
          return {
            if (sheet != null) 'sheet': _sheetJson(ledger, sheet),
            if (totals != null) ...{
              'opening_balance_by_account': {
                for (final acc in LedgerAccount.values)
                  acc.name: totals.opening[acc],
              },
              'available_balance_by_account': {
                for (final acc in LedgerAccount.values)
                  acc.name: totals.closing[acc],
              },
            },
            'entries': list.length,
            'balance_by_account': {
              for (final acc in LedgerAccount.values)
                acc.name: list
                    .where((e) => e.account == acc)
                    .fold<int>(0, (s, e) => s + e.signedAmount),
            },
            'total_by_type': {
              for (final t in LedgerType.values)
                t.name: list
                    .where((e) => e.type == t)
                    .fold<int>(0, (s, e) => s + e.amount),
            },
            'net': list.fold<int>(0, (s, e) => s + e.signedAmount),
          };
        },
      ),
      AgentTool(
        name: 'add_transaction',
        label: 'Nouvelle opération',
        description: 'Ajoute une opération comptable à la feuille en cours. '
            'Le sens par défaut : vente = entrée (credit), achat/dépense = '
            'sortie (debit).',
        properties: {
          'amount': sInt('Montant positif en Ariary.'),
          'account': sStr('Compte.', values: _accounts),
          'type': sStr('Type.', values: _types),
          'direction': sStr('Sens (optionnel).', values: ['credit', 'debit']),
          'date': sStr("Date AAAA-MM-JJ (défaut aujourd'hui)."),
          'note': sStr('Libellé.'),
        },
        required: ['amount', 'account', 'type'],
        run: (a, ctx) async {
          await _ledger(ctx);
          final type = _enum(LedgerType.values, a.str('type'))!;
          final amount = a.int_('amount').abs();
          if (amount == 0) throw const ToolError('Montant nul.');
          final entry = LedgerEntry(
            id: _uuid.v4(),
            date: _date(a.optStr('date')) ?? DateTime.now(),
            amount: amount,
            account: _enum(LedgerAccount.values, a.str('account'))!,
            type: type,
            direction: _enum(LedgerDirection.values, a.optStr('direction')) ??
                type.defaultDirection,
            note: a.text('note'),
          );
          await ctx.ref.read(ledgerProvider.notifier).save(entry);
          return {'added': _ledgerJson(entry)};
        },
      ),
      AgentTool(
        name: 'update_transaction',
        label: 'Modification de l’opération',
        description: 'Modifie une opération comptable existante (par id). '
            'Les opérations des feuilles clôturées sont en lecture seule.',
        properties: {
          'id': sStr('Id de l’opération.'),
          'amount': sInt('Montant positif en Ariary.'),
          'account': sStr('Compte.', values: _accounts),
          'type': sStr('Type.', values: _types),
          'direction': sStr('Sens.', values: ['credit', 'debit']),
          'date': sStr('Date AAAA-MM-JJ.'),
          'note': sStr('Libellé.'),
        },
        required: ['id'],
        run: (a, ctx) async {
          final old = _editable(await _ledger(ctx), a.str('id'));
          final entry = LedgerEntry(
            id: old.id,
            date: _date(a.optStr('date')) ?? old.date,
            amount: a.optInt('amount')?.abs() ?? old.amount,
            account:
                _enum(LedgerAccount.values, a.optStr('account')) ?? old.account,
            type: _enum(LedgerType.values, a.optStr('type')) ?? old.type,
            direction: _enum(LedgerDirection.values, a.optStr('direction')) ??
                old.direction,
            note: a.has('note') ? a.text('note') : old.note,
          );
          await ctx.ref.read(ledgerProvider.notifier).save(entry);
          return {'updated': _ledgerJson(entry)};
        },
      ),
      AgentTool(
        name: 'delete_transaction',
        label: 'Suppression de l’opération',
        description: 'Supprime définitivement une opération comptable.',
        properties: {'id': sStr('Id de l’opération.')},
        required: ['id'],
        confirm: (a, ctx) =>
            "Supprimer définitivement l'opération comptable ${a.str('id')} ?",
        run: (a, ctx) async {
          final old = _editable(await _ledger(ctx), a.str('id'));
          await ctx.ref.read(ledgerProvider.notifier).remove(old.id);
          return {'deleted': _ledgerJson(old)};
        },
      ),
      AgentTool(
        name: 'list_ledger_sheets',
        label: 'Feuilles comptables',
        description: 'Liste les feuilles comptables, la plus récente d’abord : '
            'la feuille en cours (open) et les feuilles clôturées (closed, '
            'lecture seule) avec dates de début / fin, totaux crédit / débit, '
            'solde reporté et solde de clôture (Ariary).',
        run: (a, ctx) async {
          final ledger = await _ledger(ctx);
          return {
            'sheets': [
              for (final s in ledger.sheets.reversed) _sheetJson(ledger, s),
            ],
          };
        },
      ),
      AgentTool(
        name: 'close_ledger_sheet',
        label: 'Clôture de la feuille',
        description: 'Clôture la feuille comptable en cours maintenant (elle '
            'passe en lecture seule) et démarre une nouvelle feuille vide, avec '
            'le solde reporté. Seulement si l’utilisateur le demande.',
        confirm: (a, ctx) => 'Clôturer la feuille comptable en cours '
            'maintenant et en commencer une nouvelle ?',
        run: (a, ctx) async {
          final ledger = await _ledger(ctx);
          if (!ledger.canClose) {
            throw const ToolError(
                'La feuille en cours est vide : rien à clôturer.');
          }
          final closed =
              await ctx.ref.read(ledgerProvider.notifier).closeCurrentSheet();
          final next = await _ledger(ctx);
          return {
            if (closed != null) 'closed': _sheetJson(next, closed),
            'current': _sheetJson(next, next.current),
          };
        },
      ),

      // Mobile-money fees
      AgentTool(
        name: 'mobile_money_fees',
        label: 'Calcul des frais',
        description:
            'Calcule les frais mobile money (Madagascar : MVola, Orange Money, '
            'Airtel Money…) pour un retrait ou un transfert, et la façon la moins '
            'chère de découper le montant. Sans opérateur : compare tous.',
        properties: {
          'amount': sInt('Montant en Ariary.'),
          'operation':
              sStr('Type d’opération.', values: ['withdraw', 'transfer']),
          'operator': sStr('Opérateur (optionnel).'),
          'to_other_operator': sBool('Transfert vers un autre opérateur.'),
          'via_app':
              sBool("Transfert fait depuis l'application de l'opérateur."),
        },
        required: ['amount', 'operation'],
        run: (a, ctx) async {
          final tariffs = await ctx.ref.read(tariffsProvider.future);
          final kind = a.str('operation') == 'withdraw'
              ? FeeKind.withdraw
              : FeeKind.transfer;
          final target = a.flag('to_other_operator')
              ? TransferTarget.other
              : TransferTarget.same;
          final amount = a.int_('amount');
          final op = a.optStr('operator');
          final chosen = op == null
              ? tariffs
              : tariffs
                  .where(
                      (t) => foldForSearch(t.name).contains(foldForSearch(op)))
                  .toList();
          if (chosen.isEmpty) {
            throw ToolError('Opérateur inconnu : $op (connus : '
                '${tariffs.map((t) => t.name).join(', ')})');
          }
          const optimizer = FeeOptimizer();
          final plans = [
            for (final t in chosen)
              optimizer.plan(t, kind, amount,
                  target: target, app: a.flag('via_app')),
          ].whereType<FeePlan>().toList()
            ..sort((x, y) => x.totalFee.compareTo(y.totalFee));
          return {
            'amount': amount,
            'operation': kind.name,
            'plans': [for (final pl in plans) _planJson(pl)],
            if (plans.isEmpty) 'note': 'Montant hors des grilles tarifaires.',
          };
        },
      ),
      AgentTool(
        name: 'list_fee_tariffs',
        label: 'Grilles tarifaires',
        description: 'Grilles de frais mobile money utilisées (par tranche).',
        run: (a, ctx) async => [
          for (final t in await ctx.ref.read(tariffsProvider.future))
            t.toJson(),
        ],
      ),
    ];
