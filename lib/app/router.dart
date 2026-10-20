import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/about/presentation/about_screen.dart';
import '../features/accounting/presentation/accounting_screen.dart';
import '../features/fees/presentation/fees_screen.dart';
import '../features/menu/presentation/menu_screen.dart';
import '../features/tasks/presentation/task_editor_screen.dart';
import '../features/tasks/presentation/tasks_screen.dart';
import '../features/assistant/presentation/assistant_screen.dart';
import '../features/favorites/presentation/favorites_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/library/presentation/browse_screen.dart';
import '../features/library/presentation/index_screen.dart';
import '../features/library/presentation/note_screen.dart';
import '../features/library/presentation/preview_screen.dart';
import '../features/library/presentation/table_screen.dart';
import '../features/reseller/presentation/reseller_login_screen.dart';
import '../features/search/presentation/search_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/trash/presentation/trash_screen.dart';
import 'widgets/app_shell.dart';

/// Application router. Filesystem paths travel as the `path` / `dir` query
/// parameter (they contain slashes, so they can't be path segments).
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/browse',
            builder: (context, state) {
              final path = state.uri.queryParameters['path'];
              if (path == null) return const HomeScreen();
              return BrowseScreen(dirPath: path);
            },
          ),
          GoRoute(
            path: '/note',
            builder: (context, state) {
              final q = state.uri.queryParameters;
              if (q['path'] == null && q['dir'] == null) {
                return const HomeScreen();
              }
              return NoteScreen(
                existingPath: q['path'],
                newDir: q['dir'],
              );
            },
          ),
          GoRoute(
            path: '/preview',
            builder: (context, state) {
              final path = state.uri.queryParameters['path'];
              if (path == null) return const HomeScreen();
              final extra = state.extra;
              return PreviewScreen(
                path: path,
                paths: extra is List<String> ? extra : null,
              );
            },
          ),
          GoRoute(
            path: '/index',
            builder: (context, state) {
              final q = state.uri.queryParameters;
              final dir = q['dir'];
              if (dir == null) return const HomeScreen();
              return IndexScreen(dir: dir, images: q['kind'] == 'image');
            },
          ),
          GoRoute(
            path: '/table',
            builder: (context, state) {
              final path = state.uri.queryParameters['path'];
              if (path == null) return const HomeScreen();
              return TableScreen(path: path);
            },
          ),
          GoRoute(
            path: '/search',
            builder: (context, state) => SearchScreen(
              initialQuery: state.uri.queryParameters['q'],
            ),
          ),
          GoRoute(
            path: '/favorites',
            builder: (context, state) => const FavoritesScreen(),
          ),
          GoRoute(
            path: '/assistant',
            pageBuilder: (context, state) => _assistantPage(
              state,
              const AssistantScreen(),
            ),
          ),
          GoRoute(
            path: '/deganeo',
            pageBuilder: (context, state) => _assistantPage(
              state,
              const AssistantScreen(section: AssistantSection.deganeo),
            ),
          ),
          GoRoute(
            path: '/trash',
            builder: (context, state) => const TrashScreen(),
          ),
          GoRoute(
            path: '/menu',
            builder: (context, state) => const MenuScreen(),
          ),
          GoRoute(
            path: '/accounting',
            builder: (context, state) => const AccountingScreen(),
          ),
          GoRoute(
            path: '/fees',
            builder: (context, state) => const FeesScreen(),
          ),
          GoRoute(
            path: '/task',
            builder: (context, state) => const TasksScreen(),
          ),
          GoRoute(
            path: '/task/edit',
            builder: (context, state) {
              final id = state.uri.queryParameters['id'];
              if (id == null) return const TasksScreen();
              return TaskEditorScreen(taskId: id);
            },
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/about',
            builder: (context, state) => const AboutScreen(),
          ),
          GoRoute(
            path: '/pro',
            builder: (context, state) => const ResellerLoginScreen(),
          ),
        ],
      ),
    ],
  );
});

CustomTransitionPage<void> _assistantPage(
  GoRouterState state,
  Widget child,
) {
  return CustomTransitionPage<void>(
    // One shared key: Assistant <-> Deganeo is a swipe inside the same page,
    // not a navigation, so the state (chat, Deganeo queue) is kept.
    key: const ValueKey('assistant-shell'),
    child: child,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.04, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
