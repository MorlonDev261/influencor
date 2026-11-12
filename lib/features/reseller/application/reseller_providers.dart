import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/constants/app_constants.dart';
import '../../../core/providers/settings_providers.dart';
import '../../../shared/enums/enums.dart';
import '../data/reseller_push.dart';

/// The badge only exists once a reseller session was created (the hidden
/// `reseller` flag) — or while the user is inside the reseller space, so they
/// can always get back. Never in a build without the reseller space.
final modeBadgeVisibleProvider = Provider<bool>((ref) {
  if (!AppConstants.resellerEnabled) return false;
  final s = ref.watch(settingsProvider);
  return s.reseller || s.appMode == AppMode.reseller;
});

/// Without the reseller space (Google Play build) the home is always the
/// library, even if settings saved by the website APK say otherwise.
final appModeProvider = Provider<AppMode>(
  (ref) => AppConstants.resellerEnabled
      ? ref.watch(settingsProvider.select((s) => s.appMode))
      : AppMode.clipboard,
);

/// A reseller deep link waiting to be shown by the reseller WebView.
class PendingResellerUrl extends Notifier<Uri?> {
  @override
  Uri? build() => null;

  void set(Uri? uri) => state = uri;
}

final pendingResellerUrlProvider =
    NotifierProvider<PendingResellerUrl, Uri?>(PendingResellerUrl.new);

/// One push service for the whole app (Firebase is initialised once).
final resellerPushProvider = Provider<ResellerPush>((ref) {
  final push = ResellerPush();
  ref.onDispose(push.dispose);
  return push;
});
