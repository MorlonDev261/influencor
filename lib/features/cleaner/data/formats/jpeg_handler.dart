import 'dart:typed_data';

import '../../domain/clean_options.dart';
import '../../domain/clean_report.dart';
import '../binary.dart';
import '../exif_inspector.dart';
import '../format_handler.dart';
import 'jpeg_rotate.dart';

/// JPEG: keeps only the segments needed to decode the picture (+ JFIF, Adobe
/// colour transform, optionally the ICC profile) and re-inserts a minimal EXIF
/// block carrying only the orientation. Everything after EOI is dropped.
class JpegHandler extends ByteFormatHandler {
  const JpegHandler();

  @override
  MediaFormat get format => MediaFormat.jpeg;

  @override
  HandlerResult process(
    Uint8List b,
    CleanOptions options,
    BytesBuilder? out,
  ) {
    final n = b.length;
    if (n < 4 || b[0] != 0xFF || b[1] != 0xD8) {
      throw const FormatException('Not a JPEG');
    }
    final segments = <JpegSegment>[];
    var trailing = 0;
    var i = 2;
    while (i < n) {
      if (b[i] != 0xFF) throw const FormatException('Corrupt JPEG marker');
      while (i < n && b[i] == 0xFF) {
        i++; // fill bytes
      }
      if (i >= n) throw const FormatException('Truncated JPEG');
      final marker = b[i];
      final start = i - 1;
      i++;
      if (marker == 0xD9) {
        segments.add(JpegSegment(marker, start, i));
        trailing = n - i;
        i = n;
        break;
      }
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        segments.add(JpegSegment(marker, start, i));
        continue;
      }
      if (marker == 0x00 || marker == 0xD8) {
        throw const FormatException('Unexpected JPEG marker');
      }
      if (i + 2 > n) throw const FormatException('Truncated JPEG');
      final length = u16be(b, i);
      if (length < 2 || i + length > n) {
        throw const FormatException('Truncated JPEG segment');
      }
      var end = i + length;
      if (marker == 0xDA) {
        // Entropy-coded data runs to the next real marker.
        var j = end;
        while (j + 1 < n) {
          if (b[j] == 0xFF &&
              b[j + 1] != 0x00 &&
              b[j + 1] != 0xFF &&
              !(b[j + 1] >= 0xD0 && b[j + 1] <= 0xD7)) {
            break;
          }
          j++;
        }
        end = j + 1 >= n ? n : j;
      }
      segments.add(JpegSegment(marker, start, end));
      i = end;
    }

    final findings = <MetadataFinding>[];
    if (trailing > 0) {
      findings.add(MetadataFinding(
        MetadataCategory.trailingData,
        'data after end of image',
        bytes: trailing,
      ));
    }

    // Pass 1: classify. `rewrite` maps a segment to replacement bytes.
    final keep = List<bool>.filled(segments.length, true);
    final rewrite = <int, Uint8List>{};
    int? orientation;
    for (var s = 0; s < segments.length; s++) {
      final seg = segments[s];
      final m = seg.marker;
      final size = seg.end - seg.start;
      if ((m >= 0xE0 && m <= 0xEF) || m == 0xFE) {
        final p = seg.start + 4; // payload start
        final pe = seg.end;
        MetadataFinding? f;
        var drop = true;
        if (m == 0xE0 && startsWithAscii(b, p, 'JFIF\u0000')) {
          drop = false;
          if (pe - p < 14) {
            drop = true; // truncated header: nothing a decoder needs
          } else if (size != 18 || b[p + 12] != 0 || b[p + 13] != 0) {
            // A thumbnail, or bytes after the header (anything can hide
            // there): keep the 14-byte header only.
            findings.add(b[p + 12] != 0 || b[p + 13] != 0
                ? MetadataFinding(MetadataCategory.thumbnail, 'JFIF thumbnail',
                    bytes: size)
                : MetadataFinding(
                    MetadataCategory.container, 'data after JFIF header',
                    bytes: size - 18));
            final fixed =
                Uint8List.fromList(b.sublist(seg.start, seg.start + 18));
            fixed[2] = 0;
            fixed[3] = 16; // length = 16: header only, no thumbnail
            fixed[16] = 0;
            fixed[17] = 0;
            rewrite[s] = fixed;
          }
        } else if (m == 0xE0 && startsWithAscii(b, p, 'JFXX')) {
          f = MetadataFinding(MetadataCategory.thumbnail, 'JFXX thumbnail',
              bytes: size);
        } else if (m == 0xEE &&
            startsWithAscii(b, p, 'Adobe') &&
            pe - p >= 12) {
          drop = false; // colour transform flag: needed to decode correctly
          if (size != 16) {
            // Only the 12-byte payload is defined; drop anything after it.
            findings.add(MetadataFinding(
                MetadataCategory.container, 'data after Adobe header',
                bytes: size - 16));
            final fixed =
                Uint8List.fromList(b.sublist(seg.start, seg.start + 16));
            fixed[2] = 0;
            fixed[3] = 14;
            rewrite[s] = fixed;
          }
        } else if (m == 0xE2 && startsWithAscii(b, p, 'ICC_PROFILE\u0000')) {
          final k = options.keepColorProfile;
          drop = !k;
          findings.add(MetadataFinding(
              MetadataCategory.colorProfile, 'ICC profile',
              bytes: size, sensitive: false));
        } else if (m == 0xE2 && startsWithAscii(b, p, 'MPF\u0000')) {
          f = MetadataFinding(MetadataCategory.thumbnail, 'multi-picture (MPF)',
              bytes: size);
        } else if (m == 0xE1 && startsWithAscii(b, p, 'Exif\u0000\u0000')) {
          final info = ExifInspector.inspect(b, p + 6, pe);
          orientation ??= info.orientation;
          for (final e in info.findings) {
            findings.add(e.copyWith(bytes: e.sensitive ? size : 0));
          }
        } else if (m == 0xE1 && startsWithAscii(b, p, 'http://ns.adobe.com/')) {
          f = MetadataFinding(MetadataCategory.xmp, 'XMP', bytes: size);
        } else if (m == 0xED && startsWithAscii(b, p, 'Photoshop 3.0')) {
          f = MetadataFinding(MetadataCategory.iptc, 'IPTC / Photoshop IRB',
              bytes: size);
        } else if (m == 0xFE) {
          f = MetadataFinding(MetadataCategory.comment, 'JPEG comment',
              bytes: size,
              entries: [MetadataEntry('Comment', latin1Text(b, p, pe))]);
        } else {
          f = MetadataFinding(
              MetadataCategory.container, 'APP${m - 0xE0} segment',
              bytes: size);
        }
        if (f != null) findings.add(f);
        keep[s] = !drop;
      }
    }

    final caveats = <CleanCaveat>{};
    if (out != null) {
      final rotated =
          options.bakeOrientation && orientation != null && orientation > 1
              ? rotateJpegLossless(b, segments, orientation)
              : null;
      if (rotated != null) {
        // Rotation now lives in the coefficients: no orientation flag at all.
        out.add(const [0xFF, 0xD8]);
        for (var s = 0; s < segments.length; s++) {
          final m = segments[s].marker;
          if (!keep[s] || !((m >= 0xE0 && m <= 0xEF) || m == 0xFE)) continue;
          out.add(rewrite[s] ?? b.sublist(segments[s].start, segments[s].end));
        }
        out.add(rotated);
        out.add(const [0xFF, 0xD9]);
        return HandlerResult(findings, caveats);
      }
      final wantsFlag =
          options.keepOrientationFlag && orientation != null && orientation > 1;
      if (options.bakeOrientation && wantsFlag) {
        caveats.add(CleanCaveat.orientationFlagKept);
      }
      final exifOrientation = wantsFlag ? orientation : null;
      var exifWritten = exifOrientation == null;
      out.add(const [0xFF, 0xD8]);
      for (var s = 0; s < segments.length; s++) {
        if (!keep[s]) continue;
        final seg = segments[s];
        if (!exifWritten && seg.marker != 0xE0) {
          out.add(_exifSegment(exifOrientation!));
          exifWritten = true;
        }
        out.add(rewrite[s] ?? b.sublist(seg.start, seg.end));
      }
    }
    return HandlerResult(findings, caveats);
  }

  static Uint8List _exifSegment(int orientation) {
    final tiff = ExifInspector.minimalTiff(orientation);
    final body = BytesBuilder(copy: false)
      ..add(const [0xFF, 0xE1])
      ..add(be16(2 + 6 + tiff.length))
      ..add(const [0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
      ..add(tiff);
    return body.takeBytes();
  }
}
