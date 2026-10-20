import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/constants/app_constants.dart';
import '../../../core/l10n/app_strings.dart';

/// `/about`: what Influencor is, what it does, what it does with your data and
/// where its limits are — plus the entry to the professional (reseller) space.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    Widget section(String title, String body, {IconData? icon}) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 20, color: scheme.primary),
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: Text(title, style: text.titleMedium)),
                ],
              ),
              const SizedBox(height: 6),
              Text(body, style: text.bodyMedium),
            ],
          ),
        );

    Widget feature(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: scheme.primaryContainer,
                child: Icon(icon, size: 18, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleSmall),
                    const SizedBox(height: 2),
                    Text(body, style: text.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(s.aboutTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              children: [
                Center(
                  child: Column(
                    children: [
                      Image.asset(
                        'assets/icon/logo.png',
                        width: 96,
                        height: 96,
                        filterQuality: FilterQuality.medium,
                      ),
                      const SizedBox(height: 12),
                      Text(s.appName, style: text.headlineSmall),
                      const SizedBox(height: 4),
                      Text(
                        s.aboutVersion(AppConstants.version),
                        style: text.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        s.aboutTagline,
                        textAlign: TextAlign.center,
                        style: text.bodyLarge,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                section(s.aboutWhatTitle, s.aboutWhatBody,
                    icon: Icons.info_outline),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(s.aboutFeaturesTitle, style: text.titleMedium),
                ),
                feature(Icons.folder_copy_outlined, s.aboutFeatureLibraryTitle,
                    s.aboutFeatureLibraryBody),
                feature(Icons.search, s.aboutFeatureFindTitle,
                    s.aboutFeatureFindBody),
                feature(Icons.ios_share_outlined, s.aboutFeatureShareTitle,
                    s.aboutFeatureShareBody),
                feature(Icons.auto_fix_high_outlined,
                    s.aboutFeatureCleanerTitle, s.aboutFeatureCleanerBody),
                feature(Icons.assistant_outlined, s.aboutFeatureAssistantTitle,
                    s.aboutFeatureAssistantBody),
                const SizedBox(height: 6),
                section(s.aboutPrivacyTitle, s.aboutPrivacyBody,
                    icon: Icons.lock_outline),
                section(s.aboutCleanerFormatsTitle, s.aboutCleanerFormatsBody,
                    icon: Icons.perm_media_outlined),
                section(s.aboutLimitsTitle, s.aboutLimitsBody,
                    icon: Icons.rule_outlined),
                section(s.aboutLanguagesTitle, s.aboutLanguagesBody,
                    icon: Icons.language),
                const Divider(height: 32),
                Card(
                  elevation: 0,
                  color: scheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.storefront_outlined,
                                color: scheme.primary),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(s.aboutProTitle,
                                    style: text.titleMedium)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(s.aboutProBody, style: text.bodyMedium),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            key: const ValueKey('access-pro'),
                            onPressed: () => context.go('/pro'),
                            icon: const Icon(Icons.login),
                            label: Text(s.accessPro),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    'Powered by Morlon Rnd',
                    style: text.labelMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
