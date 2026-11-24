import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/app_strings.dart';
import '../../core/providers/settings_providers.dart';
import '../../core/services/update_gate_service.dart';

final updateGateServiceProvider =
    Provider<UpdateGateService>((ref) => UpdateGateService());

/// Minimum-version check, run once per launch.
final updateGateProvider = FutureProvider<UpdateGateStatus>(
  (ref) => ref.watch(updateGateServiceProvider).check(),
);

/// Shows [child] unless this build is older than the minimum the website
/// allows, in which case a full-screen "update required" page replaces the
/// whole app. While the check runs (or if it fails) the app opens normally.
class UpdateGate extends ConsumerWidget {
  const UpdateGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(updateGateProvider).value;
    if (status == null || !status.mustUpdate) return child;
    return ForceUpdateScreen(status: status);
  }
}

class ForceUpdateScreen extends ConsumerWidget {
  const ForceUpdateScreen({super.key, required this.status});

  final UpdateGateStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStringsProvider);
    final lang = ref.watch(settingsProvider).languageCode;
    final theme = Theme.of(context);
    final url = status.updateUrl;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/icon/logo.png', width: 72, height: 72),
                  const SizedBox(height: 24),
                  Text(
                    s.updateRequiredTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    status.messageFor(lang) ?? s.updateRequiredBody,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 28),
                  if (url != null)
                    FilledButton.icon(
                      icon: const Icon(Icons.system_update_alt),
                      label: Text(s.updateNow),
                      onPressed: () => launchUrl(
                        Uri.parse(url),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  TextButton(
                    onPressed: () => ref.invalidate(updateGateProvider),
                    child: Text(s.updateCheckAgain),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
