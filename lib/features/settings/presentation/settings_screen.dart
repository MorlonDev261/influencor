import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/app_inputs.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/picker/pick_workspace.dart';
import '../../../core/providers/settings_providers.dart';
import '../../../core/providers/workspace_providers.dart';
import '../../../shared/enums/enums.dart';
import '../../assistant/application/assistant_providers.dart';
import '../../assistant/presentation/assistant_settings_screen.dart';
import '../../fees/presentation/tariffs_settings_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _changeWorkspace(BuildContext context, WidgetRef ref) =>
      pickWorkspaceWithFeedback(context, ref,
          title: ref.read(appStringsProvider).changeWorkspace);

  Future<void> _editGlobalSeparator(
    BuildContext context,
    WidgetRef ref,
    String? current,
  ) async {
    final strings = ref.read(appStringsProvider);
    final controller = TextEditingController(text: current ?? '');
    const resetValue = '__reset_separator__';
    const cancelValue = '__cancel_separator__';
    final result = await showAppDialog<String>(
      context,
      builder: (context) => AppDialog(
        title: strings.noteSeparator,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTextField(
              controller: controller,
              autofocus: true,
              label: strings.customSeparator,
              hint: '########',
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '########   [ ----- ]',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, cancelValue),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, resetValue),
            child: Text(strings.defaultSeparator),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(strings.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result == cancelValue) return;
    await ref
        .read(settingsControllerProvider.notifier)
        .setNoteSeparator(result == resetValue ? null : result);
  }

  /// "Claude (Anthropic) · claude-opus-5-5", or a hint while not connected.
  String _assistantSubtitle(WidgetRef ref, AppStrings strings) {
    final config = ref.watch(assistantConfigProvider);
    if (config.isReady) return '${config.provider.label} · ${config.model}';
    return ref.watch(deganyEnvProvider).userModels
        ? strings.assistantSettingsHint
        : strings.deganyManagedMissing;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final root = ref.watch(workspaceRootProvider);
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/menu')),
        title: Text(strings.settings),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                _SectionHeader(strings.workspaceFolder),
                ListTile(
                  leading: const Icon(Icons.folder_open),
                  title: Text(strings.workspaceFolder),
                  subtitle: Text(root ?? '—'),
                ),
                ListTile(
                  leading: const Icon(Icons.drive_folder_upload_outlined),
                  title: Text(strings.changeWorkspace),
                  onTap: () => _changeWorkspace(context, ref),
                ),
                const Divider(),
                _SectionHeader(strings.appearance),
                ListTile(
                  leading: const Icon(Icons.brightness_6_outlined),
                  title: Text(strings.theme),
                  trailing: DropdownButton<ThemeMode>(
                    value: settings.themeMode,
                    onChanged: (m) =>
                        m == null ? null : controller.setThemeMode(m),
                    items: [
                      DropdownMenuItem(
                          value: ThemeMode.system,
                          child: Text(strings.themeSystem)),
                      DropdownMenuItem(
                          value: ThemeMode.light,
                          child: Text(strings.themeLight)),
                      DropdownMenuItem(
                          value: ThemeMode.dark,
                          child: Text(strings.themeDark)),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.grid_view_outlined),
                  title: Text(strings.defaultView),
                  trailing: DropdownButton<ViewMode>(
                    value: settings.viewMode,
                    onChanged: (v) =>
                        v == null ? null : controller.setViewMode(v),
                    items: [
                      DropdownMenuItem(
                          value: ViewMode.grid, child: Text(strings.viewGrid)),
                      DropdownMenuItem(
                          value: ViewMode.list, child: Text(strings.viewList)),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.language),
                  title: Text(strings.language),
                  trailing: DropdownButton<String>(
                    value: settings.languageCode,
                    onChanged: (c) =>
                        c == null ? null : controller.setLanguage(c),
                    items: [
                      DropdownMenuItem(
                          value: 'mg', child: Text(strings.malagasy)),
                      DropdownMenuItem(
                          value: 'fr', child: Text(strings.french)),
                      DropdownMenuItem(
                          value: 'en', child: Text(strings.english)),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.splitscreen_outlined),
                  title: Text(strings.noteSeparator),
                  subtitle:
                      Text(settings.noteSeparator ?? strings.defaultSeparator),
                  onTap: () => _editGlobalSeparator(
                      context, ref, settings.noteSeparator),
                ),
                const Divider(),
                ListTile(
                  key: const ValueKey('settings-assistant'),
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: Text(strings.assistantSettings),
                  subtitle: Text(_assistantSubtitle(ref, strings)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const AssistantSettingsScreen()),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.price_change_outlined),
                  title: Text(strings.feeTariffs),
                  subtitle: Text(strings.feeTariffsHint),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const TariffsSettingsScreen()),
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(strings.appName),
                  subtitle: const Text('Influencor'),
                  onTap: () => context.go('/about'),
                  trailing: IconButton(
                    key: const ValueKey('about-help'),
                    tooltip: strings.aboutTitle,
                    icon: const Icon(Icons.help_outline),
                    onPressed: () => context.go('/about'),
                  ),
                ),
              ],
            ),
          ),
          const _CreatorCredit(),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

class _CreatorCredit extends StatelessWidget {
  const _CreatorCredit();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.favorite_border_rounded,
              color: scheme.primary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text('Powered by Morlon Rnd', style: textStyle),
          ],
        ),
      ),
    );
  }
}
