import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/clean_options.dart';
import '../../domain/clean_report.dart';
import '../binary.dart';
import '../format_handler.dart';
import '../unsupported_content.dart';
import 'iso/heif_meta.dart';
import 'iso/iso_node.dart';
import 'iso/meta_reader.dart';
import 'iso/sample_table.dart';
import 'iso/video_scrub.dart';

class _TopBox {
  _TopBox(this.type, this.start, this.size, this.headerSize);

  final String type;
  final int start;
  final int size;
  final int headerSize;

  int get end => start + size;
}

/// Everything collected while walking `moov`.
class _Ctx {
  final findings = <MetadataFinding>[];
  final caveats = <CleanCaveat>{};
  final offsetBoxes = <IsoNode>[]; // stco / co64
  final zero = <ByteRange>[]; // payload of dropped tracks
  final video = <VideoTarget>[];

  /// `track_ID` of the dropped timed-metadata tracks.
  final droppedTracks = <int>{};

  /// File positions of the absolute `base_data_offset` of fragment headers.
  final baseOffsets = <int>[];

  /// A fragment (`moof`) still carries samples of a dropped track.
  var fragmentOfDroppedTrack = false;
}

class _Plan {
  _Plan(this.kept, this.rebuilt, this.ctx, this.heif);

  final List<_TopBox> kept;

  /// Top-level boxes replaced by a rebuilt tree (moov, and meta for HEIF).
  final Map<_TopBox, IsoNode> rebuilt;
  final _Ctx ctx;
  final HeifMetaResult? heif;
}

/// MP4 / MOV / M4V and (with [heif]) HEIC / AVIF.
///
/// Sample data (`mdat`) is copied byte-for-byte and streamed, so memory is
/// bounded by the `moov`/`meta` size, not the file size.
///
/// * Dropped: `udta`, `meta` (QuickTime `mdta` keys: GPS, make, model, creation
///   date, Live-Photo identifier…), `uuid`/XMP boxes, `free`/`skip` padding,
///   `mfra`, and timed-metadata tracks (`meta`, `camm`, `gpmd`…).
/// * Blanked in place: creation/modification times, handler names, codec
///   "compressor name" strings, the bytes of dropped tracks and of removed
///   Exif/XMP items, and x264-style user-data SEI units.
/// * Because `moov`/`meta` shrink, every `stco`/`co64` and `iloc` offset is
///   remapped so playback / decoding keeps working.
class IsoBmffHandler extends FormatHandler {
  const IsoBmffHandler({this.heif = false});

  final bool heif;

  static const _topKeep = {
    'ftyp', 'styp', 'moov', 'mdat', 'moof', 'sidx', 'ssix', //
  };
  static const _padding = {'free', 'skip', 'wide', 'mfra', 'pnot'};

  static const _moovKeep = {'mvhd', 'trak', 'mvex', 'iods'};
  static const _trakKeep = {'tkhd', 'tref', 'edts', 'mdia', 'trgr', 'tapt'};
  static const _mdiaKeep = {'mdhd', 'hdlr', 'minf'};
  static const _minfKeep = {
    'vmhd', 'smhd', 'hmhd', 'nmhd', 'gmhd', 'sthd', 'dinf', 'stbl', 'hdlr', //
  };

  /// Handler types of tracks that only carry metadata samples.
  static const _timedMetadata = {'meta', 'camm', 'gpmd', 'nrtm', 'mebx'};

  @override
  MediaFormat get format => heif ? MediaFormat.heif : MediaFormat.isoVideo;

  @override
  Future<HandlerResult> scan(File file, CleanOptions options) async {
    final raf = await file.open();
    try {
      final plan = await _plan(raf, await raf.length());
      final seiTexts = <String>[];
      final sei = await VideoScrub.run(raf, plan.ctx.video, (o) => o,
          write: false, texts: seiTexts);
      if (sei > 0) _noteSei(plan.ctx, sei, seiTexts);
      return HandlerResult(plan.ctx.findings, plan.ctx.caveats);
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
    final outRaf = await output.open(mode: FileMode.write);
    try {
      final plan = await _plan(inRaf, await inRaf.length());
      if (plan.ctx.fragmentOfDroppedTrack) {
        // Its samples sit in fragments we do not rewrite: refuse rather than
        // hand back a file that still holds the GPS / sensor track.
        throw const UnsupportedContent(
            'Fragmented video with a timed metadata track (GPS…) is not '
            'supported');
      }

      // New layout: kept boxes in original order, rebuilt boxes at new size.
      final newStart = <_TopBox, int>{};
      var pos = 0;
      for (final box in plan.kept) {
        newStart[box] = pos;
        pos += plan.rebuilt[box]?.size ?? box.size;
      }
      int mapOffset(int old) {
        for (final box in plan.kept) {
          if (plan.rebuilt.containsKey(box)) continue;
          if (old >= box.start && old < box.end) {
            return newStart[box]! + (old - box.start);
          }
        }
        throw const FormatException('Offset points outside kept data');
      }

      _remapOffsets(plan, mapOffset);
      final baseOffsets = <int, int>{};
      for (final field in plan.ctx.baseOffsets) {
        await inRaf.setPosition(field);
        final old = await inRaf.read(8);
        if (old.length != 8) throw const FormatException('Truncated tfhd');
        baseOffsets[mapOffset(field)] = mapOffset(u64be(old, 0));
      }

      for (final box in plan.kept) {
        final node = plan.rebuilt[box];
        if (node != null) {
          await outRaf.writeFrom(node.toBytes());
        } else {
          await _copy(inRaf, outRaf, box.start, box.size);
        }
      }

      // Fragment headers pointing at absolute positions follow the new layout.
      for (final e in baseOffsets.entries) {
        final value = Uint8List(8);
        putU64be(value, 0, e.value);
        await outRaf.setPosition(e.key);
        await outRaf.writeFrom(value);
      }

      // Blank the bytes of removed tracks / items in place (offsets unchanged).
      for (final r in [...plan.ctx.zero, ...?plan.heif?.zeroRanges]) {
        if (r.length == 0) continue;
        final start = mapOffset(r.offset);
        if (mapOffset(r.offset + r.length - 1) != start + r.length - 1) {
          throw const FormatException('Blanked range spans several boxes');
        }
        await _zeroRange(outRaf, start, r.length);
      }

      final seiTexts = <String>[];
      final sei = await VideoScrub.run(outRaf, plan.ctx.video, mapOffset,
          write: true, texts: seiTexts);
      if (sei > 0) _noteSei(plan.ctx, sei, seiTexts);
      await outRaf.flush();
      return HandlerResult(plan.ctx.findings, plan.ctx.caveats);
    } finally {
      await inRaf.close();
      await outRaf.close();
    }
  }

  void _noteSei(_Ctx ctx, int n, List<String> texts) =>
      ctx.findings.add(MetadataFinding(
        MetadataCategory.device,
        'encoder user-data SEI x$n',
        entries: [
          for (final t in texts.toSet().take(3))
            MetadataEntry('Encoder SEI', t.isEmpty ? '<binary data>' : t),
        ],
      ));

  // -- planning ------------------------------------------------------------

  Future<List<_TopBox>> _topLevel(RandomAccessFile raf, int length) async {
    final boxes = <_TopBox>[];
    var pos = 0;
    while (pos + 8 <= length) {
      await raf.setPosition(pos);
      final head = await raf.read(16);
      if (head.length < 8) break;
      final size32 = u32be(head, 0);
      final type = fourcc(head, 4);
      int size;
      var headerSize = 8;
      if (size32 == 1) {
        if (head.length < 16) throw const FormatException('Truncated box');
        size = u64be(head, 8);
        headerSize = 16;
      } else if (size32 == 0) {
        size = length - pos;
      } else {
        size = size32;
      }
      if (size < headerSize || pos + size > length) {
        throw FormatException('Truncated or corrupt box "$type"');
      }
      boxes.add(_TopBox(type, pos, size, headerSize));
      pos += size;
    }
    return boxes;
  }

  Future<_Plan> _plan(RandomAccessFile raf, int length) async {
    final tops = await _topLevel(raf, length);
    if (tops.isEmpty) throw const FormatException('Empty media file');
    // HEIF must declare its brand; classic QuickTime may omit `ftyp`.
    if (heif && tops.first.type != 'ftyp') {
      throw const FormatException('Missing ftyp box');
    }
    final ctx = _Ctx();
    final kept = <_TopBox>[];
    final rebuilt = <_TopBox, IsoNode>{};
    HeifMetaResult? heifResult;
    _TopBox? moovBox;
    _TopBox? metaBox;
    for (final box in tops) {
      final isMeta = heif && box.type == 'meta';
      if (_topKeep.contains(box.type) || isMeta) {
        kept.add(box);
        if (box.type == 'moov') {
          if (moovBox != null) throw const FormatException('Two moov boxes');
          moovBox = box;
        } else if (isMeta) {
          if (metaBox != null) throw const FormatException('Two meta boxes');
          metaBox = box;
        }
      } else if (_padding.contains(box.type)) {
        ctx.findings.add(MetadataFinding(MetadataCategory.container, box.type,
            bytes: box.size, sensitive: false));
      } else {
        ctx.findings.add(await _describeDropped(raf, box));
      }
    }
    if (tops.last.end < length) {
      ctx.findings.add(MetadataFinding(
          MetadataCategory.trailingData, 'bytes after last box',
          bytes: length - tops.last.end));
    }

    if (heif) {
      if (metaBox == null) throw const FormatException('HEIF without meta');
      final payload = await _readPayload(raf, metaBox);
      heifResult =
          await HeifMeta.clean(payload, ctx.findings, (offset, len) async {
        await raf.setPosition(offset);
        return raf.read(len);
      });
      rebuilt[metaBox] = heifResult.meta;
    } else if (moovBox == null) {
      throw const FormatException('Missing moov box');
    }
    if (moovBox != null) {
      final payload = await _readPayload(raf, moovBox);
      final moov = IsoNode('moov', kids: _cleanMoov(payload, ctx));
      if (!moov.kids!.any((k) => k.type == 'mvhd')) {
        throw const FormatException('moov has no mvhd (compressed moov?)');
      }
      rebuilt[moovBox] = moov;
    }
    for (final box in kept.where((b) => b.type == 'moof')) {
      _scanMoof(await _readPayload(raf, box), box.start + box.headerSize, ctx);
    }
    return _Plan(kept, rebuilt, ctx, heifResult);
  }

  /// Fragment headers (`moof/traf/tfhd`): notes the absolute
  /// `base_data_offset`s, which must follow when boxes move, and fragments of
  /// a dropped track. [at] is the file position of `d[0]`.
  void _scanMoof(Uint8List d, int at, _Ctx ctx) {
    for (final (type, start, end) in _boxes(d, 0, d.length)) {
      if (type != 'traf') continue;
      for (final (t, s, e) in _boxes(d, start, end)) {
        if (t != 'tfhd') continue;
        if (e - s < 8) throw const FormatException('Corrupt tfhd');
        if (ctx.droppedTracks.contains(u32be(d, s + 4))) {
          ctx.fragmentOfDroppedTrack = true;
        }
        if (d[s + 3] & 1 != 0) {
          if (e - s < 16) throw const FormatException('Corrupt tfhd');
          ctx.baseOffsets.add(at + s + 8);
        }
      }
    }
  }

  /// (type, payload start, payload end) of the boxes in `d[start, end)`.
  static List<(String, int, int)> _boxes(Uint8List d, int start, int end) {
    final boxes = <(String, int, int)>[];
    var o = start;
    while (o + 8 <= end) {
      final size32 = u32be(d, o);
      var header = 8;
      var size = size32;
      if (size32 == 1) {
        if (o + 16 > end) throw const FormatException('Truncated box');
        size = u64be(d, o + 8);
        header = 16;
      } else if (size32 == 0) {
        size = end - o;
      }
      if (size < header || o + size > end) {
        throw const FormatException('Corrupt fragment box');
      }
      boxes.add((fourcc(d, o + 4), o + header, o + size));
      o += size;
    }
    return boxes;
  }

  Future<Uint8List> _readPayload(RandomAccessFile raf, _TopBox box) async {
    await raf.setPosition(box.start + box.headerSize);
    final b = await raf.read(box.size - box.headerSize);
    if (b.length != box.size - box.headerSize) {
      throw const FormatException('Unexpected end of file');
    }
    return b;
  }

  Future<MetadataFinding> _describeDropped(
    RandomAccessFile raf,
    _TopBox box,
  ) async {
    var peek = Uint8List(0);
    if (box.size <= 4 * 1024 * 1024) {
      await raf.setPosition(box.start);
      peek = await raf.read(box.size);
    }
    return _classifyDropped(box.type, peek, box.size,
        payload: peek.length > box.headerSize
            ? Uint8List.sublistView(peek, box.headerSize)
            : null);
  }

  /// Classifies a dropped metadata box by sniffing its payload for the well
  /// known QuickTime / iTunes keys, so the report can say *what* it held.
  MetadataFinding _classifyDropped(String type, Uint8List bytes, int size,
      {Uint8List? payload}) {
    final text = latin1.decode(bytes, allowInvalid: true);
    var category = MetadataCategory.container;
    bool has(String s) => text.contains(s);
    if (has('©xyz') || has('ISO6709') || has('location')) {
      category = MetadataCategory.gps;
    } else if (has('©mak') ||
        has('©mod') ||
        has('quicktime.make') ||
        has('quicktime.model') ||
        has('quicktime.software') ||
        has('©swr')) {
      category = MetadataCategory.device;
    } else if (has('©day') || has('creationdate')) {
      category = MetadataCategory.dateTime;
    } else if (has('xmpmeta') || has('adobe.com/xap')) {
      category = MetadataCategory.xmp;
    }
    final entries = payload == null || (type != 'udta' && type != 'meta')
        ? const <MetadataEntry>[]
        : IsoMetaReader.read(type, payload);
    return MetadataFinding(category, type, bytes: size, entries: entries);
  }

  MetadataFinding _dropped(IsoNode n) =>
      _classifyDropped(n.type, n.data!, n.data!.length + 8, payload: n.data);

  List<IsoNode> _cleanMoov(Uint8List payload, _Ctx ctx) {
    final result = <IsoNode>[];
    for (final node in IsoNode.parse(payload)) {
      if (!_moovKeep.contains(node.type)) {
        ctx.findings.add(_dropped(node));
      } else if (node.type == 'mvhd') {
        result.add(_zeroTimes(node, ctx));
      } else if (node.type == 'trak') {
        final trak = _cleanTrak(node, ctx);
        if (trak != null) result.add(trak);
      } else {
        result.add(node);
      }
    }
    return result;
  }

  String? _handlerType(IsoNode trak) {
    final mdia = IsoNode.find(IsoNode.parse(trak.data!), 'mdia');
    if (mdia == null) return null;
    final hdlr = IsoNode.find(IsoNode.parse(mdia.data!), 'hdlr');
    final d = hdlr?.data;
    return d == null || d.length < 12 ? null : fourcc(d, 8);
  }

  IsoNode? _cleanTrak(IsoNode node, _Ctx ctx) {
    final handler = _handlerType(node);
    if (_timedMetadata.contains(handler)) {
      // Drop the track and blank the sample bytes it left inside mdat.
      final mdia = IsoNode.find(IsoNode.parse(node.data!), 'mdia')!;
      final minf = IsoNode.find(IsoNode.parse(mdia.data!), 'minf');
      final stbl =
          minf == null ? null : IsoNode.find(IsoNode.parse(minf.data!), 'stbl');
      if (stbl != null) {
        ctx.zero.addAll(SampleTable.merged(IsoNode.parse(stbl.data!)));
      }
      final tkhd = IsoNode.find(IsoNode.parse(node.data!), 'tkhd')?.data;
      if (tkhd != null && tkhd.isNotEmpty) {
        final at = tkhd[0] == 1 ? 20 : 12; // after version/flags and times
        if (tkhd.length >= at + 4) ctx.droppedTracks.add(u32be(tkhd, at));
      }
      ctx.findings.add(MetadataFinding(
          MetadataCategory.timedTrack, 'timed metadata track ($handler)',
          bytes: node.size));
      return null;
    }
    final kids = <IsoNode>[];
    for (final child in IsoNode.parse(node.data!)) {
      if (!_trakKeep.contains(child.type)) {
        ctx.findings.add(_dropped(child));
      } else if (child.type == 'tkhd') {
        kids.add(_zeroTimes(child, ctx));
      } else if (child.type == 'mdia') {
        kids.add(_cleanMdia(child, handler, ctx));
      } else {
        kids.add(child);
      }
    }
    return IsoNode('trak', kids: kids);
  }

  IsoNode _cleanMdia(IsoNode node, String? handler, _Ctx ctx) {
    final kids = <IsoNode>[];
    for (final child in IsoNode.parse(node.data!)) {
      if (!_mdiaKeep.contains(child.type)) {
        ctx.findings.add(_dropped(child));
      } else if (child.type == 'mdhd') {
        kids.add(_zeroTimes(child, ctx));
      } else if (child.type == 'hdlr') {
        kids.add(_blankHandlerName(child, ctx));
      } else if (child.type == 'minf') {
        kids.add(_cleanMinf(child, handler, ctx));
      } else {
        kids.add(child);
      }
    }
    return IsoNode('mdia', kids: kids);
  }

  IsoNode _cleanMinf(IsoNode node, String? handler, _Ctx ctx) {
    final kids = <IsoNode>[];
    for (final child in IsoNode.parse(node.data!)) {
      if (!_minfKeep.contains(child.type)) {
        ctx.findings.add(_dropped(child));
      } else if (child.type == 'hdlr') {
        kids.add(_blankHandlerName(child, ctx));
      } else if (child.type == 'stbl') {
        kids.add(_cleanStbl(child, handler, ctx));
      } else {
        kids.add(child);
      }
    }
    return IsoNode('minf', kids: kids);
  }

  IsoNode _cleanStbl(IsoNode node, String? handler, _Ctx ctx) {
    final kids = IsoNode.parse(node.data!);
    for (final k in kids) {
      if (k.type == 'stco' || k.type == 'co64') ctx.offsetBoxes.add(k);
    }
    if (handler == 'vide') {
      final stsd = IsoNode.find(kids, 'stsd');
      if (stsd != null) _cleanStsd(stsd, kids, ctx);
    }
    return IsoNode('stbl', kids: kids);
  }

  /// Blanks the 32-byte "compressor name" of every visual sample entry and
  /// registers H.264 / HEVC tracks for SEI scrubbing.
  void _cleanStsd(IsoNode stsd, List<IsoNode> stbl, _Ctx ctx) {
    final d = Uint8List.fromList(stsd.data!);
    if (d.length < 16) return;
    final count = u32be(d, 4);
    var o = 8;
    VideoCodec? codec;
    var lengthSize = 4;
    var unknownCodec = false;
    var named = false;
    String? compressor;
    for (var i = 0; i < count && o + 8 <= d.length; i++) {
      final size = u32be(d, o);
      if (size < 8 || o + size > d.length) {
        throw const FormatException('Corrupt stsd entry');
      }
      final type = fourcc(d, o + 4);
      final payload = o + 8; // sample-entry payload
      if (size - 8 >= 78) {
        for (var k = payload + 42; k < payload + 74; k++) {
          if (d[k] != 0) named = true;
        }
        if (named && compressor == null) {
          final len = d[payload + 42];
          compressor =
              latin1Text(d, payload + 43, payload + 43 + (len > 31 ? 31 : len));
        }
        d.fillRange(payload + 42, payload + 74, 0);
        final c = switch (type) {
          'avc1' || 'avc3' || 'dvav' || 'dva1' => VideoCodec.avc,
          'hvc1' || 'hev1' || 'dvhe' || 'dvh1' => VideoCodec.hevc,
          _ => null,
        };
        if (c == null) {
          unknownCodec = true;
        } else {
          codec = c;
          for (final child in IsoNode.parse(d, payload + 78, o + size)) {
            final cd = child.data!;
            if (child.type == 'avcC' && cd.length > 4) {
              lengthSize = (cd[4] & 3) + 1;
            } else if (child.type == 'hvcC' && cd.length > 21) {
              lengthSize = (cd[21] & 3) + 1;
            }
          }
        }
      }
      o += size;
    }
    if (named) {
      ctx.findings.add(MetadataFinding(
          MetadataCategory.container, 'codec compressor name',
          sensitive: false,
          entries: [MetadataEntry('Compressor name', compressor ?? '')]));
    }
    stsd.data = d;
    if (unknownCodec) ctx.caveats.add(CleanCaveat.unsupportedCodecStream);
    if (codec != null && !unknownCodec) {
      try {
        ctx.video
            .add(VideoTarget(codec, lengthSize, SampleTable.samples(stbl)));
      } on FormatException {
        // Sample tables we cannot walk (compact sizes…): the SEI scrub is
        // skipped for this track and the report says so.
        ctx.caveats.add(CleanCaveat.unsupportedCodecStream);
      }
    }
  }

  /// Zeroes creation / modification time in `mvhd`, `tkhd` and `mdhd`.
  IsoNode _zeroTimes(IsoNode node, _Ctx ctx) {
    final d = node.data!;
    if (d.isEmpty) return node;
    final width = d[0] == 1 ? 8 : 4;
    final end = 4 + 2 * width;
    if (d.length < end) return node;
    var any = false;
    for (var i = 4; i < end; i++) {
      if (d[i] != 0) any = true;
    }
    if (!any) return node;
    String stamp(int at) {
      var secs = 0;
      for (var i = 0; i < width; i++) {
        secs = (secs << 8) | d[at + i];
      }
      if (secs == 0) return '-';
      final t = DateTime.utc(1904).add(Duration(seconds: secs));
      return t.toIso8601String().replaceFirst('T', ' ').split('.').first;
    }

    ctx.findings.add(MetadataFinding(
        MetadataCategory.dateTime, '${node.type} timestamps',
        bytes: 2 * width,
        entries: [
          MetadataEntry('${node.type} created', stamp(4)),
          MetadataEntry('${node.type} modified', stamp(4 + width)),
        ]));
    final copy = Uint8List.fromList(d)..fillRange(4, end, 0);
    return IsoNode(node.type, data: copy);
  }

  /// `hdlr`: keeps the handler type, clears vendor fields and the name
  /// ("Core Media Video", "Mainconcept Video Media Handler").
  IsoNode _blankHandlerName(IsoNode node, _Ctx ctx) {
    final d = node.data!;
    if (d.length < 24) return node;
    var dirty = d.length != 25 || d[24] != 0;
    for (var i = 12; i < 24; i++) {
      if (d[i] != 0) dirty = true;
    }
    if (!dirty) return node;
    if (d.length > 25) {
      ctx.findings.add(MetadataFinding(
          MetadataCategory.container, 'handler name',
          bytes: d.length - 24,
          sensitive: false,
          entries: [MetadataEntry('Handler name', _pascalOrC(d, 24))]));
    }
    final copy = Uint8List(25)..setRange(0, 12, d);
    return IsoNode(node.type, data: copy);
  }

  /// A QuickTime (length-prefixed) or ISO (NUL-terminated) name at [at].
  String _pascalOrC(Uint8List d, int at) {
    if (at >= d.length) return '';
    final first = d[at];
    if (first > 0 && first < 64 && at + 1 + first <= d.length) {
      final inner = d.sublist(at + 1, at + 1 + first);
      if (inner.every((c) => c >= 32 && c < 127)) {
        return latin1Text(inner, 0, inner.length);
      }
    }
    var e = at;
    while (e < d.length && d[e] != 0) {
      e++;
    }
    return latin1Text(d, at, e);
  }

  // -- offsets -------------------------------------------------------------

  void _remapOffsets(_Plan plan, int Function(int) map) {
    for (final node in plan.ctx.offsetBoxes) {
      final d = node.data!;
      if (d.length < 8) throw const FormatException('Corrupt chunk offset box');
      final count = u32be(d, 4);
      final wide = node.type == 'co64';
      final step = wide ? 8 : 4;
      if (8 + count * step > d.length) {
        throw const FormatException('Corrupt chunk offset table');
      }
      final copy = Uint8List.fromList(d);
      for (var i = 0; i < count; i++) {
        final at = 8 + i * step;
        final mapped = map(wide ? u64be(copy, at) : u32be(copy, at));
        if (wide) {
          putU64be(copy, at, mapped);
        } else {
          if (mapped > 0xFFFFFFFF) {
            throw const FormatException('Chunk offset exceeds 32 bits');
          }
          putU32be(copy, at, mapped);
        }
      }
      node.data = copy;
    }
    plan.heif?.remap(map);
  }

  Future<void> _zeroRange(RandomAccessFile raf, int start, int length) async {
    final block = Uint8List(length < (1 << 20) ? length : (1 << 20));
    await raf.setPosition(start);
    var left = length;
    while (left > 0) {
      final n = left < block.length ? left : block.length;
      await raf.writeFrom(block, 0, n);
      left -= n;
    }
  }

  Future<void> _copy(
    RandomAccessFile from,
    RandomAccessFile to,
    int start,
    int length,
  ) async {
    const chunk = 1 << 20;
    await from.setPosition(start);
    var left = length;
    while (left > 0) {
      final data = await from.read(left < chunk ? left : chunk);
      if (data.isEmpty) throw const FormatException('Unexpected end of file');
      await to.writeFrom(data);
      left -= data.length;
    }
  }
}
