import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Where the reseller space lives and which hosts the in-app browser trusts.
abstract final class ResellerConfig {
  static const host = 'reseller.poma-original.com';
  static const mainHost = 'poma-original.com';

  static final loginUri = Uri.https(host, '/login');

  /// Entry of « Accès professionnel » (About screen): the public page of the
  /// reseller program. Signing in starts from there (« Se connecter »).
  static final aboutUri = Uri.https(host, '/about');

  /// JavaScript channel the site looks for to know it runs inside the app
  /// (see `ClipboardButton` and `ResellerHeader` in the poma-original repo).
  static const appChannel = 'InfluencorApp';
  static final homeUri = Uri.https(host, '/');

  /// The WebView plugin ships for Android, iOS and macOS only; elsewhere the
  /// space is opened in the system browser instead.
  static bool get webViewSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// Hosts that may be shown *inside* the app: the main site (shared login),
  /// the reseller back office and reseller shops (`name.poma-original.com`).
  static bool isTrusted(Uri uri) =>
      uri.scheme == 'https' &&
      (uri.host == mainHost || uri.host.endsWith('.$mainHost'));

  /// A link that belongs to the reseller space (deep links).
  static bool isResellerLink(Uri uri) =>
      uri.scheme == 'https' && uri.host == host;

  /// Asks the page (same origin, cookies included) whether an Auth.js session
  /// exists and reports a boolean back through the `PomaSession` channel. No
  /// token, cookie or user data ever leaves the page.
  ///
  /// [nonce] is embedded in the injected script only (never a global): the
  /// channel is reachable from *every* frame of the page, so a third-party
  /// iframe could otherwise post `{"a":true}` and fake a session.
  static String sessionProbe(String nonce) => '''
(function () {
  try {
    fetch('/api/auth/session', { credentials: 'include', cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (j) {
        PomaSession.postMessage(JSON.stringify({ a: !!(j && j.user), n: '$nonce' }));
      })
      .catch(function () {});
  } catch (e) {}
})();
''';

  /// Tells the page which theme the app shows (`light` / `dark`): stored in
  /// `window.__influencorTheme` (read by the site when its header mounts) and
  /// announced through the `influencor:theme` event (already-mounted header).
  static String themePush(String theme) {
    assert(theme == 'light' || theme == 'dark');
    return '''
(function () {
  try {
    window.__influencorTheme = '$theme';
    window.dispatchEvent(new CustomEvent('influencor:theme', { detail: '$theme' }));
  } catch (e) {}
})();
''';
  }

  /// Registers (`POST`) or removes (`DELETE`) this installation's push token on
  /// `/api/push/native`, from the page itself so the user's session cookie is
  /// used (the token is a JSON-encoded literal, never concatenated raw). The
  /// outcome comes back through the `PomaPush` channel, tagged with [nonce].
  static String pushRequest(
      String nonce, String method, String token, String platform) {
    assert(method == 'POST' || method == 'DELETE');
    assert(platform == 'android' || platform == 'ios');
    return '''
(function () {
  var done = function (ok) {
    try { PomaPush.postMessage(JSON.stringify({ ok: ok, n: '$nonce' })); } catch (e) {}
  };
  try {
    fetch('/api/push/native', {
      method: '$method',
      credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: ${jsonEncode(token)}, platform: '$platform' })
    }).then(function (r) { done(r.ok); }).catch(function () { done(false); });
  } catch (e) { done(false); }
})();
''';
  }

  /// Schemes that may be handed to the system when a page navigates away from
  /// the trusted hosts. Everything else (`intent:`, `file:`, `javascript:`,
  /// `data:`…) is dropped.
  static const externalSchemes = {
    'https',
    'http',
    'mailto',
    'tel',
    'sms',
    'whatsapp'
  };
}
