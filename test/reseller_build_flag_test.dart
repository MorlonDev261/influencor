import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:influencor/app/constants/app_constants.dart';
import 'package:influencor/app/router.dart';
import 'package:influencor/core/providers/settings_providers.dart';
import 'package:influencor/core/services/settings_service.dart';
import 'package:influencor/features/reseller/application/reseller_providers.dart';
import 'package:influencor/shared/enums/enums.dart';

// Run as is (website APK: reseller space present) and with
// `--dart-define=INFLUENCOR_RESELLER=false` (Google Play build: absent).
void main() {
  ProviderContainer containerWith(AppSettings settings) {
    final c = ProviderContainer(overrides: [
      settingsProvider.overrideWithValue(settings),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('saved reseller mode only applies when the space is built in', () {
    final c = containerWith(
        const AppSettings(reseller: true, appMode: AppMode.reseller));
    expect(c.read(appModeProvider),
        AppConstants.resellerEnabled ? AppMode.reseller : AppMode.clipboard);
    expect(c.read(modeBadgeVisibleProvider), AppConstants.resellerEnabled);
  });

  test('the /pro route exists only when the space is built in', () {
    final c = containerWith(const AppSettings());
    final router = c.read(routerProvider);
    final paths = <String>[];
    void walk(List<RouteBase> routes) {
      for (final r in routes) {
        if (r is GoRoute) paths.add(r.path);
        walk(r.routes);
      }
    }

    walk(router.configuration.routes);
    expect(paths.contains('/pro'), AppConstants.resellerEnabled);
  });
}
