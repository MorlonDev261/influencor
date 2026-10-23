import 'package:influencor/app/app.dart';
import 'package:influencor/core/providers/settings_providers.dart';
import 'package:influencor/core/providers/workspace_providers.dart';
import 'package:influencor/core/services/settings_service.dart';
import 'package:influencor/features/about/presentation/about_screen.dart';
import 'package:influencor/features/reseller/data/reseller_config.dart';
import 'package:influencor/features/reseller/presentation/mode_badge.dart';
import 'package:influencor/features/settings/presentation/settings_screen.dart';
import 'package:influencor/shared/enums/enums.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// In-memory settings (the real service reads a file through path_provider).
class _FakeSettings extends SettingsService {
  _FakeSettings(this.value);

  AppSettings value;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
}

class _FakeWorkspace extends WorkspaceController {
  @override
  Future<String?> build() async => '/tmp/ws';
}

Widget _app(_FakeSettings settings, Widget home,
    {List<GoRoute> extraRoutes = const []}) {
  final router = GoRouter(
    initialLocation: '/start',
    routes: [
      GoRoute(path: '/start', builder: (_, __) => home),
      GoRoute(
          path: '/about',
          builder: (_, __) => const Scaffold(body: Text('ABOUT'))),
      GoRoute(
          path: '/pro', builder: (_, __) => const Scaffold(body: Text('PRO'))),
      ...extraRoutes,
    ],
  );
  return ProviderScope(
    overrides: [
      settingsServiceProvider.overrideWithValue(settings),
      workspaceControllerProvider.overrideWith(_FakeWorkspace.new),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  group('hidden reseller flag', () {
    test('is persisted in the settings JSON and defaults to off', () {
      expect(const AppSettings().reseller, isFalse);
      expect(const AppSettings().appMode, AppMode.clipboard);
      final json =
          const AppSettings(reseller: true, appMode: AppMode.reseller).toJson();
      final back = AppSettings.fromJson(json);
      expect(back.reseller, isTrue);
      expect(back.appMode, AppMode.reseller);
      // Old settings files (no such keys) still load.
      final old = AppSettings.fromJson({'themeMode': 'dark'});
      expect(old.reseller, isFalse);
      expect(old.appMode, AppMode.clipboard);
    });
  });

  group('ResellerConfig', () {
    test('only poma-original https hosts are shown inside the app', () {
      bool t(String u) => ResellerConfig.isTrusted(Uri.parse(u));
      expect(t('https://reseller.poma-original.com/login'), isTrue);
      expect(t('https://poma-original.com/login?callbackUrl=x'), isTrue);
      expect(t('https://morlon.poma-original.com/'), isTrue);
      expect(t('http://reseller.poma-original.com/'), isFalse);
      expect(t('https://evil-poma-original.com/'), isFalse);
      expect(t('https://poma-original.com.evil.io/'), isFalse);
      expect(t('https://wa.me/261340000000'), isFalse);
    });

    test('deep links are recognised only for the reseller host', () {
      bool l(String u) => ResellerConfig.isResellerLink(Uri.parse(u));
      expect(l('https://reseller.poma-original.com/orders/1'), isTrue);
      expect(l('https://poma-original.com/'), isFalse);
      expect(l('http://reseller.poma-original.com/'), isFalse);
    });

    test('the login entry point is the reseller /login', () {
      expect(ResellerConfig.loginUri.toString(),
          'https://reseller.poma-original.com/login');
    });

    test('professional access opens the reseller program /about', () {
      expect(ResellerConfig.aboutUri.toString(),
          'https://reseller.poma-original.com/about');
      expect(ResellerConfig.isTrusted(ResellerConfig.aboutUri), isTrue);
    });

    test('the theme is pushed to the site as light/dark only', () {
      final script = ResellerConfig.themePush('dark');
      expect(script, contains("window.__influencorTheme = 'dark'"));
      expect(script, contains("new CustomEvent('influencor:theme'"));
      expect(() => ResellerConfig.themePush('blue'),
          throwsA(isA<AssertionError>()));
    });
  });

  group('mode badge', () {
    testWidgets('is absent until a reseller session exists', (tester) async {
      await tester.pumpWidget(_app(
        _FakeSettings(const AppSettings()),
        const Scaffold(body: ModeBadge()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('clipboard'), findsNothing);
      expect(find.text('reseller'), findsNothing);
    });

    testWidgets('collapses to the current space and expands to switch',
        (tester) async {
      final settings = _FakeSettings(const AppSettings(reseller: true));
      await tester.pumpWidget(_app(
        settings,
        const Scaffold(body: ModeBadge()),
      ));
      await tester.pumpAndSettle();
      // Collapsed: only the current space, untranslated.
      expect(find.text('clipboard'), findsOneWidget);
      expect(find.text('reseller'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('mode-expand')));
      await tester.pumpAndSettle();
      expect(find.text('clipboard'), findsOneWidget);
      expect(find.text('reseller'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mode-reseller')));
      await tester.pumpAndSettle();
      expect(settings.value.appMode, AppMode.reseller);
      // Collapsed again, now showing the new current space.
      expect(find.text('reseller'), findsOneWidget);
      expect(find.text('clipboard'), findsNothing);
    });

    testWidgets(
        'stays available inside the reseller space even without the flag',
        (tester) async {
      await tester.pumpWidget(_app(
        _FakeSettings(const AppSettings(appMode: AppMode.reseller)),
        const Scaffold(body: ModeBadge()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('reseller'), findsOneWidget);
    });
  });

  group('about page', () {
    testWidgets('is complete and ends with the professional access button',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(
          _FakeSettings(const AppSettings(languageCode: 'en')),
          const AboutScreen()));
      await tester.pumpAndSettle();
      for (final t in [
        'What is Influencor?',
        'What you can do',
        'Deganeo: clean metadata',
        'Your data stays with you',
        'Formats cleaned by Deganeo',
        'The limits, honestly',
        'Languages',
        'Professional space',
        'Professional access',
        'Powered by Morlon Rnd',
      ]) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      await tester.tap(find.byKey(const ValueKey('access-pro')));
      await tester.pumpAndSettle();
      expect(find.text('PRO'), findsOneWidget);
    });
  });

  integrationTests();
  signOutTests();
  narrowScreenTests();

  group('settings', () {
    testWidgets('the ? icon next to Influencor opens /about', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
          _app(_FakeSettings(const AppSettings()), const SettingsScreen()));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('about-help')));
      await tester.pumpAndSettle();
      expect(find.text('ABOUT'), findsOneWidget);
    });
  });
}

void integrationTests() {
  group('app shell in reseller mode', () {
    testWidgets(
        'the home tab is the reseller space, full screen, with the badge',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final settings = _FakeSettings(const AppSettings(
          languageCode: 'en', reseller: true, appMode: AppMode.reseller));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
          workspaceControllerProvider.overrideWith(_FakeWorkspace.new),
        ],
        child: const ClipboardApp(),
      ));
      await tester.pumpAndSettle();
      // No bottom navigation: the reseller space owns the whole screen.
      expect(find.byIcon(Icons.settings_outlined), findsNothing);
      // Header + badge are still there, and so is the way back.
      expect(find.text('Influencor'), findsOneWidget);
      expect(find.text('reseller'), findsOneWidget);
      // On this (desktop test) platform the WebView plugin does not exist, so
      // the fallback offers the system browser.
      expect(find.text('Open in browser'), findsOneWidget);
    });
  });
}

void signOutTests() {
  group('reseller sign-out', () {
    testWidgets('confirms, then drops the flag and returns to clipboard',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final settings = _FakeSettings(const AppSettings(
          languageCode: 'en', reseller: true, appMode: AppMode.reseller));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
          workspaceControllerProvider.overrideWith(_FakeWorkspace.new),
        ],
        child: const ClipboardApp(),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('reseller-sign-out')));
      await tester.pumpAndSettle();
      expect(find.text('Leave the reseller space?'), findsOneWidget);

      // Cancel: nothing changes.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(settings.value.reseller, isTrue);
      expect(settings.value.appMode, AppMode.reseller);

      // Confirm: flag cleared AND mode back to clipboard, in one state.
      await tester.tap(find.byKey(const ValueKey('reseller-sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reseller-sign-out-confirm')));
      // The clipboard home that follows keeps a loading spinner running (the
      // fake workspace has no real folder): pump a few frames, not "settle".
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(settings.value.reseller, isFalse);
      expect(settings.value.appMode, AppMode.clipboard);
    });
  });
}

void narrowScreenTests() {
  group('reseller header on a narrow phone', () {
    for (final width in [320.0, 360.0]) {
      testWidgets(
          'no overflow at ${width.toInt()} dp (logo, title, badge, 2 icons)',
          (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(ProviderScope(
          overrides: [
            settingsServiceProvider.overrideWithValue(_FakeSettings(
                const AppSettings(
                    languageCode: 'fr',
                    reseller: true,
                    appMode: AppMode.reseller))),
            workspaceControllerProvider.overrideWith(_FakeWorkspace.new),
          ],
          child: const ClipboardApp(),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('reseller-sign-out')), findsOneWidget);
      });
    }
  });
}
