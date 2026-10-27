import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../services/workspace_service.dart';

final workspaceServiceProvider = Provider<WorkspaceService>((ref) {
  return WorkspaceService();
});

/// Holds the current workspace root path (null until the user picks one).
class WorkspaceController extends AsyncNotifier<String?> {
  @override
  Future<String?> build() {
    return ref.watch(workspaceServiceProvider).loadRoot();
  }

  /// Returns `false` when the folder could not be used (typically: storage
  /// access refused) — the previous workspace is then left untouched.
  Future<bool> setRoot(String path) async {
    final saved = await ref.read(workspaceServiceProvider).saveRoot(path);
    if (saved == null) return false;
    state = AsyncData(saved);
    return true;
  }

  /// Uses a folder in the app's own storage (needs no permission).
  Future<bool> useAppFolder() async {
    final service = ref.read(workspaceServiceProvider);
    return setRoot(await service.appFolderPath());
  }
}

final workspaceControllerProvider =
    AsyncNotifierProvider<WorkspaceController, String?>(
        WorkspaceController.new);

/// Convenience: the current root path, or null.
final workspaceRootProvider = Provider<String?>((ref) {
  return ref.watch(workspaceControllerProvider).value;
});

/// Whether [path] is the workspace [root] or one of its files/folders, outside
/// the hidden `.clipboard` folder that holds the app's own data (trash, tasks,
/// accounting…). False when no workspace is chosen.
bool isInWorkspace(String? root, String path) {
  if (root == null || root.isEmpty || path.trim().isEmpty) return false;
  final r = p.normalize(p.absolute(root));
  final abs = p.normalize(p.absolute(path));
  if (p.equals(abs, r)) return true;
  if (!p.isWithin(r, abs)) return false;
  return !p.split(p.relative(abs, from: r)).contains('.clipboard');
}
