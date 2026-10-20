import 'package:path/path.dart' as p;

import '../features/library/domain/library_entry.dart';

/// Helpers to build routes that carry an absolute filesystem path as a query
/// parameter (paths contain slashes, so they don't belong in the path segment).
String browseRoute(String path) =>
    Uri(path: '/browse', queryParameters: {'path': path}).toString();

String noteRoute(String path) =>
    Uri(path: '/note', queryParameters: {'path': path}).toString();

String newNoteRoute(String dir) =>
    Uri(path: '/note', queryParameters: {'dir': dir}).toString();

/// Route a folder entry opens: its listing, or for an `index.note` /
/// `index.img` folder the flat list of every note / image of its parent folder
/// and sub-folders.
String folderRoute(LibraryEntry folder) {
  final index = indexKindOf(folder);
  if (index == null) return browseRoute(folder.path);
  return Uri(path: '/index', queryParameters: {
    'dir': p.dirname(folder.path),
    'kind': index == EntryKind.image ? 'image' : 'note',
  }).toString();
}

String previewRoute(String path) =>
    Uri(path: '/preview', queryParameters: {'path': path}).toString();

String tableRoute(String path) =>
    Uri(path: '/table', queryParameters: {'path': path}).toString();

/// Search route, optionally pre-filled with an initial [query].
String searchRoute([String? query]) => (query == null || query.isEmpty)
    ? '/search'
    : Uri(path: '/search', queryParameters: {'q': query}).toString();
