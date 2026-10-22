import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/library/domain/library_entry.dart';

/// file_picker copies Photos picks into `Documents/picked_images` and never
/// removes them. On iOS that folder shows in the Files app (the workspace lives
/// in Documents) and grows with every import, so the copies move to the
/// temporary folder, under readable names (`IMG_20261022_140305.jpg`), before
/// anyone uses them. Paths outside `picked_images` are returned unchanged.
///
/// [tempDir] replaces the system temporary folder (tests).
Future<List<String>> relocatePickedMedia(
  List<String> paths, {
  Future<Directory> Function() tempDir = getTemporaryDirectory,
}) async {
  if (!paths.any(_isPluginCopy)) return paths;
  final dir = Directory(p.join((await tempDir()).path, 'picked_media'));
  await dir.create(recursive: true);
  final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
  final out = <String>[];
  for (var i = 0; i < paths.length; i++) {
    final path = paths[i];
    if (!_isPluginCopy(path)) {
      out.add(path);
      continue;
    }
    final ext = p.extension(path).toLowerCase();
    final prefix = videoExtensions.contains(ext) ? 'VID' : 'IMG';
    final base =
        paths.length > 1 ? '${prefix}_${stamp}_${i + 1}' : '${prefix}_$stamp';
    var dest = p.join(dir.path, '$base$ext');
    for (var n = 2; File(dest).existsSync(); n++) {
      dest = p.join(dir.path, '$base ($n)$ext');
    }
    try {
      out.add((await File(path).rename(dest)).path);
    } catch (_) {
      out.add(path);
    }
  }
  return out;
}

bool _isPluginCopy(String path) =>
    p.basename(p.dirname(path)) == 'picked_images';
