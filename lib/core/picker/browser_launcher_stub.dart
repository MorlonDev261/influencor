import 'package:flutter/widgets.dart';

import 'pick_mode.dart';

/// Web stub: there is no filesystem to browse in a browser sandbox, so the
/// in-app browser is never launched (the facade falls back to the native
/// picker on web). Present only so the app compiles for web.
Future<List<String>> launchInAppBrowser(
  BuildContext context, {
  required PickMode mode,
  bool allowMultiple = true,
  String? title,
  String? initialDirectory,
  String? actionLabel,
  String? root,
}) async =>
    const [];

Future<({List<String> paths, bool move})> launchInAppBrowserForImport(
  BuildContext context, {
  String? title,
}) async =>
    (paths: const <String>[], move: false);
