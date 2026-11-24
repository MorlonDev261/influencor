import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'atomic_file.dart';

/// Distribution channel of this build, set by the release scripts:
/// `play` (Google Play AAB), `apk` (APK of the website). Empty for other
/// builds, which fall back to the platform name (see [resolveUpdateChannel]).
const String _channelDefine = String.fromEnvironment('INFLUENCOR_CHANNEL');

/// Result of the minimum-version check.
@immutable
class UpdateGateStatus {
  const UpdateGateStatus.ok()
      : mustUpdate = false,
        updateUrl = null,
        messages = const {};

  const UpdateGateStatus.blocked({
    required this.updateUrl,
    required this.messages,
  }) : mustUpdate = true;

  /// `true` when this build is older than the channel's `min_build`.
  final bool mustUpdate;

  /// Where to get the new version (store page or website), if any.
  final String? updateUrl;

  /// Message per language code (`fr`, `en`, `mg`) from the remote file.
  final Map<String, String> messages;

  String? messageFor(String languageCode) =>
      messages[languageCode] ?? messages['fr'];
}

/// Channel whose `min_build` applies to this build, or `null` when the check
/// does not apply (web: every reload already serves the latest version).
String? resolveUpdateChannel({
  String define = _channelDefine,
  bool isWeb = kIsWeb,
  TargetPlatform? platform,
}) {
  if (isWeb) return null;
  if (define.isNotEmpty) return define;
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'play';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.linux:
      return 'linux';
    case TargetPlatform.fuchsia:
      return null;
  }
}

/// Pure decision from the remote JSON (see influencor-web
/// `public/app-version.json`). Anything missing or malformed lets the app run.
UpdateGateStatus evaluateUpdateConfig(
  Object? json, {
  required String channel,
  required int currentBuild,
}) {
  if (json is! Map) return const UpdateGateStatus.ok();
  final channels = json['channels'];
  if (channels is! Map) return const UpdateGateStatus.ok();
  final entry = channels[channel];
  if (entry is! Map) return const UpdateGateStatus.ok();
  final minBuild = entry['min_build'];
  if (minBuild is! num || currentBuild >= minBuild) {
    return const UpdateGateStatus.ok();
  }
  final url = entry['update_url'];
  final rawMessages = json['message'];
  return UpdateGateStatus.blocked(
    updateUrl: url is String && url.trim().isNotEmpty ? url.trim() : null,
    messages: {
      if (rawMessages is Map)
        for (final e in rawMessages.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
    },
  );
}

/// Asks the website which builds are still allowed to run.
///
/// Offline-friendly: without network the last downloaded file is used, so an
/// offline user is only blocked once a block has already been seen. A first
/// launch with no network and no cache always opens the app.
class UpdateGateService {
  UpdateGateService({http.Client? client, this.timeout = const Duration(seconds: 6)})
      : _client = client ?? http.Client();

  static final Uri configUri =
      Uri.parse('https://influencor.mi-kandra.org/app-version.json');
  static const _cacheFileName = 'app_version_gate.json';

  final http.Client _client;
  final Duration timeout;

  Future<UpdateGateStatus> check() async {
    final channel = resolveUpdateChannel();
    if (channel == null) return const UpdateGateStatus.ok();

    final int? build;
    try {
      final info = await PackageInfo.fromPlatform();
      build = int.tryParse(info.buildNumber);
    } catch (_) {
      return const UpdateGateStatus.ok();
    }
    if (build == null) return const UpdateGateStatus.ok();

    var body = await _download();
    if (body != null) {
      await _writeCache(body);
    } else {
      body = await _readCache();
    }
    if (body == null) return const UpdateGateStatus.ok();

    try {
      return evaluateUpdateConfig(
        jsonDecode(body),
        channel: channel,
        currentBuild: build,
      );
    } catch (_) {
      return const UpdateGateStatus.ok();
    }
  }

  Future<String?> _download() async {
    try {
      final res = await _client
          .get(configUri, headers: const {'Cache-Control': 'no-cache'})
          .timeout(timeout);
      if (res.statusCode != 200) return null;
      final body = utf8.decode(res.bodyBytes);
      jsonDecode(body); // Never cache a broken file.
      return body;
    } catch (_) {
      return null;
    }
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, _cacheFileName));
  }

  Future<void> _writeCache(String body) async {
    try {
      await writeStringAtomic(await _cacheFile(), body);
    } catch (_) {}
  }

  Future<String?> _readCache() async {
    try {
      final file = await _cacheFile();
      return await file.exists() ? await file.readAsString() : null;
    } catch (_) {
      return null;
    }
  }
}
