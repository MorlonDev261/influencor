import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/providers/settings_providers.dart';
import '../data/reseller_config.dart';
import '../data/reseller_web_controller.dart';

/// The reseller site inside the app, with a thin progress bar and an offline /
/// error panel. [controller] is owned by the caller (so it can load deep links,
/// reload and handle the system back button).
class ResellerWebView extends ConsumerWidget {
  const ResellerWebView({required this.controller, super.key});

  final ResellerWebController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    // The site follows the app's theme (the effective one, so « system » is
    // resolved here); rebuilt whenever that theme changes.
    final brightness = Theme.of(context).brightness;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => controller.setTheme(brightness));
    return Stack(
      children: [
        WebViewWidget(controller: controller.web),
        ValueListenableBuilder<int>(
          valueListenable: controller.progress,
          builder: (context, p, _) => p >= 100
              ? const SizedBox.shrink()
              : LinearProgressIndicator(value: p <= 0 ? null : p / 100),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: controller.error,
          builder: (context, failed, _) {
            if (!failed) return const SizedBox.shrink();
            return ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_outlined, size: 48),
                      const SizedBox(height: 12),
                      Text(strings.resellerOfflineTitle,
                          style: Theme.of(context).textTheme.titleMedium,
                          textAlign: TextAlign.center),
                      const SizedBox(height: 6),
                      Text(strings.resellerOfflineBody,
                          textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: controller.reload,
                        icon: const Icon(Icons.refresh),
                        label: Text(strings.retry),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Shown where the WebView plugin does not exist (Windows, Linux, web): the
/// reseller space opens in the system browser instead.
class ResellerBrowserFallback extends ConsumerWidget {
  const ResellerBrowserFallback({required this.uri, super.key});

  final Uri uri;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.open_in_browser, size: 48),
            const SizedBox(height: 12),
            Text(strings.resellerUnsupportedBody, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () =>
                  launchUrl(uri, mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new),
              label: Text(strings.resellerOpenInBrowser),
            ),
          ],
        ),
      ),
    );
  }
}

bool get resellerWebViewSupported => ResellerConfig.webViewSupported;

/// The site's theme button changes the app's theme too (an explicit light /
/// dark choice, like picking it in the settings).
void setAppThemeFromSite(WidgetRef ref, Brightness brightness) {
  unawaited(ref.read(settingsControllerProvider.notifier).setThemeMode(
      brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light));
}
