import 'dart:typed_data';

import '../../domain/clean_options.dart';
import '../../domain/clean_report.dart';
import '../binary.dart';
import '../format_handler.dart';

/// AVI (RIFF). Metadata chunks are blanked **in place**: each one becomes a
/// `JUNK` chunk of the same size filled with zeros, so no byte moves and every
/// offset stays valid — `idx1` (relative *or* absolute offsets) and the
/// OpenDML `indx` super-index (always absolute).
///
/// Blanked wherever they sit (top level or inside `hdrl` / `strl` / `odml`):
/// `LIST INFO` (title, software, creation date…), `IDIT` / `ISMP` date and
/// timecode stamps, stream names (`strn`), any unknown chunk or list (camera
/// vendor blocks such as `LIST ncdt`), and the content of `JUNK` padding,
/// where some cameras write their make and model. Data after the RIFF chunk is
/// dropped.
class AviHandler extends ByteFormatHandler {
  const AviHandler();

  /// Chunks needed to play the file, per enclosing list ('' = top level).
  static const _keep = <String, Set<String>>{
    '': {'idx1'},
    'hdrl': {'avih'},
    'strl': {'strh', 'strf', 'strd', 'indx', 'vprp'},
    'odml': {'dmlh'},
  };

  /// Lists walked into, per enclosing list. `movi` (the frames) is kept as is.
  static const _lists = <String, Set<String>>{
    '': {'hdrl'},
    'hdrl': {'strl', 'odml'},
  };

  @override
  MediaFormat get format => MediaFormat.avi;

  @override
  HandlerResult process(
    Uint8List b,
    CleanOptions options,
    BytesBuilder? out,
  ) {
    if (b.length < 12 ||
        !startsWithAscii(b, 0, 'RIFF') ||
        !startsWithAscii(b, 8, 'AVI ')) {
      throw const FormatException('Not an AVI');
    }
    final declared = u32le(b, 4) + 8;
    final fileEnd = declared < b.length ? declared : b.length;
    final findings = <MetadataFinding>[];
    if (b.length > declared) {
      findings.add(MetadataFinding(
          MetadataCategory.trailingData, 'data after RIFF',
          bytes: b.length - declared));
    }
    final copy = out == null ? null : Uint8List.fromList(b.sublist(0, fileEnd));

    // Turns [start, end) into a zero-filled JUNK chunk of the same size.
    void blank(int start, int end) {
      if (copy == null) return;
      copy.setRange(start, start + 4, ascii4('JUNK'));
      copy.fillRange(start + 8, end, 0);
    }

    void walk(int from, int to, String list) {
      var offset = from;
      while (offset + 8 <= to) {
        final id = fourcc(b, offset);
        final size = u32le(b, offset + 4);
        final dataStart = offset + 8;
        final dataEnd = dataStart + size;
        if (dataEnd > to) throw const FormatException('Truncated AVI');
        final padded = dataEnd + (size.isOdd ? 1 : 0);
        final end = padded > to ? to : padded;
        final listType =
            id == 'LIST' && size >= 4 ? fourcc(b, dataStart) : null;
        if (listType == 'INFO') {
          findings.add(MetadataFinding(
            MetadataCategory.container,
            'LIST INFO',
            bytes: end - offset,
            entries: _infoEntries(b, dataStart + 4, dataEnd),
          ));
          blank(offset, end);
        } else if (listType != null &&
            (_lists[list]?.contains(listType) ?? false)) {
          walk(dataStart + 4, dataEnd, listType);
        } else if (listType == 'movi' && list.isEmpty) {
          // Frames: untouched.
        } else if (id == 'JUNK') {
          if (b.sublist(dataStart, dataEnd).any((v) => v != 0)) {
            findings.add(MetadataFinding(
                MetadataCategory.container, 'JUNK data',
                bytes: end - offset,
                entries: [
                  MetadataEntry('JUNK', latin1Text(b, dataStart, dataEnd)),
                ]));
            blank(offset, end);
          }
        } else if (id == 'IDIT' || id == 'ISMP') {
          findings.add(MetadataFinding(MetadataCategory.dateTime, id,
              bytes: end - offset,
              entries: [MetadataEntry(id, latin1Text(b, dataStart, dataEnd))]));
          blank(offset, end);
        } else if (id == 'strn') {
          findings.add(MetadataFinding(MetadataCategory.comment, 'stream name',
              bytes: end - offset,
              entries: [
                MetadataEntry('Stream name', latin1Text(b, dataStart, dataEnd)),
              ]));
          blank(offset, end);
        } else if (listType == null && (_keep[list]?.contains(id) ?? false)) {
          // Needed for playback.
        } else {
          final label = listType == null ? id : 'LIST $listType';
          findings.add(MetadataFinding(MetadataCategory.container, label,
              bytes: end - offset,
              entries: [MetadataEntry(label, sizeLabel(end - offset))]));
          blank(offset, end);
        }
        offset = end;
      }
    }

    walk(12, fileEnd, '');
    if (copy != null) {
      // The RIFF size must match what is written (trailing data dropped).
      copy.setRange(4, 8, le32(fileEnd - 8));
      out!.add(copy);
    }
    return HandlerResult(findings);
  }

  /// Sub-chunks of a `LIST INFO` (INAM title, ISFT software, ICRD date…).
  static List<MetadataEntry> _infoEntries(Uint8List b, int from, int end) {
    const names = {
      'INAM': 'Title',
      'IART': 'Artist',
      'ISFT': 'Software',
      'ICRD': 'Creation date',
      'ICMT': 'Comment',
      'ICOP': 'Copyright',
      'IGNR': 'Genre',
      'ISRC': 'Source',
      'IENG': 'Engineer',
    };
    final out = <MetadataEntry>[];
    var o = from;
    while (o + 8 <= end && out.length < 20) {
      final id = fourcc(b, o);
      final size = u32le(b, o + 4);
      final dataEnd = o + 8 + size;
      if (dataEnd > end) break;
      out.add(MetadataEntry(names[id] ?? id, latin1Text(b, o + 8, dataEnd)));
      o = dataEnd + (size.isOdd ? 1 : 0);
    }
    return out;
  }
}
