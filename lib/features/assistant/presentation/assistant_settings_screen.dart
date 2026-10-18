import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/l10n/app_strings.dart';
import '../application/assistant_providers.dart';
import '../data/assistant_config_store.dart';
import '../data/llm_client.dart';
import '../domain/chat_message.dart';
import '../domain/llm_provider.dart';

/// Where the user connects their preferred LLM (provider, key, model).
class AssistantSettingsScreen extends ConsumerStatefulWidget {
  const AssistantSettingsScreen({super.key});

  @override
  ConsumerState<AssistantSettingsScreen> createState() =>
      _AssistantSettingsScreenState();
}

class _AssistantSettingsScreenState
    extends ConsumerState<AssistantSettingsScreen> {
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _url = TextEditingController();
  LlmProviderKind? _shown;
  bool _obscure = true;
  bool _busy = false;
  String? _status;
  bool _statusOk = false;
  List<String> _models = const [];
  Timer? _debounce;

  /// Captured up front: [dispose] may still need to flush a pending save,
  /// when `ref` can no longer be used.
  late final _controller = ref.read(assistantConfigControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _controller; // resolve while the widget is mounted
  }

  @override
  void dispose() {
    if (_debounce?.isActive ?? false) _save();
    _key.dispose();
    _model.dispose();
    _url.dispose();
    super.dispose();
  }

  /// Fills the fields from the saved settings of [kind].
  void _load(AssistantConfig config, LlmProviderKind kind) {
    final s = config.settingsFor(kind);
    _key.text = s.apiKey;
    _model.text = s.model.isEmpty ? kind.defaultModel : s.model;
    _url.text = s.baseUrl;
    _shown = kind;
    _models = const [];
    _status = null;
  }

  /// Typing saves after a short pause (one write, not one per keystroke).
  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    _debounce?.cancel();
    final kind = _shown;
    if (kind == null) return;
    await _controller.setProviderSettings(
      kind,
      ProviderSettings(
        apiKey: _key.text.trim(),
        model: _model.text.trim(),
        baseUrl: _url.text.trim(),
      ),
    );
  }

  Future<void> _selectProvider(LlmProviderKind kind) async {
    await _save();
    await _controller.setProvider(kind);
    if (!mounted) return;
    setState(() => _load(ref.read(assistantConfigProvider), kind));
  }

  Future<void> _run(Future<String> Function(LlmClient client) action) async {
    await _save();
    final config = ref.read(assistantConfigProvider);
    final client = ref.read(llmClientFactoryProvider)(config);
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final msg = await action(client);
      if (mounted) {
        setState(() {
          _status = msg;
          _statusOk = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = e is LlmException && e.kind == LlmFailure.insecureUrl
              ? ref.read(appStringsProvider).llmInsecureUrl
              : '$e';
          _statusOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test(AppStrings strings) => _run((client) async {
        final reply = await client.complete(
          system: 'Reply with the single word: OK',
          history: const [ChatMessage.user('ping')],
          tools: const [],
        );
        final text = reply.message.text.trim();
        return text.isEmpty
            ? strings.connectionOk
            : '${strings.connectionOk}  « ${text.length > 60 ? text.substring(0, 60) : text} »';
      });

  Future<void> _loadModels(AppStrings strings) => _run((client) async {
        final models = await client.listModels();
        if (mounted) setState(() => _models = models);
        return '${models.length} ${strings.llmModel.toLowerCase()}(s)';
      });

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final async = ref.watch(assistantConfigControllerProvider);
    final config = async.value;
    if (config == null) {
      return Scaffold(
        appBar: AppBar(title: Text(strings.assistantSettings)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_shown == null) _load(config, config.provider);
    final kind = _shown!;
    final scheme = Theme.of(context).colorScheme;
    final suggestions = {..._models, ...kind.models}.toList();

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _save();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(strings.assistantSettings)),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(strings.assistantNotConfigured,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            DropdownButtonFormField<LlmProviderKind>(
              initialValue: kind,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: strings.llmProvider,
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final k in LlmProviderKind.values)
                  DropdownMenuItem(value: k, child: Text(k.label)),
              ],
              onChanged: (k) => k == null ? null : _selectProvider(k),
            ),
            const SizedBox(height: 16),
            if (config.keysInPlainText) ...[
              _PlainTextKeyWarning(
                title: strings.keysInPlainTextTitle,
                message: strings.keysInPlainTextMessage,
              ),
              const SizedBox(height: 16),
            ],
            if (kind.needsKey || kind == LlmProviderKind.custom) ...[
              TextField(
                key: const ValueKey('assistant-api-key'),
                controller: _key,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => _scheduleSave(),
                decoration: InputDecoration(
                  labelText: strings.apiKey,
                  border: const OutlineInputBorder(),
                  helperText: strings.apiKeyLocal,
                  helperMaxLines: 3,
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              if (kind.keyUrl != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(strings.getApiKey),
                    onPressed: () => launchUrl(Uri.parse(kind.keyUrl!),
                        mode: LaunchMode.externalApplication),
                  ),
                ),
              const SizedBox(height: 8),
            ],
            Autocomplete<String>(
              key: ValueKey('model-$kind-${_models.length}'),
              initialValue: TextEditingValue(text: _model.text),
              optionsBuilder: (value) {
                final q = value.text.toLowerCase();
                return suggestions.where((m) => m.toLowerCase().contains(q));
              },
              onSelected: (m) {
                _model.text = m;
                _scheduleSave();
              },
              fieldViewBuilder: (context, controller, focus, onSubmit) {
                return TextField(
                  controller: controller,
                  focusNode: focus,
                  autocorrect: false,
                  onChanged: (v) {
                    _model.text = v;
                    _scheduleSave();
                  },
                  decoration: InputDecoration(
                    labelText: strings.llmModel,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: strings.loadModels,
                      icon: const Icon(Icons.cloud_download_outlined),
                      onPressed: _busy ? null : () => _loadModels(strings),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              autocorrect: false,
              keyboardType: TextInputType.url,
              onChanged: (_) {
                setState(() {}); // refresh the error below
                _scheduleSave();
              },
              decoration: InputDecoration(
                labelText: strings.llmBaseUrl,
                hintText: kind.baseUrl.isEmpty ? 'https://…/v1' : kind.baseUrl,
                helperText: strings.llmBaseUrlHint,
                helperMaxLines: 3,
                errorText:
                    _url.text.trim().isNotEmpty && !isSecureEndpoint(_url.text)
                        ? strings.llmInsecureUrl
                        : null,
                errorMaxLines: 4,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : () => _test(strings),
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: Text(strings.testConnection),
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(
                _status!,
                style:
                    TextStyle(color: _statusOk ? scheme.primary : scheme.error),
              ),
            ],
            const Divider(height: 32),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(strings.confirmDestructive),
              subtitle: Text(strings.confirmDestructiveHint),
              value: config.confirmDestructive,
              onChanged: (v) => ref
                  .read(assistantConfigControllerProvider.notifier)
                  .setConfirmDestructive(v),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the API keys could not go into the system's secure storage.
class _PlainTextKeyWarning extends StatelessWidget {
  const _PlainTextKeyWarning({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.gpp_maybe_outlined, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      message,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
