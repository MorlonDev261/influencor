import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:super_clipboard/super_clipboard.dart';

typedef _Image = ({
  String name,
  String path,
  SimpleFileFormat format,
  Uint8List bytes,
});

final bool _desktop =
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;
typedef _FileAttachment = ({String name, Uri uri});

/// Writes [text] and the readable [imagePaths] to the system clipboard.
///
/// Each image becomes its own clipboard item with a suggested file name, so it
/// pastes as an actual **file** (into a file manager, chat, etc.), not just as
/// an in-memory image. The text rides on the first item as an extra
/// representation, so a single paste gives the text in text fields and the
/// image/file elsewhere. Non-image attachments are added as file URIs where the
/// platform clipboard supports them. Returns the number of files written
/// (0 = text only).
Future<int> copyNoteToClipboard(String text, List<String> imagePaths) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) {
    await Clipboard.setData(ClipboardData(text: text));
    return 0;
  }

  final images = <_Image>[];
  final files = <_FileAttachment>[];
  for (final path in imagePaths) {
    final format = _formatFor(path);
    try {
      if (!await File(path).exists()) continue;
      if (format == null) {
        // Android rejects file:// URIs on the clipboard
        // (FileUriExposedException), which would fail the whole copy, text
        // included; mobile paste targets cannot use them anyway.
        if (_desktop) files.add((name: p.basename(path), uri: Uri.file(path)));
      } else {
        images.add((
          name: p.basename(path),
          path: path,
          format: format,
          bytes: await File(path).readAsBytes(),
        ));
      }
    } catch (_) {
      // Skip unreadable/missing files.
    }
  }

  if (images.isEmpty && files.isEmpty) {
    if (text.isNotEmpty) {
      await clipboard.write([DataWriterItem()..add(Formats.plainText(text))]);
    } else {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
    return 0;
  }

  final items = <DataWriterItem>[];
  if (images.isNotEmpty) {
    final firstImage = images.first;
    // suggestedName makes the receiving app treat the image data as a file.
    final first = DataWriterItem(suggestedName: firstImage.name);
    // HTML with the caption + every image inlined, so a single paste into an
    // HTML-aware composer (many social/web editors, Gmail, Docs…) inserts the
    // note together with its images.
    // Skipped for media-only copies: a base64 blob is huge and some clipboards
    // reject it, which made plain "copy media" fail.
    // Not on Android: the HTML travels inline in the ClipData, and a photo in
    // base64 exceeds the ~1 MB Binder limit, so the copy would fail.
    if (text.isNotEmpty) {
      if (!Platform.isAndroid) {
        first.add(Formats.htmlText(_buildHtml(text, images)));
      }
      first.add(Formats.plainText(text));
    }
    await _addImage(first, firstImage);
    // On desktop also expose the real file so it pastes into file managers.
    if (_desktop && images.length == 1 && files.isEmpty) {
      first.add(Formats.fileUri(Uri.file(firstImage.path)));
    }
    items.add(first);
  } else if (text.isNotEmpty) {
    items.add(DataWriterItem()..add(Formats.plainText(text)));
  }
  for (final image in images.skip(1)) {
    items.add(
      await _addImage(DataWriterItem(suggestedName: image.name), image),
    );
  }
  for (final file in files) {
    items.add(
      DataWriterItem(suggestedName: file.name)..add(Formats.fileUri(file.uri)),
    );
  }
  await clipboard.write(items);
  return images.length + files.length;
}

/// Builds an HTML fragment: the caption (line breaks preserved) followed by
/// each image inlined as a base64 data URI.
String _buildHtml(String text, List<_Image> images) {
  final sb = StringBuffer();
  if (text.isNotEmpty) {
    sb.write('<div>${_escapeHtml(text).replaceAll('\n', '<br>')}</div>');
  }
  for (final image in images) {
    final data = base64Encode(image.bytes);
    sb.write('<div><img src="data:${_mime(image.name)};base64,$data"></div>');
  }
  return sb.toString();
}

String _escapeHtml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _mime(String name) {
  switch (p.extension(name).toLowerCase()) {
    case '.png':
      return 'image/png';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.bmp':
      return 'image/bmp';
    case '.tif':
    case '.tiff':
      return 'image/tiff';
    default:
      return 'image/jpeg';
  }
}

/// The clipboard image format for [path], or null if unsupported.
SimpleFileFormat? _formatFor(String path) {
  switch (p.extension(path).toLowerCase()) {
    case '.png':
      return Formats.png;
    case '.jpg':
    case '.jpeg':
      return Formats.jpeg;
    case '.gif':
      return Formats.gif;
    case '.webp':
      return Formats.webp;
    case '.bmp':
      return Formats.bmp;
    case '.tif':
    case '.tiff':
      return Formats.tiff;
    default:
      return null;
  }
}

/// Adds [image] to [item] in its own format plus a PNG rendition: PNG is the
/// image format virtually every paste target (Paint, chat apps, editors) reads,
/// whereas JPEG/WebP/GIF are ignored by many on Windows.
Future<DataWriterItem> _addImage(DataWriterItem item, _Image image) async {
  if (image.format != Formats.png) {
    final png = await _toPng(image.bytes);
    if (png != null) item.add(Formats.png(png));
  }
  item.add(image.format(image.bytes));
  return item;
}

Future<Uint8List?> _toPng(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
