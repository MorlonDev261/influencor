import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/app_inputs.dart';
import '../../../core/l10n/app_strings.dart';
import '../../accounting/presentation/accounting_screen.dart' show formatAr;
import '../application/tariff_providers.dart';
import '../domain/mobile_money_fees.dart';
import 'operator_logo.dart';

class FeesScreen extends ConsumerStatefulWidget {
  const FeesScreen({super.key});

  @override
  ConsumerState<FeesScreen> createState() => _FeesScreenState();
}

class _FeesScreenState extends ConsumerState<FeesScreen> {
  static const _optimizer = FeeOptimizer();

  final _amount = TextEditingController();
  FeeKind _kind = FeeKind.withdraw;
  String? _operatorName;
  TransferTarget _target = TransferTarget.same;
  bool _app = false;

  /// The amount is the balance: fees are taken out of it.
  bool _feesIncluded = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    final tariffs = ref.watch(currentTariffsProvider);
    final operator = tariffs.firstWhere(
      (t) => t.name == _operatorName,
      orElse: () => tariffs.first,
    );
    final value = AppAmountField.parse(_amount.text);
    final valid = value != null && value > 0;
    final app = _app && operator.transferApp != null;
    final plan = !valid
        ? null
        : _feesIncluded
            ? _optimizer.planWithin(operator, _kind, value,
                target: _target, app: app)
            : _optimizer.plan(operator, _kind, value,
                target: _target, app: app);
    final others = tariffs
        .where((t) => t.name != operator.name)
        .map((t) => t.name)
        .join(' / ');
    final isTransfer = _kind == FeeKind.transfer;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/accounting'),
        ),
        title: Text(s.fees),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AppSectionLabel(s.feeOperator),
          AppChoiceChips<String>(
            options: [for (final t in tariffs) (t.name, t.name)],
            avatar: (name) => OperatorLogo(name, size: 20),
            selected: operator.name,
            onChanged: (name) => setState(() {
              _operatorName = name;
              if (tariffs.firstWhere((t) => t.name == name).transferApp ==
                  null) {
                _app = false;
              }
            }),
          ),
          if (!operator.official)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(s.feeEstimated,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 12),
          SegmentedButton<FeeKind>(
            segments: [
              ButtonSegment(
                  value: FeeKind.withdraw, label: Text(s.feeWithdraw)),
              ButtonSegment(
                  value: FeeKind.transfer, label: Text(s.feeTransfer)),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          if (isTransfer) ...[
            const SizedBox(height: 12),
            AppSectionLabel(s.feeTo),
            SegmentedButton<TransferTarget>(
              segments: [
                ButtonSegment(
                    value: TransferTarget.same, label: Text(operator.name)),
                ButtonSegment(value: TransferTarget.other, label: Text(others)),
              ],
              selected: {_target},
              onSelectionChanged: (v) => setState(() => _target = v.first),
            ),
            if (_target == TransferTarget.same &&
                operator.transferApp != null) ...[
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(s.feeChannelUssd)),
                  ButtonSegment(value: true, label: Text(s.feeChannelApp)),
                ],
                selected: {_app},
                onSelectionChanged: (v) => setState(() => _app = v.first),
              ),
            ],
          ],
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.feeIncludeFees),
            subtitle: _feesIncluded ? Text(s.feeIncludeFeesHint) : null,
            value: _feesIncluded,
            onChanged: (v) => setState(() => _feesIncluded = v),
          ),
          AppAmountField(
            controller: _amount,
            label: _feesIncluded ? s.feeBalance : s.amount,
            hint: s.example('50 000'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          if (valid && plan == null)
            Text(s.feeNoPlan, style: TextStyle(color: theme.colorScheme.error)),
          if (plan != null)
            _PlanCard(
              plan: plan,
              best: true,
              strings: s,
              balance: _feesIncluded ? value : null,
            ),
          const SizedBox(height: 8),
          Text(s.feeUnverified, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.best,
    required this.strings,
    this.balance,
  });

  final FeePlan plan;
  final bool best;
  final AppStrings strings;

  /// Set when fees are included: the balance the plan was fitted into.
  final int? balance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final withdraw = plan.kind == FeeKind.withdraw;
    final debited = plan.amount + plan.totalFee;
    return Card(
      color: best ? scheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                OperatorLogo(plan.operator, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(plan.operator,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
                if (best)
                  Chip(
                    label: Text(strings.feeBest),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            // Splitting wins: show what the direct operation would cost first.
            if (plan.isSplit && plan.directFee != null) ...[
              const SizedBox(height: 6),
              Text(
                '${withdraw ? strings.feeDirectWithdraw : strings.feeDirectTransfer}'
                ' : ${formatAr(plan.directFee!)}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            if (balance != null) ...[
              const SizedBox(height: 6),
              Text(
                '${withdraw ? strings.feeNetWithdraw : strings.feeNetTransfer}'
                ' : ${formatAr(plan.amount)}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              '${strings.feeTotal}: ${formatAr(plan.totalFee)}'
              ' · ${plan.isSplit ? strings.feeSplit : strings.feeDirect}',
              style: theme.textTheme.titleLarge,
            ),
            if (plan.isSplit) ...[
              const SizedBox(height: 4),
              Text(strings.feeOps(plan.operationCount),
                  style: theme.textTheme.labelLarge),
              for (final p in plan.parts)
                Text(p.count > 1
                    ? '${p.count} × ${formatAr(p.amount)} : ${formatAr(p.fee)}'
                    : '${formatAr(p.amount)} : ${formatAr(p.fee)}'),
              if (plan.savings > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    strings.feeSaves(formatAr(plan.savings)),
                    style: TextStyle(
                      color: Colors.green.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Text('${strings.feeDebited} : ${formatAr(debited)}',
                style: theme.textTheme.bodyMedium),
            if (balance != null && balance! > debited)
              Text('${strings.feeLeft} : ${formatAr(balance! - debited)}',
                  style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
