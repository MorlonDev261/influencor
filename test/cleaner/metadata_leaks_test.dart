import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/features/cleaner/data/binary.dart';
import 'package:influencor/features/cleaner/data/clean_pipeline.dart';
import 'package:influencor/features/cleaner/domain/clean_options.dart';
import 'package:influencor/features/cleaner/domain/clean_report.dart';

import 'fixtures.dart';

/// Metadata that used to survive a "verified" clean.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('cleaner_leaks_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<CleanReport> run(String name, Uint8List data) async {
    final src = File('${dir.path}/$name')..writeAsBytesSync(data);
    final out = Directory('${dir.path}/out')..createSync(recursive: true);
    return const CleanPipeline().run(src.path, out, CleanOptions.stripAll);
  }

  Uint8List output(CleanReport r) => File(r.outputPath!).readAsBytesSync();

  bool has(Uint8List hay, String needle) => indexOfBytes(hay, asc(needle)) >= 0;

  Future<void> expectIdempotent(String name, Uint8List cleaned) async {
    final again = await run(name, cleaned);
    expect(again.removed, isEmpty);
    expect(output(again), cleaned);
  }

  group('AVI', () {
    const frame = 'FRAME-0123456789';
    Uint8List list(String type, List<int> body) =>
        riffChunk('LIST', [...asc(type), ...body]);

    Uint8List avi() {
      final strl = list('strl', [
        ...riffChunk('strh', List.filled(56, 1)),
        ...riffChunk('strf', List.filled(40, 2)),
        ...riffChunk('strn', asc('Camera of John')),
      ]);
      final hdrl = list('hdrl', [
        ...riffChunk('avih', List.filled(56, 3)),
        ...strl,
        ...list('INFO', riffChunk('ISFT', asc('nested secret soft'))),
      ]);
      final movi = list('movi', riffChunk('00dc', asc(frame)));
      final body = cat([
        asc('AVI '),
        hdrl,
        riffChunk('JUNK', asc('NIKON D750 secret')),
        list('INFO', riffChunk('INAM', asc('Private title'))),
        riffChunk('IDIT', asc('MON JAN 02 2025')),
        list('ncdt', riffChunk('nctg', asc('maker secret'))),
        movi,
        riffChunk('idx1', List.filled(16, 4)),
      ]);
      return cat([asc('RIFF'), le32(body.length), body, asc('AFTER-RIFF')]);
    }

    test('blanks metadata in place, wherever it sits', () async {
      final input = avi();
      final r = await run('a.avi', input);
      expect(r.status, CleanStatus.verifiedClean);
      final out = output(r);
      for (final s in [
        'Camera of John',
        'nested secret',
        'NIKON',
        'Private title',
        'MON JAN',
        'maker secret',
        'ncdt',
        'AFTER-RIFF',
      ]) {
        expect(has(out, s), isFalse, reason: s);
      }
      // Nothing moved: absolute index offsets (OpenDML `indx`) stay valid.
      expect(out.length, input.length - 'AFTER-RIFF'.length);
      expect(indexOfBytes(out, asc(frame)), indexOfBytes(input, asc(frame)));
      expect(u32le(out, 4), out.length - 8);
      await expectIdempotent('b.avi', out);
    });
  });

  group('JPEG', () {
    Uint8List jpeg(List<List<int>> segments) => cat([
          [0xFF, 0xD8],
          ...segments,
          jpegSegment(0xDB, [0, 1, 2, 3]),
          jpegSegment(0xC0, [8, 0, 1, 0, 1, 1, 1, 0x11, 0]),
          jpegSegment(0xDA, [1, 1, 0, 0, 0x3F, 0]),
          jpegScan,
          [0xFF, 0xD9],
        ]);

    test('drops bytes hidden after the JFIF and Adobe headers', () async {
      final r = await run(
          'a.jpg',
          jpeg([
            jpegSegment(0xE0, [
              ...asc('JFIF\u0000'), 1, 1, 0, 0, 1, 0, 1, 0, 0, //
              ...asc('HIDDEN-AFTER-JFIF'),
            ]),
            jpegSegment(0xEE, [
              ...asc('Adobe'), 0, 100, 0, 0, 0, 0, 1, //
              ...asc('HIDDEN-AFTER-ADOBE'),
            ]),
          ]));
      expect(r.status, CleanStatus.verifiedClean);
      final out = output(r);
      expect(has(out, 'HIDDEN'), isFalse);
      // Both headers are kept, at their defined length.
      final jfif = indexOfBytes(out, asc('JFIF'));
      expect(u16be(out, jfif - 2), 16);
      final adobe = indexOfBytes(out, asc('Adobe'));
      expect(u16be(out, adobe - 2), 14);
      await expectIdempotent('b.jpg', out);
    });
  });

  group('PDF', () {
    Uint8List pdf() => cat([
          asc('%PDF-1.7\n'),
          pdfObj(
              1,
              '<< /Type /Catalog /Pages 2 0 R '
              '/Names << /EmbeddedFiles << /Names [(a.txt) 5 0 R] >> >> >>'),
          pdfObj(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
          pdfObj(
              3,
              '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] '
              '/Annots [4 0 R] >>'),
          // No `/Type /Annot`: optional, and most writers leave it out.
          pdfObj(
              4,
              '<< /Subtype /Highlight /Rect [0 0 5 5] /T (Jane Hidden) '
              '/M (D:20250303030303) /Contents (kept note) >>'),
          pdfObj(5, '<< /Type /Filespec /F (a.txt) /EF << /F 6 0 R >> >>'),
          pdfObj(
              6,
              '<< /Type /EmbeddedFile /Params << /CreationDate '
              '(D:20240101010101) /ModDate (D:20240202020202) /Size 3 >> '
              '/Length 3 >>',
              stream: asc('abc')),
          asc('trailer\n<< /Size 7 /Root 1 0 R >>\n%%EOF\n'),
        ]);

    test('annotation authors and embedded file dates are removed', () async {
      final r = await run('a.pdf', pdf());
      expect(r.status, CleanStatus.verifiedClean);
      final out = output(r);
      for (final s in ['Jane Hidden', 'D:2025', 'D:2024']) {
        expect(has(out, s), isFalse, reason: s);
      }
      expect(has(out, 'kept note'), isTrue);
      expect(has(out, 'abc'), isTrue);
      await expectIdempotent('b.pdf', out);
    });
  });

  group('Matroska', () {
    test('every Segment is cleaned, and data after them voided', () async {
      final second = ebml(0x18538067, [
        ...ebml(0x1549A966, [...ebml(0x7BA9, asc('Second secret title'))]),
        ...ebml(0x1254C367, [...ebml(0x7373, asc('second secret tags'))]),
      ]);
      final input = cat([mkvWithMetadata(), second, asc('XX-TRAIL-secret')]);
      final r = await run('a.mkv', input);
      expect(r.status, CleanStatus.verifiedClean);
      final out = output(r);
      expect(out.length, input.length);
      for (final s in ['secret', 'Camera of John']) {
        expect(has(out, s), isFalse, reason: s);
      }
      expect(indexOfBytes(out, asc(mkvBlockText)),
          indexOfBytes(input, asc(mkvBlockText)));
      await expectIdempotent('b.mkv', out);
    });
  });

  group('GIF', () {
    test('the loop extension keeps its loop count only', () async {
      final input = cat([
        asc('GIF89a'),
        [1, 0, 1, 0, 0x80, 0, 0],
        [0, 0, 0, 255, 255, 255],
        [0x21, 0xFF, 11, ...asc('NETSCAPE2.0'), 3, 1, 5, 0],
        [6, ...asc('SECRET'), 0],
        [0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0],
        [2, 2, 0x44, 0x01, 0],
        [0x3B],
      ]);
      final r = await run('a.gif', input);
      expect(r.status, CleanStatus.verifiedClean);
      final out = output(r);
      expect(has(out, 'SECRET'), isFalse);
      expect(indexOfBytes(out, [...asc('NETSCAPE2.0'), 3, 1, 5, 0, 0]),
          isPositive);
      await expectIdempotent('b.gif', out);
    });
  });

  group('TIFF', () {
    test('data no IFD points to is zeroed', () async {
      final input = cat([tiffWithMetadata(), asc('OLD-IFD Nikon secret')]);
      final r = await run('a.tif', input);
      expect(r.status, CleanStatus.verifiedClean);
      final out = output(r);
      expect(has(out, 'Nikon secret'), isFalse);
      expect(out.length, input.length);
      expect(indexOfBytes(out, asc(tiffPixels)),
          indexOfBytes(input, asc(tiffPixels)));
      await expectIdempotent('b.tif', out);
    });
  });

  group('MP4 fragments', () {
    Uint8List moof(int trackId, int base) => isoBox('moof', [
          ...isoBox('mfhd', [0, 0, 0, 0, ...be32(1)]),
          ...isoBox('traf', [
            ...isoBox('tfhd', [0, 0, 0, 1, ...be32(trackId), ...be64(base)]),
            ...isoBox('trun', [0, 0, 0, 0, ...be32(0)]),
          ]),
        ]);

    test('absolute base offsets follow the moved media data', () async {
      final plain = mp4WithMetadata();
      final base = indexOfBytes(plain, videoSample);
      final r = await run('a.mp4', cat([plain, moof(1, base)]));
      expect(r.isClean, isTrue, reason: '${r.status} ${r.errorMessage}');
      final out = output(r);
      final tfhd = indexOfBytes(out, asc('tfhd'));
      final moved = u64be(out, tfhd + 12);
      expect(moved, isNot(base)); // moov shrank, free was dropped
      expect(out.sublist(moved, moved + videoSample.length).take(4),
          videoSample.take(4));
    });

    test('a GPS track with fragments is refused, not half cleaned', () async {
      final plain = mp4WithMetadata(timedMetaTrack: true);
      // The fixture's tracks have track_ID 0.
      final r = await run('a.mp4', cat([plain, moof(0, 0)]));
      expect(r.status, CleanStatus.unsupported);
      expect(r.hasOutput, isFalse);
    });
  });
}

Uint8List be64(int v) {
  final b = Uint8List(8);
  putU64be(b, 0, v);
  return b;
}
