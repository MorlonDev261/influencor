import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/widgets/app_inputs.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/providers/edit_mode_provider.dart';
import '../../../core/providers/workspace_providers.dart';
import '../../../core/widgets/empty_state.dart';
import '../application/accounting_providers.dart';
import '../domain/ledger.dart';
import '../domain/ledger_entry.dart';
import 'ledger_chart.dart';
import 'ledger_format.dart';

export 'ledger_format.dart';

extension on LedgerType {
  String text(AppStrings s) => switch (this) {
        LedgerType.purchase => s.purchase,
        LedgerType.sale => s.sale,
        LedgerType.expense => s.expense,
      };
}

extension on LedgerAccount {
  String text(AppStrings s) => this == LedgerAccount.cash ? s.cash : label;
}

class AccountingScreen extends ConsumerStatefulWidget {
  const AccountingScreen({super.key});

  @override
  ConsumerState<AccountingScreen> createState() => _AccountingScreenState();
}

class _AccountingScreenState extends ConsumerState<AccountingScreen> {
  LedgerAccount? _filter;

  /// The sheet on screen; null follows the open (current) sheet.
  String? _sheetId;

  Future<void> _openEditor({LedgerEntry? entry, bool readOnly = false}) async {
    final strings = ref.read(appStringsProvider);
    final editing = ref.read(editModeProvider);
    final result = await showAppDialog<_EditorResult>(
      context,
      builder: (_) => _EntryDialog(
        entry: entry,
        strings: strings,
        startEditing: !readOnly && (entry == null || editing),
        readOnly: readOnly,
      ),
    );
    if (result == null) return;
    final controller = ref.read(ledgerProvider.notifier);
    if (result.delete) {
      await controller.remove(entry!.id);
    } else {
      await controller.save(result.entry!);
    }
  }

  Future<void> _closeSheet(Ledger ledger) async {
    final s = ref.read(appStringsProvider);
    final now = DateTime.now();
    final ok = await showConfirmDialog(
      context,
      title: s.closeSheetTitle,
      message: s.closeSheetMessage(
        formatDate(ledger.current.start),
        '${formatDate(now)} ${formatTime(now)}',
        formatAr(ledger.totalsOf(ledger.current.id).closingTotal),
      ),
      confirmLabel: s.closeSheetShort,
      cancelLabel: s.cancel,
      confirmKey: const ValueKey('ledger-close-confirm'),
    );
    if (!ok || !mounted) return;
    final closed = await ref.read(ledgerProvider.notifier).closeCurrentSheet();
    if (!mounted || closed == null) return;
    setState(() => _sheetId = null);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s.sheetClosed)));
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final hasWorkspace = ref.watch(workspaceRootProvider) != null;
    final editing = ref.watch(editModeProvider);
    final ledger = ref.watch(ledgerProvider).value ?? Ledger.empty();
    final sheet = ledger.sheetById(_sheetId) ?? ledger.current;
    final isCurrent = sheet.isOpen;
    final entries = ledger.entriesOf(sheet.id);
    final totals = ledger.totalsOf(sheet.id);
    final shown = _filter == null
        ? entries
        : entries.where((e) => e.account == _filter).toList();

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/menu')),
        title: Text(strings.accounting),
        actions: [
          IconButton(
            key: const ValueKey('ledger-fees'),
            tooltip: 'Deganeo',
            icon: const Icon(Icons.currency_exchange_rounded),
            onPressed: () => context.push('/fees'),
          ),
          if (hasWorkspace) const EditModeButton(),
        ],
      ),
      floatingActionButton: hasWorkspace && editing && isCurrent
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: Text(strings.newTransaction),
            )
          : null,
      body: !hasWorkspace
          ? EmptyState(
              icon: Icons.folder_off_outlined,
              title: strings.needWorkspace,
            )
          : LayoutBuilder(builder: (context, constraints) {
              final width = constraints.maxWidth;
              final wide = width >= 840;
              // Centre the content on large screens instead of stretching it.
              final side = math.max(16.0, (width - 1080) / 2);
              final balance = _BalanceCard(
                strings: strings,
                totals: totals,
                isCurrent: isCurrent,
                showOpening: ledger.sheets.first.id != sheet.id,
              );
              final hasChart = shown.isNotEmpty;
              final chart = LedgerChartCard(
                entries: shown,
                strings: strings,
                from: sheet.start,
                to: sheet.end ?? DateTime.now(),
                height: wide ? 200 : 170,
              );
              return CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(side, 12, side, 4),
                    sliver: SliverList.list(
                      children: [
                        _SheetBar(
                          strings: strings,
                          ledger: ledger,
                          sheet: sheet,
                          canEdit: editing,
                          onSelect: (id) => setState(() =>
                              _sheetId = id == ledger.current.id ? null : id),
                          onClose: () => _closeSheet(ledger),
                        ),
                        const SizedBox(height: 12),
                        if (wide && hasChart)
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(flex: 2, child: balance),
                                const SizedBox(width: 12),
                                Expanded(flex: 3, child: chart),
                              ],
                            ),
                          )
                        else ...[
                          balance,
                          if (hasChart) ...[
                            const SizedBox(height: 12),
                            chart,
                          ],
                        ],
                      ],
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 52,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.symmetric(
                            horizontal: side - 4, vertical: 6),
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: ChoiceChip(
                              label: Text(strings.all),
                              selected: _filter == null,
                              onSelected: (_) => setState(() => _filter = null),
                            ),
                          ),
                          for (final a in LedgerAccount.values)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: ChoiceChip(
                                label: Text(a.text(strings)),
                                selected: _filter == a,
                                onSelected: (_) => setState(() => _filter = a),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (shown.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        icon: Icons.account_balance_wallet_outlined,
                        title: strings.noTransactions,
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(side - 16, 0, side - 16, 88),
                      sliver: SliverList.separated(
                        itemCount: shown.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) => _EntryTile(
                          entry: shown[i],
                          strings: strings,
                          onTap: () => _openEditor(
                              entry: shown[i], readOnly: !isCurrent),
                        ),
                      ),
                    ),
                ],
              );
            }),
    );
  }
}

/// Which sheet is on screen, the sheet history and the "close" action.
class _SheetBar extends StatelessWidget {
  const _SheetBar({
    required this.strings,
    required this.ledger,
    required this.sheet,
    required this.canEdit,
    required this.onSelect,
    required this.onClose,
  });

  final AppStrings strings;
  final Ledger ledger;
  final LedgerSheet sheet;
  final bool canEdit;
  final ValueChanged<String> onSelect;
  final VoidCallback onClose;

  String _period(LedgerSheet s) => s.isOpen
      ? strings.sheetSince(formatDate(s.start))
      : strings.sheetPeriod(formatDate(s.start), formatDate(s.end!));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = strings;
    final isCurrent = sheet.isOpen;
    final count = ledger.entriesOf(sheet.id).length;
    final history = ledger.sheets.length > 1
        ? PopupMenuButton<String>(
            key: const ValueKey('ledger-sheets'),
            tooltip: s.sheetHistory,
            icon: const Icon(Icons.history_rounded),
            onSelected: onSelect,
            itemBuilder: (_) => [
              for (final item in ledger.sheets.reversed)
                PopupMenuItem(
                  value: item.id,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(item.isOpen
                        ? Icons.edit_note_rounded
                        : Icons.lock_outline_rounded),
                    title: Text(item.isOpen ? s.currentSheet : _period(item)),
                    subtitle: Text(
                      '${s.sheetEntries(ledger.entriesOf(item.id).length)}'
                      ' · ${formatAr(ledger.totalsOf(item.id).closingTotal)}',
                    ),
                    trailing: item.id == sheet.id
                        ? Icon(Icons.check_rounded, color: scheme.primary)
                        : null,
                  ),
                ),
            ],
          )
        : null;

    Widget? action;
    if (!isCurrent) {
      action = TextButton.icon(
        key: const ValueKey('ledger-back-current'),
        onPressed: () => onSelect(ledger.current.id),
        icon: const Icon(Icons.undo_rounded, size: 18),
        label: Text(s.currentSheet),
      );
    } else if (canEdit) {
      action = Tooltip(
        message: ledger.canClose ? s.closeSheet : s.closeSheetNeedsEntry,
        child: FilledButton.tonalIcon(
          key: const ValueKey('ledger-close-sheet'),
          onPressed: ledger.canClose ? onClose : null,
          icon: const Icon(Icons.event_available_rounded, size: 18),
          label: Text(s.closeSheetShort),
        ),
      );
    }

    final heading = Row(
      children: [
        Icon(
          isCurrent ? Icons.edit_note_rounded : Icons.lock_outline_rounded,
          color: isCurrent ? scheme.primary : scheme.onTertiaryContainer,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isCurrent ? s.currentSheet : s.sheetReadOnly,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                '${_period(sheet)} · ${s.sheetEntries(count)}',
                key: const ValueKey('ledger-sheet-period'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );

    return Container(
      key: const ValueKey('ledger-sheet-bar'),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: isCurrent
            ? scheme.surfaceContainerHigh
            : scheme.tertiaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      // Phones: the action button goes under the title instead of squeezing it.
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 440 && action != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(child: heading),
                    if (history != null) history,
                  ]),
                  Align(alignment: Alignment.centerRight, child: action),
                ],
              )
            : Row(
                children: [
                  Expanded(child: heading),
                  if (action != null) ...[const SizedBox(width: 8), action],
                  if (history != null) history,
                ],
              ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.strings,
    required this.totals,
    required this.isCurrent,
    required this.showOpening,
  });

  final AppStrings strings;
  final LedgerSheetTotals totals;
  final bool isCurrent;
  final bool showOpening;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final balance = totals.closingTotal;
    final small =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            isCurrent ? strings.availableBalance : strings.closingBalance,
            style: theme.textTheme.labelLarge
                ?.copyWith(color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              formatAr(balance),
              key: const ValueKey('ledger-balance'),
              style: theme.textTheme.headlineMedium?.copyWith(
                color: balance < 0 ? scheme.error : scheme.onPrimaryContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (showOpening)
            Text(
              '${strings.openingBalance} : ${formatAr(totals.openingTotal)}',
              key: const ValueKey('ledger-opening'),
              style: small,
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              for (final a in LedgerAccount.values)
                Text('${a.text(strings)}: ${formatAr(totals.closing[a]!)}',
                    style: small),
            ],
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.strings,
    required this.onTap,
  });

  final LedgerEntry entry;
  final AppStrings strings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final e = entry;
    final credit = e.direction == LedgerDirection.credit;
    final color = credit ? scheme.ledgerCredit : scheme.ledgerDebit;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(
          credit ? Icons.south_west_rounded : Icons.north_east_rounded,
          color: color,
        ),
      ),
      title: Text(
        e.note.isEmpty ? e.type.text(strings) : e.note,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${formatDate(e.date)} · ${e.type.text(strings)}'
        ' · ${e.account.text(strings)}',
      ),
      trailing: Text(
        '${credit ? '+' : '-'}${formatAr(e.amount)}',
        style: theme.textTheme.titleSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EditorResult {
  const _EditorResult.save(LedgerEntry this.entry) : delete = false;
  const _EditorResult.remove()
      : entry = null,
        delete = true;

  final LedgerEntry? entry;
  final bool delete;
}

class _EntryDialog extends StatefulWidget {
  const _EntryDialog({
    required this.entry,
    required this.strings,
    required this.startEditing,
    this.readOnly = false,
  });

  final LedgerEntry? entry;
  final AppStrings strings;
  final bool startEditing;

  /// Entry of a closed sheet: details only, no edit button.
  final bool readOnly;

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  late LedgerDirection _direction;
  late LedgerType _type;
  late LedgerAccount _account;
  late DateTime _date;
  late final TextEditingController _amount;
  late final TextEditingController _note;
  bool _amountInvalid = false;
  late bool _editing;

  @override
  void initState() {
    super.initState();
    _editing = widget.startEditing;
    final e = widget.entry;
    _type = e?.type ?? LedgerType.sale;
    _direction = e?.direction ?? _type.defaultDirection;
    _account = e?.account ?? LedgerAccount.cash;
    _date = e?.date ?? DateTime.now();
    _amount = TextEditingController(text: e == null ? '' : '${e.amount}');
    _note = TextEditingController(text: e?.note ?? '');
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _submit() {
    final amount = AppAmountField.parse(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _amountInvalid = true);
      return;
    }
    Navigator.pop(
      context,
      _EditorResult.save(LedgerEntry(
        id: widget.entry?.id ?? const Uuid().v4(),
        date: _date,
        amount: amount,
        account: _account,
        type: _type,
        direction: _direction,
        note: _note.text.trim(),
      )),
    );
  }

  Widget _detailRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelMedium),
            Text(value, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      );

  Widget _buildReadOnly(AppStrings s) {
    final e = widget.entry!;
    final credit = e.direction == LedgerDirection.credit;
    return AppDialog(
      title: e.type.text(s),
      titleActions: [
        if (!widget.readOnly)
          IconButton(
            key: const ValueKey('ledger-dialog-edit'),
            tooltip: s.edit,
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => setState(() => _editing = true),
          ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _detailRow(s.amount, '${credit ? '+' : '-'}${formatAr(e.amount)}'),
          _detailRow(s.account, e.account.text(s)),
          _detailRow(s.date, formatDate(e.date)),
          if (e.note.isNotEmpty) _detailRow(s.note, e.note),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.closeAction),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    if (!_editing) return _buildReadOnly(s);
    return AppDialog(
      title: widget.entry == null ? s.newTransaction : s.editTransaction,
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<LedgerDirection>(
              segments: [
                ButtonSegment(
                    value: LedgerDirection.credit, label: Text(s.credit)),
                ButtonSegment(
                    value: LedgerDirection.debit, label: Text(s.debit)),
              ],
              selected: {_direction},
              onSelectionChanged: (v) => setState(() => _direction = v.first),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<LedgerType>(
              initialValue: _type,
              decoration: InputDecoration(labelText: s.type),
              items: [
                for (final t in LedgerType.values)
                  DropdownMenuItem(value: t, child: Text(t.text(s))),
              ],
              onChanged: (t) {
                if (t == null) return;
                setState(() {
                  _type = t;
                  _direction = t.defaultDirection;
                });
              },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<LedgerAccount>(
              initialValue: _account,
              decoration: InputDecoration(labelText: s.account),
              items: [
                for (final a in LedgerAccount.values)
                  DropdownMenuItem(value: a, child: Text(a.text(s))),
              ],
              onChanged: (a) => setState(() => _account = a ?? _account),
            ),
            const SizedBox(height: 8),
            AppAmountField(
              controller: _amount,
              label: s.amount,
              hint: s.example('25 000'),
              errorText: _amountInvalid ? s.invalidAmount : null,
              onChanged: (_) {
                if (_amountInvalid) setState(() => _amountInvalid = false);
              },
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: _pickDate,
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: s.date,
                  suffixIcon: const Icon(Icons.calendar_today_outlined),
                ),
                child: Text(formatDate(_date)),
              ),
            ),
            const SizedBox(height: 8),
            AppTextField(
              controller: _note,
              minLines: 1,
              maxLines: 3,
              label: s.note,
            ),
          ],
        ),
      ),
      actions: [
        if (widget.entry != null)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, const _EditorResult.remove()),
            child: Text(s.delete),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(s.save)),
      ],
    );
  }
}
