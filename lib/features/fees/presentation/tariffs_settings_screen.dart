import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/app_dialog.dart';
import '../../../core/l10n/app_strings.dart';
import '../application/tariff_providers.dart';
import '../domain/mobile_money_fees.dart';
import 'operator_logo.dart';
import 'tariff_editor_screen.dart';

/// Settings page listing the operators; tap one to edit its grids.
class TariffsSettingsScreen extends ConsumerWidget {
  const TariffsSettingsScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final s = ref.read(appStringsProvider);
    final name = await showTextPromptDialog(
      context,
      title: s.feeAddOperator,
      label: s.feeOperatorName,
      confirmLabel: s.add,
      cancelLabel: s.cancel,
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || !context.mounted) return;
    final exists =
        ref.read(currentTariffsProvider).any((t) => t.name == trimmed);
    if (exists) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.feeNameTaken)));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TariffEditorScreen(
        tariff: OperatorTariff(
          name: trimmed,
          withdraw: const [],
          transfer: const [],
          official: false,
        ),
        isNew: true,
      ),
    ));
  }

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final s = ref.read(appStringsProvider);
    final ok = await showConfirmDialog(
      context,
      title: s.feeResetDefaults,
      message: s.feeResetConfirm,
      confirmLabel: s.feeResetDefaults,
      cancelLabel: s.cancel,
      destructive: true,
    );
    if (ok) await ref.read(tariffsProvider.notifier).resetToDefaults();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStringsProvider);
    final tariffs = ref.watch(currentTariffsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.feeTariffs),
        actions: [
          PopupMenuButton<void>(
            itemBuilder: (_) => [
              PopupMenuItem(
                onTap: () => _reset(context, ref),
                child: Text(s.feeResetDefaults),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.add),
        label: Text(s.feeAddOperator),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          for (final t in tariffs)
            ListTile(
              leading: OperatorLogo(t.name, size: 32),
              title: Text(t.name),
              subtitle: t.official ? null : Text(s.feeEstimatedTag),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => TariffEditorScreen(tariff: t),
              )),
            ),
        ],
      ),
    );
  }
}
