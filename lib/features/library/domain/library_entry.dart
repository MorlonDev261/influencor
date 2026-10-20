import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'table_document.dart';

/// The kind of a filesystem entry, inferred from whether it is a directory and,
/// for files, from the extension.
enum EntryKind { folder, note, image, video, table, other }

/// A single entry in the library: a real folder or file on disk, enriched with
/// sidecar metadata (favorite, tags).
@immutable
class LibraryEntry {
  const LibraryEntry({
    required this.path,
    required this.name,
    required this.kind,
    required this.size,
    required this.modified,
    this.isFavorite = false,
    this.tags = const [],
  });

  /// Absolute path on disk.
  final String path;

  /// File or folder name (basename).
  final String name;

  final EntryKind kind;

  /// Size in bytes (0 for folders).
  final int size;

  final DateTime modified;

  final bool isFavorite;
  final List<String> tags;

  bool get isFolder => kind == EntryKind.folder;
  bool get isNote => kind == EntryKind.note;
  bool get isImage => kind == EntryKind.image;
  bool get isVideo => kind == EntryKind.video;
  bool get isTable => kind == EntryKind.table;
  bool get isMedia => isImage || isVideo;

  /// Display name without the content extension for editable content.
  String get displayName =>
      (isNote || isTable) ? p.basenameWithoutExtension(name) : name;

  @override
  bool operator ==(Object other) => other is LibraryEntry && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// Hidden "index" folders: a folder named `index.note` or `index.img` (any
/// case) shows as a coloured Pro folder that lists every note / image of the
/// folder it sits in, sub-folders included at any depth. Returns the kind it
/// gathers, or null for an ordinary entry.
EntryKind? indexKindOf(LibraryEntry entry) {
  if (!entry.isFolder) return null;
  switch (entry.name.toLowerCase()) {
    case 'index.note':
      return EntryKind.note;
    case 'index.img':
      return EntryKind.image;
  }
  return null;
}

/// File extensions recognised as images and videos.
const imageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
  '.heic',
  '.heif',
  '.svg',
  '.tiff',
  '.tif',
  '.avif',
  '.ico',
};
const videoExtensions = {'.mp4', '.mov', '.webm', '.avi', '.mkv', '.m4v'};

/// Documents the metadata cleaner accepts besides images and videos.
const cleanableDocumentExtensions = {'.pdf'};

bool isCleanableDocument(String path) =>
    cleanableDocumentExtensions.contains(p.extension(path).toLowerCase());

const noteExtensions = {'.md', '.markdown', '.txt'};
const tableExtensions = {'.json'};

/// Image extensions Flutter can decode and display natively for thumbnails.
/// Other recognised image formats (heic, svg, tiff, avif, ico) still count as
/// images but fall back to an icon instead of a rendered preview.
const decodableImageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
};

/// Whether a file can be shown as a rendered thumbnail (vs. an image icon).
bool canRenderThumbnail(String fileName) =>
    decodableImageExtensions.contains(p.extension(fileName).toLowerCase());

/// Classifies a file (not a directory) by its extension.
EntryKind kindForFile(String fileName) {
  final ext = p.extension(fileName).toLowerCase();
  if (imageExtensions.contains(ext)) return EntryKind.image;
  if (videoExtensions.contains(ext)) return EntryKind.video;
  if (noteExtensions.contains(ext)) return EntryKind.note;
  return EntryKind.other;
}

Future<EntryKind> kindForFilePath(String path) async {
  final ext = p.extension(path).toLowerCase();
  if (tableExtensions.contains(ext)) {
    return await isCompatibleTableJson(path)
        ? EntryKind.table
        : EntryKind.other;
  }
  return kindForFile(path);
}

Future<bool> isAcceptedImportFile(String path) async => true;
