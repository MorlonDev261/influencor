import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/constants/app_constants.dart';
import '../../../core/providers/settings_providers.dart';
import '../../../shared/enums/enums.dart';
import '../application/reseller_providers.dart';
import '../data/reseller_config.dart';

/// Opens `https://reseller.poma-original.com/*` links (WhatsApp, SMS, e-mail…)
/// inside the reseller space of this app. Android App Links route these here
/// first (see the manifest); the poma-original app is the fallback.
class ResellerLinkHandler extends ConsumerStatefulWidget {
  const ResellerLinkHandler({
    required this.router,
    required this.child,
    super.key,
  });

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<ResellerLinkHandler> createState() =>
      _ResellerLinkHandlerState();
}

class _ResellerLinkHandlerState extends ConsumerState<ResellerLinkHandler> {
  StreamSubscription<Uri>? _sub;
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    // Deep links only exist on the mobile platforms, and only in builds that
    // include the reseller space.
    if (!AppConstants.resellerEnabled ||
        kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      return;
    }
    // Settings load asynchronously: also cover a flag that is already set.
    Future.microtask(() {
      if (mounted && ref.read(settingsProvider).reseller) {
        _listenForNotificationTaps();
      }
    });
    final links = AppLinks();
    _sub = links.uriLinkStream.listen(_handle, onError: (_) {});
    links.getInitialLink().then((u) {
      if (u != null) _handle(u);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _handle(Uri uri) async {
    if (!ResellerConfig.isResellerLink(uri)) return;
    // The initial link can be delivered both ways: ignore the echo.
    final now = DateTime.now();
    if (_last == uri.toString() &&
        now.difference(_lastAt) < const Duration(seconds: 2)) {
      return;
    }
    _last = uri.toString();
    _lastAt = now;

    ref.read(pendingResellerUrlProvider.notifier).set(uri);
    await ref
        .read(settingsControllerProvider.notifier)
        .setAppMode(AppMode.reseller);
    widget.router.go('/');
  }

  @override
  Widget build(BuildContext context) {
    // Once there is a reseller session, a tapped notification opens its page.
    ref.listen<bool>(settingsProvider.select((s) => s.reseller), (_, active) {
      if (active && AppConstants.resellerEnabled) _listenForNotificationTaps();
    });
    return widget.child;
  }

  void _listenForNotificationTaps() {
    unawaited(ref.read(resellerPushProvider).listenForTaps(_handle));
  }
}
