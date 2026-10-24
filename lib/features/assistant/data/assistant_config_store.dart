import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/services/atomic_file.dart';
import '../domain/llm_provider.dart';

/// Connection details for one provider. Kept per provider so switching back
/// and forth never loses a key.
@immutable
class ProviderSettings {
  const ProviderSettings(
      {this.apiKey = '', this.model = '', this.baseUrl = ''});

  final String apiKey;
  final String model;

  /// Empty = the provider's default endpoint.
  final String baseUrl;

  ProviderSettings copyWith({String? apiKey, String? model, String? baseUrl}) =>
      ProviderSettings(
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        baseUrl: baseUrl ?? this.baseUrl,
      );

  /// The key is left out unless [withKey]: it lives in the system's secure
  /// storage (see [AssistantConfigStore]).
  Map<String, dynamic> toJson({bool withKey = false}) => {
        if (withKey) 'apiKey': apiKey,
        'model': model,
        'baseUrl': baseUrl,
      };

  static ProviderSettings fromJson(Object? raw) {
    if (raw is! Map) return const ProviderSettings();
    String str(String k) => raw[k] is String ? raw[k] as String : '';
    return ProviderSettings(
      apiKey: str('apiKey'),
      model: str('model'),
      baseUrl: str('baseUrl'),
    );
  }
}

/// The assistant's preferences: which LLM to use and how careful to be.
@immutable
class AssistantConfig {
  const AssistantConfig({
    this.provider = LlmProviderKind.openai,
    this.providers = const {},
    this.confirmDestructive = true,
    this.memory = true,
    this.maxSteps = 24,
    this.keysInPlainText = false,
  });

  final LlmProviderKind provider;
  final Map<LlmProviderKind, ProviderSettings> providers;

  /// Ask before trashing, deleting or overwriting anything.
  final bool confirmDestructive;

  /// Degany keeps a private profile of the user (see `UserProfileStore`).
  final bool memory;

  /// Tool rounds allowed for one user message (guards against loops).
  final int maxSteps;

  /// The system's secure storage failed, so the API keys sit in clear in
  /// the app's settings file. Runtime state only, never saved; the settings
  /// screen warns about it.
  final bool keysInPlainText;

  bool get hasAnyKey => providers.values.any((s) => s.apiKey.trim().isNotEmpty);

  ProviderSettings settingsFor(LlmProviderKind kind) =>
      providers[kind] ?? const ProviderSettings();

  ProviderSettings get current => settingsFor(provider);

  String get model {
    final m = current.model.trim();
    return m.isEmpty ? provider.defaultModel : m;
  }

  String get baseUrl {
    final u = current.baseUrl.trim();
    return u.isEmpty ? provider.baseUrl : u;
  }

  /// Enough to send a request.
  bool get isReady =>
      model.isNotEmpty &&
      baseUrl.isNotEmpty &&
      (!provider.needsKey || current.apiKey.trim().isNotEmpty);

  AssistantConfig copyWith({
    LlmProviderKind? provider,
    Map<LlmProviderKind, ProviderSettings>? providers,
    bool? confirmDestructive,
    bool? memory,
    int? maxSteps,
    bool? keysInPlainText,
  }) =>
      AssistantConfig(
        provider: provider ?? this.provider,
        providers: providers ?? this.providers,
        confirmDestructive: confirmDestructive ?? this.confirmDestructive,
        memory: memory ?? this.memory,
        maxSteps: maxSteps ?? this.maxSteps,
        keysInPlainText: keysInPlainText ?? this.keysInPlainText,
      );

  AssistantConfig withProviderSettings(
          LlmProviderKind kind, ProviderSettings settings) =>
      copyWith(providers: {...providers, kind: settings});

  Map<String, dynamic> toJson({bool withKeys = false}) => {
        'provider': provider.name,
        'confirmDestructive': confirmDestructive,
        'memory': memory,
        'maxSteps': maxSteps,
        'providers': {
          for (final e in providers.entries)
            e.key.name: e.value.toJson(withKey: withKeys),
        },
      };

  static AssistantConfig fromJson(Object? raw) {
    if (raw is! Map) return const AssistantConfig();
    final rawProviders = raw['providers'];
    final steps = raw['maxSteps'];
    return AssistantConfig(
      provider: LlmProviderKind.byName(raw['provider']),
      confirmDestructive: raw['confirmDestructive'] != false,
      memory: raw['memory'] != false,
      maxSteps: steps is int && steps >= 1 && steps <= 100 ? steps : 24,
      providers: {
        if (rawProviders is Map)
          for (final e in rawProviders.entries)
            if (LlmProviderKind.values.any((k) => k.name == e.key))
              LlmProviderKind.byName(e.key): ProviderSettings.fromJson(e.value),
      },
    );
  }
}

/// Where API keys are kept. The default is the operating system's protected
/// store; tests use an in-memory one.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android Keystore, Windows Credential Manager (DPAPI), Apple Keychain,
/// libsecret on Linux, WebCrypto in a browser.
class SystemSecretStore implements SecretStore {
  const SystemSecretStore();

  static const _storage = FlutterSecureStorage(
    // Values written by an older algorithm are migrated, never lost.
    aOptions: AndroidOptions(migrateOnAlgorithmChange: true),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Persists [AssistantConfig]: provider, models and options as JSON in the
/// app support directory (never in the possibly synced workspace), and each
/// API key in the system's secure storage.
///
/// If the secure storage is unavailable on a device, the keys fall back to
/// the JSON file so the assistant keeps working. Keys found in the JSON file
/// (written by an older version) are moved to the secure storage on load.
class AssistantConfigStore {
  AssistantConfigStore({
    SecretStore secrets = const SystemSecretStore(),
    Future<File> Function()? file,
  })  : _secrets = secrets,
        _fileOverride = file;

  final SecretStore _secrets;
  final Future<File> Function()? _fileOverride;

  static const _fileName = 'assistant_settings.json';

  static String _keyName(LlmProviderKind kind) =>
      'influencor.assistant.apiKey.${kind.name}';

  Future<File> _file() async {
    if (_fileOverride case final override?) return override();
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, _fileName));
  }

  Future<AssistantConfig> load() async {
    AssistantConfig config;
    try {
      final file = await _file();
      config = await file.exists()
          ? AssistantConfig.fromJson(
              jsonDecode(await file.readAsString(encoding: utf8)))
          : const AssistantConfig();
    } catch (_) {
      config = const AssistantConfig();
    }

    final providers = {...config.providers};
    var migrated = false;
    try {
      for (final kind in LlmProviderKind.values) {
        final stored = await _secrets.read(_keyName(kind)) ?? '';
        final legacy = providers[kind]?.apiKey ?? '';
        if (stored.isNotEmpty) {
          providers[kind] = (providers[kind] ?? const ProviderSettings())
              .copyWith(apiKey: stored);
        } else if (legacy.isNotEmpty) {
          await _secrets.write(_keyName(kind), legacy);
          migrated = true;
        }
      }
    } catch (e) {
      // No secure storage here: keep whatever the file holds, and say so.
      debugPrint('Assistant: secure storage unavailable ($e)');
      return config.copyWith(keysInPlainText: config.hasAnyKey);
    }
    final result = config.copyWith(providers: providers);
    // Rewrite the file without the keys that were just moved.
    if (migrated) await _writeFile(result, withKeys: false);
    return result;
  }

  /// Saves [config]; returns it as stored, with [AssistantConfig.keysInPlainText]
  /// set when the keys had to go in clear into the settings file.
  Future<AssistantConfig> save(AssistantConfig config) async {
    var secured = true;
    try {
      for (final kind in LlmProviderKind.values) {
        final key = config.settingsFor(kind).apiKey.trim();
        if (key.isEmpty) {
          await _secrets.delete(_keyName(kind));
        } else {
          await _secrets.write(_keyName(kind), key);
        }
      }
    } catch (e) {
      debugPrint('Assistant: secure storage unavailable ($e)');
      secured = false;
    }
    await _writeFile(config, withKeys: !secured);
    return config.copyWith(keysInPlainText: !secured && config.hasAnyKey);
  }

  Future<void> _writeFile(AssistantConfig config,
          {required bool withKeys}) async =>
      writeStringAtomic(
          await _file(), jsonEncode(config.toJson(withKeys: withKeys)));
}
