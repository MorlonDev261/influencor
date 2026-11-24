import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'file_names.dart';
import '../../../core/services/storage_permission_service.dart';
import '../domain/library_entry.dart';
import '../domain/table_document.dart';
import 'metadata_store.dart';
import 'trash_store.dart';

/// Filesystem-backed data layer. The workspace folder on disk is the source of
/// truth; this repository lists, creates, renames, imports and trashes real
/// files and folders, enriching them with sidecar metadata.
class LibraryRepository {
  LibraryRepository({
    required this.root,
    required MetadataStore metadata,
    required TrashStore trash,
  })  : _metadata = metadata,
        _trash = trash;

  final String root;
  final MetadataStore _metadata;
  final TrashStore _trash;
  final _fileKindCache = <String, _FileKindCacheEntry>{};
  static const _uuid = Uuid();

  // --- Listing ---------------------------------------------------------------

  /// Lists the direct children of [dirPath], hiding dotfiles (like the
  /// `.clipboard` metadata directory). Folders come first, then by name.
  Future<List<LibraryEntry>> listEntries(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    final meta = await _metadata.load();
    final entries = <LibraryEntry>[];

    await for (final ent in dir.list(followLinks: false)) {
      final name = p.basename(ent.path);
      if (name.startsWith('.')) continue; // skip hidden files/dirs
      FileStat stat;
      try {
        stat = await ent.stat();
      } catch (_) {
        continue;
      }
      final relKey = _metadata.relKey(ent.path);
      final m = meta[relKey];
      if (ent is Directory) {
        entries.add(LibraryEntry(
          path: ent.path,
          name: name,
          kind: EntryKind.folder,
          size: 0,
          modified: stat.modified,
          isFavorite: m?.favorite ?? false,
          tags: m?.tags ?? const [],
        ));
      } else if (ent is File) {
        final kind = await _kindForFile(ent.path, stat);
        if (_isRejectedStructuredFile(ent.path, kind)) continue;
        entries.add(LibraryEntry(
          path: ent.path,
          name: name,
          kind: kind,
          size: stat.size,
          modified: stat.modified,
          isFavorite: m?.favorite ?? false,
          tags: m?.tags ?? const [],
        ));
      }
    }

    entries.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return entries;
  }

  /// Recursively lists every entry under the workspace root. Used by search and
  /// favorites, which also include note attachments (media in `.attachments`).
  Future<List<LibraryEntry>> listAllEntries() =>
      listAllUnder(root, includeAttachments: true);

  /// Recursively lists every entry under [dirPath].
  ///
  /// When [includeAttachments] is true, media stored in the hidden
  /// `.attachments` folders (images/videos attached to notes) is included too —
  /// used by the folder stats so attachments are counted. The `.attachments`
  /// folder itself is never added as a folder entry.
  Future<List<LibraryEntry>> listAllUnder(
    String dirPath, {
    bool includeAttachments = false,
  }) async {
    final meta = await _metadata.load();
    final out = <LibraryEntry>[];
    await _walk(Directory(dirPath), meta, out,
        includeAttachments: includeAttachments);
    return out;
  }

  Future<void> _walk(
    Directory dir,
    Map<String, EntryMeta> meta,
    List<LibraryEntry> out, {
    bool includeAttachments = false,
  }) async {
    List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    for (final ent in children) {
      final name = p.basename(ent.path);
      if (name.startsWith('.')) {
        // Descend into note attachment folders to count embedded media, but
        // never list the hidden folder itself.
        if (includeAttachments && ent is Directory && name == '.attachments') {
          await _walk(ent, meta, out, includeAttachments: includeAttachments);
        }
        continue;
      }
      FileStat stat;
      try {
        stat = await ent.stat();
      } catch (_) {
        continue;
      }
      final m = meta[_metadata.relKey(ent.path)];
      if (ent is Directory) {
        out.add(LibraryEntry(
          path: ent.path,
          name: name,
          kind: EntryKind.folder,
          size: 0,
          modified: stat.modified,
          isFavorite: m?.favorite ?? false,
          tags: m?.tags ?? const [],
        ));
        await _walk(ent, meta, out, includeAttachments: includeAttachments);
      } else if (ent is File) {
        final kind = await _kindForFile(ent.path, stat);
        if (_isRejectedStructuredFile(ent.path, kind)) continue;
        out.add(LibraryEntry(
          path: ent.path,
          name: name,
          kind: kind,
          size: stat.size,
          modified: stat.modified,
          isFavorite: m?.favorite ?? false,
          tags: m?.tags ?? const [],
        ));
      }
    }
  }

  // --- Create ----------------------------------------------------------------

  Future<String> createFolder(String parentPath, String name) async {
    final dir = Directory(p.join(parentPath, _sanitize(name)));
    if (await dir.exists()) {
      throw const FileSystemException('Un dossier du même nom existe déjà.');
    }
    await dir.create();
    return dir.path;
  }

  /// Creates a `.md` note. Returns the created file path.
  Future<String> createNote(
    String dirPath, {
    required String title,
    required String content,
  }) async {
    final base = _sanitize(title.trim().isEmpty ? 'Note' : title.trim());
    final path = await _claimFile(p.join(dirPath, '$base.md'));
    final file = File(path);
    try {
      await file.writeAsString(content, encoding: utf8);
    } catch (_) {
      await _dropClaim(path);
      rethrow;
    }
    return file.path;
  }

  /// Creates a table `.json` file. Returns the created file path.
  Future<String> createTable(
    String dirPath, {
    required String name,
    required TableDocument table,
  }) async {
    final base = _sanitize(name.trim().isEmpty ? 'Tableau' : name.trim());
    final path = await _claimFile(p.join(dirPath, '$base.json'));
    try {
      await File(path).writeAsString(table.toPrettyJson(), encoding: utf8);
    } catch (_) {
      await _dropClaim(path);
      rethrow;
    }
    return path;
  }

  /// Copies an image into a hidden `.attachments` folder next to notes in
  /// [dirPath] and returns its absolute path. Hidden, so it never clutters the
  /// folder listing, but it is still counted in the folder stats (see
  /// [listAllUnder] with `includeAttachments`).
  Future<String> attachImageToDir(String dirPath, String sourcePath) async {
    final attachDir = Directory(p.join(dirPath, '.attachments'));
    await attachDir.create(recursive: true);
    final target =
        await _claimFile(p.join(attachDir.path, p.basename(sourcePath)));
    try {
      await _copyInto(sourcePath, target);
    } catch (_) {
      await _dropClaim(target);
      rethrow;
    }
    return target;
  }

  Future<String> readTextFile(String path) =>
      File(path).readAsString(encoding: utf8);

  Future<void> writeTextFile(String path, String content) =>
      File(path).writeAsString(content, encoding: utf8);

  // --- Rename ----------------------------------------------------------------

  Future<String> rename(String path, String newName) async {
    final isDir = await FileSystemEntity.isDirectory(path);
    final parent = p.dirname(path);
    final String target;
    if (isDir) {
      target = p.join(parent, _sanitize(newName));
    } else {
      // Keep the original extension for files (notes stay .md).
      final ext = p.extension(path);
      final base = _sanitize(newName);
      target = p.join(parent, base.endsWith(ext) ? base : '$base$ext');
    }
    if (target == path) return path;
    if (await FileSystemEntity.type(target) != FileSystemEntityType.notFound) {
      throw const FileSystemException('Un élément du même nom existe déjà.');
    }
    final renamed = isDir
        ? await Directory(path).rename(target)
        : await File(path).rename(target);
    await _metadata.move(path, renamed.path);
    return renamed.path;
  }

  // --- Favorites / tags ------------------------------------------------------

  Future<void> setFavorite(String path, bool value) =>
      _metadata.setFavorite(path, value);

  Future<void> setTags(String path, List<String> tags) =>
      _metadata.setTags(path, tags);

  Future<EntryMeta> getMeta(String path) => _metadata.get(path);

  Future<void> setNoteSeparator(String path, String? separator) =>
      _metadata.setNoteSeparator(path, separator);

  // --- Move / duplicate ------------------------------------------------------

  Future<String> move(String path, String destDir) async {
    if (p.equals(path, destDir) || p.isWithin(path, destDir)) {
      throw const FileSystemException(
          'Impossible de déplacer un dossier dans lui-même.');
    }
    final isDir = await FileSystemEntity.isDirectory(path);
    // Files: claim the name first, so a concurrent create can never be
    // replaced by this rename.
    final target = isDir
        ? _uniquePath(p.join(destDir, p.basename(path)))
        : await _claimFile(p.join(destDir, p.basename(path)));
    final FileSystemEntity result;
    try {
      result = isDir
          ? await Directory(path).rename(target)
          : await File(path).rename(target);
    } catch (_) {
      if (!isDir) await _dropClaim(target);
      rethrow;
    }
    await _metadata.move(path, result.path);
    return result.path;
  }

  Future<String> duplicate(String path) async {
    final parent = p.dirname(path);
    final isDir = await FileSystemEntity.isDirectory(path);
    if (isDir) {
      final target = _uniquePath(p.join(parent, '${p.basename(path)} (copie)'));
      await _copyDirectory(path, target);
      return target;
    }
    final base = p.basenameWithoutExtension(path);
    final ext = p.extension(path);
    final target = await _claimFile(p.join(parent, '$base (copie)$ext'));
    try {
      await _copyInto(path, target);
    } catch (_) {
      await _dropClaim(target);
      rethrow;
    }
    return target;
  }

  /// Stores a metadata-free copy of [path] (produced into [cleanedTemp]).
  ///
  /// [replace] swaps the original in place (copy next to it, then one rename,
  /// so a failure can never leave a truncated original); otherwise the copy is
  /// added beside it as `name_clean.ext`. Returns the resulting path.
  Future<String> storeCleaned(
    String path,
    String cleanedTemp, {
    required bool replace,
  }) async {
    if (replace) {
      final tmp = File('$path.influencor-tmp');
      try {
        await _copyInto(cleanedTemp, tmp.path);
        await tmp.rename(path);
        // Same name, new size: refresh the gallery entry.
        await StoragePermissionService().scanMedia([path]);
      } catch (_) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        rethrow;
      }
      return path;
    }
    final target = await _claimFile(p.join(
      p.dirname(path),
      '${p.basenameWithoutExtension(path)}_clean${p.extension(cleanedTemp)}',
    ));
    try {
      await _copyInto(cleanedTemp, target);
    } catch (_) {
      await _dropClaim(target);
      rethrow;
    }
    await StoragePermissionService().scanMedia([target]);
    return target;
  }

  /// Stores a metadata-free copy of [sourcePath] (produced into [cleanedTemp])
  /// in the library folder [dirPath], as `name_clean.ext` (or `name.ext` with
  /// [keepName]), never overwriting, and registers it in the gallery index so
  /// other apps list it. Returns the created path.
  Future<String> storeCleanedIn(
    String dirPath,
    String sourcePath,
    String cleanedTemp, {
    bool keepName = false,
  }) async {
    await Directory(dirPath).create(recursive: true);
    final suffix = keepName ? '' : '_clean';
    final target = await _claimFile(p.join(
      dirPath,
      '${p.basenameWithoutExtension(sourcePath)}$suffix'
      '${p.extension(cleanedTemp)}',
    ));
    try {
      await _copyInto(cleanedTemp, target);
    } catch (_) {
      await _dropClaim(target);
      rethrow;
    }
    await StoragePermissionService().scanMedia([target]);
    return target;
  }

  // --- Import (copy into the workspace) --------------------------------------

  /// Copies files/folders into [destDir]. Continues on individual failures and
  /// returns the list of paths that failed. With [move], each source is
  /// removed once it has been copied in (cut instead of copy).
  Future<List<String>> importPaths(String destDir, List<String> sourcePaths,
      {bool move = false}) async {
    final failed = <String>[];
    for (final src in sourcePaths) {
      try {
        // A folder cannot go into itself or one of its own sub-folders: the
        // copy would nest into itself and, in "move" mode, deleting the source
        // would delete the copy too (everything lost).
        if (p.equals(src, destDir) || p.isWithin(src, destDir)) {
          failed.add(src);
          continue;
        }
        final type = await FileSystemEntity.type(src);
        switch (type) {
          case FileSystemEntityType.directory:
            final copied =
                await _copyDirectory(src, p.join(destDir, p.basename(src)));
            if (copied) {
              if (move) await Directory(src).delete(recursive: true);
            } else {
              failed.add(src);
            }
          case FileSystemEntityType.file:
            final copied = await _copyFileInto(destDir, src);
            if (copied) {
              if (move) await File(src).delete();
            } else {
              failed.add(src);
            }
          default:
            // Missing, a link, or otherwise not something we can copy.
            failed.add(src);
        }
      } catch (_) {
        failed.add(src);
      }
    }
    return failed;
  }

  Future<bool> _copyFileInto(String destDir, String srcPath) async {
    return _copyAcceptedFileInto(destDir, srcPath);
  }

  Future<bool> _copyAcceptedFileInto(String destDir, String srcPath) async {
    if (!await isAcceptedImportFile(srcPath)) return false;
    await Directory(destDir).create(recursive: true);
    final ext = p.extension(srcPath).toLowerCase();
    final sourceName = p.basename(srcPath);
    final targetName = ext == '.txt'
        ? '${p.basenameWithoutExtension(sourceName)}.md'
        : sourceName;
    final target = await _claimFile(p.join(destDir, targetName));
    try {
      if (ext == '.txt') {
        await File(target).writeAsString(
          await File(srcPath).readAsString(encoding: utf8),
          encoding: utf8,
        );
      } else {
        await _copyInto(srcPath, target);
      }
    } catch (_) {
      await _dropClaim(target);
      rethrow;
    }
    return true;
  }

  Future<bool> _copyDirectory(String srcDir, String destDir) async {
    final target = _uniquePath(destDir);
    var copiedAny = false;
    await for (final ent in Directory(srcDir).list(followLinks: false)) {
      final name = p.basename(ent.path);
      if (ent is Directory) {
        final copied = await _copyDirectory(ent.path, p.join(target, name));
        copiedAny = copiedAny || copied;
      } else if (ent is File) {
        if (await _copyAcceptedFileInto(target, ent.path)) {
          copiedAny = true;
        }
      }
    }
    return copiedAny;
  }

  // --- Trash -----------------------------------------------------------------

  Future<void> moveToTrash(String path) async {
    final isDir = await FileSystemEntity.isDirectory(path);
    final id = _uuid.v4();
    final name = p.basename(path);
    await _trash.trashDir.create(recursive: true);
    final trashedPath = p.join(_trash.trashDir.path, '${id}__$name');
    if (isDir) {
      await Directory(path).rename(trashedPath);
    } else {
      await File(path).rename(trashedPath);
    }
    await _trash.add(TrashEntry(
      id: id,
      name: name,
      originalPath: path,
      trashedPath: trashedPath,
      isDir: isDir,
      deletedAt: DateTime.now(),
    ));
  }

  Future<List<TrashEntry>> listTrash() => _trash.list();

  Future<void> restoreFromTrash(String id) async {
    final entry = await _trash.find(id);
    if (entry == null) return;
    // Restore to the original location, or to the workspace root if the
    // original parent no longer exists — or lies outside the workspace (the
    // index is untrusted: a crafted one must not move files elsewhere).
    var target = entry.originalPath;
    final inside = p.isWithin(root, target) && !_hasDotDot(target);
    if (!inside || !await Directory(p.dirname(target)).exists()) {
      target = p.join(root, p.basename(entry.name));
    }
    final source = _trash.resolve(entry);
    if (entry.isDir) {
      target = _uniquePath(target);
      await Directory(source).rename(target);
    } else {
      target = await _claimFile(target);
      try {
        await File(source).rename(target);
      } catch (_) {
        await _dropClaim(target);
        rethrow;
      }
    }
    await _trash.remove(id);
  }

  Future<void> deleteForever(String id) async {
    final entry = await _trash.find(id);
    if (entry == null) return;
    // Only ever delete inside the trash folder, whatever the index says.
    final source = _trash.resolve(entry);
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(source).delete(recursive: true);
    } else if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      await File(source).delete();
    }
    await _trash.remove(id);
  }

  Future<void> emptyTrash() async {
    for (final entry in await _trash.list()) {
      await deleteForever(entry.id);
    }
  }

  // --- Helpers ---------------------------------------------------------------

  Future<EntryKind> _kindForFile(String path, [FileStat? knownStat]) async {
    final ext = p.extension(path).toLowerCase();
    if (!tableExtensions.contains(ext)) return kindForFile(path);

    FileStat stat;
    try {
      stat = knownStat ?? await File(path).stat();
    } catch (_) {
      return EntryKind.other;
    }

    final cached = _fileKindCache[path];
    if (cached != null &&
        cached.modified == stat.modified &&
        cached.size == stat.size) {
      return cached.kind;
    }

    final kind =
        await isCompatibleTableJson(path) ? EntryKind.table : EntryKind.other;
    _fileKindCache[path] = _FileKindCacheEntry(
      modified: stat.modified,
      size: stat.size,
      kind: kind,
    );
    return kind;
  }

  bool _isRejectedStructuredFile(String path, EntryKind kind) {
    return tableExtensions.contains(p.extension(path).toLowerCase()) &&
        kind == EntryKind.other;
  }

  /// Atomically reserves a free file name (`create(exclusive: true)` fails if
  /// the name is taken) and returns it: unlike "test then write", two
  /// simultaneous imports can never end up on the same path and overwrite each
  /// other. Falls back to `name (1).ext`, `name (2).ext`…
  Future<String> _claimFile(String path) async {
    final dir = p.dirname(path);
    final ext = p.extension(path);
    final base = p.basenameWithoutExtension(path);
    var candidate = path;
    // A permanent failure (read-only folder, disk full…) must surface instead
    // of spinning through names forever.
    const maxAttempts = 2000;
    for (var i = 1; i <= maxAttempts; i++) {
      try {
        await File(candidate).create(exclusive: true, recursive: true);
        return candidate;
      } on FileSystemException catch (e) {
        // Do not rely on an existence check: on Windows it fails with a sharing
        // violation while another task is writing to the very file that blocked
        // us. The OS error code is the reliable signal.
        final code = e.osError?.errorCode;
        final taken = e is PathExistsException ||
            code == 80 || // ERROR_FILE_EXISTS (Windows)
            code == 183 || // ERROR_ALREADY_EXISTS (Windows)
            code == 32 || // ERROR_SHARING_VIOLATION: busy, so it exists
            code == 33 || // ERROR_LOCK_VIOLATION
            code == 17 || // EEXIST (POSIX)
            _exists(candidate);
        if (!taken || i == maxAttempts) rethrow;
      }
      candidate = p.join(dir, '$base ($i)$ext');
    }
    throw FileSystemException('Aucun nom libre trouvé', path);
  }

  /// Copies [from] into the file reserved by [_claimFile] by *writing into it*.
  /// `File.copy` cannot be used here: on Windows it first deletes an existing
  /// target, and in that gap another task can reserve the same name — the copy
  /// then fails (or two files end up fighting for one name).
  Future<void> _copyInto(String from, String claimed) async {
    final sink = File(claimed).openWrite();
    try {
      await sink.addStream(File(from).openRead());
    } finally {
      await sink.close();
    }
  }

  /// Removes the empty placeholder left by [_claimFile] when the write failed.
  Future<void> _dropClaim(String path) async {
    try {
      final f = File(path);
      if (await f.exists() && await f.length() == 0) await f.delete();
    } catch (_) {
      // best effort
    }
  }

  bool _hasDotDot(String path) => p.split(path).contains('..');

  bool _exists(String path) =>
      File(path).existsSync() || Directory(path).existsSync();

  /// Returns [path] or, if it already exists, an incremented variant so nothing
  /// is overwritten.
  String _uniquePath(String path) {
    if (!_exists(path)) return path;
    final dir = p.dirname(path);
    final ext = p.extension(path);
    final base = p.basenameWithoutExtension(path);
    var i = 1;
    while (true) {
      final candidate = p.join(dir, '$base ($i)$ext');
      if (!_exists(candidate)) return candidate;
      i++;
    }
  }

  String _sanitize(String name) => sanitizeFileName(name);
}

class _FileKindCacheEntry {
  const _FileKindCacheEntry({
    required this.modified,
    required this.size,
    required this.kind,
  });

  final DateTime modified;
  final int size;
  final EntryKind kind;
}
