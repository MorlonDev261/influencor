import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_strings.dart';
import '../../features/reseller/application/reseller_providers.dart';
import '../../features/reseller/presentation/mode_badge.dart';
import '../constants/app_constants.dart';

/// The app's brand title for the header.
///
/// On the mobile layout (the bottom navigation bar) it shows the logo next to
/// the app name. On desktop/tablet — where the [NavigationRail] on the left
/// already shows the logo — it shows just the name, to avoid duplicating it.
///
/// With [showModeBadge], the collapsible `clipboard | reseller` badge sits
/// under the name once a reseller session exists.
class AppHeaderTitle extends ConsumerWidget {
  const AppHeaderTitle({this.showModeBadge = false, super.key});

  final bool showModeBadge;

  /// Toolbar height that fits the title plus the badge.
  static const heightWithBadge = 68.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final isDesktop =
        MediaQuery.sizeOf(context).width >= AppConstants.desktopBreakpoint;
    // Flexible + ellipsis: next to action icons (reseller header) a narrow
    // phone must shrink the title, never overflow.
    final name = Text(
      strings.appName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
    );
    final title = isDesktop
        ? name
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/icon/logo.png',
                width: 28,
                height: 28,
                filterQuality: FilterQuality.medium,
              ),
              const SizedBox(width: 8),
              Flexible(child: name),
            ],
          );
    if (!showModeBadge || !ref.watch(modeBadgeVisibleProvider)) return title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [title, const SizedBox(height: 3), const ModeBadge()],
    );
  }
}
