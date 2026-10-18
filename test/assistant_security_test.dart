import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:influencor/core/l10n/app_strings.dart';
import 'package:influencor/features/assistant/application/assistant_providers.dart';
import 'package:influencor/features/assistant/data/assistant_config_store.dart';
import 'package:influencor/features/assistant/data/llm_client.dart';
import 'package:influencor/features/assistant/domain/chat_message.dart';
import 'package:influencor/features/assistant/domain/llm_provider.dart';
import 'package:influencor/features/assistant/presentation/assistant_settings_screen.dart';

class _StaticConfigStore extends AssistantConfigStore {
  _StaticConfigStore(this.config);

  final AssistantConfig config;

  @override
  Future<AssistantConfig> load() async => config;

  @override
  Future<AssistantConfig> save(AssistantConfig config) async =>
      config.copyWith(keysInPlainText: this.config.keysInPlainText);
}

void main() {
  group('isSecureEndpoint', () {
    test('HTTPS anywhere, plain HTTP only to this device', () {
      for (final ok in [
        'https://api.openai.com/v1',
        'https://my-proxy.example.org:8443/v1',
        'http://localhost:11434/v1',
        'http://LOCALHOST:1234',
        'http://ollama.localhost/v1',
        'http://127.0.0.1:1234/v1',
        'http://127.1.2.3',
        'http://[::1]:11434/v1',
      ]) {
        expect(isSecureEndpoint(ok), isTrue, reason: ok);
      }
      for (final bad in [
        'http://api.openai.com/v1',
        'http://192.168.1.10:11434/v1',
        'http://10.0.0.2',
        'http://localhost.evil.com/v1',
        'http://127.0.0.1.evil.com',
        'ftp://localhost',
        'api.openai.com/v1',
        '',
        'not a url',
      ]) {
        expect(isSecureEndpoint(bad), isFalse, reason: bad);
      }
    });

    test('every built-in provider default is accepted', () {
      for (final kind in LlmProviderKind.values) {
        if (kind.baseUrl.isEmpty) continue;
        expect(isSecureEndpoint(kind.baseUrl), isTrue, reason: kind.name);
      }
    });
  });

  group('LLM client', () {
    AssistantConfig config(String baseUrl) => AssistantConfig(
          provider: LlmProviderKind.openai,
          providers: {
            LlmProviderKind.openai:
                ProviderSettings(apiKey: 'sk-secret', baseUrl: baseUrl),
          },
        );

    test('refuses plain HTTP to another machine without sending anything',
        () async {
      var sent = 0;
      final mock = MockClient((_) async {
        sent++;
        return http.Response('{}', 200);
      });
      for (final url in ['http://api.openai.com/v1', 'http://192.168.1.4/v1']) {
        final client = LlmClient.forConfig(config(url), client: mock);
        await expectLater(
          client.complete(
            system: 's',
            history: const [ChatMessage.user('hi')],
            tools: const [],
          ),
          throwsA(isA<LlmException>()
              .having((e) => e.kind, 'kind', LlmFailure.insecureUrl)),
        );
        await expectLater(client.listModels(), throwsA(isA<LlmException>()));
      }
      expect(sent, 0);
    });

    test('still talks to a local model over HTTP', () async {
      Uri? seen;
      final mock = MockClient((request) async {
        seen = request.url;
        return http.Response(
          '{"choices":[{"message":{"role":"assistant","content":"OK"}}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = LlmClient.forConfig(config('http://localhost:11434/v1'),
          client: mock);
      final reply = await client.complete(
        system: 's',
        history: const [ChatMessage.user('hi')],
        tools: const [],
      );
      expect(reply.message.text, 'OK');
      expect(seen?.host, 'localhost');
    });
  });

  group('settings screen', () {
    Future<void> pump(WidgetTester tester, AssistantConfig config) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          assistantConfigStoreProvider
              .overrideWithValue(_StaticConfigStore(config)),
          appStringsProvider.overrideWithValue(const AppStrings(Locale('fr'))),
        ],
        child: const MaterialApp(home: AssistantSettingsScreen()),
      ));
      await tester.pumpAndSettle();
    }

    const strings = AppStrings(Locale('fr'));

    testWidgets('warns when the key is stored in clear', (tester) async {
      await pump(
        tester,
        const AssistantConfig(
          providers: {
            LlmProviderKind.openai: ProviderSettings(apiKey: 'sk-x'),
          },
          keysInPlainText: true,
        ),
      );
      expect(find.text(strings.keysInPlainTextTitle), findsOneWidget);
    });

    testWidgets('no warning when the key is in the secure storage',
        (tester) async {
      await pump(
        tester,
        const AssistantConfig(
          providers: {
            LlmProviderKind.openai: ProviderSettings(apiKey: 'sk-x'),
          },
        ),
      );
      expect(find.text(strings.keysInPlainTextTitle), findsNothing);
    });

    testWidgets('flags a plain HTTP address to another machine',
        (tester) async {
      await pump(tester, const AssistantConfig());
      final url = find.widgetWithText(TextField, strings.llmBaseUrl);
      await tester.enterText(url, 'http://api.openai.com/v1');
      await tester.pump();
      expect(find.text(strings.llmInsecureUrl), findsOneWidget);

      await tester.enterText(url, 'http://localhost:11434/v1');
      await tester.pump();
      expect(find.text(strings.llmInsecureUrl), findsNothing);

      await tester.enterText(url, 'https://api.openai.com/v1');
      await tester.pump();
      expect(find.text(strings.llmInsecureUrl), findsNothing);
    });
  });
}
