import 'package:flutter/widgets.dart';

import 'pick_mode.dart';

/// Web stub: there is no filesystem to browse in a browser sandbox, so the
/// in-app workspace browser is never launched (the facade uses the browser's
/// own picker on web). Present only so the app compiles for web.
Future<List<String>> launchInAppBrowser(
  BuildContext context, {
  required PickMode mode,
  required String root,
  bool allowMultiple = true,
  String? title,
  String? initialDirectory,
  String? actionLabel,
}) async =>
    const [];
