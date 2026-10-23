import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'; // StateProvider (moved here in v3)
import 'package:path/path.dart' as p;

import '../../../core/providers/workspace_providers.dart';
import '../../../shared/enums/enums.dart';
import '../data/library_repository.dart';
import '../data/metadata_store.dart';
import '../data/trash_store.dart';
import '../domain/library_entry.dart';
import '../domain/table_document.dart';

/// Active sort order in the browser (session state).
final browseSortProvider =
    StateProvider<SortOption>((ref) => SortOption.nameAsc);

/// Active kind filter in the browser; null means "all" (session state).
final browseFilterProvider = StateProvider<EntryKind?>((ref) => null);

/// Paths currently selected in the browser and preview screen (session state).
final selectedEntriesProvider = StateProvider<Set<String>>((ref) => <String>{});

/// The filesystem repository bound to the current workspace, or null if no
/// workspace has been chosen yet.
final libraryRepositoryProvider = Provider<LibraryRepository?>((ref) {
  final root = ref.watch(workspaceRootProvider);
  if (root == null) return null;
  return LibraryRepository(
    root: root,
    metadata: MetadataStore(root),
    trash: TrashStore(root),
  );
});

/// Live listing of a directory. Re-scans on any filesystem change in that
/// directory, so files dropped in (from the app or from the OS) appear
/// automatically.
final directoryProvider =
    StreamProvider.family<List<LibraryEntry>, String>((ref, dirPath) async* {
  final repo = ref.watch(libraryRepositoryProvider);
  if (repo == null) {
    yield const [];
    return;
  }
  yield await repo.listEntries(dirPath);

  // Android/iOS filesystem watching can assert inside dart:io for app/private
  // and external-storage paths. Poll lightly there; app-driven mutations still
  // invalidate this provider immediately through LibraryController.
  if (Platform.isAndroid || Platform.isIOS) {
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 2));
      yield await repo.listEntries(dirPath);
    }
  }

  try {
    // Recursive: a change deep in a sub-folder also re-emits, so the recursive
    // folder stats (which count sub-folders) stay in sync. Best-effort — some
    // platforms don't support recursive watching and throw here.
    await for (final _ in Directory(dirPath).watch(recursive: true)) {
      yield await repo.listEntries(dirPath);
    }
  } catch (_) {
    // Recursive watching unsupported/failed: fall back to watching this
    // directory only, so at least direct changes still refresh.
    try {
      await for (final _ in Directory(dirPath).watch()) {
        yield await repo.listEntries(dirPath);
      }
    } catch (_) {
      // Directory watching is best-effort; ignore watcher errors.
    }
  }
});

/// Recursive listing of everything under [dirPath] (the folder itself and all
/// its sub-folders), including media attached to notes (the hidden
/// `.attachments` folders). Used by the browser's kind filters so a filter
/// reveals matching items nested deep in sub-folders, consistent with the
/// recursive stat cards.
final dirRecursiveProvider =
    FutureProvider.family<List<LibraryEntry>, String>((ref, dirPath) async {
  final repo = ref.watch(libraryRepositoryProvider);
  if (repo == null) return const [];
  // Re-run whenever this folder's live listing changes. On mobile the live
  // listing uses a light polling fallback, which would make filtered views
  // flash/reload every couple of seconds; app-driven mutations explicitly
  // invalidate this provider instead.
  if (!Platform.isAndroid && !Platform.isIOS) {
    ref.watch(directoryProvider(dirPath));
  }
  return repo.listAllUnder(dirPath, includeAttachments: true);
});

/// Trashed entries for the current workspace.
final trashProvider = FutureProvider.autoDispose<List<TrashEntry>>((ref) async {
  final repo = ref.watch(libraryRepositoryProvider);
  if (repo == null) return const [];
  return repo.listTrash();
});

/// Flat, recursive index of every entry in the workspace (for search &
/// favorites). Kept alive so it isn't rebuilt on every keystroke.
final libraryIndexProvider = FutureProvider<List<LibraryEntry>>((ref) async {
  final repo = ref.watch(libraryRepositoryProvider);
  if (repo == null) return const [];
  return repo.listAllEntries();
});

/// All favorite entries across the workspace.
final favoritesProvider = FutureProvider<List<LibraryEntry>>((ref) async {
  final all = await ref.watch(libraryIndexProvider.future);
  return all.where((e) => e.isFavorite).toList();
});

/// Recursive counts for a folder (the folder itself + all sub-folders).
typedef DirStats = ({
  int folders,
  int images,
  int videos,
  int notes,
  int tables,
});

final dirStatsProvider =
    FutureProvider.autoDispose.family<DirStats, String>((ref, dirPath) async {
  // Derived from the single recursive listing (which already includes note
  // attachments and refreshes on any change under the folder), so the walk is
  // done once and shared with the browser's filtered view.
  final all = await ref.watch(dirRecursiveProvider(dirPath).future);
  return (
    folders: all.where((e) => e.isFolder).length,
    images: all.where((e) => e.isImage).length,
    videos: all.where((e) => e.isVideo).length,
    notes: all.where((e) => e.isNote).length,
    tables: all.where((e) => e.isTable).length,
  );
});

final tableDocumentProvider = FutureProvider.autoDispose
    .family<TableDocument?, String>((ref, path) async {
  ref.watch(directoryProvider(p.dirname(path)));
  return TableDocument.read(path);
});

/// Controller for library mutations. Callers pass the directory that should be
/// refreshed so metadata-only changes (which don't trigger the fs watcher)
/// still update the UI.
final libraryControllerProvider = Provider<LibraryController>((ref) {
  return LibraryController(ref);
});

class LibraryController {
  LibraryController(this._ref);

  final Ref _ref;

  LibraryRepository get _repo {
    final repo = _ref.read(libraryRepositoryProvider);
    if (repo == null) {
      throw StateError('Aucun dossier de travail sélectionné.');
    }
    return repo;
  }

  void _touchIndex() {
    _ref.invalidate(libraryIndexProvider);
    _ref.invalidate(dirStatsProvider); // refresh all folder stat cards
    _ref.invalidate(dirRecursiveProvider); // refresh recursive filtered views
  }

  Future<String> createFolder(String parentPath, String name) async {
    final path = await _repo.createFolder(parentPath, name);
    _ref.invalidate(directoryProvider(parentPath));
    _touchIndex();
    return path;
  }

  Future<String> createNote(
    String dirPath, {
    required String title,
    required String content,
  }) async {
    final path =
        await _repo.createNote(dirPath, title: title, content: content);
    _ref.invalidate(directoryProvider(dirPath));
    _touchIndex();
    return path;
  }

  Future<String> createTable(
    String dirPath, {
    required String name,
    required TableDocument table,
  }) async {
    final path = await _repo.createTable(dirPath, name: name, table: table);
    _ref.invalidate(directoryProvider(dirPath));
    _touchIndex();
    return path;
  }

  Future<String> readNote(String path) => _repo.readTextFile(path);

  /// Copies [sourcePath] into the note folder's `.attachments` and returns the
  /// Markdown-friendly relative link to embed in a note living in [dirPath].
  Future<String> attachImage(String dirPath, String sourcePath) async {
    final abs = await _repo.attachImageToDir(dirPath, sourcePath);
    _touchIndex(); // refresh stats so attached images are counted
    return p.relative(abs, from: dirPath).replaceAll(r'\', '/');
  }

  Future<void> saveNote(String path, String content) =>
      _repo.writeTextFile(path, content);

  Future<void> saveTable(String path, TableDocument table) async {
    await _repo.writeTextFile(path, table.toPrettyJson());
    _ref.invalidate(tableDocumentProvider(path));
    _ref.invalidate(directoryProvider(p.dirname(path)));
    _touchIndex();
  }

  Future<String> rename(String path, String newName,
      {String? parentDir}) async {
    final result = await _repo.rename(path, newName);
    if (parentDir != null) _ref.invalidate(directoryProvider(parentDir));
    _touchIndex();
    return result;
  }

  Future<void> setFavorite(String path, bool value, {String? parentDir}) async {
    await _repo.setFavorite(path, value);
    if (parentDir != null) _ref.invalidate(directoryProvider(parentDir));
    _touchIndex();
  }

  Future<void> setTags(String path, List<String> tags,
      {String? parentDir}) async {
    await _repo.setTags(path, tags);
    if (parentDir != null) _ref.invalidate(directoryProvider(parentDir));
    _touchIndex();
  }

  Future<String?> noteSeparator(String path) async =>
      (await _repo.getMeta(path)).noteSeparator;

  Future<void> setNoteSeparator(String path, String? separator,
      {String? parentDir}) async {
    await _repo.setNoteSeparator(path, separator);
    if (parentDir != null) _ref.invalidate(directoryProvider(parentDir));
    _touchIndex();
  }

  Future<List<String>> importPaths(String destDir, List<String> sourcePaths,
      {bool move = false}) async {
    final failed = await _repo.importPaths(destDir, sourcePaths, move: move);
    _ref.invalidate(directoryProvider(destDir));
    _touchIndex();
    return failed;
  }

  Future<void> move(String path, String destDir, {String? parentDir}) async {
    await _repo.move(path, destDir);
    if (parentDir != null) _ref.invalidate(directoryProvider(parentDir));
    _ref.invalidate(directoryProvider(destDir));
    _touchIndex();
  }

  Future<void> duplicate(String path, {String? parentDir}) async {
    await _repo.duplicate(path);
    if (parentDir != null) _ref.invalidate(directoryProvider(parentDir));
    _touchIndex();
  }

  /// Saves a cleaned copy of [path] (see [LibraryRepository.storeCleaned]).
  Future<String> storeCleaned(
    String path,
    String cleanedTemp, {
    required bool replace,
    String? parentDir,
  }) async {
    final result =
        await _repo.storeCleaned(path, cleanedTemp, replace: replace);
    if (parentDir != null) _ref.invalidate(directoryProvider(parentDir));
    _touchIndex();
    return result;
  }

  /// Saves a cleaned copy into a library folder (see
  /// [LibraryRepository.storeCleanedIn]).
  Future<String> storeCleanedIn(
    String dirPath,
    String sourcePath,
    String cleanedTemp,
  ) async {
    final result = await _repo.storeCleanedIn(dirPath, sourcePath, cleanedTemp);
    _ref.invalidate(directoryProvider(dirPath));
    _touchIndex();
    return result;
  }

  Future<void> moveToTrash(String path, {String? parentDir}) async {
    await _repo.moveToTrash(path);
    if (parentDir != null) _ref.invalidate(directoryProvider(parentDir));
    _ref.invalidate(trashProvider);
    _touchIndex();
  }

  Future<void> restoreFromTrash(String id) async {
    await _repo.restoreFromTrash(id);
    _ref.invalidate(trashProvider);
    _touchIndex();
  }

  Future<void> deleteForever(String id) async {
    await _repo.deleteForever(id);
    _ref.invalidate(trashProvider);
  }

  Future<void> emptyTrash() async {
    await _repo.emptyTrash();
    _ref.invalidate(trashProvider);
  }
}
