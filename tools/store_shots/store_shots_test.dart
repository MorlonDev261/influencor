// Raw Play Store screenshots of the real app screens, rendered by Flutter's
// engine with Android's font (Roboto) and a demo workspace (demo_workspace.dart).
//
//   node tools/store_shots/make_photos.mjs          (once: the demo photos)
//   flutter test tools/store_shots/store_shots_test.dart
//
// Writes build/store_shots/raw/<device>/<shot>.png; play_store_shots.mjs then
// frames them into the Play Store images. STORE_SHOTS=accueil,note limits the
// shots, STORE_DEVICES=mobile the devices.
//
// It runs under `flutter test` (a test file outside test/), so the plugin
// platform interfaces it fakes come from the app's transitive dependencies.
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/app/app.dart';
import 'package:influencor/app/router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'demo_workspace.dart';

final repo = Directory.current.path;
final out = Directory(p.join(repo, 'build', 'store_shots', 'raw'));

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.base);
  final String base;
  String _dir(String name) {
    final d = Directory(p.join(base, name))..createSync(recursive: true);
    return d.path;
  }

  @override
  Future<String?> getApplicationSupportPath() async => _dir('support');
  @override
  Future<String?> getApplicationDocumentsPath() async => _dir('documents');
  @override
  Future<String?> getTemporaryPath() async => _dir('tmp');
  @override
  Future<String?> getApplicationCachePath() async => _dir('cache');
  @override
  Future<String?> getExternalStoragePath() async => null;
}

Future<void> _loadFonts() async {
  final where = await Process.run('where', ['flutter'], runInShell: true);
  final flutterBin = where.stdout.toString().split(RegExp(r'\r?\n')).first.trim();
  final fonts = p.join(p.dirname(p.dirname(flutterBin)), 'bin', 'cache',
      'artifacts', 'material_fonts');
  final windowsFonts = p.join(Platform.environment['WINDIR'] ?? r'C:\Windows', 'Fonts');

  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      final file = File(p.isAbsolute(f) ? f : p.join(fonts, f));
      if (!file.existsSync()) continue;
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }

  const roboto = [
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
    'roboto-light.ttf',
    'roboto-italic.ttf',
    'roboto-bolditalic.ttf',
    'roboto-black.ttf',
  ];
  // Android has no Arial: the note font falls back to Roboto there.
  for (final name in ['Roboto', 'Arial', 'monospace', 'sans-serif']) {
    await family(name, roboto);
  }
  await family('MaterialIcons', ['materialicons-regular.otf']);
  // Color emoji (Android draws its own; this is the closest available here).
  for (final name in ['Segoe UI Emoji', 'Noto Color Emoji']) {
    await family(name, [p.join(windowsFonts, 'seguiemj.ttf')]);
  }
  // Bold/italic math letters (𝗕𝗼𝗹𝗱) used to style notes: Cambria Math is
  // the second face of cambria.ttc. (Segoe UI Symbol stays unloaded: its
  // black-and-white emoji would win over the color ones.)
  final ttc = File(p.join(windowsFonts, 'cambria.ttc'));
  if (ttc.existsSync()) {
    final loader = FontLoader('Cambria Math')
      ..addFont(Future.value(ByteData.sublistView(_ttcFace(ttc.readAsBytesSync(), 1))));
    await loader.load();
  }
}

/// Face [index] of a TrueType collection, as a standalone font file.
Uint8List _ttcFace(Uint8List ttc, int index) {
  final d = ByteData.sublistView(ttc);
  final dir = d.getUint32(12 + 4 * index);
  final numTables = d.getUint16(dir + 4);
  final header = 12 + 16 * numTables;
  final records = <(int, int, int, int)>[]; // tag, checksum, offset, length
  for (var i = 0; i < numTables; i++) {
    final r = dir + 12 + 16 * i;
    records.add((d.getUint32(r), d.getUint32(r + 4), d.getUint32(r + 8), d.getUint32(r + 12)));
  }
  var size = header;
  for (final r in records) {
    size += (r.$4 + 3) & ~3;
  }
  final out = ByteData(size);
  for (var i = 0; i < 12; i++) {
    out.setUint8(i, d.getUint8(dir + i));
  }
  var at = header;
  for (final (i, r) in records.indexed) {
    final w = 12 + 16 * i;
    out
      ..setUint32(w, r.$1)
      ..setUint32(w + 4, r.$2)
      ..setUint32(w + 8, at)
      ..setUint32(w + 12, r.$4);
    for (var k = 0; k < r.$4; k++) {
      out.setUint8(at + k, d.getUint8(r.$3 + k));
    }
    at += (r.$4 + 3) & ~3;
  }
  return out.buffer.asUint8List();
}

/// Lets real file IO and image decoding finish between frames.
Future<void> settle(WidgetTester tester, {int rounds = 14}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> precacheAll(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final el in find.byType(Image).evaluate().toList()) {
      final img = el.widget as Image;
      try {
        await precacheImage(img.image, el).timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
  });
}

/// Waits (up to ~[seconds]) until no spinner is left on screen.
Future<void> waitLoaded(WidgetTester tester, {int seconds = 60}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await settle(tester, rounds: 3);
    // Spinners, and the folder stat cards' "—" placeholder.
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find.text('—').evaluate().isEmpty) {
      return;
    }
  }
  // ignore: avoid_print
  print('  (still loading after ${seconds}s)');
}

Future<void> shoot(WidgetTester tester, GlobalKey key, File file, double dpr) async {
  await waitLoaded(tester);
  for (var i = 0; i < 3; i++) {
    await precacheAll(tester);
    await settle(tester, rounds: 5);
  }
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: dpr);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('  ${p.relative(file.path, from: repo)}');
}

class Device {
  const Device(this.name, this.size, this.dpr);
  final String name;
  final Size size; // logical pixels
  final double dpr;
}

const devices = [
  Device('mobile', Size(412, 860), 3),
  Device('tablette-7', Size(600, 960), 2),
  Device('tablette-10', Size(800, 1280), 2),
  Device('ordinateur', Size(1440, 900), 2),
];

List<String> _envList(String name) => (Platform.environment[name] ?? '')
    .split(',')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

void main() {
  late Directory base;
  late DemoWorkspace demo;

  setUpAll(() async {
    await _loadFonts();
    base = Directory.systemTemp.createTempSync('influencor_store_');
    PathProviderPlatform.instance = _FakePaths(base.path);
    demo = await DemoWorkspace.create(base.path,
        photosDir: p.join(repo, 'build', 'store_shots', 'photos'),
        phoneDir: p.join(repo, 'build', 'store_shots', 'phone', 'Pôma Original'));
  });

  final onlyDevices = _envList('STORE_DEVICES');
  final onlyShots = _envList('STORE_SHOTS');

  for (final device in devices) {
    if (onlyDevices.isNotEmpty && !onlyDevices.contains(device.name)) continue;
    testWidgets('store shots ${device.name}', timeout: const Timeout(Duration(minutes: 40)), (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // Real shadows (the test default draws them as black outlines).
      debugDisableShadows = false;
      tester.view.physicalSize = device.size * device.dpr;
      tester.view.devicePixelRatio = device.dpr;
      addTearDown(tester.view.reset);
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
      // Plugins without a test implementation (deep links, push…): ignored.
      final onError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exception is MissingPluginException) return;
        onError?.call(details);
      };

      final key = GlobalKey();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(key: key, child: const ClipboardApp()),
      ));
      await settle(tester, rounds: 20);
      final router = container.read(routerProvider);

      String q(String rel) => Uri.encodeQueryComponent(demo.path(rel));
      final shots = <String, (String, Future<void> Function()?)>{
        '1-accueil': ('/', null),
        '2-note': ('/note?path=${q(DemoWorkspace.featuredNote)}', null),
        '3-degany': ('/assistant', null),
        '4-favoris': ('/favorites', null),
        '5-frais': (
          '/fees',
          () async {
            await tester.enterText(find.byType(TextField).first, '250000');
            await tester.testTextInput.receiveAction(TextInputAction.done);
            FocusManager.instance.primaryFocus?.unfocus();
          }
        ),
        '6-comptabilite': ('/accounting', null),
        '7-taches': ('/task', null),
        '8-dossier': ('/browse?path=${q(DemoWorkspace.featuredFolder)}', null),
      };

      for (final MapEntry(key: name, value: (location, then)) in shots.entries) {
        if (onlyShots.isNotEmpty && !onlyShots.any(name.contains)) continue;
        router.go('/menu'); // leaves the previous screen (and its state)
        await settle(tester, rounds: 3);
        router.go(location);
        await settle(tester);
        await waitLoaded(tester);
        if (then != null) {
          await then();
          await settle(tester, rounds: 40);
          await waitLoaded(tester);
        }
        await shoot(tester, key, File(p.join(out.path, device.name, '$name.png')), device.dpr);
      }

      FlutterError.onError = onError;
      debugDisableShadows = true;
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
