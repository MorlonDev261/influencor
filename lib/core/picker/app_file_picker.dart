import 'package:file_picker/file_picker.dart' as native;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/library/domain/library_entry.dart';
import '../l10n/app_strings.dart';
import 'pick_mode.dart';
import 'picked_media_stub.dart' if (dart.library.io) 'picked_media_io.dart'
    as picked;
// The in-app browser needs dart:io, which does not compile for web. Pick the
// real implementation on desktop/mobile and a stub on web.
import 'browser_launcher_stub.dart'
    if (dart.library.io) 'browser_launcher_io.dart' as launcher;

/// Entry point for choosing files or a folder.
///
/// On desktop/mobile, media picks use the platform-native picker. Directory and
/// library import flows keep the app browser because they need folder browsing
/// and import/move actions. On iOS the app browser only sees the app's own
/// container, so every file pick goes through the system pickers instead
/// (photo library or Files app).
abstract final class AppFilePicker {
  /// Returns the selected absolute paths (empty if the user cancels). For
  /// [PickMode.directory] the list holds at most one path.
  ///
  /// With [root] (the workspace), only what is inside that folder can be
  /// chosen: the in-app browser / gallery opens there and cannot leave it, on
  /// every platform (system pickers would show the whole device).
  static Future<List<String>> pick(
    BuildContext context, {
    required PickMode mode,
    bool allowMultiple = true,
    String? title,
    String? initialDirectory,
    String? actionLabel,
    String? root,
  }) {
    if (root != null && !kIsWeb) {
      return launcher.launchInAppBrowser(
        context,
        mode: mode,
        allowMultiple: allowMultiple,
        title: title,
        initialDirectory: initialDirectory,
        actionLabel: actionLabel,
        root: root,
      );
    }
    if (_isIOS && mode != PickMode.directory) {
      return _pickIOS(context, mode, allowMultiple, title);
    }
    if (kIsWeb || mode == PickMode.imageFiles || mode == PickMode.mediaFiles) {
      return _native(mode, allowMultiple, title);
    }
    return launcher.launchInAppBrowser(
      context,
      mode: mode,
      allowMultiple: allowMultiple,
      title: title,
      initialDirectory: initialDirectory,
      actionLabel: actionLabel,
    );
  }

  /// Opens the file picker for importing into the library. Desktop/mobile show
  /// Import and Move actions on the picker page itself; web falls back to a
  /// copy-style import because the browser cannot move local files.
  static Future<({List<String> paths, bool move})> pickForImport(
    BuildContext context, {
    String? title,
  }) async {
    if (kIsWeb) {
      return (paths: await _native(PickMode.files, true, title), move: false);
    }
    if (_isIOS) {
      // Photos and the Files app hand over copies: there is nothing to move.
      final paths = await _pickIOS(context, PickMode.files, true, title);
      return (paths: paths, move: false);
    }
    return launcher.launchInAppBrowserForImport(context, title: title);
  }

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// iOS: the photo library (PHPicker, no permission needed) or the Files app.
  /// Image-only picks go straight to the photo library.
  static Future<List<String>> _pickIOS(
    BuildContext context,
    PickMode mode,
    bool allowMultiple,
    String? title,
  ) async {
    final source = mode == PickMode.imageFiles
        ? _Source.photos
        : await _askSource(context, title);
    switch (source) {
      case null:
        return const [];
      case _Source.files:
        return _native(mode, allowMultiple, title);
      case _Source.photos:
        final result = await native.FilePicker.pickFiles(
          type: mode == PickMode.imageFiles
              ? native.FileType.image
              : native.FileType.media,
          allowMultiple: allowMultiple,
          // Any value > 0 asks Photos for its "compatible" copy: JPEG instead
          // of HEIC (which gets no thumbnail here), H.264 instead of HEVC.
          compressionQuality: 100,
        );
        final paths =
            result?.files.map((f) => f.path).whereType<String>().toList() ??
                const <String>[];
        return picked.relocatePickedMedia(paths);
    }
  }

  static Future<_Source?> _askSource(BuildContext context, String? title) {
    final strings = ProviderScope.containerOf(context).read(appStringsProvider);
    return showModalBottomSheet<_Source>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                title ?? strings.addFrom,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(strings.sourcePhotos),
              onTap: () => Navigator.pop(ctx, _Source.photos),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(strings.sourceFiles),
              onTap: () => Navigator.pop(ctx, _Source.files),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static Future<List<String>> _native(
    PickMode mode,
    bool allowMultiple,
    String? title,
  ) async {
    if (mode == PickMode.directory) {
      final dir = await native.FilePicker.getDirectoryPath(dialogTitle: title);
      return dir == null ? const [] : [dir];
    }
    final mediaExtensions = [
      ...imageExtensions,
      ...videoExtensions,
      ...cleanableDocumentExtensions,
    ].map((ext) => ext.replaceFirst('.', '')).toList();
    final type = switch (mode) {
      PickMode.imageFiles => native.FileType.image,
      PickMode.mediaFiles => native.FileType.custom,
      _ => native.FileType.any,
    };
    final result = await native.FilePicker.pickFiles(
      type: type,
      allowedExtensions: mode == PickMode.mediaFiles ? mediaExtensions : null,
      allowMultiple: allowMultiple,
      dialogTitle: title,
    );
    return result?.files.map((f) => f.path).whereType<String>().toList() ??
        const [];
  }
}

enum _Source { photos, files }
