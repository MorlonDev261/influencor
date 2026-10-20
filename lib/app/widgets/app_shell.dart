import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/app_strings.dart';
import '../../features/reseller/application/reseller_providers.dart';
import '../../shared/enums/enums.dart';
import '../constants/app_constants.dart';

/// Top-level responsive navigation shell.
///
/// * Mobile (< [AppConstants.desktopBreakpoint]): a custom bottom bar with the
///   assistant as a larger, centered button.
/// * Desktop / tablet: persistent [NavigationRail] sidebar.
///
/// Search is reached from page headers, so it can be pushed onto the current
/// navigation history without becoming a top-level tab.
class AppShell extends ConsumerWidget {
  const AppShell({
    required this.location,
    required this.child,
    super.key,
  });

  final String location;
  final Widget child;

  /// Index of the assistant destination — rendered larger and centered.
  static const _centerIndex = 2;

  static const _destinations = <_Destination>[
    _Destination('/', Icons.home_outlined, Icons.home),
    _Destination('/favorites', Icons.star_border, Icons.star),
    _Destination('/assistant', Icons.assistant_outlined, Icons.assistant),
    _Destination('/trash', Icons.delete_outline, Icons.delete),
    _Destination('/menu', Icons.menu, Icons.menu),
  ];

  int get _selectedIndex {
    // Browse / note / preview / search routes belong to the "home" tab.
    if (location.startsWith('/favorites')) return 1;
    if (location.startsWith('/assistant') || location.startsWith('/deganeo')) {
      return 2;
    }
    if (location.startsWith('/trash')) return 3;
    // Menu hub and everything reached from it (accounting, tasks, settings).
    if (location.startsWith('/menu') ||
        location.startsWith('/accounting') ||
        location.startsWith('/task') ||
        location.startsWith('/settings') ||
        location.startsWith('/about')) {
      return 4;
    }
    return 0;
  }

  void _onSelect(BuildContext context, int index) {
    context.go(_destinations[index].route);
  }

  void _handleSystemBack(BuildContext context) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    // Accounting, tasks and settings are reached from the menu: back goes
    // there first, not straight to the home tab.
    if (location.startsWith('/accounting') ||
        location.startsWith('/task') ||
        location.startsWith('/settings')) {
      context.go('/menu');
      return;
    }
    if (location != '/') {
      context.go('/');
      return;
    }
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // In "reseller" mode the home tab IS the reseller space, full screen: it
    // brings its own header, badge and back handling.
    if (location == '/' && ref.watch(appModeProvider) == AppMode.reseller) {
      return child;
    }
    final strings = ref.watch(appStringsProvider);
    final labels = [
      strings.home,
      strings.favorites,
      strings.assistant,
      strings.trash,
      strings.menu,
    ];
    final isDesktop =
        MediaQuery.sizeOf(context).width >= AppConstants.desktopBreakpoint;

    if (isDesktop) {
      return PopScope<Object?>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _handleSystemBack(context);
        },
        child: Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: _selectedIndex,
                onDestinationSelected: (i) => _onSelect(context, i),
                labelType: NavigationRailLabelType.all,
                leading: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Image(
                    image: AssetImage('assets/icon/logo.png'),
                    width: 36,
                    height: 36,
                  ),
                ),
                destinations: [
                  for (var i = 0; i < _destinations.length; i++)
                    NavigationRailDestination(
                      icon: Icon(_destinations[i].icon),
                      selectedIcon: Icon(_destinations[i].selectedIcon),
                      label: Text(labels[i]),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: child),
            ],
          ),
        ),
      );
    }

    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleSystemBack(context);
      },
      child: Scaffold(
        body: child,
        bottomNavigationBar: _BottomBar(
          selectedIndex: _selectedIndex,
          labels: labels,
          destinations: _destinations,
          centerIndex: _centerIndex,
          onSelect: (i) => _onSelect(context, i),
        ),
      ),
    );
  }
}

/// Custom mobile bottom bar: four flat tabs with a larger, raised circular
/// button in the middle for the assistant.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.selectedIndex,
    required this.labels,
    required this.destinations,
    required this.centerIndex,
    required this.onSelect,
  });

  final int selectedIndex;
  final List<String> labels;
  final List<_Destination> destinations;
  final int centerIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      elevation: 3,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 68,
          child: Row(
            children: [
              for (var i = 0; i < destinations.length; i++)
                if (i == centerIndex)
                  _CenterButton(
                    icon: destinations[i].selectedIcon,
                    selected: selectedIndex == i,
                    onTap: () => onSelect(i),
                  )
                else
                  _Tab(
                    label: labels[i],
                    icon: selectedIndex == i
                        ? destinations[i].selectedIcon
                        : destinations[i].icon,
                    selected: selectedIndex == i,
                    onTap: () => onSelect(i),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterButton extends StatelessWidget {
  const _CenterButton({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Center(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
              border: selected
                  ? Border.all(color: scheme.onPrimary, width: 2)
                  : null,
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(icon, color: scheme.onPrimary, size: 28),
          ),
        ),
      ),
    );
  }
}

class _Destination {
  const _Destination(this.route, this.icon, this.selectedIcon);
  final String route;
  final IconData icon;
  final IconData selectedIcon;
}
