import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/core/picker/picked_media_io.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory picked;
  late Directory tmp;
  setUp(() {
    root = Directory.systemTemp.createTempSync('picked_');
    picked = Directory(p.join(root.path, 'Documents', 'picked_images'))
      ..createSync(recursive: true);
    tmp = Directory(p.join(root.path, 'tmp'))..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<List<String>> relocate(List<String> paths) =>
      relocatePickedMedia(paths, tempDir: () async => tmp);

  File copy(String name) =>
      File(p.join(picked.path, name))..writeAsBytesSync([1, 2, 3]);

  test('moves Photos copies out of Documents under readable names', () async {
    final photo = copy('image_8F1C_1761141785.jpeg');
    final video = copy('image_A2D4_1761141786.mov');

    final out = await relocate([photo.path, video.path]);

    expect(photo.existsSync(), isFalse);
    expect(video.existsSync(), isFalse);
    expect(out, hasLength(2));
    for (final path in out) {
      expect(p.dirname(path), p.join(tmp.path, 'picked_media'));
      expect(File(path).readAsBytesSync(), [1, 2, 3]);
    }
    expect(p.basename(out[0]), matches(RegExp(r'^IMG_\d{8}_\d{6}_1\.jpeg$')));
    expect(p.basename(out[1]), matches(RegExp(r'^VID_\d{8}_\d{6}_2\.mov$')));
  });

  test('never overwrites an earlier pick made in the same second', () async {
    final first = await relocate([copy('image_1.jpg').path]);
    final second = await relocate([copy('image_2.jpg').path]);

    expect(File(first.single).existsSync(), isTrue);
    expect(File(second.single).existsSync(), isTrue);
    expect(second.single, isNot(first.single));
  });

  test('leaves files from the Files app untouched', () async {
    final inbox = File(p.join(root.path, 'tmp', 'Inbox', 'report.pdf'))
      ..createSync(recursive: true);

    final out = await relocate([inbox.path]);

    expect(out, [inbox.path]);
    expect(inbox.existsSync(), isTrue);
  });
}
