/// The wire protocol a provider speaks. Almost every vendor exposes an
/// OpenAI-compatible `/chat/completions` endpoint; Claude and Gemini have their
/// own native APIs (needed for their tool-call details: thinking blocks, thought
/// signatures).
enum LlmProtocol { openai, anthropic, gemini }

/// The LLM services the assistant can connect to. The user picks one in the
/// settings and pastes their own API key; nothing goes through our servers.
enum LlmProviderKind {
  openai(
    label: 'ChatGPT (OpenAI)',
    protocol: LlmProtocol.openai,
    baseUrl: 'https://api.openai.com/v1',
    models: ['gpt-5', 'gpt-5-mini', 'gpt-4.1', 'gpt-4.1-mini', 'gpt-4o'],
    keyUrl: 'https://platform.openai.com/api-keys',
  ),
  anthropic(
    label: 'Claude (Anthropic)',
    protocol: LlmProtocol.anthropic,
    baseUrl: 'https://api.anthropic.com',
    models: [
      'claude-opus-5-5',
      'claude-sonnet-5-5',
      'claude-haiku-5-5',
      'claude-fable-5-1',
    ],
    keyUrl: 'https://console.anthropic.com/settings/keys',
  ),
  gemini(
    label: 'Gemini (Google)',
    protocol: LlmProtocol.gemini,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    models: ['gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.5-flash-lite'],
    keyUrl: 'https://aistudio.google.com/apikey',
  ),
  deepseek(
    label: 'DeepSeek',
    protocol: LlmProtocol.openai,
    baseUrl: 'https://api.deepseek.com/v1',
    models: ['deepseek-chat', 'deepseek-reasoner'],
    keyUrl: 'https://platform.deepseek.com/api_keys',
  ),
  mistral(
    label: 'Mistral AI',
    protocol: LlmProtocol.openai,
    baseUrl: 'https://api.mistral.ai/v1',
    models: [
      'mistral-large-latest',
      'mistral-medium-latest',
      'mistral-small-latest'
    ],
    keyUrl: 'https://console.mistral.ai/api-keys',
  ),
  xai(
    label: 'Grok (xAI)',
    protocol: LlmProtocol.openai,
    baseUrl: 'https://api.x.ai/v1',
    models: ['grok-4', 'grok-3-mini'],
    keyUrl: 'https://console.x.ai',
  ),
  groq(
    label: 'Groq',
    protocol: LlmProtocol.openai,
    baseUrl: 'https://api.groq.com/openai/v1',
    models: ['llama-3.3-70b-versatile', 'openai/gpt-oss-120b'],
    keyUrl: 'https://console.groq.com/keys',
  ),
  openrouter(
    label: 'OpenRouter (tous les modèles)',
    protocol: LlmProtocol.openai,
    baseUrl: 'https://openrouter.ai/api/v1',
    models: [
      'anthropic/claude-sonnet-5.5',
      'openai/gpt-5-mini',
      'google/gemini-2.5-flash',
      'deepseek/deepseek-chat',
    ],
    keyUrl: 'https://openrouter.ai/keys',
  ),
  qwen(
    label: 'Qwen (Alibaba)',
    protocol: LlmProtocol.openai,
    baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
    models: ['qwen-plus', 'qwen-max', 'qwen-turbo'],
    keyUrl: 'https://dashscope.console.aliyun.com/apiKey',
  ),
  ollama(
    label: 'Ollama (local)',
    protocol: LlmProtocol.openai,
    baseUrl: 'http://localhost:11434/v1',
    models: ['llama3.1', 'qwen2.5', 'mistral-nemo'],
    needsKey: false,
  ),
  custom(
    label: 'Autre (compatible OpenAI)',
    protocol: LlmProtocol.openai,
    baseUrl: '',
    models: [],
    needsKey: false,
  );

  const LlmProviderKind({
    required this.label,
    required this.protocol,
    required this.baseUrl,
    required this.models,
    this.keyUrl,
    this.needsKey = true,
  });

  final String label;
  final LlmProtocol protocol;

  /// Default endpoint; the user can override it (proxy, Azure, self-hosted…).
  final String baseUrl;

  /// Suggestions only: any model id the service accepts can be typed.
  final List<String> models;

  /// Where the user creates an API key.
  final String? keyUrl;

  /// Local servers (Ollama, LM Studio…) usually need no key.
  final bool needsKey;

  String get defaultModel => models.isEmpty ? '' : models.first;

  static LlmProviderKind byName(Object? name) => LlmProviderKind.values
      .firstWhere((k) => k.name == name, orElse: () => LlmProviderKind.openai);
}

/// Whether [url] may receive the API key and the conversation: HTTPS, or
/// plain HTTP only to this device (a local model such as Ollama or
/// LM Studio). Anything else would send them readable on the network.
bool isSecureEndpoint(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme == 'https') return true;
  if (uri.scheme != 'http') return false;
  final host = uri.host.toLowerCase();
  return host == 'localhost' ||
      host.endsWith('.localhost') ||
      host == '::1' ||
      RegExp(r'^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(host);
}
