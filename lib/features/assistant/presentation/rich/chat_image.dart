import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../../../app/nav.dart';
import '../../../../core/l10n/app_strings.dart';
import '../../../library/domain/library_entry.dart';
import 'rich_common.dart';

// Pictures in the conversation: the files the user attached, Degany's
// galleries and previews, and Markdown images (![caption](path or URL)).
// One layout everywhere: a single picture shows whole at its own shape, two
// side by side, more in a grid; a tap opens the full viewer, where the
// user can swipe through all of them.

/// A picture of the conversation: a workspace file or a web image.
@immutable
class ChatImageSource {
  const ChatImageSource.file(String this.file, {this.caption = ''})
      : url = null;
  const ChatImageSource.url(Uri this.url, {this.caption = ''}) : file = null;

  final String? file;
  final Uri? url;
  final String caption;

  String get name => file != null
      ? p.basename(file!)
      : (url!.pathSegments.isEmpty ? url!.host : url!.pathSegments.last);

  bool get isVideo => file != null && kindForFile(file!) == EntryKind.video;

  /// Whether Flutter can draw it (HEIC, TIFF… can't be decoded here).
  bool get drawable =>
      url != null || (!kIsWeb && file != null && canRenderThumbnail(file!));
}

/// The source for [src] as written by Degany: an http(s) URL, or a path in
/// the workspace (relative or absolute). Null when it is neither.
ChatImageSource? chatImageSource(String src, String? root,
    {String caption = ''}) {
  final uri = Uri.tryParse(src.trim());
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return ChatImageSource.url(uri, caption: caption);
  }
  final abs = resolveWorkspacePath(src, root);
  return abs == null ? null : ChatImageSource.file(abs, caption: caption);
}

/// `![caption](src "title")` — a Markdown image.
final markdownImage =
    RegExp(r'!\[([^\]\n]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)');

/// The pictures [sources], laid out for the chat.
class ChatImageGallery extends StatelessWidget {
  const ChatImageGallery({
    required this.sources,
    this.alignEnd = false,
    this.maxWidth = 560,
    this.maxHeight = 380,
    super.key,
  });

  final List<ChatImageSource> sources;

  /// Right-aligned (the user's own pictures).
  final bool alignEnd;

  /// Largest size of the whole gallery (and of a single picture).
  final double maxWidth;
  final double maxHeight;

  /// Tiles shown before a "+N" tile.
  static const maxTiles = 12;

  static const _gap = 6.0;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) return const SizedBox.shrink();
    // The viewer swipes through every file picture of the gallery.
    final album = [
      for (final s in sources)
        if (s.file != null) s.file!
    ];
    return LayoutBuilder(builder: (context, c) {
      final width = math.min(c.maxWidth, maxWidth);
      final Widget body;
      if (sources.length == 1) {
        body = _Single(
            source: sources.single,
            album: album,
            maxWidth: width,
            maxHeight: maxHeight);
      } else {
        final n = sources.length;
        final cols =
            n == 2 ? 2 : math.min(n, (width / 150).floor().clamp(3, 5));
        final size = (width - (cols - 1) * _gap) / cols;
        final shown = n > maxTiles ? maxTiles : n;
        body = SizedBox(
          width: width,
          child: Wrap(
            spacing: _gap,
            runSpacing: _gap,
            alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
            children: [
              for (var i = 0; i < shown; i++)
                SizedBox.square(
                  dimension: size,
                  child: _Tile(
                    source: sources[i],
                    album: album,
                    fit: BoxFit.cover,
                    decodeWidth: size,
                    more: i == shown - 1 && n > shown ? n - shown + 1 : 0,
                  ),
                ),
            ],
          ),
        );
      }
      return Align(
        alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
        child: body,
      );
    });
  }
}

/// One picture shown whole, at its own shape, with its caption.
class _Single extends StatelessWidget {
  const _Single({
    required this.source,
    required this.album,
    required this.maxWidth,
    required this.maxHeight,
  });

  final ChatImageSource source;
  final List<String> album;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget picture = source.drawable && !source.isVideo
        ? ConstrainedBox(
            constraints:
                BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
            child: _Tile(
              source: source,
              album: album,
              fit: BoxFit.contain,
              decodeWidth: maxWidth,
              loadingSize: Size(math.min(maxWidth, 320), 200),
            ),
          )
        : SizedBox(
            width: math.min(maxWidth, 320),
            height: 180,
            child: _Tile(
                source: source,
                album: album,
                fit: BoxFit.cover,
                decodeWidth: 320),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        picture,
        if (source.caption.trim().isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: Text(
                source.caption.trim(),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
      ],
    );
  }
}

/// A picture (or a video / an undrawable picture as a tile) that opens the
/// viewer when tapped.
class _Tile extends ConsumerWidget {
  const _Tile({
    required this.source,
    required this.album,
    required this.fit,
    required this.decodeWidth,
    this.loadingSize,
    this.more = 0,
  });

  final ChatImageSource source;
  final List<String> album;
  final BoxFit fit;

  /// Width it is shown at, to decode the picture at that size only.
  final double decodeWidth;

  /// While loading, a picture shown at its own shape has no size yet: hold
  /// this space so the chat doesn't jump.
  final Size? loadingSize;

  /// "+N" over the last tile when the gallery has more pictures.
  final int more;

  void _open(BuildContext context) {
    if (source.url case final url?) {
      unawaited(launchUrl(url, mode: LaunchMode.externalApplication));
      return;
    }
    final file = source.file!;
    unawaited(context.push(previewRoute(file),
        extra: album.contains(file) ? album : [file]));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (decodeWidth * dpr).round().clamp(64, 2048);

    Widget frame(BuildContext context, Widget child, int? frame, bool sync) {
      if (sync) return child;
      if (frame != null) {
        // Fades in once, when the first frame arrives.
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 200),
          builder: (_, t, child) => Opacity(opacity: t, child: child),
          child: child,
        );
      }
      final hold = loadingSize;
      return Container(
        width: hold?.width,
        height: hold?.height,
        color: scheme.surfaceContainerHigh,
      );
    }

    Widget failed(BuildContext context, Object _, StackTrace? __) =>
        _Unavailable(
            source: source, label: strings.richImageUnavailable, icon: null);

    final Widget content;
    if (source.isVideo) {
      content = _Unavailable(
          source: source, label: null, icon: Icons.play_circle_fill_rounded);
    } else if (!source.drawable) {
      content = _Unavailable(
          source: source, label: strings.richNoPreview, icon: null);
    } else if (source.url case final url?) {
      content = Image.network(
        url.toString(),
        fit: fit,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        frameBuilder: frame,
        errorBuilder: failed,
      );
    } else {
      final file = File(source.file!);
      content = file.existsSync()
          ? Image.file(
              file,
              fit: fit,
              cacheWidth: cacheWidth,
              gaplessPlayback: true,
              frameBuilder: frame,
              errorBuilder: failed,
            )
          : _Unavailable(
              source: source, label: strings.richImageUnavailable, icon: null);
    }

    final fill = fit == BoxFit.cover;
    return Tooltip(
      message: source.caption.trim().isEmpty ? source.name : source.caption,
      waitDuration: const Duration(milliseconds: 600),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: fill ? StackFit.expand : StackFit.loose,
          children: [
            if (fill)
              ColoredBox(color: scheme.surfaceContainerHigh, child: content)
            else
              content,
            if (more > 0)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.5),
                  child: Center(
                    child: Text(
                      '+$more',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(
                              color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(onTap: () => _open(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A video, or a picture that can't be drawn here: its icon, its type and
/// its name, on a soft background (instead of a broken image).
class _Unavailable extends StatelessWidget {
  const _Unavailable(
      {required this.source, required this.label, required this.icon});

  final ChatImageSource source;
  final String? label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ext = p.extension(source.name).replaceFirst('.', '').toUpperCase();
    return Container(
      color: source.isVideo
          ? scheme.inverseSurface.withValues(alpha: 0.85)
          : scheme.surfaceContainerHigh,
      padding: const EdgeInsets.all(8),
      alignment: Alignment.center,
      child: LayoutBuilder(builder: (context, c) {
        final small = c.maxHeight < 110;
        final fg =
            source.isVideo ? scheme.onInverseSurface : scheme.onSurfaceVariant;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon ?? Icons.image_outlined,
                color: fg, size: small ? 26 : 36),
            if (ext.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(ext,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: fg, fontWeight: FontWeight.w700)),
              ),
            if (!small) ...[
              const SizedBox(height: 4),
              Text(source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: fg)),
              if (label != null)
                Text(label!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: fg.withValues(alpha: 0.8))),
            ],
          ],
        );
      }),
    );
  }
}
