import 'dart:typed_data';

import '../../domain/clean_options.dart';
import '../../domain/clean_report.dart';
import '../binary.dart';
import '../format_handler.dart';

/// GIF: walks the real block structure (never scans raw bytes, which could hit
/// 0x21 0xFE inside LZW data). Keeps graphic-control and the animation loop
/// extension; drops comments, plain-text overlays and all other application
/// extensions (XMP, vendor blocks). Data after the trailer is dropped.
class GifHandler extends ByteFormatHandler {
  const GifHandler();

  @override
  MediaFormat get format => MediaFormat.gif;

  @override
  HandlerResult process(
    Uint8List b,
    CleanOptions options,
    BytesBuilder? out,
  ) {
    final n = b.length;
    if (n < 13 ||
        !(startsWithAscii(b, 0, 'GIF87a') || startsWithAscii(b, 0, 'GIF89a'))) {
      throw const FormatException('Not a GIF');
    }
    void need(int upTo) {
      if (upTo > n) throw const FormatException('Truncated GIF');
    }

    int skipSubBlocks(int i) {
      while (true) {
        need(i + 1);
        final size = b[i++];
        if (size == 0) return i;
        i += size;
        need(i);
      }
    }

    final findings = <MetadataFinding>[];
    final flags = b[10];
    var i = 13 + ((flags & 0x80) != 0 ? 3 * (1 << ((flags & 7) + 1)) : 0);
    need(i);
    out?.add(b.sublist(0, i));

    var sawTrailer = false;
    while (i < n) {
      final introducer = b[i];
      if (introducer == 0x3B) {
        sawTrailer = true;
        i++;
        if (i < n) {
          findings.add(MetadataFinding(
              MetadataCategory.trailingData, 'data after trailer',
              bytes: n - i));
        }
        out?.addByte(0x3B);
        break;
      } else if (introducer == 0x21) {
        need(i + 2);
        final label = b[i + 1];
        final start = i;
        var keep = label == 0xF9; // graphic control
        MetadataFinding? finding;
        if (label == 0xFF) {
          need(i + 14);
          final isAnim = b[i + 2] == 11 &&
              (startsWithAscii(b, i + 3, 'NETSCAPE2.0') ||
                  startsWithAscii(b, i + 3, 'ANIMEXTS1.0'));
          keep = isAnim;
          if (!isAnim) {
            final isXmp = startsWithAscii(b, i + 3, 'XMP DataXMP');
            finding = MetadataFinding(
              isXmp ? MetadataCategory.xmp : MetadataCategory.container,
              isXmp ? 'XMP' : 'application extension',
            );
          }
        } else if (label == 0xFE) {
          finding =
              const MetadataFinding(MetadataCategory.comment, 'GIF comment');
        } else if (label == 0x01) {
          finding = const MetadataFinding(
              MetadataCategory.comment, 'plain-text extension');
        } else if (label != 0xF9) {
          finding = const MetadataFinding(
              MetadataCategory.container, 'unknown extension');
        }
        i = skipSubBlocks(i + 2);
        if (keep && label == 0xFF) {
          // Loop extension: only its loop-count sub-block is needed; any
          // other sub-block could carry arbitrary data.
          final canonical = _loopExtension(b, start, i);
          if (canonical.length != i - start) {
            findings.add(MetadataFinding(
                MetadataCategory.container, 'application extension data',
                bytes: i - start - canonical.length));
          }
          out?.add(canonical);
          continue;
        }
        if (finding != null) {
          findings.add(finding.copyWith(
            bytes: i - start,
            entries: label == 0xFE
                ? [MetadataEntry('Comment', _commentText(b, start + 2))]
                : [MetadataEntry(finding.label, sizeLabel(i - start))],
          ));
        }
        if (keep) out?.add(b.sublist(start, i));
      } else if (introducer == 0x2C) {
        final start = i;
        need(i + 11);
        final f = b[i + 9];
        i += 10 + ((f & 0x80) != 0 ? 3 * (1 << ((f & 7) + 1)) : 0);
        need(i + 1);
        i++; // LZW minimum code size
        i = skipSubBlocks(i);
        out?.add(b.sublist(start, i));
      } else {
        throw const FormatException('Corrupt GIF block');
      }
    }
    if (!sawTrailer) out?.addByte(0x3B);
    return HandlerResult(findings);
  }

  /// The NETSCAPE2.0 / ANIMEXTS1.0 block in [start, end) reduced to its
  /// 14-byte header, its loop-count sub-block (`03 01 lo hi`) and terminator.
  static Uint8List _loopExtension(Uint8List b, int start, int end) {
    final out = BytesBuilder(copy: false)..add(b.sublist(start, start + 14));
    var i = start + 14;
    var looped = false;
    while (i < end && b[i] != 0) {
      final size = b[i];
      if (!looped && size == 3 && b[i + 1] == 1) {
        out.add(b.sublist(i, i + 4));
        looped = true;
      }
      i += 1 + size;
    }
    out.addByte(0);
    return out.takeBytes();
  }

  /// Concatenated sub-blocks of a comment extension starting at [from].
  static String _commentText(Uint8List b, int from) {
    final bytes = BytesBuilder(copy: false);
    var i = from;
    while (i < b.length && b[i] != 0 && bytes.length < 400) {
      final n = b[i++];
      final end = i + n > b.length ? b.length : i + n;
      bytes.add(b.sublist(i, end));
      i = end;
    }
    final data = bytes.takeBytes();
    return latin1Text(data, 0, data.length);
  }
}
