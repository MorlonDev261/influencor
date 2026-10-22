import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'atomic_file.dart';
import 'package:path_provider/path_provider.dart';

import 'storage_permission_service.dart';

/// Persists the path of the user's chosen workspace (library) folder.
///
/// The path is stored in a tiny JSON config file in the app support directory,
/// so it survives restarts. All library data itself lives in the workspace
/// folder picked by the user.
class WorkspaceService {
  WorkspaceService({
    StoragePermissionService? storagePermissionService,
    bool? isMobile,
    Future<Directory> Function()? appFolderBase,
    Future<Directory> Function()? configBase,
  })  : _storagePermissionService =
            storagePermissionService ?? StoragePermissionService(),
        _isMobile = isMobile ?? (Platform.isAndroid || Platform.isIOS),
        _appFolderBase = appFolderBase ?? _defaultAppFolderBase,
        _configBase = configBase ?? getApplicationSupportDirectory;

  final bool _isMobile;
  final Future<Directory> Function() _configBase;
  final Future<Directory> Function() _appFolderBase;

  /// App-specific storage: always writable, **no storage permission needed**.
  /// External storage exists on Android only (path_provider throws on iOS); on
  /// iOS the Documents folder is the one shown in the Files app.
  static Future<Directory> _defaultAppFolderBase() async =>
      (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
      await getApplicationDocumentsDirectory();

  static const _fileName = 'clipboard_config.json';
  static const _rootKey = 'rootPath';

  final StoragePermissionService _storagePermissionService;

  Future<File> _configFile() async {
    final dir = await _configBase();
    return File(p.join(dir.path, _fileName));
  }

  /// Returns the saved workspace path, or null if none is set yet (or the
  /// folder no longer exists).
  Future<String?> loadRoot() async {
    try {
      final file = await _configFile();
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString(encoding: utf8));
        if (data is Map) {
          final path = data[_rootKey];
          if (path is String &&
              path.isNotEmpty &&
              await Directory(path).exists() &&
              await _canUseAsWorkspace(path)) {
            return path;
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _canUseAsWorkspace(String path) async {
    if (!_isMobile) return true;
    try {
      final dir = Directory(path);
      await dir.create(recursive: true);
      final probe = File(p.join(
        path,
        '.influencor_write_test_${DateTime.now().microsecondsSinceEpoch}',
      ));
      await probe.writeAsString('ok', encoding: utf8);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A workspace inside the app's own storage. Works without any permission
  /// (the fallback when the user declines the broad "all files" access); its
  /// content is removed if the app is uninstalled.
  Future<String> appFolderPath() async {
    final base = await _appFolderBase();
    final dir = Directory(p.join(base.path, 'Influencor'));
    await dir.create(recursive: true);
    return dir.path;
  }

  Future<String?> saveRoot(String path) async {
    final root = path;
    if (!await _canUseAsWorkspace(root)) {
      final granted = await _storagePermissionService.requestStorageAccess();
      if (!granted || !await _canUseAsWorkspace(root)) {
        return null;
      }
    }
    final file = await _configFile();
    await writeStringAtomic(file, jsonEncode({_rootKey: root}));
    return root;
  }
}
