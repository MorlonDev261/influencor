import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../domain/clean_options.dart';
import '../../../domain/clean_report.dart';
import '../../binary.dart';
import '../../format_handler.dart';
import '../../unsupported_content.dart';
import '../jpeg_handler.dart';
import 'pdf_parser.dart';

class _Obj {
  _Obj(this.num, this.gen, this.src, this.value,
      {this.dataStart, this.dataEnd});

  final int num;
  final int gen;
  final Uint8List src;
  final PObj value;
  final int? dataStart;
  final int? dataEnd;

  bool get isStream => dataStart != null;
  int get size =>
      value.end - value.start + (isStream ? dataEnd! - dataStart! : 0);
}

class _Edit {
  _Edit(this.start, this.end);

  final int start;
  final int end;
}

/// PDF: rebuilt from scratch rather than patched.
///
/// Every object is read (including those packed in compressed object streams),
/// then only what is reachable from the catalog (`/Root`) is written to a fresh
/// classic file. That drops, in one move: the Info dictionary (author, creator,
/// producer, title, dates), the XMP stream, `/PieceInfo`, page thumbnails,
/// annotation authors/dates, the trailer `/ID`, and every obsolete object left
/// behind by incremental saves — which is where deleted text and old metadata
/// usually survive. EXIF/XMP inside embedded JPEG (DCT) images is stripped
/// in place (length preserved). Encrypted files are refused.
class PdfHandler extends ByteFormatHandler {
  const PdfHandler();

  /// Dropped from every dictionary. `CreationDate` / `ModDate` are optional
  /// wherever they appear (annotations, embedded files' `/Params`…).
  static const _dropKeys = {
    'Metadata', 'PieceInfo', 'Thumb', 'LastModified', 'CreationDate',
    'ModDate', //
  };

  /// Annotation subtypes (PDF 2.0, 12.5.6.1).
  static const _annotSubtypes = {
    'Text', 'Link', 'FreeText', 'Line', 'Square', 'Circle', 'Polygon',
    'PolyLine', 'Highlight', 'Underline', 'Squiggly', 'StrikeOut', 'Caret',
    'Stamp', 'Ink', 'Popup', 'FileAttachment', 'Sound', 'Movie', 'Screen',
    'Widget', 'PrinterMark', 'TrapNet', 'Watermark', '3D', 'Redact',
    'Projection', 'RichMedia', //
  };
  static const _infoKeys = <String, MetadataCategory>{
    'Title': MetadataCategory.comment,
    'Author': MetadataCategory.comment,
    'Subject': MetadataCategory.comment,
    'Keywords': MetadataCategory.comment,
    'Creator': MetadataCategory.device,
    'Producer': MetadataCategory.device,
    'CreationDate': MetadataCategory.dateTime,
    'ModDate': MetadataCategory.dateTime,
    'Trapped': MetadataCategory.container,
  };
  static const _maxBytes = 256 * 1024 * 1024;

  @override
  MediaFormat get format => MediaFormat.pdf;

  @override
  HandlerResult process(Uint8List b, CleanOptions options, BytesBuilder? out) {
    if (b.length > _maxBytes) throw const FormatException('PDF too large');
    final headAt = indexOfBytes(
        Uint8List.sublistView(b, 0, b.length < 1024 ? b.length : 1024),
        '%PDF-'.codeUnits);
    if (headAt < 0) throw const FormatException('Not a PDF');
    final version = String.fromCharCodes(b.sublist(
        headAt + 5, (headAt + 8) <= b.length ? headAt + 8 : b.length));

    final scan = _scanObjects(b);
    final findings = <MetadataFinding>[];

    // Trailers: the last one defining /Root wins; any /Encrypt is fatal.
    PRef? root;
    final infoRefs = <PRef>[];
    for (final t in scan.trailers) {
      if (t.dict['Encrypt'] != null) {
        throw const UnsupportedContent('Encrypted PDFs are not supported');
      }
      final r = t.dict['Root'];
      if (r is PRef) root = r;
      final i = t.dict['Info'];
      if (i is PRef) infoRefs.add(i);
    }
    if (root == null || scan.objs[root.num] == null) {
      throw const FormatException('PDF has no catalog');
    }

    // Info dictionaries (current and from older revisions).
    final infoNums = <int>{};
    final infoEntries = <MetadataCategory, List<MetadataEntry>>{};
    for (final ref in infoRefs) {
      final o = scan.objs[ref.num];
      if (o == null) continue;
      infoNums.add(ref.num);
      final v = o.value;
      if (v is PDict) {
        for (final e in v.entries) {
          final cat = _infoKeys[e.key];
          if (cat != null) {
            (infoEntries[cat] ??= <MetadataEntry>[])
                .add(MetadataEntry(e.key, _pdfText(o.src, e.value)));
          }
        }
      }
    }
    for (final e in infoEntries.entries) {
      findings.add(MetadataFinding(
        e.key,
        'Info: ${e.value.map((x) => x.name).toSet().join(', ')}',
        entries: e.value,
      ));
    }
    if (scan.trailers.any((t) => t.dict['ID'] != null)) {
      findings.add(const MetadataFinding(
          MetadataCategory.container, 'trailer /ID',
          sensitive: false));
    }

    // Reachability from the catalog, applying the edits as we go.
    final visited = <int>{};
    final edits = <int, List<_Edit>>{};
    final stack = <int>[root.num];
    final xmpNums = <int>{};
    while (stack.isNotEmpty) {
      final num = stack.removeLast();
      if (!visited.add(num)) continue;
      final o = scan.objs[num];
      if (o == null) {
        if (scan.malformed.contains(num)) {
          throw FormatException('Damaged PDF object $num');
        }
        continue; // dangling reference: null by spec
      }
      final list = edits[num] = <_Edit>[];
      _walk(o.value, o, scan, list, findings, (n) => stack.add(n), xmpNums);
    }

    // Unreferenced / superseded objects = residue of old revisions.
    var leftover = scan.superseded;
    var leftoverBytes = scan.supersededBytes;
    for (final o in scan.objs.values) {
      if (visited.contains(o.num) || infoNums.contains(o.num)) continue;
      final v = o.value;
      if (v is PDict) {
        final type = v['Type'];
        if (type is PName &&
            const {'XRef', 'ObjStm', 'Metadata'}.contains(type.name)) {
          if (type.name == 'Metadata' && !xmpNums.contains(o.num)) {
            xmpNums.add(o.num);
            findings.add(MetadataFinding(MetadataCategory.xmp, 'XMP stream',
                bytes: o.size));
          }
          continue;
        }
        if (v['Linearized'] != null) continue;
      }
      leftover++;
      leftoverBytes += o.size;
    }
    if (leftover > 0) {
      findings.add(MetadataFinding(MetadataCategory.trailingData,
          '$leftover unused or superseded objects (old revisions)',
          bytes: leftoverBytes));
    }

    if (out != null) {
      _write(out, b, version, scan, root, visited.toList()..sort(), edits,
          findings);
    }
    return HandlerResult(findings);
  }

  /// Text of a PDF string / name / number: handles `(literal)`, `<hex>`,
  /// UTF-16BE (BOM FE FF) and PDFDocEncoding (≈ Latin-1).
  static String _pdfText(Uint8List src, PObj v) {
    if (v is PName) return v.name;
    if (v is PNum) return '${v.value}';
    if (v is PRef) return 'object ${v.num}';
    final raw = src.sublist(v.start, v.end);
    final bytes = <int>[];
    if (raw.isNotEmpty && raw.first == 0x28) {
      for (var i = 1; i < raw.length - 1; i++) {
        var c = raw[i];
        if (c == 0x5C && i + 1 < raw.length - 1) {
          final n = raw[++i];
          c = switch (n) {
            0x6E => 10,
            0x72 => 13,
            0x74 => 9,
            0x62 => 8,
            0x66 => 12,
            _ => n,
          };
          if (n >= 0x30 && n <= 0x37) {
            var oct = n - 0x30;
            for (var k = 0;
                k < 2 &&
                    i + 1 < raw.length - 1 &&
                    raw[i + 1] >= 0x30 &&
                    raw[i + 1] <= 0x37;
                k++) {
              oct = oct * 8 + raw[++i] - 0x30;
            }
            c = oct & 0xFF;
          }
        }
        bytes.add(c);
      }
    } else if (raw.isNotEmpty && raw.first == 0x3C) {
      final hex = String.fromCharCodes(raw.where((c) =>
          (c >= 0x30 && c <= 0x39) ||
          (c | 0x20) >= 0x61 && (c | 0x20) <= 0x66));
      for (var i = 0; i + 1 < hex.length; i += 2) {
        bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
    } else {
      return clipText(String.fromCharCodes(raw));
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final units = <int>[
        for (var i = 2; i + 1 < bytes.length; i += 2)
          (bytes[i] << 8) | bytes[i + 1],
      ];
      return clipText(String.fromCharCodes(units));
    }
    return clipText(latin1.decode(bytes, allowInvalid: true));
  }

  // -- reading ---------------------------------------------------------------

  _Scan _scanObjects(Uint8List b) {
    final parser = PdfParser(b);
    final scan = _Scan();
    var pos = 0;
    final obj = 'obj'.codeUnits;
    final trailerKw = 'trailer'.codeUnits;
    var nextTrailer = indexOfBytes(b, trailerKw);
    while (pos < b.length) {
      final at = indexOfBytes(b, obj, pos);
      if (at < 0) break;
      if (nextTrailer >= 0 && nextTrailer < at) {
        _readTrailer(parser, nextTrailer + 7, scan);
        pos = nextTrailer + 7;
        nextTrailer = indexOfBytes(b, trailerKw, pos);
        continue;
      }
      // "N G obj" at a token boundary, and not "endobj".
      if (at < 4 || b[at - 1] == 0x64 || !PdfParser.isSpace(b[at - 1])) {
        pos = at + 3;
        continue;
      }
      var q = at - 1;
      while (q > 0 && PdfParser.isSpace(b[q])) {
        q--;
      }
      final genEnd = q + 1;
      while (q >= 0 && b[q] >= 0x30 && b[q] <= 0x39) {
        q--;
      }
      final genStart = q + 1;
      if (genStart == genEnd || q < 0 || !PdfParser.isSpace(b[q])) {
        pos = at + 3;
        continue;
      }
      while (q > 0 && PdfParser.isSpace(b[q])) {
        q--;
      }
      final numEnd = q + 1;
      while (q >= 0 && b[q] >= 0x30 && b[q] <= 0x39) {
        q--;
      }
      final numStart = q + 1;
      if (numStart == numEnd || numEnd - numStart > 9) {
        pos = at + 3;
        continue;
      }
      final num = int.parse(String.fromCharCodes(b.sublist(numStart, numEnd)));
      final gen = int.parse(String.fromCharCodes(b.sublist(genStart, genEnd)));
      _Obj o;
      try {
        final value = parser.parse(at + 3);
        final p = parser.skipSpace(value.end);
        if (value is PDict && _startsWith(b, p, 'stream')) {
          var ds = p + 6;
          if (ds < b.length && b[ds] == 13) ds++;
          if (ds < b.length && b[ds] == 10) ds++;
          var de = -1;
          final len = value['Length'];
          if (len is PNum && ds + len.value.toInt() <= b.length) {
            de = ds + len.value.toInt();
            if (!_startsWith(b, parser.skipSpace(de), 'endstream')) de = -1;
          }
          if (de < 0) {
            final es = indexOfBytes(b, 'endstream'.codeUnits, ds);
            if (es < 0) throw const FormatException('Unterminated stream');
            de = es;
            if (de > ds && b[de - 1] == 10) de--;
            if (de > ds && b[de - 1] == 13) de--;
          }
          o = _Obj(num, gen, b, value, dataStart: ds, dataEnd: de);
          pos = de;
        } else {
          o = _Obj(num, gen, b, value);
          pos = value.end;
        }
      } on FormatException {
        // Malformed object: only fatal if the catalog turns out to need it.
        scan.malformed.add(num);
        pos = at + 3;
        continue;
      }
      _register(scan, o);
    }
    // Trailers after the last object (the usual case for a single revision).
    while (nextTrailer >= 0) {
      _readTrailer(parser, nextTrailer + 7, scan);
      nextTrailer = indexOfBytes(b, trailerKw, nextTrailer + 7);
    }
    return scan;
  }

  bool _startsWith(Uint8List b, int p, String s) {
    if (p + s.length > b.length) return false;
    for (var i = 0; i < s.length; i++) {
      if (b[p + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  void _readTrailer(PdfParser parser, int from, _Scan scan) {
    try {
      final v = parser.parse(from);
      if (v is PDict) scan.trailers.add(_Trailer(v, true));
    } on FormatException {
      // damaged trailer: ignore, another may be intact
    }
  }

  void _register(_Scan scan, _Obj o) {
    final prev = scan.objs[o.num];
    if (prev != null) {
      scan.superseded++;
      scan.supersededBytes += prev.size;
    }
    scan.objs[o.num] = o;
    final v = o.value;
    if (v is! PDict) return;
    final type = v['Type'];
    if (type is! PName) return;
    if (type.name == 'XRef') scan.trailers.add(_Trailer(v, false));
    if (type.name == 'ObjStm' && o.isStream) _unpackObjStm(scan, o);
  }

  void _unpackObjStm(_Scan scan, _Obj o) {
    final d = o.value as PDict;
    final filter = d['Filter'];
    final name = filter is PName
        ? filter.name
        : (filter is PArray &&
                filter.items.length == 1 &&
                filter.items[0] is PName)
            ? (filter.items[0] as PName).name
            : null;
    if (name != 'FlateDecode' || d['DecodeParms'] != null) {
      throw const UnsupportedContent('Unsupported object stream encoding');
    }
    final n = d['N'];
    final first = d['First'];
    if (n is! PNum || first is! PNum) {
      throw const FormatException('Corrupt object stream');
    }
    final Uint8List data;
    try {
      data = _inflate(o.src.sublist(o.dataStart!, o.dataEnd!));
    } on UnsupportedContent {
      rethrow;
    } catch (_) {
      throw const FormatException('Corrupt object stream data');
    }
    final hp = PdfParser(data);
    final nums = <int>[];
    final offs = <int>[];
    var p = 0;
    for (var i = 0; i < n.value.toInt(); i++) {
      final a = hp.parse(p);
      final c = hp.parse(a.end);
      if (a is! PNum || c is! PNum) {
        throw const FormatException('Corrupt object stream header');
      }
      nums.add(a.value.toInt());
      offs.add(c.value.toInt());
      p = c.end;
    }
    final fs = first.value.toInt();
    for (var i = 0; i < nums.length; i++) {
      final start = fs + offs[i];
      if (start >= data.length) {
        throw const FormatException('Object stream offset out of range');
      }
      final value = hp.parse(start);
      final prev = scan.objs[nums[i]];
      if (prev != null) {
        scan.superseded++;
        scan.supersededBytes += prev.size;
      }
      scan.objs[nums[i]] = _Obj(nums[i], 0, data, value);
    }
  }

  /// zlib inflate with an output cap, so a crafted stream cannot exhaust memory.
  Uint8List _inflate(List<int> input) {
    final sink = _CapSink(_maxBytes);
    final conv = ZLibDecoder().startChunkedConversion(sink);
    conv.add(input);
    conv.close();
    return sink.result();
  }

  // -- walking & editing --------------------------------------------------

  void _walk(
    PObj v,
    _Obj owner,
    _Scan scan,
    List<_Edit> edits,
    List<MetadataFinding> findings,
    void Function(int) visit,
    Set<int> xmpNums,
  ) {
    if (v is PRef) {
      visit(v.num);
    } else if (v is PArray) {
      for (final i in v.items) {
        _walk(i, owner, scan, edits, findings, visit, xmpNums);
      }
    } else if (v is PDict) {
      final type = v['Type'];
      final subtype = v['Subtype'];
      // `/Type /Annot` is optional: most writers leave it out, so an
      // annotation is also recognised by its subtype and its `/Rect`.
      final isAnnot = (type is PName && type.name == 'Annot') ||
          (subtype is PName &&
              _annotSubtypes.contains(subtype.name) &&
              v['Rect'] != null);
      final isWidget = subtype is PName && subtype.name == 'Widget';
      for (final e in v.entries) {
        var drop = _dropKeys.contains(e.key);
        if (isAnnot && e.key == 'M') drop = true;
        if (isAnnot && e.key == 'T' && !isWidget) drop = true;
        if (!drop) {
          _walk(e.value, owner, scan, edits, findings, visit, xmpNums);
          continue;
        }
        edits.add(_Edit(e.keyStart, e.value.end));
        final val = e.value;
        switch (e.key) {
          case 'Metadata':
            if (val is PRef && xmpNums.add(val.num)) {
              findings.add(MetadataFinding(MetadataCategory.xmp, 'XMP stream',
                  bytes: scan.objs[val.num]?.size ?? 0));
            }
          case 'Thumb':
            findings.add(const MetadataFinding(
                MetadataCategory.thumbnail, 'page thumbnail'));
          case 'T':
            findings.add(MetadataFinding(
                MetadataCategory.comment, 'annotation author', entries: [
              MetadataEntry('Annotation author', _pdfText(owner.src, val))
            ]));
          case 'M' || 'CreationDate' || 'ModDate' || 'LastModified':
            findings.add(
                MetadataFinding(MetadataCategory.dateTime, e.key, entries: [
              MetadataEntry(e.key == 'M' ? 'Annotation date' : e.key,
                  _pdfText(owner.src, val))
            ]));
          default:
            findings.add(MetadataFinding(MetadataCategory.container, e.key));
        }
      }
    }
  }

  // -- writing -------------------------------------------------------------

  void _write(
    BytesBuilder out,
    Uint8List input,
    String version,
    _Scan scan,
    PRef root,
    List<int> nums,
    Map<int, List<_Edit>> edits,
    List<MetadataFinding> findings,
  ) {
    var written = 0;
    void add(List<int> bytes) {
      out.add(bytes);
      written += bytes.length;
    }

    final offsets = <int, int>{};
    add('%PDF-${_cleanVersion(version)}\n%âãÏÓ\n'.codeUnits);
    for (final n in nums) {
      final o = scan.objs[n];
      if (o == null) continue;
      offsets[n] = written;
      add('${o.num} ${o.gen} obj\n'.codeUnits);
      add(_slice(o.src, o.value.start, o.value.end, edits[n] ?? const []));
      if (o.isStream) {
        add('\nstream\n'.codeUnits);
        add(_streamData(o, findings));
        add('\nendstream'.codeUnits);
      }
      add('\nendobj\n'.codeUnits);
    }
    final maxNum = offsets.keys.fold<int>(0, (m, n) => n > m ? n : m);
    // The classic xref table has one 20-byte line per number up to the largest:
    // "999999999 0 obj" would make us write gigabytes.
    if (maxNum > 5 * 1000 * 1000) {
      throw const UnsupportedContent('PDF object numbers are too large');
    }
    final xrefAt = written;
    final xref = StringBuffer('xref\n0 ${maxNum + 1}\n')
      ..write('0000000000 65535 f \n');
    for (var n = 1; n <= maxNum; n++) {
      final off = offsets[n];
      xref.write(off == null
          ? '0000000000 00000 f \n'
          : '${off.toString().padLeft(10, '0')} ${scan.objs[n]!.gen.toString().padLeft(5, '0')} n \n');
    }
    xref
      ..write(
          'trailer\n<< /Size ${maxNum + 1} /Root ${root.num} ${root.gen} R >>\n')
      ..write('startxref\n$xrefAt\n%%EOF\n');
    add(xref.toString().codeUnits);
  }

  String _cleanVersion(String v) => RegExp(r'^\d\.\d$').hasMatch(v) ? v : '1.7';

  Uint8List _slice(Uint8List src, int start, int end, List<_Edit> edits) {
    if (edits.isEmpty) return src.sublist(start, end);
    final sorted = [...edits]..sort((a, b) => a.start.compareTo(b.start));
    final b = BytesBuilder(copy: false);
    var p = start;
    for (final e in sorted) {
      if (e.start < p) continue; // nested inside an already removed entry
      b.add(src.sublist(p, e.start));
      b.addByte(0x20);
      p = e.end;
    }
    b.add(src.sublist(p, end));
    return b.takeBytes();
  }

  /// Embedded JPEG (DCTDecode) images carry their own EXIF / XMP / IPTC: strip
  /// it and zero-pad to the declared length (decoders stop at the EOI marker).
  Uint8List _streamData(_Obj o, List<MetadataFinding> findings) {
    final data = o.src.sublist(o.dataStart!, o.dataEnd!);
    final d = o.value as PDict;
    final f = d['Filter'];
    final isDct = (f is PName && f.name == 'DCTDecode') ||
        (f is PArray &&
            f.items.length == 1 &&
            f.items[0] is PName &&
            (f.items[0] as PName).name == 'DCTDecode');
    if (!isDct) return data;
    try {
      final cleaned = BytesBuilder(copy: false);
      const opts = CleanOptions(preserveOrientation: false);
      // Zero padding from an earlier pass is not "trailing data".
      var end = data.length;
      while (end > 0 && data[end - 1] == 0) {
        end--;
      }
      final r = const JpegHandler()
          .process(Uint8List.sublistView(data, 0, end), opts, cleaned);
      if (!r.findings.any((x) => x.sensitive)) return data;
      for (final x in r.findings.where((x) => x.sensitive)) {
        findings.add(x.copyWith(label: 'image: ${x.label}', entries: [
          for (final e in x.entries) MetadataEntry('Image ${e.name}', e.value),
        ]));
      }
      final bytes = cleaned.takeBytes();
      final padded = Uint8List(data.length)..setRange(0, bytes.length, bytes);
      return padded;
    } on FormatException {
      return data;
    }
  }
}

class _CapSink extends ByteConversionSinkBase {
  _CapSink(this.cap);

  final int cap;
  final _b = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (_b.length + chunk.length > cap) {
      throw const UnsupportedContent('Object stream expands too much');
    }
    _b.add(chunk);
  }

  @override
  void close() {}

  Uint8List result() => _b.takeBytes();
}

class _Trailer {
  _Trailer(this.dict, this.fromTrailer);

  final PDict dict;
  final bool fromTrailer;
}

class _Scan {
  final objs = <int, _Obj>{};
  final trailers = <_Trailer>[];
  final malformed = <int>{};
  var superseded = 0;
  var supersededBytes = 0;
}
