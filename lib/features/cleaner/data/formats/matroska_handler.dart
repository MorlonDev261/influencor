import 'dart:io';
import 'dart:typed_data';

import '../../domain/clean_options.dart';
import '../../domain/clean_report.dart';
import '../binary.dart';
import '../format_handler.dart';

class _Header {
  _Header(this.id, this.start, this.headerLen, this.size);

  final int id;
  final int start;
  final int headerLen;

  /// Payload size, or -1 for "unknown size" (live streams).
  final int size;

  int get payloadStart => start + headerLen;
  int get end => payloadStart + size;
}

class _Target {
  _Target(this.start, this.length, this.finding);

  final int start;
  final int length;
  final MetadataFinding? finding; // null for CRC-32 invalidated by an edit
}

/// Matroska / WebM (EBML). Metadata elements are not removed (that would shift
/// every offset in `SeekHead` / `Cues`) but *overwritten in place* by an EBML
/// `Void` element of the exact same total size, which every demuxer skips.
///
/// Voided: `Tags` (encoder, statistics, titles…), in `Info` the Title,
/// MuxingApp, WritingApp, DateUTC and file-name links, in each `TrackEntry` the
/// Name, and any CRC-32 element the edits would otherwise invalidate.
class MatroskaHandler extends FormatHandler {
  const MatroskaHandler();

  static const _ebml = 0x1A45DFA3;
  static const _segment = 0x18538067;
  static const _info = 0x1549A966;
  static const _tracks = 0x1654AE6B;
  static const _trackEntry = 0xAE;
  static const _tags = 0x1254C367;
  static const _cluster = 0x1F43B675;
  static const _attachments = 0x1941A469;
  static const _void = 0xEC;
  static const _crc32 = 0xBF;

  static const _level1 = {
    0x114D9B74, // SeekHead
    _info,
    _tracks,
    _tags,
    0x1C53BB6B, // Cues
    0x1043A770, // Chapters
    _attachments,
    _cluster,
    _void,
    _crc32,
  };

  static const _infoTargets = <int, (MetadataCategory, String)>{
    0x7BA9: (MetadataCategory.comment, 'Title'),
    0x4D80: (MetadataCategory.device, 'MuxingApp'),
    0x5741: (MetadataCategory.device, 'WritingApp'),
    0x4461: (MetadataCategory.dateTime, 'DateUTC'),
    0x7384: (MetadataCategory.comment, 'SegmentFilename'),
    0x3C83AB: (MetadataCategory.comment, 'PrevFilename'),
    0x3E83BB: (MetadataCategory.comment, 'NextFilename'),
  };

  @override
  MediaFormat get format => MediaFormat.matroska;

  @override
  Future<HandlerResult> scan(File file, CleanOptions options) async {
    final raf = await file.open();
    try {
      return (await _plan(raf, await raf.length())).$1;
    } finally {
      await raf.close();
    }
  }

  @override
  Future<HandlerResult> sanitize(
    File input,
    File output,
    CleanOptions options,
  ) async {
    final inRaf = await input.open();
    try {
      final length = await inRaf.length();
      final (result, targets) = await _plan(inRaf, length);
      // Straight copy, then overwrite the targets in the copy.
      final outRaf = await output.open(mode: FileMode.write);
      try {
        await inRaf.setPosition(0);
        var left = length;
        while (left > 0) {
          final data = await inRaf.read(left < (1 << 20) ? left : (1 << 20));
          if (data.isEmpty) throw const FormatException('Unexpected EOF');
          await outRaf.writeFrom(data);
          left -= data.length;
        }
        for (final t in targets) {
          await _writeVoid(outRaf, t.start, t.length);
        }
        await outRaf.flush();
      } finally {
        await outRaf.close();
      }
      return result;
    } finally {
      await inRaf.close();
    }
  }

  // -- EBML reading --------------------------------------------------------

  Future<_Header?> _read(RandomAccessFile raf, int pos, int limit) async {
    if (pos + 2 > limit) return null;
    await raf.setPosition(pos);
    final b = await raf.read(16);
    if (b.length < 2) return null;
    final idLen = _vintLength(b[0]);
    if (idLen == 0 || idLen > 4 || idLen >= b.length) {
      throw const FormatException('Corrupt EBML element id');
    }
    var id = 0;
    for (var i = 0; i < idLen; i++) {
      id = (id << 8) | b[i];
    }
    final sizeLen = _vintLength(b[idLen]);
    if (sizeLen == 0 || idLen + sizeLen > b.length) {
      throw const FormatException('Corrupt EBML element size');
    }
    var size = b[idLen] & ((1 << (8 - sizeLen)) - 1);
    var allOnes = size == (1 << (8 - sizeLen)) - 1;
    for (var i = 1; i < sizeLen; i++) {
      final v = b[idLen + i];
      size = (size << 8) | v;
      if (v != 0xFF) allOnes = false;
    }
    return _Header(id, pos, idLen + sizeLen, allOnes ? -1 : size);
  }

  int _vintLength(int first) {
    for (var i = 0; i < 8; i++) {
      if (first & (0x80 >> i) != 0) return i + 1;
    }
    return 0;
  }

  Future<(HandlerResult, List<_Target>)> _plan(
      RandomAccessFile raf, int length) async {
    final findings = <MetadataFinding>[];
    final caveats = <CleanCaveat>{};
    final targets = <_Target>[];

    final head = await _read(raf, 0, length);
    if (head == null || head.id != _ebml || head.size < 0) {
      throw const FormatException('Not a Matroska/WebM file');
    }
    // Every Segment is cleaned (chained files hold several); anything else
    // after them is voided: no player needs it and it may hold anything.
    var pos = head.end;
    var segments = 0;
    while (pos < length) {
      _Header? top;
      try {
        top = await _read(raf, pos, length);
      } on FormatException {
        top = null; // garbage: voided below
        if (segments == 0) rethrow;
      }
      if (top != null && top.id == _segment) {
        final segEnd = top.size < 0 ? length : top.end;
        if (segEnd > length) throw const FormatException('Truncated Segment');
        await _segmentTargets(
            raf, top.payloadStart, segEnd, findings, caveats, targets);
        segments++;
        pos = segEnd;
      } else if (top != null &&
          const {_ebml, _void, _crc32}.contains(top.id) &&
          top.size >= 0 &&
          top.end <= length) {
        pos = top.end;
      } else {
        if (segments == 0) throw const FormatException('Missing Segment');
        if (length - pos >= 2) {
          findings.add(MetadataFinding(
              MetadataCategory.trailingData, 'data after Segment',
              bytes: length - pos));
          targets.add(_Target(pos, length - pos, null));
        }
        break;
      }
    }
    if (segments == 0) throw const FormatException('Missing Segment');
    return (HandlerResult(findings, caveats), targets);
  }

  /// Metadata targets among the level-1 elements of one Segment.
  Future<void> _segmentTargets(
    RandomAccessFile raf,
    int start,
    int segEnd,
    List<MetadataFinding> findings,
    Set<CleanCaveat> caveats,
    List<_Target> targets,
  ) async {
    var pos = start;
    while (pos < segEnd) {
      final h = await _read(raf, pos, segEnd);
      if (h == null) break;
      if (h.size >= 0 && h.end > segEnd) {
        throw const FormatException('Element overruns Segment');
      }
      if (h.id == _tags) {
        targets.add(_Target(h.start, h.headerLen + h.size, null));
        findings.add(MetadataFinding(MetadataCategory.container, 'Tags',
            bytes: h.headerLen + h.size));
      } else if (h.id == _info) {
        await _masterTargets(
            raf, h, (id) => _infoTargets[id], findings, targets);
      } else if (h.id == _tracks) {
        await _tracksTargets(raf, h, findings, targets);
      } else if (h.id == _attachments) {
        caveats.add(CleanCaveat.attachmentsKept);
      }
      if (h.size >= 0) {
        pos = h.end;
      } else if (h.id == _cluster) {
        pos = await _skipUnknownCluster(raf, h, segEnd);
      } else {
        throw const FormatException('Unknown-size element');
      }
    }
  }

  /// Children of an unknown-size Cluster run until the next level-1 element.
  Future<int> _skipUnknownCluster(
      RandomAccessFile raf, _Header cluster, int limit) async {
    var pos = cluster.payloadStart;
    while (pos < limit) {
      final c = await _read(raf, pos, limit);
      if (c == null || _level1.contains(c.id)) break;
      if (c.size < 0) throw const FormatException('Nested unknown size');
      pos = c.end;
    }
    return pos;
  }

  Future<void> _masterTargets(
    RandomAccessFile raf,
    _Header master,
    (MetadataCategory, String)? Function(int) pick,
    List<MetadataFinding> findings,
    List<_Target> targets,
  ) async {
    if (master.size < 0) throw const FormatException('Unknown-size master');
    var pos = master.payloadStart;
    final crcs = <_Target>[];
    var edited = false;
    while (pos < master.end) {
      final c = await _read(raf, pos, master.end);
      if (c == null || c.size < 0 || c.end > master.end) {
        throw const FormatException('Corrupt master element');
      }
      final total = c.headerLen + c.size;
      if (c.id == _crc32) crcs.add(_Target(c.start, total, null));
      final hit = pick(c.id);
      if (hit != null) {
        edited = true;
        await raf.setPosition(c.payloadStart);
        final payload = await raf.read(c.size < 400 ? c.size : 400);
        final f = MetadataFinding(hit.$1, hit.$2,
            bytes: total,
            entries: [MetadataEntry(hit.$2, _text(c.id, payload))]);
        targets.add(_Target(c.start, total, f));
        findings.add(f);
      }
      pos = c.end;
    }
    if (edited) targets.addAll(crcs);
  }

  Future<void> _tracksTargets(
    RandomAccessFile raf,
    _Header tracks,
    List<MetadataFinding> findings,
    List<_Target> targets,
  ) async {
    if (tracks.size < 0) throw const FormatException('Unknown-size Tracks');
    var pos = tracks.payloadStart;
    final before = targets.length;
    final crcs = <_Target>[];
    while (pos < tracks.end) {
      final e = await _read(raf, pos, tracks.end);
      if (e == null || e.size < 0 || e.end > tracks.end) {
        throw const FormatException('Corrupt Tracks element');
      }
      if (e.id == _crc32) {
        crcs.add(_Target(e.start, e.headerLen + e.size, null));
      }
      if (e.id == _trackEntry) {
        await _masterTargets(
          raf,
          e,
          (id) =>
              id == 0x536E ? (MetadataCategory.comment, 'Track name') : null,
          findings,
          targets,
        );
      }
      pos = e.end;
    }
    if (targets.length > before) targets.addAll(crcs);
  }

  /// Element payload as text; `DateUTC` is nanoseconds since 2001-01-01.
  String _text(int id, Uint8List payload) {
    if (id == 0x4461 && payload.length == 8) {
      var ns = 0;
      for (final byte in payload) {
        ns = (ns << 8) | byte;
      }
      final t = DateTime.utc(2001).add(Duration(microseconds: ns ~/ 1000));
      return t.toIso8601String().replaceFirst('T', ' ').split('.').first;
    }
    return utf8Text(payload, 0, payload.length);
  }

  // -- writing -------------------------------------------------------------

  /// Overwrites `[start, start+length)` with one Void element of that size.
  Future<void> _writeVoid(RandomAccessFile raf, int start, int length) async {
    for (var s = 1; s <= 8; s++) {
      final payload = length - 1 - s;
      if (payload >= 0 && payload < (1 << (7 * s)) - 1) {
        final head = Uint8List(1 + s);
        head[0] = _void;
        var v = payload;
        for (var i = s; i >= 1; i--) {
          head[i] = v & 0xFF;
          v >>= 8;
        }
        head[1] |= 0x80 >> (s - 1);
        await raf.setPosition(start);
        await raf.writeFrom(head);
        var left = payload;
        final block = Uint8List(left < (1 << 20) ? left : (1 << 20));
        while (left > 0) {
          final n = left < block.length ? left : block.length;
          await raf.writeFrom(block, 0, n);
          left -= n;
        }
        return;
      }
    }
    throw const FormatException('Element too small to void');
  }
}
