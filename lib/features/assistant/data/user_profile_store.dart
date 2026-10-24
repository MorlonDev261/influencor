import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:meta/meta.dart';

import 'assistant_config_store.dart';

/// What Degany knows about the user, gathered from the conversation and from
/// the user's own content: name, activity, audience, pages, site, contacts,
/// preferred tone… One free-form value per key.
@immutable
class UserProfile {
  const UserProfile({this.fields = const {}, this.updatedAt});

  final Map<String, String> fields;
  final DateTime? updatedAt;

  bool get isEmpty => fields.isEmpty;

  /// At most this many facts are kept, each at most [maxValueLength] long.
  static const maxFields = 80;
  static const maxValueLength = 500;

  /// `"Page Facebook"` → `page_facebook`, so the same fact keeps one key.
  static String normalizeKey(String key) {
    final k = key
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-./]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return k.length > 40 ? k.substring(0, 40) : k;
  }

  static final _secretKey = RegExp(
    r'pass|mot_de_passe|(^|_)(mdp|pin|otp|cvv|cvc|puk)(_|$)|secret|token|'
    r'api_?key|cle_api|iban|carte_bancaire|numero_carte|card_number|'
    r'credit_card|seed|private_key|cle_privee',
  );

  /// Facts that must never be kept: passwords, PINs and codes, card numbers,
  /// keys and tokens.
  static bool isSecret(String key, String value) {
    if (_secretKey.hasMatch(normalizeKey(key))) return true;
    // A bank card number: 13 to 19 digits (spaces or dashes allowed) that
    // pass the card checksum. Phone numbers are shorter or fail it.
    for (final m
        in RegExp(r'(?<![\d+])(?:\d[ \-]?){12,18}\d(?!\d)').allMatches(value)) {
      if (_luhn(m[0]!.replaceAll(RegExp(r'\D'), ''))) return true;
    }
    return RegExp(r'^(sk|pk|rk)-[A-Za-z0-9_\-]{16,}$').hasMatch(value.trim());
  }

  static bool _luhn(String digits) {
    var sum = 0;
    for (var i = 0; i < digits.length; i++) {
      var d = digits.codeUnitAt(digits.length - 1 - i) - 48;
      if (i.isOdd) {
        d *= 2;
        if (d > 9) d -= 9;
      }
      sum += d;
    }
    return sum % 10 == 0;
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'fields': fields,
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      };

  static UserProfile fromJson(Object? raw) {
    if (raw is! Map) return const UserProfile();
    final fields = raw['fields'];
    return UserProfile(
      fields: {
        if (fields is Map)
          for (final e in fields.entries)
            if (e.value is String && '${e.key}'.isNotEmpty)
              '${e.key}': e.value as String,
      },
      updatedAt: DateTime.tryParse('${raw['updatedAt']}'),
    );
  }
}

/// Keeps the [UserProfile] in the operating system's protected store
/// (Android Keystore, Apple Keychain, Windows DPAPI, libsecret, WebCrypto):
/// encrypted, readable by this app only, never in the workspace or a plain
/// file. Without a working store it lives for the session only.
class UserProfileStore {
  UserProfileStore({SecretStore secrets = const SystemSecretStore()})
      : _secrets = secrets;

  final SecretStore _secrets;

  static const _key = 'influencor.assistant.userProfile';

  Future<UserProfile> load() async {
    try {
      final raw = await _secrets.read(_key);
      if (raw == null || raw.isEmpty) return const UserProfile();
      return UserProfile.fromJson(jsonDecode(raw));
    } catch (e) {
      debugPrint('Assistant: profile unavailable ($e)');
      return const UserProfile();
    }
  }

  /// Returns false when the secure storage is unavailable (nothing is then
  /// written anywhere).
  Future<bool> save(UserProfile profile) async {
    try {
      if (profile.isEmpty) {
        await _secrets.delete(_key);
      } else {
        await _secrets.write(_key, jsonEncode(profile.toJson()));
      }
      return true;
    } catch (e) {
      debugPrint('Assistant: profile not saved ($e)');
      return false;
    }
  }

  Future<bool> clear() => save(const UserProfile());
}
