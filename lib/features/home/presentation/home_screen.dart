import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/app_header_title.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/picker/pick_workspace.dart';
import '../../../core/providers/workspace_providers.dart';
import '../../../shared/enums/enums.dart';
import '../../library/presentation/browse_screen.dart';
import '../../reseller/application/reseller_providers.dart';
import '../../reseller/presentation/reseller_home.dart';

/// Home tab: shows the working folder directly (its contents + the Add button)
/// once a workspace is chosen, or the workspace picker otherwise.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _pickWorkspace(BuildContext context, WidgetRef ref) =>
      pickWorkspaceWithFeedback(context, ref,
          title: ref.read(appStringsProvider).chooseWorkspace);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final workspace = ref.watch(workspaceControllerProvider);

    // "reseller" mode: the whole home is the reseller space.
    if (ref.watch(appModeProvider) == AppMode.reseller) {
      return const ResellerHome();
    }

    return workspace.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(
          toolbarHeight: ref.watch(modeBadgeVisibleProvider)
              ? AppHeaderTitle.heightWithBadge
              : null,
          title: const AppHeaderTitle(showModeBadge: true),
        ),
        body: Center(child: Text(strings.genericError)),
      ),
      data: (root) {
        if (root == null) {
          return Scaffold(
            appBar: AppBar(
              toolbarHeight: ref.watch(modeBadgeVisibleProvider)
                  ? AppHeaderTitle.heightWithBadge
                  : null,
              title: const AppHeaderTitle(showModeBadge: true),
            ),
            body: _ChooseWorkspace(onPick: () => _pickWorkspace(context, ref)),
          );
        }
        // The working folder IS the home view: add/import/drag & drop happen
        // directly here, on the current (root) folder.
        return BrowseScreen(dirPath: root, showBack: false);
      },
    );
  }
}

class _ChooseWorkspace extends ConsumerWidget {
  const _ChooseWorkspace({required this.onPick});

  final VoidCallback onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Image.asset(
              'assets/icon/logo.png',
              width: 160,
              height: 160,
              filterQuality: FilterQuality.medium,
            ),
            const SizedBox(height: 24),
            Text(strings.chooseWorkspace,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(strings.workspaceIntro,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.drive_folder_upload_outlined),
              label: Text(strings.chooseWorkspace),
            ),
          ],
        ),
      ),
    );
  }
}
