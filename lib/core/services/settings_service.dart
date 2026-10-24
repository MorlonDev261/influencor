import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'atomic_file.dart';

import '../../shared/enums/enums.dart';
import '../formatting/note_separator.dart';

const supportedLanguageCodes = ['mg', 'fr', 'en'];

String resolveSupportedLanguageCode(String? code, {String fallback = 'fr'}) {
  final normalized = code?.toLowerCase().split(RegExp('[-_]')).first;
  if (normalized != null && supportedLanguageCodes.contains(normalized)) {
    return normalized;
  }
  return fallback;
}

/// User preferences persisted between launches (theme, default view, language).
@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.light,
    this.viewMode = ViewMode.grid,
    this.languageCode = 'fr',
    this.noteSeparator,
    this.reseller = false,
    this.appMode = AppMode.clipboard,
  });

  final ThemeMode themeMode;
  final ViewMode viewMode;
  final String languageCode;
  final String? noteSeparator;

  /// Hidden flag: `true` once a reseller session was created in the app (never
  /// shown in the settings UI; it only reveals the clipboard / reseller badge).
  ///
  /// It means "a session was created" and is **never an access control**: it is
  /// client-side. Every reseller action is authorised by the server.
  final bool reseller;

  /// The space currently shown on the home tab.
  final AppMode appMode;

  AppSettings copyWith({
    ThemeMode? themeMode,
    ViewMode? viewMode,
    String? languageCode,
    String? noteSeparator,
    bool clearNoteSeparator = false,
    bool? reseller,
    AppMode? appMode,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        viewMode: viewMode ?? this.viewMode,
        languageCode: languageCode ?? this.languageCode,
        noteSeparator:
            clearNoteSeparator ? null : noteSeparator ?? this.noteSeparator,
        reseller: reseller ?? this.reseller,
        appMode: appMode ?? this.appMode,
      );

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode.name,
        'viewMode': viewMode.name,
        'languageCode': languageCode,
        if (noteSeparator != null) 'noteSeparator': noteSeparator,
        'reseller': reseller,
        'appMode': appMode.name,
      };

  factory AppSettings.fromJson(
    Map<String, dynamic> json, {
    String fallbackLanguageCode = 'fr',
  }) {
    final rawSeparator = json['noteSeparator'];
    final separator =
        rawSeparator is String ? NoteSeparator.normalize(rawSeparator) : null;
    final rawLanguage = json['languageCode'];
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == json['themeMode'],
        orElse: () => ThemeMode.light,
      ),
      viewMode: ViewMode.values.firstWhere(
        (v) => v.name == json['viewMode'],
        orElse: () => ViewMode.grid,
      ),
      languageCode: resolveSupportedLanguageCode(
        rawLanguage is String ? rawLanguage : null,
        fallback: fallbackLanguageCode,
      ),
      noteSeparator: separator,
      reseller: json['reseller'] == true,
      appMode: AppMode.values.firstWhere(
        (m) => m.name == json['appMode'],
        orElse: () => AppMode.clipboard,
      ),
    );
  }
}

/// Reads/writes [AppSettings] as JSON in the app support directory.
class SettingsService {
  static const _fileName = 'clipboard_settings.json';

  static String systemLanguageCode() => resolveSupportedLanguageCode(
        PlatformDispatcher.instance.locale.languageCode,
      );

  static AppSettings defaultSettings() =>
      AppSettings(languageCode: systemLanguageCode());

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, _fileName));
  }

  Future<AppSettings> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return defaultSettings();
      final data = jsonDecode(await file.readAsString(encoding: utf8));
      if (data is! Map<String, dynamic>) return defaultSettings();
      return AppSettings.fromJson(data,
          fallbackLanguageCode: systemLanguageCode());
    } catch (_) {
      return defaultSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    final file = await _file();
    await writeStringAtomic(file, jsonEncode(settings.toJson()));
  }
}
