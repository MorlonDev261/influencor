import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../domain/chat_message.dart';
import '../domain/llm_provider.dart';
import 'assistant_config_store.dart';

/// What went wrong talking to the provider; the chat shows each kind in the
/// app's language.
enum LlmFailure {
  /// No answer in time.
  timeout,

  /// Could not reach the service ([LlmException.message] has the detail).
  connection,

  /// The connection dropped mid-answer.
  interrupted,

  /// A streamed answer went silent.
  stalled,

  /// The model answered nothing.
  emptyReply,

  /// The answer could not be understood.
  unexpectedReply,

  /// The provider reported an error ([LlmException.message] is its own text).
  service,

  /// The endpoint is plain HTTP to another machine: nothing was sent
  /// ([LlmException.message] is the address).
  insecureUrl,
}

/// A provider error worth showing to the user (bad key, quota, model…).
class LlmException implements Exception {
  const LlmException(
    this.message, {
    this.statusCode,
    this.kind = LlmFailure.service,
  });

  /// The provider's message (for [LlmFailure.service]) or a technical detail.
  final String message;
  final int? statusCode;
  final LlmFailure kind;

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode — $message';
}

/// One request/response round with a chat model that can call tools.
abstract class LlmClient {
  const LlmClient();

  /// The whole reply at once.
  Future<LlmReply> complete({
    required String system,
    required List<ChatMessage> history,
    required List<ToolSchema> tools,
  });

  /// The reply token by token (text, reasoning), ending with [ReplyDone].
  /// Default: one chunk, for clients that cannot stream.
  Stream<LlmEvent> stream({
    required String system,
    required List<ChatMessage> history,
    required List<ToolSchema> tools,
  }) async* {
    final reply =
        await complete(system: system, history: history, tools: tools);
    if (reply.message.text.isNotEmpty) yield TextDelta(reply.message.text);
    yield ReplyDone(reply);
  }

  /// Model ids the account can use (for the settings picker).
  Future<List<String>> listModels();

  /// Aborts the request in flight, if any.
  void cancel();

  static LlmClient forConfig(AssistantConfig config, {http.Client? client}) {
    final key = config.current.apiKey.trim();
    return switch (config.provider.protocol) {
      LlmProtocol.openai => OpenAiCompatibleClient(
          baseUrl: config.baseUrl,
          apiKey: key,
          model: config.model,
          client: client,
        ),
      LlmProtocol.anthropic => AnthropicClient(
          baseUrl: config.baseUrl,
          apiKey: key,
          model: config.model,
          client: client,
        ),
      LlmProtocol.gemini => GeminiClient(
          baseUrl: config.baseUrl,
          apiKey: key,
          model: config.model,
          client: client,
        ),
    };
  }
}

/// One Server-Sent Event.
typedef SseEvent = ({String? event, String data});

/// Splits a `text/event-stream` body into events.
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  String? event;
  final data = StringBuffer();
  var hasData = false;
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (hasData) yield (event: event, data: data.toString());
      event = null;
      data.clear();
      hasData = false;
      continue;
    }
    if (line.startsWith(':')) continue; // comment / keep-alive
    final i = line.indexOf(':');
    final field = i < 0 ? line : line.substring(0, i);
    var value = i < 0 ? '' : line.substring(i + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') {
      event = value;
    } else if (field == 'data') {
      if (hasData) data.write('\n');
      data.write(value);
      hasData = true;
    }
  }
  if (hasData) yield (event: event, data: data.toString());
}

/// Shared HTTP plumbing: JSON in/out, streams, readable errors, cancellation.
abstract class _HttpLlmClient extends LlmClient {
  _HttpLlmClient({required String baseUrl, http.Client? client})
      : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final String baseUrl;
  http.Client _client;
  final bool _ownsClient;

  static const _timeout = Duration(minutes: 5);

  /// Longest silence tolerated inside a stream (models can think a while).
  static const _idle = Duration(minutes: 4);

  @override
  void cancel() {
    if (!_ownsClient) return;
    _client.close();
    _client = http.Client();
  }

  Future<http.StreamedResponse> _open(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    // Checked on every request, whatever the settings screen let through:
    // the key must never leave the device unencrypted.
    if (!isSecureEndpoint(uri.toString())) {
      throw LlmException('${uri.scheme}://${uri.authority}',
          kind: LlmFailure.insecureUrl);
    }
    try {
      final request = http.Request(method, uri)
        ..headers.addAll({
          'content-type': 'application/json',
          ...headers,
        });
      if (body != null) request.body = jsonEncode(body);
      return await _client.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const LlmException('timeout', kind: LlmFailure.timeout);
    } on http.ClientException catch (e) {
      throw LlmException(e.message, kind: LlmFailure.connection);
    }
  }

  Future<Never> _fail(http.StreamedResponse res) async {
    final text = utf8.decode(await res.stream.toBytes(), allowMalformed: true);
    Object? data;
    try {
      data = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {}
    throw LlmException(_errorMessage(data) ?? _clip(text),
        statusCode: res.statusCode);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri,
    Map<String, String> headers, [
    Map<String, dynamic>? body,
  ]) async {
    final res = await _open(method, uri, headers, body);
    if (res.statusCode < 200 || res.statusCode >= 300) await _fail(res);
    final List<int> bytes;
    try {
      bytes = await res.stream.toBytes();
    } on http.ClientException catch (e) {
      throw LlmException(e.message, kind: LlmFailure.interrupted);
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    Object? data;
    try {
      data = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {}
    if (data is! Map<String, dynamic>) {
      throw const LlmException('unexpected reply',
          kind: LlmFailure.unexpectedReply);
    }
    return data;
  }

  /// Opens a streamed request and yields its events as JSON objects.
  Stream<({String? event, Map<String, dynamic> json})> _sse(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body,
  ) async* {
    final res = await _open('POST', uri, headers, body);
    if (res.statusCode < 200 || res.statusCode >= 300) await _fail(res);
    final events = parseSse(res.stream.timeout(_idle, onTimeout: (sink) {
      sink.addError(const LlmException('stalled', kind: LlmFailure.stalled));
      sink.close();
    }));
    try {
      await for (final e in events) {
        if (e.data == '[DONE]') return;
        Object? json;
        try {
          json = jsonDecode(e.data);
        } catch (_) {
          continue; // keep-alives and junk lines
        }
        if (json is! Map<String, dynamic>) continue;
        if (e.event == 'error' || json['error'] != null) {
          throw LlmException(_errorMessage(json) ?? '');
        }
        yield (event: e.event, json: json);
      }
    } on http.ClientException catch (e) {
      throw LlmException(e.message, kind: LlmFailure.interrupted);
    }
  }

  static String? _errorMessage(Object? data) {
    if (data is! Map) return null;
    final err = data['error'];
    if (err is Map && err['message'] is String) return err['message'] as String;
    if (err is String) return err;
    if (data['message'] is String) return data['message'] as String;
    return null;
  }

  static String _clip(String s) =>
      s.length > 300 ? '${s.substring(0, 300)}…' : s;
}

Map<String, dynamic> _decodeArgs(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return raw.cast<String, dynamic>();
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
  }
  return {};
}

// ---------------------------------------------------------------------------
// OpenAI-compatible: OpenAI, DeepSeek, Mistral, Groq, xAI, OpenRouter, Qwen,
// Ollama, LM Studio…
// ---------------------------------------------------------------------------

class OpenAiCompatibleClient extends _HttpLlmClient {
  OpenAiCompatibleClient({
    required super.baseUrl,
    required this.apiKey,
    required this.model,
    super.client,
  });

  final String apiKey;
  final String model;

  static const _rawKey = 'openai';

  Map<String, String> get _headers => {
        if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
        // OpenRouter attribution (ignored by everyone else).
        'x-title': 'Influencor',
      };

  Uri get _uri => Uri.parse('$baseUrl/chat/completions');

  // No max_tokens / temperature: newer models reject the classic names or
  // non-default values, and the provider defaults are sensible.
  Map<String, dynamic> _body(
          String system, List<ChatMessage> history, List<ToolSchema> tools) =>
      {
        'model': model,
        'messages': [
          {'role': 'system', 'content': system},
          for (final m in history) ..._toWire(m),
        ],
        if (tools.isNotEmpty)
          'tools': [
            for (final t in tools)
              {
                'type': 'function',
                'function': {
                  'name': t.name,
                  'description': t.description,
                  'parameters': t.parameters,
                },
              },
          ],
      };

  @override
  Future<LlmReply> complete({
    required String system,
    required List<ChatMessage> history,
    required List<ToolSchema> tools,
  }) async {
    final data =
        await _send('POST', _uri, _headers, _body(system, history, tools));
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const LlmException('empty reply', kind: LlmFailure.emptyReply);
    }
    final choice = choices.first as Map;
    final msg = choice['message'] is Map ? choice['message'] as Map : const {};
    final content = msg['content'];
    final text = content is String
        ? content
        : content is List
            ? content
                .whereType<Map<dynamic, dynamic>>()
                .map((p) => p['text'])
                .whereType<String>()
                .join()
            : '';
    return _reply(
      text: text,
      rawCalls:
          msg['tool_calls'] is List ? msg['tool_calls'] as List : const [],
      reasoning: msg['reasoning_content'] as String?,
      finishReason: choice['finish_reason'] as String?,
      refusal: msg['refusal'] is String,
    );
  }

  @override
  Stream<LlmEvent> stream({
    required String system,
    required List<ChatMessage> history,
    required List<ToolSchema> tools,
  }) async* {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final calls = <int, Map<String, dynamic>>{};
    String? finish;
    var refusal = false;
    await for (final e in _sse(
        _uri, _headers, {..._body(system, history, tools), 'stream': true})) {
      final choices = e.json['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        continue;
      }
      final choice = choices.first as Map;
      finish = choice['finish_reason'] as String? ?? finish;
      final delta = choice['delta'];
      if (delta is! Map) continue;
      if (delta['content'] case final String t when t.isNotEmpty) {
        text.write(t);
        yield TextDelta(t);
      }
      // DeepSeek / Qwen use reasoning_content; OpenRouter, Groq, Ollama use
      // reasoning.
      final think = delta['reasoning_content'] ?? delta['reasoning'];
      if (think is String && think.isNotEmpty) {
        reasoning.write(think);
        yield ThinkingDelta(think);
      }
      if (delta['refusal'] is String) refusal = true;
      final rawCalls = delta['tool_calls'];
      if (rawCalls is List) {
        for (final (pos, c) in rawCalls.indexed) {
          if (c is! Map) continue;
          final index = c['index'] is int ? c['index'] as int : pos;
          final fn = c['function'] is Map ? c['function'] as Map : const {};
          final call = calls.putIfAbsent(
              index,
              () => {
                    'id': '',
                    'type': 'function',
                    'function': {'name': '', 'arguments': ''},
                  });
          final f = call['function'] as Map<String, dynamic>;
          if (c['id'] is String && (c['id'] as String).isNotEmpty) {
            call['id'] = c['id'];
          }
          if (fn['name'] is String && (fn['name'] as String).isNotEmpty) {
            final isNew = (f['name'] as String).isEmpty;
            f['name'] = '${f['name']}${fn['name']}';
            if (isNew) yield ToolCallDelta(f['name'] as String);
          }
          if (fn['arguments'] is String) {
            f['arguments'] = '${f['arguments']}${fn['arguments']}';
          } else if (fn['arguments'] is Map) {
            f['arguments'] = jsonEncode(fn['arguments']);
          }
        }
      }
    }
    final ordered = (calls.keys.toList()..sort()).map((k) => calls[k]!);
    yield ReplyDone(_reply(
      text: text.toString(),
      rawCalls: [
        for (final (i, c) in ordered.indexed)
          {...c, 'id': (c['id'] as String).isEmpty ? 'call_$i' : c['id']},
      ],
      reasoning: reasoning.isEmpty ? null : reasoning.toString(),
      finishReason: finish,
      refusal: refusal,
    ));
  }

  static LlmReply _reply({
    required String text,
    required List<Object?> rawCalls,
    required String? reasoning,
    required String? finishReason,
    required bool refusal,
  }) {
    final calls = <ToolCall>[];
    for (final (i, c) in rawCalls.indexed) {
      if (c is! Map || c['function'] is! Map) continue;
      final fn = c['function'] as Map;
      calls.add(ToolCall(
        id: c['id'] is String && (c['id'] as String).isNotEmpty
            ? c['id'] as String
            : 'call_$i',
        name: '${fn['name']}',
        args: _decodeArgs(fn['arguments']),
      ));
    }
    // What we send back next turn. DeepSeek's thinking mode needs its
    // reasoning echoed within a tool loop.
    final wire = <String, dynamic>{
      'role': 'assistant',
      'content': text.isEmpty && calls.isNotEmpty ? null : text,
      if (rawCalls.isNotEmpty) 'tool_calls': rawCalls,
      if (reasoning != null) 'reasoning_content': reasoning,
    };
    return LlmReply(
      message: ChatMessage(
        role: ChatRole.assistant,
        text: text,
        toolCalls: calls,
        raw: {_rawKey: wire},
      ),
      stopReason: finishReason,
      refused: finishReason == 'content_filter' ||
          (text.isEmpty && calls.isEmpty && refusal),
    );
  }

  static List<Map<String, dynamic>> _toWire(ChatMessage m) {
    switch (m.role) {
      case ChatRole.user:
        return [
          {'role': 'user', 'content': m.text},
        ];
      case ChatRole.assistant:
        final raw = m.raw[_rawKey];
        if (raw is Map<String, dynamic>) return [raw];
        return [
          {
            'role': 'assistant',
            'content': m.text.isEmpty && m.toolCalls.isNotEmpty ? null : m.text,
            if (m.toolCalls.isNotEmpty)
              'tool_calls': [
                for (final c in m.toolCalls)
                  {
                    'id': c.id,
                    'type': 'function',
                    'function': {
                      'name': c.name,
                      'arguments': jsonEncode(c.args),
                    },
                  },
              ],
          },
        ];
      case ChatRole.tool:
        return [
          for (final r in m.toolResults)
            {'role': 'tool', 'tool_call_id': r.callId, 'content': r.content},
        ];
    }
  }

  @override
  Future<List<String>> listModels() async {
    final data = await _send('GET', Uri.parse('$baseUrl/models'), _headers);
    final list = data['data'];
    return [
      if (list is List)
        for (final m in list)
          if (m is Map && m['id'] is String) m['id'] as String,
    ]..sort();
  }
}

// ---------------------------------------------------------------------------
// Claude (Anthropic Messages API)
// ---------------------------------------------------------------------------

class AnthropicClient extends _HttpLlmClient {
  AnthropicClient({
    required super.baseUrl,
    required this.apiKey,
    required this.model,
    super.client,
  });

  final String apiKey;
  final String model;

  static const _rawKey = 'anthropic';

  /// Models that accept server-side refusal fallbacks: a request declined by
  /// a safety classifier is re-run on another Claude model instead of failing.
  static const _fallbackModels = {
    'claude-fable-5-1',
    'claude-opus-5-5',
    'claude-opus-5',
    'claude-sonnet-5-5',
  };

  /// Models with adaptive thinking, whose reasoning summary can be shown.
  static final _adaptiveThinking = RegExp(
    r'^claude-(fable-5|mythos-5|opus-5|sonnet-5|haiku-5|opus-4-[678]|sonnet-4-6)',
  );

  bool get _official => Uri.tryParse(baseUrl)?.host == 'api.anthropic.com';

  bool get _withFallback => _fallbackModels.contains(model) && _official;

  Map<String, String> get _headers => {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        if (_withFallback) 'anthropic-beta': 'server-side-fallback-2026-07-01',
        // Required for calls made straight from a browser (web build).
        if (kIsWeb) 'anthropic-dangerous-direct-browser-access': 'true',
      };

  String get _root => baseUrl.endsWith('/v1') ? baseUrl : '$baseUrl/v1';

  Map<String, dynamic> _body(
          String system, List<ChatMessage> history, List<ToolSchema> tools,
          {required bool streaming}) =>
      {
        'model': model,
        'max_tokens': streaming ? 32000 : 16000,
        'system': system,
        'messages': _toWire(history),
        if (_adaptiveThinking.hasMatch(model))
          // Readable summary of the reasoning (the default hides it).
          'thinking': {'type': 'adaptive', 'display': 'summarized'},
        if (tools.isNotEmpty)
          'tools': [
            for (final t in tools)
              {
                'name': t.name,
                'description': t.description,
                'input_schema': t.parameters,
                // Large arguments (note bodies) stream instead of arriving in
                // one burst; inputs are validated when the block ends.
                if (streaming && _official) 'eager_input_streaming': true,
              },
          ],
        if (_withFallback) 'fallbacks': 'default',
        if (streaming) 'stream': true,
      };

  @override
  Future<LlmReply> complete({
    required String system,
    required List<ChatMessage> history,
    required List<ToolSchema> tools,
  }) async {
    final data = await _send('POST', Uri.parse('$_root/messages'), _headers,
        _body(system, history, tools, streaming: false));
    return _reply(data['content'] is List ? data['content'] as List : const [],
        data['stop_reason'] as String?);
  }

  @override
  Stream<LlmEvent> stream({
    required String system,
    required List<ChatMessage> history,
    required List<ToolSchema> tools,
  }) async* {
    final blocks = <int, Map<String, dynamic>>{};
    final partialJson = <int, StringBuffer>{};
    String? stop;
    await for (final e in _sse(Uri.parse('$_root/messages'), _headers,
        _body(system, history, tools, streaming: true))) {
      final json = e.json;
      final index = json['index'] is int ? json['index'] as int : -1;
      switch (json['type']) {
        case 'content_block_start':
          final block = json['content_block'] is Map
              ? Map<String, dynamic>.from(json['content_block'] as Map)
              : <String, dynamic>{};
          blocks[index] = block;
          switch (block['type']) {
            case 'tool_use':
              partialJson[index] = StringBuffer();
              yield ToolCallDelta('${block['name']}');
            case 'text' when (block['text'] as String? ?? '').isNotEmpty:
              yield TextDelta(block['text'] as String);
            case 'thinking'
                when (block['thinking'] as String? ?? '').isNotEmpty:
              yield ThinkingDelta(block['thinking'] as String);
          }
        case 'content_block_delta':
          final block = blocks[index];
          final delta = json['delta'];
          if (block == null || delta is! Map) continue;
          switch (delta['type']) {
            case 'text_delta':
              final t = '${delta['text']}';
              block['text'] = '${block['text'] ?? ''}$t';
              yield TextDelta(t);
            case 'thinking_delta':
              final t = '${delta['thinking']}';
              block['thinking'] = '${block['thinking'] ?? ''}$t';
              yield ThinkingDelta(t);
            case 'signature_delta':
              block['signature'] =
                  '${block['signature'] ?? ''}${delta['signature']}';
            case 'input_json_delta':
              partialJson[index]?.write(delta['partial_json'] ?? '');
          }
        case 'content_block_stop':
          final block = blocks[index];
          final buffer = partialJson.remove(index);
          if (block != null && buffer != null) {
            // A truncated input (max_tokens) parses to {} and the tool then
            // reports the missing parameters to the model.
            block['input'] = _decodeArgs(buffer.toString());
          }
        case 'message_delta':
          final delta = json['delta'];
          if (delta is Map && delta['stop_reason'] is String) {
            stop = delta['stop_reason'] as String;
          }
      }
    }
    final content = [
      for (final k in blocks.keys.toList()..sort()) blocks[k]!,
    ];
    yield ReplyDone(_reply(content, stop));
  }

  static LlmReply _reply(List<Object?> content, String? stop) {
    final text = StringBuffer();
    final calls = <ToolCall>[];
    for (final block in content) {
      if (block is! Map) continue;
      if (block['type'] == 'text' && block['text'] is String) {
        text.write(block['text']);
      } else if (block['type'] == 'tool_use') {
        calls.add(ToolCall(
          id: '${block['id']}',
          name: '${block['name']}',
          args: _decodeArgs(block['input']),
        ));
      }
    }
    return LlmReply(
      message: ChatMessage(
        role: ChatRole.assistant,
        text: text.toString(),
        toolCalls: calls,
        // Sent back unchanged: thinking blocks must be replayed verbatim.
        raw: {_rawKey: content},
      ),
      stopReason: stop,
      refused: stop == 'refusal',
    );
  }

  static List<Map<String, dynamic>> _toWire(List<ChatMessage> history) {
    final out = <Map<String, dynamic>>[];
    for (final m in history) {
      switch (m.role) {
        case ChatRole.user:
          out.add({'role': 'user', 'content': m.text});
        case ChatRole.assistant:
          final raw = m.raw[_rawKey];
          final List<Object?> blocks;
          if (raw is List && raw.isNotEmpty) {
            blocks = raw;
          } else {
            blocks = [
              if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
              for (final c in m.toolCalls)
                {
                  'type': 'tool_use',
                  'id': c.id,
                  'name': c.name,
                  'input': c.args,
                },
            ];
          }
          if (blocks.isEmpty) continue;
          out.add({'role': 'assistant', 'content': blocks});
        case ChatRole.tool:
          // All results of one turn go in a single user message.
          out.add({
            'role': 'user',
            'content': [
              for (final r in m.toolResults)
                {
                  'type': 'tool_result',
                  'tool_use_id': r.callId,
                  'content': r.content,
                  if (r.isError) 'is_error': true,
                },
            ],
          });
      }
    }
    return out;
  }

  @override
  Future<List<String>> listModels() async {
    final data =
        await _send('GET', Uri.parse('$_root/models?limit=100'), _headers);
    final list = data['data'];
    return [
      if (list is List)
        for (final m in list)
          if (m is Map && m['id'] is String) m['id'] as String,
    ];
  }
}

// ---------------------------------------------------------------------------
// Gemini (Google Generative Language API)
// ---------------------------------------------------------------------------

class GeminiClient extends _HttpLlmClient {
  GeminiClient({
    required super.baseUrl,
    required this.apiKey,
    required this.model,
    super.client,
  });

  final String apiKey;
  final String model;

  static const _rawKey = 'gemini';

  /// Thinking models, which can return a summary of their thoughts.
  static final _thinking = RegExp(r'gemini-(2\.5|[3-9])');

  Map<String, String> get _headers => {'x-goog-api-key': apiKey};

  String get _modelPath =>
      model.startsWith('models/') ? model : 'models/$model';

  Map<String, dynamic> _body(
          String system, List<ChatMessage> history, List<ToolSchema> tools) =>
      {
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
        'contents': _toWire(history),
        if (_thinking.hasMatch(model))
          'generationConfig': {
            'thinkingConfig': {'includeThoughts': true},
          },
        if (tools.isNotEmpty)
          'tools': [
            {
              'functionDeclarations': [
                for (final t in tools)
                  {
                    'name': t.name,
                    'description': t.description,
                    // An OBJECT without properties is rejected: omit it.
                    if (t.parameters['properties']
                        case final Map<dynamic, dynamic> p when p.isNotEmpty)
                      'parameters': geminiSchema(t.parameters),
                  },
              ],
            },
          ],
      };

  @override
  Future<LlmReply> complete({
    required String system,
    required List<ChatMessage> history,
    required List<ToolSchema> tools,
  }) async {
    final data = await _send(
        'POST',
        Uri.parse('$baseUrl/$_modelPath:generateContent'),
        _headers,
        _body(system, history, tools));
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty || candidates.first is! Map) {
      if (_blockReason(data) case final block?) return _blocked(block);
      throw const LlmException('empty reply', kind: LlmFailure.emptyReply);
    }
    final cand = candidates.first as Map;
    final contentMap = cand['content'] is Map ? cand['content'] as Map : {};
    return _reply(
      contentMap['parts'] is List ? contentMap['parts'] as List : const [],
      cand['finishReason'] as String?,
    );
  }

  @override
  Stream<LlmEvent> stream({
    required String system,
    required List<ChatMessage> history,
    required List<ToolSchema> tools,
  }) async* {
    final parts = <Map<String, dynamic>>[];
    String? reason;
    await for (final e in _sse(
        Uri.parse('$baseUrl/$_modelPath:streamGenerateContent?alt=sse'),
        _headers,
        _body(system, history, tools))) {
      final candidates = e.json['candidates'];
      if (candidates is! List ||
          candidates.isEmpty ||
          candidates.first is! Map) {
        if (_blockReason(e.json) case final block?) {
          yield ReplyDone(_blocked(block));
          return;
        }
        continue;
      }
      final cand = candidates.first as Map;
      reason = cand['finishReason'] as String? ?? reason;
      final content = cand['content'];
      final chunk = content is Map && content['parts'] is List
          ? content['parts'] as List
          : const [];
      for (final raw in chunk) {
        if (raw is! Map) continue;
        final part = Map<String, dynamic>.from(raw);
        final t = part['text'];
        if (t is String && t.isNotEmpty) {
          yield part['thought'] == true ? ThinkingDelta(t) : TextDelta(t);
        }
        if (part['functionCall'] is Map) {
          yield ToolCallDelta('${(part['functionCall'] as Map)['name']}');
        }
        _merge(parts, part);
      }
    }
    yield ReplyDone(_reply(parts, reason));
  }

  /// Appends [part], gluing streamed text pieces back together (same kind,
  /// no signature) so the replayed turn stays compact.
  static void _merge(
      List<Map<String, dynamic>> parts, Map<String, dynamic> part) {
    bool plainText(Map<String, dynamic> p) =>
        p['text'] is String &&
        p.keys.every((k) => k == 'text' || k == 'thought');
    if (parts.isNotEmpty &&
        plainText(parts.last) &&
        plainText(part) &&
        parts.last['thought'] == part['thought']) {
      parts.last['text'] = '${parts.last['text']}${part['text']}';
    } else {
      parts.add(part);
    }
  }

  static Object? _blockReason(Map<String, dynamic> data) =>
      data['promptFeedback'] is Map
          ? (data['promptFeedback'] as Map)['blockReason']
          : null;

  static LlmReply _blocked(Object block) => LlmReply(
        message: const ChatMessage(role: ChatRole.assistant),
        stopReason: '$block',
        refused: true,
      );

  static LlmReply _reply(List<Object?> parts, String? reason) {
    final text = StringBuffer();
    final calls = <ToolCall>[];
    for (final (i, part) in parts.indexed) {
      if (part is! Map) continue;
      if (part['text'] is String && part['thought'] != true) {
        text.write(part['text']);
      }
      final fc = part['functionCall'];
      if (fc is Map) {
        calls.add(ToolCall(
          id: fc['id'] is String ? fc['id'] as String : 'gemini_$i',
          name: '${fc['name']}',
          args: _decodeArgs(fc['args']),
        ));
      }
    }
    return LlmReply(
      message: ChatMessage(
        role: ChatRole.assistant,
        text: text.toString(),
        toolCalls: calls,
        // Keeps the thought signatures Gemini requires on replayed calls.
        raw: {_rawKey: parts},
      ),
      stopReason: reason,
      refused: reason == 'SAFETY' || reason == 'PROHIBITED_CONTENT',
    );
  }

  static List<Map<String, dynamic>> _toWire(List<ChatMessage> history) {
    final out = <Map<String, dynamic>>[];
    for (final m in history) {
      switch (m.role) {
        case ChatRole.user:
          out.add({
            'role': 'user',
            'parts': [
              {'text': m.text},
            ],
          });
        case ChatRole.assistant:
          final raw = m.raw[_rawKey];
          final List<Object?> parts;
          if (raw is List && raw.isNotEmpty) {
            parts = raw;
          } else {
            parts = [
              if (m.text.isNotEmpty) {'text': m.text},
              for (final c in m.toolCalls)
                {
                  'functionCall': {'name': c.name, 'args': c.args},
                },
            ];
          }
          if (parts.isEmpty) continue;
          out.add({'role': 'model', 'parts': parts});
        case ChatRole.tool:
          out.add({
            'role': 'user',
            'parts': [
              for (final r in m.toolResults)
                {
                  'functionResponse': {
                    // Newer Gemini models issue call ids; echo them back.
                    if (!r.callId.startsWith('gemini_')) 'id': r.callId,
                    'name': r.name,
                    'response': _responseObject(r),
                  },
                },
            ],
          });
      }
    }
    return out;
  }

  /// Gemini wants an object, not a string, as the function response.
  static Map<String, dynamic> _responseObject(ToolOutcome r) {
    try {
      final v = jsonDecode(r.content);
      if (v is Map<String, dynamic>) return r.isError ? {'error': v} : v;
      return {r.isError ? 'error' : 'result': v};
    } catch (_) {
      return {r.isError ? 'error' : 'result': r.content};
    }
  }

  @override
  Future<List<String>> listModels() async {
    final data =
        await _send('GET', Uri.parse('$baseUrl/models?pageSize=200'), _headers);
    final list = data['models'];
    return [
      if (list is List)
        for (final m in list)
          if (m is Map &&
              m['name'] is String &&
              (m['supportedGenerationMethods'] is! List ||
                  (m['supportedGenerationMethods'] as List)
                      .contains('generateContent')))
            (m['name'] as String).replaceFirst('models/', ''),
    ];
  }
}

/// Converts a JSON Schema to the OpenAPI subset Gemini accepts (upper-case
/// types, no `additionalProperties` / `default`…).
Map<String, dynamic> geminiSchema(Map<String, dynamic> schema) {
  final out = <String, dynamic>{};
  final type = schema['type'];
  if (type is String) out['type'] = type.toUpperCase();
  if (schema['description'] is String) {
    out['description'] = schema['description'];
  }
  if (schema['enum'] is List) out['enum'] = schema['enum'];
  final props = schema['properties'];
  if (props is Map) {
    out['properties'] = {
      for (final e in props.entries)
        if (e.value is Map)
          '${e.key}': geminiSchema((e.value as Map).cast<String, dynamic>()),
    };
    if (props.isEmpty) out.remove('properties');
  }
  if (schema['required'] is List && (schema['required'] as List).isNotEmpty) {
    out['required'] = schema['required'];
  }
  if (schema['items'] is Map) {
    out['items'] =
        geminiSchema((schema['items'] as Map).cast<String, dynamic>());
  }
  return out;
}
