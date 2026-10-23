// =============================================================================
// tools/verify_project.dart — Vérification complète d'Influencor en une commande :
//   dart run tools/verify_project.dart [options]
//
// Le projet est une app Flutter, sans package.json : ce script tient le rôle du
// `bun run verify` des projets web Mi Kandra (ArTest, influencor-web), avec les mêmes options.
// Formatage, analyse statique (zéro info / avertissement toléré), tests, Worker de maintenance
// Cloudflare et build web release, plus en option les auto-tests edge partagés.
//
// Le build va dans build/verify-web et non dans build/web : start.sh sert build/web, une
// vérification ne doit jamais remplacer le site en place.
//
// Tout s'exécute même après un échec (sauf --bail) puis un bilan s'affiche : on voit d'un coup
// tout ce qui casse. Code de sortie 1 si une étape échoue.
// =============================================================================
import 'dart:io';

const _help = '''
Usage : dart run tools/verify_project.dart [options]

Par défaut : formatage Dart, flutter analyze, flutter test, tests du Worker de
maintenance, build web release (dans build/verify-web).

Options :
  --install     commence par flutter pub get --enforce-lockfile
  --edge        ajoute ShellCheck, auto-tests edge et test workerd (Linux + Docker requis)
  --all         équivaut à --edge
  --no-build    saute le build web (le plus long)
  --skip=a,b    saute les étapes nommées (voir les identifiants avec --dry-run)
  --bail        s'arrête au premier échec
  --dry-run     affiche les commandes sans les exécuter
  --help        affiche cette aide''';

const _known = {
  'install',
  'edge',
  'all',
  'no-build',
  'bail',
  'dry-run',
  'help'
};
const _workerDir = 'scripts/edge/cloudflare/maintenance-worker';

class _Step {
  const _Step(this.id, this.label, this.executable, this.arguments,
      {this.linuxOnly = false});

  final String id;
  final String label;
  final String executable;
  final List<String> arguments;

  /// Étape qui démarre Docker sur 80/443 : ailleurs, elle compte comme un échec (prérequis
  /// manquant) et non comme une étape sautée.
  final bool linuxOnly;

  String get display => [
        executable,
        ...arguments.map((a) => a.contains(' ') ? '"$a"' : a)
      ].join(' ');

  String? get blocker => linuxOnly && !Platform.isLinux
      ? 'Linux requis (Docker, ports 80/443)'
      : null;
}

class _Result {
  const _Result(this.step,
      {required this.ok, required this.elapsed, this.note = ''});

  final _Step step;
  final bool ok;
  final Duration elapsed;
  final String note;
}

final bool _color =
    stdout.supportsAnsiEscapes && !Platform.environment.containsKey('NO_COLOR');
String Function(String) _paint(String code) =>
    (text) => _color ? '\x1b[${code}m$text\x1b[0m' : text;
final _green = _paint('32');
final _red = _paint('31');
final _yellow = _paint('33');
final _bold = _paint('1');
final _dim = _paint('2');
String _seconds(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

Future<void> main(List<String> args) async {
  bool flag(String name) => args.contains('--$name');
  final unknown = args
      .where((a) =>
          !a.startsWith('--skip=') &&
          !_known.contains(a.replaceFirst('--', '')))
      .toList();
  if (unknown.isNotEmpty) {
    stderr.writeln('Option inconnue : ${unknown.join(' ')}\n\n$_help');
    exit(2);
  }
  if (flag('help')) {
    stdout.writeln(_help);
    exit(0);
  }

  final edge = flag('edge') || flag('all');
  final bail = flag('bail');
  final skip = args
      .where((a) => a.startsWith('--skip='))
      .expand((a) => a.substring(7).split(','))
      .where((id) => id.isNotEmpty)
      .toSet();
  final buildDir =
      '${Directory.current.path}${Platform.pathSeparator}build${Platform.pathSeparator}verify-web';

  final steps = <_Step>[
    if (flag('install'))
      const _Step('install', 'Installation des dépendances', 'flutter',
          ['pub', 'get', '--enforce-lockfile']),
    const _Step('format', 'Formatage Dart', 'dart', [
      'format',
      '--output=none',
      '--set-exit-if-changed',
      'lib',
      'test',
      'tools'
    ]),
    const _Step('analyze', 'Analyse statique', 'flutter', ['analyze']),
    const _Step('test', 'Tests Flutter', 'flutter', ['test']),
    const _Step('worker', 'Tests du Worker de maintenance', 'node',
        ['--test', '$_workerDir/worker.test.mjs']),
    if (edge) ...[
      const _Step(
          'shellcheck',
          'ShellCheck des scripts edge',
          'sh',
          [
            '-c',
            'shellcheck -s sh -S warning scripts/edge/mi-kandra-*.sh scripts/edge/tests/selftest.sh scripts/edge/tests/lock-test.sh'
                ' && shellcheck -s bash -S warning scripts/edge/tests/hooks-test.sh',
          ],
          linuxOnly: true),
      const _Step('edge-selftest', 'Auto-tests du routeur edge', 'sh',
          ['scripts/edge/tests/selftest.sh'],
          linuxOnly: true),
      const _Step('edge-hooks', 'Hooks de démarrage edge', 'bash',
          ['scripts/edge/tests/hooks-test.sh'],
          linuxOnly: true),
      const _Step('edge-lock', 'Verrou des tests edge', 'sh',
          ['scripts/edge/tests/lock-test.sh'],
          linuxOnly: true),
      const _Step('workerd', 'Worker dans workerd (wrangler dev)', 'node',
          ['--test', '$_workerDir/workerd.test.mjs']),
    ],
    if (!flag('no-build'))
      _Step('build', 'Build web (release)', 'flutter', [
        'build',
        'web',
        '--release',
        '--no-wasm-dry-run',
        '--output',
        buildDir
      ]),
  ].where((s) => !skip.contains(s.id)).toList();

  if (flag('dry-run')) {
    stdout.writeln(_bold('${steps.length} étape(s) prévue(s) :'));
    for (final (i, s) in steps.indexed) {
      final reason = s.blocker;
      stdout.writeln(
          '  ${i + 1}. ${s.id.padRight(16)} ${s.display}${reason != null ? _yellow('  (bloquée : $reason)') : ''}');
    }
    exit(0);
  }

  final results = <_Result>[];
  final total = Stopwatch()..start();

  for (final (i, step) in steps.indexed) {
    final prefix = '[${i + 1}/${steps.length}]';
    final reason = step.blocker;
    if (reason != null) {
      stdout.writeln('\n${_red('$prefix ✘ ${step.label}')} — $reason');
      results
          .add(_Result(step, ok: false, elapsed: Duration.zero, note: reason));
    } else {
      stdout.writeln(
          '\n${_bold('$prefix ${step.label}')} ${_dim('\$ ${step.display}')}');
      final watch = Stopwatch()..start();
      try {
        // runInShell pour résoudre flutter.bat / dart.bat sous Windows ; les commandes sont
        // toutes définies ici, aucune entrée utilisateur n'y est injectée.
        final process = await Process.start(step.executable, step.arguments,
            runInShell: true, mode: ProcessStartMode.inheritStdio);
        final code = await process.exitCode;
        results.add(_Result(step,
            ok: code == 0,
            elapsed: watch.elapsed,
            note: code == 0 ? '' : 'code $code'));
      } on ProcessException catch (e) {
        results.add(
            _Result(step, ok: false, elapsed: watch.elapsed, note: e.message));
      }
    }
    if (bail && !results.last.ok) break;
  }

  stdout.writeln('\n${_bold('Bilan')}');
  for (final r in results) {
    final mark = r.ok ? _green('✔') : _red('✘');
    stdout.writeln(
        '  $mark ${r.step.label.padRight(38)} ${_dim(_seconds(r.elapsed))}${r.note.isNotEmpty ? '  ${_red(r.note)}' : ''}');
  }
  for (final s in steps.skip(results.length)) {
    stdout.writeln(
        '  ${_yellow('–')} ${s.label.padRight(38)} ${_dim('non lancée (--bail)')}');
  }

  final failed = results.where((r) => !r.ok).length;
  final elapsed = _seconds(total.elapsed);
  if (failed > 0) {
    stdout.writeln(
        '\n${_red(_bold('$failed étape(s) en échec'))} sur ${steps.length} ($elapsed).');
    exit(1);
  }
  stdout.writeln(
      '\n${_green(_bold('Tous les contrôles sont passés'))} (${steps.length} étapes, $elapsed).');
  if (!edge) {
    stdout
        .writeln(_dim('Non couverts par ce lancement : --edge (voir --help).'));
  }
}
