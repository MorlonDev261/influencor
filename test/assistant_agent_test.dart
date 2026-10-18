import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:influencor/core/providers/settings_providers.dart';
import 'package:influencor/core/providers/workspace_providers.dart';
import 'package:influencor/core/services/settings_service.dart';
import 'package:influencor/features/assistant/application/assistant_providers.dart';
import 'package:influencor/features/assistant/application/tools/deganeo_tools.dart';
import 'package:influencor/features/assistant/data/assistant_config_store.dart';
import 'package:influencor/features/assistant/data/chat_store.dart';
import 'package:influencor/features/assistant/data/llm_client.dart';
import 'package:influencor/features/assistant/domain/chat_message.dart';
import 'package:influencor/features/assistant/domain/llm_provider.dart';
import 'package:influencor/features/cleaner/application/metadata_cleaner_service.dart';
import 'package:influencor/features/cleaner/data/clean_pipeline.dart';
import 'package:influencor/features/cleaner/domain/clean_options.dart';
import 'package:influencor/features/cleaner/domain/clean_report.dart';
import 'package:path/path.dart' as p;

import 'cleaner/fixtures.dart';

/// The real cleaning pipeline, writing into a test folder instead of the
/// platform temp directory (path_provider is not available in tests).
class _TestCleaner extends MetadataCleanerService {
  _TestCleaner(this.out);

  final Directory out;

  @override
  Future<CleanReport> clean(String sourcePath,
          {CleanOptions options = CleanOptions.stripAll}) =>
      const CleanPipeline().run(sourcePath, out, options);

  @override
  Future<InspectResult> inspect(String sourcePath) =>
      const CleanPipeline().inspect(sourcePath);
}

class _FakeSettings extends SettingsService {
  @override
  Future<AppSettings> load() async => const AppSettings();

  @override
  Future<void> save(AppSettings settings) async {}
}

class _EnglishSettings extends SettingsService {
  @override
  Future<AppSettings> load() async => const AppSettings(languageCode: 'en');

  @override
  Future<void> save(AppSettings settings) async {}
}

class _FakeConfigStore extends AssistantConfigStore {
  @override
  Future<AssistantConfig> load() async => const AssistantConfig(
        provider: LlmProviderKind.openai,
        providers: {
          LlmProviderKind.openai: ProviderSettings(apiKey: 'sk-test')
        },
      );

  @override
  Future<AssistantConfig> save(AssistantConfig config) async => config;
}

/// Plays back scripted turns and records what the agent sent.
class _ScriptedClient extends LlmClient {
  _ScriptedClient(this.turns);

  final List<LlmReply Function(List<ChatMessage> history)> turns;
  final requests = <List<ChatMessage>>[];

  @override
  Future<LlmReply> complete({
    required String system,
    required List<ChatMessage> history,
    required List<ToolSchema> tools,
  }) async {
    requests.add(List.of(history));
    return turns[requests.length - 1](history);
  }

  @override
  Future<List<String>> listModels() async => const [];

  @override
  void cancel() {}
}

/// Streams the given deltas, then the text they spell as the final reply.
class _StreamingClient extends LlmClient {
  _StreamingClient(this.events);

  final List<LlmEvent> events;

  @override
  Stream<LlmEvent> stream({
    required String system,
    required List<ChatMessage> history,
    required List<ToolSchema> tools,
  }) async* {
    for (final e in events) {
      await Future<void>.delayed(Duration.zero);
      yield e;
    }
    yield ReplyDone(LlmReply(
      message: ChatMessage(
        role: ChatRole.assistant,
        text: events.whereType<TextDelta>().map((e) => e.text).join(),
      ),
    ));
  }

  @override
  Future<LlmReply> complete({
    required String system,
    required List<ChatMessage> history,
    required List<ToolSchema> tools,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<String>> listModels() async => const [];

  @override
  void cancel() {}
}

LlmReply _calls(List<(String, Map<String, dynamic>)> calls) => LlmReply(
      message: ChatMessage(
        role: ChatRole.assistant,
        toolCalls: [
          for (final (i, (name, args)) in calls.indexed)
            ToolCall(id: 'c$i', name: name, args: args),
        ],
      ),
    );

LlmReply _text(String text) =>
    LlmReply(message: ChatMessage(role: ChatRole.assistant, text: text));

/// API keys kept in memory instead of the system's secure storage.
class _MemorySecrets implements SecretStore {
  final values = <String, String>{};
  bool broken = false;

  @override
  Future<String?> read(String key) async {
    if (broken) throw StateError('no secure storage');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (broken) throw StateError('no secure storage');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (broken) throw StateError('no secure storage');
    values.remove(key);
  }
}

void main() {
  late Directory root;
  late Directory appData;
  late File chatFile;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('influencor_agent_');
    appData = await Directory.systemTemp.createTemp('influencor_appdata_');
    chatFile = File(p.join(appData.path, 'assistant_chat.json'));
  });

  tearDown(() async {
    // Best effort: Windows refuses while a background save still holds a file.
    for (final dir in [root, appData]) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException catch (_) {}
    }
  });

  Future<ProviderContainer> container(_ScriptedClient client) async {
    final c = ProviderContainer(overrides: [
      settingsServiceProvider.overrideWithValue(_FakeSettings()),
      workspaceRootProvider.overrideWithValue(root.path),
      assistantConfigStoreProvider.overrideWithValue(_FakeConfigStore()),
      chatStoreProvider
          .overrideWithValue(ChatStore(file: () async => chatFile)),
      llmClientFactoryProvider.overrideWithValue((_) => client),
      appPrivateDirectoriesProvider.overrideWith((ref) async => [appData.path]),
    ]);
    addTearDown(c.dispose);
    await c.read(assistantConfigControllerProvider.future);
    return c;
  }

  group('API keys', () {
    test('live in the secure storage, never in the settings file', () async {
      final file = File(p.join(appData.path, 'assistant_settings.json'));
      final secrets = _MemorySecrets();
      final store =
          AssistantConfigStore(secrets: secrets, file: () async => file);

      await store.save(const AssistantConfig(
        provider: LlmProviderKind.anthropic,
        providers: {
          LlmProviderKind.anthropic: ProviderSettings(
              apiKey: 'sk-ant-secret', model: 'claude-opus-5-5'),
        },
      ));

      expect(file.readAsStringSync(), isNot(contains('sk-ant-secret')));
      expect(secrets.values.values, contains('sk-ant-secret'));
      final loaded = await store.load();
      expect(loaded.settingsFor(LlmProviderKind.anthropic).apiKey,
          'sk-ant-secret');
      expect(loaded.settingsFor(LlmProviderKind.anthropic).model,
          'claude-opus-5-5');
    });

    test('a key saved in clear by an older version is moved on load', () async {
      final file = File(p.join(appData.path, 'assistant_settings.json'))
        ..writeAsStringSync(jsonEncode({
          'provider': 'openai',
          'providers': {
            'openai': {
              'apiKey': 'sk-old-plain',
              'model': 'gpt-5',
              'baseUrl': ''
            },
          },
        }));
      final secrets = _MemorySecrets();
      final store =
          AssistantConfigStore(secrets: secrets, file: () async => file);

      final loaded = await store.load();

      expect(loaded.current.apiKey, 'sk-old-plain');
      expect(secrets.values.values, contains('sk-old-plain'));
      expect(file.readAsStringSync(), isNot(contains('sk-old-plain')));
    });

    test('without secure storage the assistant keeps working', () async {
      final file = File(p.join(appData.path, 'assistant_settings.json'));
      final store = AssistantConfigStore(
          secrets: _MemorySecrets()..broken = true, file: () async => file);
      await store.save(const AssistantConfig(
        providers: {LlmProviderKind.openai: ProviderSettings(apiKey: 'sk-x')},
      ));
      expect((await store.load()).current.apiKey, 'sk-x');
    });

    test('a key stored in clear is flagged, never a missing or secured one',
        () async {
      final file = File(p.join(appData.path, 'assistant_settings.json'));
      const withKey = AssistantConfig(
        providers: {LlmProviderKind.openai: ProviderSettings(apiKey: 'sk-x')},
      );
      final broken = AssistantConfigStore(
          secrets: _MemorySecrets()..broken = true, file: () async => file);
      expect((await broken.save(withKey)).keysInPlainText, isTrue);
      expect(file.readAsStringSync(), contains('sk-x'));
      expect((await broken.load()).keysInPlainText, isTrue);
      // No key at all: nothing to warn about.
      expect((await broken.save(const AssistantConfig())).keysInPlainText,
          isFalse);

      final secure = AssistantConfigStore(
          secrets: _MemorySecrets(), file: () async => file);
      expect((await secure.save(withKey)).keysInPlainText, isFalse);
      expect((await secure.load()).keysInPlainText, isFalse);
      // The flag itself is never written to the file.
      expect(file.readAsStringSync(), isNot(contains('keysInPlainText')));
    });
  });

  test('the conversation is saved and comes back on the next launch', () async {
    final first = await container(_ScriptedClient([
      (_) => _calls([
            ('list_tags', <String, dynamic>{}),
          ]),
      (_) => _text('Aucun tag.'),
    ]));
    await first.read(assistantChatProvider.notifier).send('mes tags ?');
    await first.read(assistantChatProvider.notifier).pendingSave;
    expect(chatFile.existsSync(), isTrue);

    // A new app session with the same storage.
    final client = _ScriptedClient([(_) => _text('Toujours aucun.')]);
    final second = await container(client);
    await second.read(assistantChatProvider.notifier).restored;
    final restored = second.read(assistantChatProvider).items;
    expect(restored.first.text, 'mes tags ?');
    expect(restored.any((i) => i.kind == ChatItemKind.tool), isTrue);
    expect(restored.last.text, 'Aucun tag.');

    // The model gets the earlier exchange as context.
    await second.read(assistantChatProvider.notifier).send('et maintenant ?');
    expect(client.requests.single.where((m) => m.role == ChatRole.user),
        hasLength(2));

    // A new conversation forgets it, on disk too.
    second.read(assistantChatProvider.notifier).clear();
    await second.read(assistantChatProvider.notifier).pendingSave;
    expect(chatFile.existsSync(), isFalse);
  });

  test('a very long conversation keeps only what fits, from a user turn',
      () async {
    final big = 'x' * 60000;
    final client = _ScriptedClient([
      for (var i = 0; i < 6; i++) (_) => _text('réponse $i $big'),
    ]);
    final c = await container(client);
    final chat = c.read(assistantChatProvider.notifier);
    for (var i = 0; i < 6; i++) {
      await chat.send('question $i');
    }

    final sent = client.requests.last;
    final size = sent.fold<int>(0, (s, m) => s + jsonEncode(m.toJson()).length);
    expect(size, lessThan(260000));
    expect(sent.first.role, ChatRole.user);
    expect(sent.last.text, 'question 5');
    expect(sent.any((m) => m.raw.isNotEmpty), isFalse);
    expect(
      c
          .read(assistantChatProvider)
          .items
          .where((i) => i.kind == ChatItemKind.notice),
      isNotEmpty,
    );
  });

  test('errors are shown in the app language', () async {
    final client = _ScriptedClient([
      (_) => throw const LlmException('timeout', kind: LlmFailure.timeout),
    ]);
    final c = ProviderContainer(overrides: [
      settingsServiceProvider.overrideWithValue(_EnglishSettings()),
      workspaceRootProvider.overrideWithValue(root.path),
      assistantConfigStoreProvider.overrideWithValue(_FakeConfigStore()),
      chatStoreProvider
          .overrideWithValue(ChatStore(file: () async => chatFile)),
      llmClientFactoryProvider.overrideWithValue((_) => client),
    ]);
    addTearDown(c.dispose);
    await c.read(assistantConfigControllerProvider.future);
    await c.read(settingsControllerProvider.future);

    await c.read(assistantChatProvider.notifier).send('hi');
    expect(c.read(assistantChatProvider).items.last.text,
        'The service is not responding (timed out).');
  });

  test('runs tools in a loop until the model answers', () async {
    final client = _ScriptedClient([
      (_) => _calls([
            ('create_folder', {'name': 'Clients'}),
            (
              'create_note',
              {
                'folder': 'Clients',
                'title': 'Brief',
                'content': 'Prix : 25 000 Ar'
              }
            ),
          ]),
      (_) => _calls([
            ('search_library', {'query': 'prix'}),
          ]),
      (_) => _text('Fait : [[Clients/Brief.md]]'),
    ]);
    final c = await container(client);

    await c.read(assistantChatProvider.notifier).send('Crée un brief');

    expect(File(p.join(root.path, 'Clients', 'Brief.md')).readAsStringSync(),
        'Prix : 25 000 Ar');
    // The search found the note through its content, with a relative path.
    final searchResult = client.requests[2].last.toolResults.single;
    expect(searchResult.isError, isFalse);
    expect(searchResult.content, contains('Clients/Brief.md'));

    final state = c.read(assistantChatProvider);
    expect(state.busy, isFalse);
    expect(
      state.items
          .where((i) => i.kind == ChatItemKind.tool)
          .map((i) => i.status),
      everyElement(ToolStatus.done),
    );
    expect(state.items.last.text, 'Fait : [[Clients/Brief.md]]');
  });

  test('destructive tools wait for the user and respect a refusal', () async {
    final note = File(p.join(root.path, 'a.md'))..writeAsStringSync('x');
    final client = _ScriptedClient([
      (_) => _calls([
            (
              'move_to_trash',
              {
                'paths': ['a.md']
              }
            ),
          ]),
      (_) => _text('ok'),
      (_) => _calls([
            (
              'move_to_trash',
              {
                'paths': ['a.md']
              }
            ),
          ]),
      (_) => _text('ok'),
    ]);
    final c = await container(client);
    final chat = c.read(assistantChatProvider.notifier);

    var asked = 0;
    chat.confirmHandler = (title, message) async {
      asked++;
      expect(message, contains('a.md'));
      return false;
    };
    await chat.send('supprime a');
    expect(asked, 1);
    expect(note.existsSync(), isTrue);
    expect(client.requests[1].last.toolResults.single.isError, isTrue);

    chat.confirmHandler = (_, __) async => true;
    await chat.send('supprime a, je confirme');
    expect(note.existsSync(), isFalse);
  });

  test('paths cannot leave the workspace or touch app metadata', () async {
    final client = _ScriptedClient([
      (_) => _calls([
            ('read_note', {'path': '../secret.txt'}),
            ('read_note', {'path': '.clipboard/metadata.json'}),
          ]),
      (_) => _text('non'),
    ]);
    final c = await container(client);
    await c.read(assistantChatProvider.notifier).send('lis');

    final results = client.requests[1].last.toolResults;
    expect(results.map((r) => r.isError), [true, true]);
  });

  test('the app data folder is off limits, even by absolute path', () async {
    final settings = File(p.join(appData.path, 'assistant_settings.json'))
      ..writeAsStringSync('{"providers":{}}');
    final outside = await Directory.systemTemp.createTemp('influencor_out_');
    addTearDown(() => outside.delete(recursive: true));
    final photo = File(p.join(outside.path, 'photo.txt'))
      ..writeAsStringSync('ok');
    final client = _ScriptedClient([
      (_) => _calls([
            (
              'import_files',
              {
                'sources': [settings.path],
              }
            ),
            (
              'import_files',
              {
                'sources': [appData.path],
              }
            ),
            ('deganeo_inspect', {'path': chatFile.path}),
            (
              'import_files',
              {
                'sources': [photo.path],
              }
            ),
          ]),
      (_) => _text('fait'),
    ]);
    final c = await container(client);
    await c.read(assistantChatProvider.notifier).send('importe');

    final results = client.requests[1].last.toolResults;
    expect(results.map((r) => r.isError), [true, true, true, false]);
    expect(results.first.content, contains('données internes'));
    expect(results.last.content, contains('"imported": 1'));
    // Nothing of the app's data ended up in the workspace.
    final copied = root
        .listSync(recursive: true)
        .map((e) => p.basename(e.path))
        .where((n) => n.startsWith('assistant_'));
    expect(copied, isEmpty);
  });

  test('ask_user shows choices and waits for the tapped answer', () async {
    final client = _ScriptedClient([
      (_) => _calls([
            (
              'ask_user',
              {
                'question': 'Où enregistrer ?',
                'options': ['Copie à côté', 'Remplacer', 'Bibliothèque'],
              }
            ),
          ]),
      (h) => _text('Choix : ${h.last.toolResults.single.content}'),
    ]);
    final c = await container(client);
    final chat = c.read(assistantChatProvider.notifier);

    final run = chat.send('nettoie');
    await pumpEventQueue();
    final waiting = c.read(assistantChatProvider);
    expect(waiting.awaitingAnswer, isTrue);
    final question =
        waiting.items.singleWhere((i) => i.kind == ChatItemKind.question);
    expect(question.options, ['Copie à côté', 'Remplacer', 'Bibliothèque']);

    chat.answer('Bibliothèque');
    await run;

    final state = c.read(assistantChatProvider);
    expect(state.awaitingAnswer, isFalse);
    expect(
      state.items.singleWhere((i) => i.kind == ChatItemKind.question).answer,
      'Bibliothèque',
    );
    expect(state.items.last.text, contains('Bibliothèque'));
  });

  test('typing while a question waits answers it', () async {
    final client = _ScriptedClient([
      (_) => _calls([
            (
              'ask_user',
              {
                'question': 'Quel dossier ?',
                'options': ['A']
              }
            ),
          ]),
      (h) => _text(h.last.toolResults.single.content),
    ]);
    final c = await container(client);
    final chat = c.read(assistantChatProvider.notifier);
    final run = chat.send('range');
    await pumpEventQueue();

    await chat.send('Promo/Octobre');
    await run;
    expect(c.read(assistantChatProvider).items.last.text,
        contains('Promo/Octobre'));
    // The typed answer is not a new user turn.
    expect(client.requests.last.where((m) => m.role == ChatRole.user),
        hasLength(1));
  });

  test('attached photo is cleaned by Deganeo into a library folder', () async {
    final outside = await Directory.systemTemp.createTemp('influencor_pick_');
    addTearDown(() => outside.delete(recursive: true));
    final photo = File(p.join(outside.path, 'photo.jpg'))
      ..writeAsBytesSync(jpegWithMetadata());
    final original = photo.readAsBytesSync();
    final tempOut = await Directory.systemTemp.createTemp('influencor_clean_');
    addTearDown(() => tempOut.delete(recursive: true));

    final client = _ScriptedClient([
      (h) {
        // The model sees the attachment with its absolute path.
        expect(h.first.text, contains("[Fichiers joints par l'utilisateur]"));
        expect(h.first.text, contains(photo.path));
        return _calls([
          (
            'deganeo_clean',
            {
              'paths': [photo.path],
              'save': 'library',
              'folder': 'Publié',
            }
          ),
        ]);
      },
      (_) => _text('Fait : [[Publié/photo_clean.jpg]]'),
    ]);
    final c = ProviderContainer(overrides: [
      settingsServiceProvider.overrideWithValue(_FakeSettings()),
      workspaceRootProvider.overrideWithValue(root.path),
      assistantConfigStoreProvider.overrideWithValue(_FakeConfigStore()),
      chatStoreProvider
          .overrideWithValue(ChatStore(file: () async => chatFile)),
      llmClientFactoryProvider.overrideWithValue((_) => client),
      metadataCleanerProvider.overrideWithValue(_TestCleaner(tempOut)),
    ]);
    addTearDown(c.dispose);
    await c.read(assistantConfigControllerProvider.future);

    await c
        .read(assistantChatProvider.notifier)
        .send('', attachments: [photo.path]);

    final result = client.requests[1].last.toolResults.single;
    expect(result.isError, isFalse, reason: result.content);
    final saved = File(p.join(root.path, 'Publié', 'photo_clean.jpg'));
    expect(saved.existsSync(), isTrue, reason: result.content);
    // Only the orientation flag may remain (no personal data).
    final rescan = await const CleanPipeline().inspect(saved.path);
    expect(rescan.findings.where((f) => f.sensitive), isEmpty);
    expect(String.fromCharCodes(saved.readAsBytesSync()),
        isNot(contains('shot by someone')));
    // The original is untouched and the temp copy is gone.
    expect(photo.readAsBytesSync(), original);
    expect(tempOut.listSync(), isEmpty);
    final user = c.read(assistantChatProvider).items.first;
    expect(user.attachments, [photo.path]);
  });

  test('tasks and accounting tools', () async {
    final client = _ScriptedClient([
      (_) => _calls([
            (
              'create_task',
              {
                'title': 'Shooting',
                'items': ['Lumière', 'Robe']
              }
            ),
            (
              'add_transaction',
              {'amount': '15 000', 'account': 'MVola', 'type': 'sale'}
            ),
            (
              'add_transaction',
              {'amount': 4000, 'account': 'cash', 'type': 'expense'}
            ),
            ('accounting_summary', <String, dynamic>{}),
          ]),
      (_) => _text('ok'),
    ]);
    final c = await container(client);
    await c.read(assistantChatProvider.notifier).send('go');

    final results = client.requests[1].last.toolResults;
    expect(results.map((r) => r.isError), everyElement(isFalse));
    final summary = jsonDecode(results.last.content) as Map;
    expect(summary['net'], 11000);
    expect((summary['balance_by_account'] as Map)['mvola'], 15000);
    expect(
      Directory(p.join(root.path, '.clipboard', 'tasks')).listSync(),
      hasLength(1),
    );
  });

  test('accounting tools work on the current sheet', () async {
    // A ledger written before sheets existed.
    File(p.join(root.path, '.clipboard', 'accounting.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'version': 1,
        'entries': [
          {
            'id': 'old',
            'date': '2026-10-10',
            'amount': 20000,
            'account': 'mvola',
            'type': 'sale',
            'direction': 'credit',
          },
        ],
      }));
    final client = _ScriptedClient([
      (_) => _calls([
            ('close_ledger_sheet', <String, dynamic>{}),
            ('update_transaction', {'id': 'old', 'amount': 1}),
            (
              'add_transaction',
              {'amount': 3000, 'account': 'mvola', 'type': 'expense'}
            ),
            ('accounting_summary', <String, dynamic>{}),
            ('list_ledger_sheets', <String, dynamic>{}),
          ]),
      (_) => _text('ok'),
    ]);
    final c = await container(client);
    final chat = c.read(assistantChatProvider.notifier);
    var asked = 0;
    chat.confirmHandler = (_, __) async {
      asked++;
      return true;
    };
    await chat.send('clôture ma feuille');

    expect(asked, 1);
    final results = client.requests[1].last.toolResults;
    expect(results.map((r) => r.isError), [false, true, false, false, false]);
    final summary = jsonDecode(results[3].content) as Map;
    expect(summary['net'], -3000);
    expect((summary['opening_balance_by_account'] as Map)['mvola'], 20000);
    expect((summary['available_balance_by_account'] as Map)['mvola'], 17000);
    final sheets = (jsonDecode(results[4].content) as Map)['sheets'] as List;
    expect(sheets.map((s) => (s as Map)['status']), ['open', 'closed']);
    expect((sheets.last as Map)['closing_balance'], 20000);
  });

  test('an unanswered message is dropped so the history stays valid', () async {
    final client = _ScriptedClient([
      (_) => throw const LlmException('boom', statusCode: 401),
      (_) => _text('ok'),
    ]);
    final c = await container(client);
    final chat = c.read(assistantChatProvider.notifier);
    await chat.send('one');
    expect(c.read(assistantChatProvider).items.last.kind, ChatItemKind.error);
    await chat.send('two');
    expect(client.requests[1].map((m) => m.text), ['two']);
  });

  test('a refusal is not replayed and the next message starts clean', () async {
    final client = _ScriptedClient([
      (_) => const LlmReply(
            message: ChatMessage(role: ChatRole.assistant),
            stopReason: 'refusal',
            refused: true,
          ),
      (_) => _text('ok'),
    ]);
    final c = await container(client);
    final chat = c.read(assistantChatProvider.notifier);
    await chat.send('one');
    expect(c.read(assistantChatProvider).items.last.kind, ChatItemKind.error);
    await chat.send('two');
    expect(client.requests[1].map((m) => m.text), ['two']);
  });

  test('streams reasoning and text into the chat as they arrive', () async {
    final seen = <List<String>>[];
    final client = _StreamingClient([
      const ThinkingDelta('Je regarde '),
      const ThinkingDelta('la bibliothèque.'),
      const TextDelta('Bonjour'),
      const TextDelta(' !'),
    ]);
    final c = ProviderContainer(overrides: [
      settingsServiceProvider.overrideWithValue(_FakeSettings()),
      workspaceRootProvider.overrideWithValue(root.path),
      assistantConfigStoreProvider.overrideWithValue(_FakeConfigStore()),
      chatStoreProvider
          .overrideWithValue(ChatStore(file: () async => chatFile)),
      llmClientFactoryProvider.overrideWithValue((_) => client),
    ]);
    addTearDown(c.dispose);
    await c.read(assistantConfigControllerProvider.future);
    c.listen(assistantChatProvider, (_, next) {
      final text = next.items.where((i) => i.kind == ChatItemKind.assistant);
      if (text.isNotEmpty) seen.add([text.first.text]);
    });

    await c.read(assistantChatProvider.notifier).send('salut');

    // The answer grew token by token…
    expect(seen.map((s) => s.single),
        containsAllInOrder(['Bonjour', 'Bonjour !']));
    // …and ends settled: reasoning first, then the answer, nothing streaming.
    final items = c.read(assistantChatProvider).items;
    expect(items.map((i) => i.kind), [
      ChatItemKind.user,
      ChatItemKind.thinking,
      ChatItemKind.assistant,
    ]);
    expect(items[1].text, 'Je regarde la bibliothèque.');
    expect(items[1].elapsed, isNotNull);
    expect(items.any((i) => i.streaming), isFalse);
  });

  group('streaming (SSE)', () {
    http.Response sse(List<String> events) => http.Response(
          events.join(),
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
    String ev(Object json, [String? name]) =>
        '${name == null ? '' : 'event: $name\n'}data: ${jsonEncode(json)}\n\n';
    final history = [const ChatMessage.user('hi')];

    Future<List<LlmEvent>> run(LlmClient client) =>
        client.stream(system: 's', history: history, tools: const []).toList();

    test('Claude: thinking, text and a tool call with streamed input',
        () async {
      late Map<String, dynamic> body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return sse([
          ev({'type': 'message_start', 'message': {}}, 'message_start'),
          ev({
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'thinking', 'thinking': ''},
          }),
          ev({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'thinking_delta', 'thinking': 'Hmm'},
          }),
          ev({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'signature_delta', 'signature': 'sig'},
          }),
          ev({'type': 'content_block_stop', 'index': 0}),
          ev({
            'type': 'content_block_start',
            'index': 1,
            'content_block': {'type': 'text', 'text': ''},
          }),
          ev({
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'text_delta', 'text': 'Je '},
          }),
          ev({
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'text_delta', 'text': 'cherche.'},
          }),
          ev({'type': 'content_block_stop', 'index': 1}),
          ev({
            'type': 'content_block_start',
            'index': 2,
            'content_block': {
              'type': 'tool_use',
              'id': 'tu1',
              'name': 'search_library',
              'input': {},
            },
          }),
          ev({
            'type': 'content_block_delta',
            'index': 2,
            'delta': {'type': 'input_json_delta', 'partial_json': '{"query":'},
          }),
          ev({
            'type': 'content_block_delta',
            'index': 2,
            'delta': {'type': 'input_json_delta', 'partial_json': '"prix"}'},
          }),
          ev({'type': 'content_block_stop', 'index': 2}),
          ev({
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
          }),
          ev({'type': 'message_stop'}),
        ]);
      });
      final events = await run(AnthropicClient(
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'k',
        model: 'claude-opus-5-5',
        client: mock,
      ));

      expect(body['stream'], isTrue);
      expect(body['thinking'], {'type': 'adaptive', 'display': 'summarized'});
      expect(events.whereType<ThinkingDelta>().map((e) => e.text), ['Hmm']);
      expect(events.whereType<TextDelta>().map((e) => e.text).join(),
          'Je cherche.');
      expect(events.whereType<ToolCallDelta>().single.name, 'search_library');
      final reply = (events.last as ReplyDone).reply;
      expect(reply.stopReason, 'tool_use');
      expect(reply.message.toolCalls.single.args, {'query': 'prix'});
      final raw = reply.message.raw['anthropic'] as List;
      expect(raw.first,
          {'type': 'thinking', 'thinking': 'Hmm', 'signature': 'sig'});
    });

    test('OpenAI-compatible: content, reasoning and split tool arguments',
        () async {
      final mock = MockClient((req) async {
        expect((jsonDecode(req.body) as Map)['stream'], isTrue);
        Map<String, dynamic> chunk(Map<String, dynamic> delta,
                [String? finish]) =>
            {
              'choices': [
                {'delta': delta, 'finish_reason': finish},
              ],
            };
        return sse([
          ev(chunk({'reasoning_content': 'Réfléchir'})),
          ev(chunk({'content': 'Bon'})),
          ev(chunk({'content': 'jour'})),
          ev(chunk({
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_9',
                'function': {'name': 'list_tags', 'arguments': '{"a"'},
              },
            ],
          })),
          ev(chunk({
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': ':1}'},
              },
            ],
          }, 'tool_calls')),
          'data: [DONE]\n\n',
        ]);
      });
      final events = await run(OpenAiCompatibleClient(
          baseUrl: 'https://api.deepseek.com/v1',
          apiKey: 'k',
          model: 'deepseek-chat',
          client: mock));

      expect(events.whereType<TextDelta>().map((e) => e.text), ['Bon', 'jour']);
      expect(events.whereType<ThinkingDelta>().single.text, 'Réfléchir');
      final reply = (events.last as ReplyDone).reply;
      expect(reply.message.text, 'Bonjour');
      expect(reply.message.toolCalls.single.id, 'call_9');
      expect(reply.message.toolCalls.single.args, {'a': 1});
      // DeepSeek's reasoning is echoed back within the tool loop.
      expect((reply.message.raw['openai'] as Map)['reasoning_content'],
          'Réfléchir');
    });

    test('Gemini: thoughts, text pieces merged, function call kept', () async {
      late Uri url;
      final mock = MockClient((req) async {
        url = req.url;
        Map<String, dynamic> chunk(List<Map<String, dynamic>> parts,
                [String? finish]) =>
            {
              'candidates': [
                {
                  'content': {'role': 'model', 'parts': parts},
                  'finishReason': finish,
                },
              ],
            };
        return sse([
          ev(chunk([
            {'text': 'Je pense', 'thought': true},
          ])),
          ev(chunk([
            {'text': 'Voi'},
          ])),
          ev(chunk([
            {'text': 'ci'},
          ])),
          ev(chunk([
            {
              'functionCall': {'name': 'list_tags', 'args': {}},
              'thoughtSignature': 'xyz',
            },
          ], 'STOP')),
        ]);
      });
      final events = await run(GeminiClient(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        apiKey: 'k',
        model: 'gemini-2.5-flash',
        client: mock,
      ));

      expect(url.path, endsWith(':streamGenerateContent'));
      expect(url.queryParameters['alt'], 'sse');
      expect(events.whereType<ThinkingDelta>().single.text, 'Je pense');
      final reply = (events.last as ReplyDone).reply;
      expect(reply.message.text, 'Voici');
      final parts = reply.message.raw['gemini'] as List;
      expect(parts, hasLength(3)); // thought, merged text, call
      expect(parts.last['thoughtSignature'], 'xyz');
    });

    test('an error event becomes a readable LlmException', () async {
      final mock = MockClient((req) async => sse([
            ev({
              'type': 'error',
              'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
            }, 'error'),
          ]));
      expect(
        run(AnthropicClient(
            baseUrl: 'https://api.anthropic.com',
            apiKey: 'k',
            model: 'claude-sonnet-5-5',
            client: mock)),
        throwsA(isA<LlmException>()
            .having((e) => e.message, 'message', 'Overloaded')),
      );
    });
  });

  group('wire formats', () {
    const tools = [
      ToolSchema(
        name: 'search_library',
        description: 'd',
        parameters: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
          },
        },
      ),
    ];
    final history = [
      const ChatMessage.user('hi'),
      const ChatMessage(role: ChatRole.assistant, toolCalls: [
        ToolCall(id: 't1', name: 'search_library', args: {'query': 'x'}),
        ToolCall(id: 't2', name: 'list_tags', args: {}),
      ]),
      const ChatMessage(role: ChatRole.tool, toolResults: [
        ToolOutcome(
            callId: 't1', name: 'search_library', content: '{"total":0}'),
        ToolOutcome(
            callId: 't2', name: 'list_tags', content: 'oops', isError: true),
      ]),
    ];

    test('Claude: tools, tool results in one user turn, tool_use parsed',
        () async {
      late Map<String, dynamic> body;
      late Map<String, String> headers;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        headers = req.headers;
        return http.Response(
          jsonEncode({
            'stop_reason': 'tool_use',
            'content': [
              {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
              {'type': 'text', 'text': 'Je cherche.'},
              {
                'type': 'tool_use',
                'id': 'tu1',
                'name': 'search_library',
                'input': {'query': 'prix'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = AnthropicClient(
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'k',
        model: 'claude-opus-5-5',
        client: mock,
      );
      final reply =
          await client.complete(system: 's', history: history, tools: tools);

      expect(headers['x-api-key'], 'k');
      expect(headers['anthropic-version'], '2023-06-01');
      expect(body['fallbacks'], 'default');
      expect((body['tools'] as List).single['input_schema'], isNotNull);
      final messages = body['messages'] as List;
      expect(messages.map((m) => m['role']), ['user', 'assistant', 'user']);
      final results = messages.last['content'] as List;
      expect(results.map((r) => r['tool_use_id']), ['t1', 't2']);
      expect(results.last['is_error'], isTrue);

      expect(reply.message.text, 'Je cherche.');
      expect(reply.message.toolCalls.single.args, {'query': 'prix'});
      // Thinking blocks are kept to be replayed verbatim.
      expect(
          (reply.message.raw['anthropic'] as List).first['type'], 'thinking');
    });

    test('OpenAI-compatible: tool_calls round trip', () async {
      late Map<String, dynamic> body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(
            req.url.toString(), 'https://api.deepseek.com/v1/chat/completions');
        expect(req.headers['authorization'], 'Bearer k');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'tool_calls',
                'message': {
                  'role': 'assistant',
                  'content': null,
                  'tool_calls': [
                    {
                      'id': 'call_1',
                      'type': 'function',
                      'function': {
                        'name': 'search_library',
                        'arguments': '{"query":"robe"}',
                      },
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      });
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://api.deepseek.com/v1/',
        apiKey: 'k',
        model: 'deepseek-chat',
        client: mock,
      );
      final reply =
          await client.complete(system: 's', history: history, tools: tools);

      final messages = body['messages'] as List;
      expect(messages.map((m) => m['role']),
          ['system', 'user', 'assistant', 'tool', 'tool']);
      expect(messages[2]['tool_calls'][0]['function']['arguments'],
          '{"query":"x"}');
      expect(messages[3]['tool_call_id'], 't1');
      expect(reply.message.toolCalls.single.name, 'search_library');
      expect(reply.message.toolCalls.single.args, {'query': 'robe'});
    });

    test('Gemini: function calls, responses and schema conversion', () async {
      late Map<String, dynamic> body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(
            req.url.path, endsWith('/models/gemini-2.5-flash:generateContent'));
        expect(req.headers['x-goog-api-key'], 'k');
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'finishReason': 'STOP',
                'content': {
                  'role': 'model',
                  'parts': [
                    {
                      'functionCall': {
                        'name': 'search_library',
                        'args': {'query': 'a'},
                      },
                      'thoughtSignature': 'abc',
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      });
      final client = GeminiClient(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        apiKey: 'k',
        model: 'gemini-2.5-flash',
        client: mock,
      );
      final reply =
          await client.complete(system: 's', history: history, tools: tools);

      final decl = (body['tools'] as List).single['functionDeclarations'][0];
      expect(decl['parameters']['type'], 'OBJECT');
      final contents = body['contents'] as List;
      expect(contents.map((c) => c['role']), ['user', 'model', 'user']);
      final responses = contents.last['parts'] as List;
      expect(responses.first['functionResponse']['response'], {'total': 0});
      expect(responses.last['functionResponse']['response'], {'error': 'oops'});
      expect(reply.message.toolCalls.single.args, {'query': 'a'});
      expect((reply.message.raw['gemini'] as List).first['thoughtSignature'],
          'abc');
    });

    test('HTTP errors surface the provider message', () async {
      final mock = MockClient((req) async => http.Response(
            jsonEncode({
              'error': {'message': 'Incorrect API key'},
            }),
            401,
          ));
      final client = OpenAiCompatibleClient(
          baseUrl: 'https://x/v1', apiKey: 'k', model: 'm', client: mock);
      expect(
        () => client.complete(system: 's', history: history, tools: tools),
        throwsA(isA<LlmException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.message, 'message', 'Incorrect API key')),
      );
    });
  });
}
