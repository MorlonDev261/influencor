import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/providers/settings_providers.dart';
import '../../../shared/enums/enums.dart';
import '../data/reseller_config.dart';
import '../data/reseller_web_controller.dart';
import 'reseller_web_view.dart';

/// "Accès professionnel": opens https://reseller.poma-original.com/about (the
/// reseller program page) inside the app; the user signs in from there. When
/// the site reports that a session now exists, the hidden `reseller` flag is
/// stored and the app switches to the reseller space.
class ResellerLoginScreen extends ConsumerStatefulWidget {
  const ResellerLoginScreen({super.key});

  @override
  ConsumerState<ResellerLoginScreen> createState() =>
      _ResellerLoginScreenState();
}

class _ResellerLoginScreenState extends ConsumerState<ResellerLoginScreen> {
  ResellerWebController? _web;
  var _done = false;

  @override
  void initState() {
    super.initState();
    if (ResellerConfig.webViewSupported) {
      _web = ResellerWebController(
        initial: ResellerConfig.aboutUri,
        onSession: _onSession,
        onBackToClipboard: () => context.go('/'),
        onThemeChange: (b) => setAppThemeFromSite(ref, b),
      );
    }
  }

  @override
  void dispose() {
    _web?.dispose();
    super.dispose();
  }

  Future<void> _onSession(bool authenticated) async {
    if (!authenticated || _done || !mounted) return;
    _done = true;
    final strings = ref.read(appStringsProvider);
    final settings = ref.read(settingsControllerProvider.notifier);
    await settings.setReseller(true);
    await settings.setAppMode(AppMode.reseller);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(strings.resellerSessionCreated)));
    context.go('/');
  }

  Future<void> _back() async {
    final web = _web;
    if (web != null && await web.goBack()) return;
    if (mounted) context.go('/about');
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final web = _web;
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(strings.accessPro),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => context.go('/about'),
          ),
        ),
        body: web == null
            ? ResellerBrowserFallback(uri: ResellerConfig.aboutUri)
            : ResellerWebView(controller: web),
      ),
    );
  }
}
