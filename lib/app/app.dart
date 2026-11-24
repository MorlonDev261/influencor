import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers/settings_providers.dart';
import '../core/widgets/smooth_wheel_scroll.dart';
import '../features/reseller/presentation/reseller_link_handler.dart';
import 'constants/app_constants.dart';
import 'router.dart';
import 'theme/app_theme.dart';
import 'theme/dialog_sizing.dart';
import 'widgets/update_gate.dart';

/// Root application widget.
class ClipboardApp extends ConsumerWidget {
  const ClipboardApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final settings = ref.watch(settingsProvider);
    final materialLocale =
        settings.languageCode == 'en' ? const Locale('en') : const Locale('fr');

    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      // Allow drag-to-scroll with a mouse and trackpad, not only touch/stylus.
      // Without this, scrollable views feel "stuck" on desktop and web.
      scrollBehavior: const _AppScrollBehavior(),
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: settings.themeMode,
      locale: materialLocale,
      routerConfig: router,
      builder: (context, child) => Theme(
        data: wideDialogTheme(context),
        child: UpdateGate(
          child: ResellerLinkHandler(
            router: router,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
      supportedLocales: const [Locale('fr'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}

/// Scroll behavior that also accepts mouse and trackpad drags, so scrolling
/// works the same on desktop and web as it does on touch devices.
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();

  /// No overscroll glow; the mouse wheel glides instead of jumping.
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      SmoothWheelScroll(controller: details.controller, child: child);
}
