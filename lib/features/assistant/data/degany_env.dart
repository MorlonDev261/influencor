import '../domain/llm_provider.dart';
import 'assistant_config_store.dart';

/// Degany's model as set at build time in `.env`, passed to Flutter with
/// `--dart-define-from-file=.env` (see `.env.example`):
///
/// * `DEGANY_USER_MODELS=true` (default): users connect their own provider,
///   key and model in Degany's settings, as before. A model given here is
///   used until they do.
/// * `DEGANY_USER_MODELS=false`: those settings are hidden and Degany always
///   uses the provider, model and key given here.
///
/// The values end up inside the app: anyone holding the build can extract
/// the key.
class DeganyEnv {
  const DeganyEnv({
    this.userModels = true,
    this.provider,
    this.model = '',
    this.apiKey = '',
    this.baseUrl = '',
  });

  /// What the build was given.
  factory DeganyEnv.fromBuild() => DeganyEnv(
        userModels: const bool.fromEnvironment('DEGANY_USER_MODELS',
            defaultValue: true),
        provider:
            providerNamed(const String.fromEnvironment('DEGANY_PROVIDER')),
        model: const String.fromEnvironment('DEGANY_MODEL'),
        apiKey: const String.fromEnvironment('DEGANY_API_KEY'),
        baseUrl: const String.fromEnvironment('DEGANY_BASE_URL'),
      );

  /// Users may choose their own provider, key and model.
  final bool userModels;

  /// Null when unset or unknown.
  final LlmProviderKind? provider;
  final String model;
  final String apiKey;
  final String baseUrl;

  /// `openai`, `anthropic`… (case and spaces ignored), or null.
  static LlmProviderKind? providerNamed(String name) {
    final n = name.trim().toLowerCase();
    for (final k in LlmProviderKind.values) {
      if (k.name.toLowerCase() == n) return k;
    }
    return null;
  }

  /// The user's [config] with the build's model applied: always when users
  /// cannot choose, otherwise only while their own is not usable. Their other
  /// choices (confirmations, memory) are kept.
  AssistantConfig apply(AssistantConfig config) {
    final kind = provider;
    if (kind == null) return config;
    if (userModels && config.isReady) return config;
    final managed = config.copyWith(provider: kind, providers: {
      kind: ProviderSettings(apiKey: apiKey, model: model, baseUrl: baseUrl),
    });
    return userModels && !managed.isReady ? config : managed;
  }
}
