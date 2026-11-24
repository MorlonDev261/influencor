import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/core/services/update_gate_service.dart';

void main() {
  final config = {
    'channels': {
      'play': {'min_build': 5, 'update_url': 'https://play.example/app'},
      'apk': {'min_build': 0, 'update_url': 'https://site.example/#dl'},
    },
    'message': {'fr': 'Mettez à jour', 'en': 'Please update'},
  };

  group('evaluateUpdateConfig', () {
    test('blocks a build older than min_build', () {
      final s = evaluateUpdateConfig(config, channel: 'play', currentBuild: 4);
      expect(s.mustUpdate, isTrue);
      expect(s.updateUrl, 'https://play.example/app');
      expect(s.messageFor('en'), 'Please update');
      expect(s.messageFor('mg'), 'Mettez à jour'); // falls back to French
    });

    test('lets min_build and newer builds through', () {
      expect(
        evaluateUpdateConfig(config, channel: 'play', currentBuild: 5)
            .mustUpdate,
        isFalse,
      );
      expect(
        evaluateUpdateConfig(config, channel: 'play', currentBuild: 9)
            .mustUpdate,
        isFalse,
      );
    });

    test('channels are independent', () {
      expect(
        evaluateUpdateConfig(config, channel: 'apk', currentBuild: 1)
            .mustUpdate,
        isFalse,
      );
    });

    test('unknown channel or malformed file never blocks', () {
      for (final json in <Object?>[
        null,
        'oops',
        <String, Object>{},
        {'channels': 'x'},
        {
          'channels': {
            'play': {'min_build': '9'}
          }
        },
      ]) {
        expect(
          evaluateUpdateConfig(json, channel: 'play', currentBuild: 1)
              .mustUpdate,
          isFalse,
        );
      }
      expect(
        evaluateUpdateConfig(config, channel: 'windows', currentBuild: 1)
            .mustUpdate,
        isFalse,
      );
    });
  });

  group('resolveUpdateChannel', () {
    test('web is never gated', () {
      expect(resolveUpdateChannel(define: '', isWeb: true), isNull);
    });

    test('the build define wins over the platform', () {
      expect(
        resolveUpdateChannel(
          define: 'apk',
          isWeb: false,
          platform: TargetPlatform.android,
        ),
        'apk',
      );
    });

    test('platform fallback', () {
      expect(
        resolveUpdateChannel(
            define: '', isWeb: false, platform: TargetPlatform.android),
        'play',
      );
      expect(
        resolveUpdateChannel(
            define: '', isWeb: false, platform: TargetPlatform.windows),
        'windows',
      );
    });
  });
}
