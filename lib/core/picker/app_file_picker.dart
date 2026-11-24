import 'package:file_picker/file_picker.dart' as native;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/library/domain/library_entry.dart';
import '../l10n/app_strings.dart';
import 'pick_mode.dart';
import 'picked_media_stub.dart' if (dart.library.io) 'picked_media_io.dart'
    as picked;
// The in-app workspace browser needs dart:io, which does not compile for web.
import 'browser_launcher_stub.dart'
    if (dart.library.io) 'browser_launcher_io.dart' as launcher;

/// Entry point for choosing files or a folder.
///
/// Two worlds, never mixed:
/// - **Inside the workspace** ([root] given): the app's own browser / gallery,
///   confined to that folder.
/// - **Everything else** (phone storage, gallery, other apps, the computer's
///   disks): the system's own pickers, like any other app — the photo picker
///   / gallery, the Files app or Documents UI, the desktop file dialog. The app
///   never browses the device itself.
abstract final class AppFilePicker {
  /// Returns the selected absolute paths (empty if the user cancels). For
  /// [PickMode.directory] the list holds at most one path.
  ///
  /// On Android and iOS, files chosen in the system pickers are usually
  /// temporary copies: use them right away (import, attach, clean) and call
  /// [releaseTemporaryFiles] when done.
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
    return pickFromDevice(
      context,
      mode: mode,
      allowMultiple: allowMultiple,
      title: title,
    );
  }

  /// System pickers only (see the class doc). Media picks on a phone first ask
  /// "gallery or files", as messaging and social apps do.
  static Future<List<String>> pickFromDevice(
    BuildContext context, {
    required PickMode mode,
    bool allowMultiple = true,
    String? title,
  }) async {
    switch (mode) {
      case PickMode.directory:
        return _directory(title);
      case PickMode.files:
        return _files(native.FileType.any, null, allowMultiple, title);
      case PickMode.imageFiles:
        return _isMobile
            ? _gallery(mode, allowMultiple)
            : _media(mode, allowMultiple, title);
      case PickMode.mediaFiles:
        if (!_isMobile) return _media(mode, allowMultiple, title);
        final source = await _askSource(context, title, const [
          _Source.gallery,
          _Source.files,
        ]);
        return switch (source) {
          _Source.gallery => _gallery(mode, allowMultiple),
          _Source.files => _media(mode, allowMultiple, title),
          _ => const <String>[],
        };
    }
  }

  /// Files or a whole folder to import into the library, through the system
  /// pickers. Always a copy: the system hands over copies on phones, and the
  /// originals outside the app are never touched.
  static Future<List<String>> pickForImport(
    BuildContext context, {
    String? title,
  }) async {
    if (kIsWeb) {
      return _files(native.FileType.any, null, true, title);
    }
    final source = await _askSource(context, title, [
      if (_isMobile) _Source.gallery,
      _Source.files,
      _Source.folder,
    ]);
    switch (source) {
      case null:
        return const [];
      case _Source.gallery:
        return _gallery(PickMode.mediaFiles, true);
      case _Source.files:
        return _files(native.FileType.any, null, true, title);
      case _Source.folder:
        return _directory(title);
    }
  }

  /// Deletes the temporary copies the system pickers made on Android / iOS.
  /// Best effort; a no-op elsewhere.
  static Future<void> releaseTemporaryFiles() async {
    if (!_isMobile) return;
    try {
      await native.FilePicker.clearTemporaryFiles();
    } catch (_) {
      // The OS purges its cache anyway.
    }
  }

  static bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// The phone's gallery: Android photo picker, iOS photo library (PHPicker).
  /// Neither needs a storage permission.
  static Future<List<String>> _gallery(
    PickMode mode,
    bool allowMultiple,
  ) async {
    final result = await native.FilePicker.pickFiles(
      type: mode == PickMode.imageFiles
          ? native.FileType.image
          : native.FileType.media,
      allowMultiple: allowMultiple,
      // iOS: any value > 0 asks Photos for its "compatible" copy: JPEG instead
      // of HEIC (which gets no thumbnail here), H.264 instead of HEVC.
      compressionQuality: _isIOS ? 100 : 0,
    );
    final paths =
        result?.files.map((f) => f.path).whereType<String>().toList() ??
            const <String>[];
    return _isIOS ? picked.relocatePickedMedia(paths) : paths;
  }

  /// The system file browser restricted to images / videos / cleanable
  /// documents (Files app, Android Documents UI, desktop dialog).
  static Future<List<String>> _media(
    PickMode mode,
    bool allowMultiple,
    String? title,
  ) {
    if (mode == PickMode.imageFiles) {
      return _files(native.FileType.image, null, allowMultiple, title);
    }
    final extensions = [
      ...imageExtensions,
      ...videoExtensions,
      ...cleanableDocumentExtensions,
    ].map((ext) => ext.replaceFirst('.', '')).toList();
    return _files(native.FileType.custom, extensions, allowMultiple, title);
  }

  static Future<List<String>> _files(
    native.FileType type,
    List<String>? extensions,
    bool allowMultiple,
    String? title,
  ) async {
    final result = await native.FilePicker.pickFiles(
      type: type,
      allowedExtensions: extensions,
      allowMultiple: allowMultiple,
      dialogTitle: title,
    );
    return result?.files.map((f) => f.path).whereType<String>().toList() ??
        const [];
  }

  static Future<List<String>> _directory(String? title) async {
    final dir = await native.FilePicker.getDirectoryPath(dialogTitle: title);
    // Android returns "/" for folders it will not expose.
    return dir == null || dir.isEmpty || dir == '/' ? const [] : [dir];
  }

  static Future<_Source?> _askSource(
    BuildContext context,
    String? title,
    List<_Source> sources,
  ) {
    final strings = ProviderScope.containerOf(context).read(appStringsProvider);
    if (sources.length == 1) return Future.value(sources.single);
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
            for (final source in sources)
              ListTile(
                leading: Icon(switch (source) {
                  _Source.gallery => Icons.photo_library_outlined,
                  _Source.files => Icons.insert_drive_file_outlined,
                  _Source.folder => Icons.folder_outlined,
                }),
                title: Text(switch (source) {
                  _Source.gallery => strings.sourcePhotos,
                  _Source.files => strings.sourceFiles,
                  _Source.folder => strings.sourceFolder,
                }),
                onTap: () => Navigator.pop(ctx, source),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

enum _Source { gallery, files, folder }
