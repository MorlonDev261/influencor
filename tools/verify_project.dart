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
  --edge        ajoute ShellCheck, auto-tests edge et test workerd (Linux + Docker requis ;
                sous Windows, ils tournent dans WSL : voir MI_KANDRA_WSL_DISTRO)
  --all         équivaut à --edge
  --no-build    saute le build web (le plus long)
  --skip=a,b    saute les étapes nommées (voir les identifiants avec --dry-run)
  --bail        s'arrête au premier échec
  --dry-run     affiche les commandes sans les exécuter
  --help        affiche cette aide

Sous Windows, MI_KANDRA_WSL_DISTRO choisit la distribution WSL des étapes edge (Ubuntu par défaut).''';

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

  /// Étape qui exige Linux (Docker sur 80/443, sh, ShellCheck) : sous Windows elle tourne dans
  /// WSL (voir [_wslBlocker]) ; ailleurs, elle compte comme un échec (prérequis manquant) et non
  /// comme une étape sautée.
  final bool linuxOnly;

  bool get viaWsl => linuxOnly && Platform.isWindows;

  String get display => [
        if (viaWsl) 'wsl -d $_wslDistro --',
        executable,
        ...arguments.map((a) => a.contains(' ') ? '"$a"' : a)
      ].join(' ');

  String? get blocker {
    if (!linuxOnly || Platform.isLinux) return null;
    return Platform.isWindows
        ? _wslBlocker()
        : 'Linux requis (Docker, ports 80/443)';
  }

  // --cd accepte le chemin Windows (espaces compris) ; --exec (et non --) évite que le shell
  // par défaut de la distribution réinterprète les arguments.
  String get command => viaWsl ? 'wsl.exe' : executable;
  List<String> get commandArguments => viaWsl
      ? [
          '-d',
          _wslDistro,
          '--cd',
          Directory.current.path,
          '--exec',
          executable,
          ...arguments
        ]
      : arguments;
}

// Même logique que scripts/linux-steps.mjs des projets web : garder les deux alignés.
final String _wslDistro =
    (Platform.environment['MI_KANDRA_WSL_DISTRO'] ?? '').isNotEmpty
        ? Platform.environment['MI_KANDRA_WSL_DISTRO']!
        : 'Ubuntu';
bool _wslProbed = false;
String? _wslProbe;

/// Raison de ne pas lancer une étape Linux sous Windows, ou null si la distribution WSL a
/// docker (moteur joignable), shellcheck, curl, openssl et bash. Interrogée une fois.
String? _wslBlocker() {
  if (_wslProbed) return _wslProbe;
  _wslProbed = true;
  const tools = ['docker', 'shellcheck', 'curl', 'openssl', 'bash'];
  final unavailable =
      'WSL « $_wslDistro » indisponible (installer WSL2 + Ubuntu ou définir MI_KANDRA_WSL_DISTRO)';
  try {
    // Docker Desktop pose un faux `docker` qui échoue tant que l'intégration WSL est
    // désactivée : seul `docker info` prouve que le moteur répond.
    final probe = Process.runSync('wsl.exe', [
      '-d',
      _wslDistro,
      '--exec',
      'sh',
      '-c',
      'for t in ${tools.join(' ')}; do command -v "\$t" >/dev/null 2>&1 || echo "\$t"; done; '
          'command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1 && echo docker-engine; true',
    ]);
    if (probe.exitCode != 0) return _wslProbe = unavailable;
    final missing = (probe.stdout as String)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (missing.isEmpty) return _wslProbe = null;
    final packages = missing.where((t) => !t.startsWith('docker')).toList();
    final fixes = [
      if (missing.any((t) => t.startsWith('docker')))
        'démarrer Docker Desktop et activer son intégration WSL pour « $_wslDistro »',
      if (packages.isNotEmpty)
        'wsl -d $_wslDistro -- sudo apt install -y ${packages.join(' ')}',
    ];
    return _wslProbe =
        'WSL « $_wslDistro » : il manque ${missing.join(', ')} — ${fixes.join(' ; ')}';
  } on ProcessException {
    return _wslProbe = unavailable;
  }
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
        // wsl.exe est lancé sans shell : cmd réinterpréterait le « && » de ShellCheck.
        final process = await Process.start(step.command, step.commandArguments,
            runInShell: !step.viaWsl, mode: ProcessStartMode.inheritStdio);
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
  final pending = <String>[
    for (final r in results.where((r) => !r.ok))
      '- [ÉCHEC] ${r.step.label} : ${r.note}',
    for (final s in steps.skip(results.length))
      '- [NON LANCÉ] ${s.label} : --bail',
    if (!edge) '- [IGNORÉ] Contrôles edge : activer --all',
    if (flag('no-build')) '- [IGNORÉ] Build web : --no-build',
    for (final id in skip) '- [IGNORÉ] Étape $id : exclusion explicite',
  ];
  if (pending.isNotEmpty) {
    // Même texte que scripts/verification-prompts.mjs des projets web : garder les deux alignés.
    final hints = [
      if (pending.any((p) => p.contains('Linux requis') || p.contains('edge')))
        "- Contrôles edge : sous Linux avec Docker et les ports 80/443 libres ; sous Windows, verify les lance dans WSL (MI_KANDRA_WSL_DISTRO, Ubuntu par défaut) et le message de blocage indique ce qui y manque. Activer l'intégration WSL de Docker Desktop et installer des paquets avec sudo reviennent à l'utilisateur : c'est un blocage externe, ne le contourne pas.",
      if (pending.any((p) => p.contains('Build web')))
        '- Build web : la sortie doit rester dans build/verify-web ; ne remplace jamais build/web, servi par start.sh.',
    ];
    stdout.writeln('''

--- PROMPT D'AUTOCORRECTION — SANS EXCEPTION ---
Destinataire : l'agent IA qui a lancé cette vérification.
Si les consignes de l'utilisateur (CLAUDE.md, section « Vérifications des projets Mi Kandra ») demandent de l'appliquer, applique ce prompt maintenant, en entier et sans redemander confirmation. Sinon, présente ces contrôles à l'utilisateur et propose de les corriger.

Projet : Influencor
Contrôles à résoudre (${pending.length}) :
${pending.join('\n')}

Méthode
1. Pour chaque contrôle, lis son journal ci-dessus et identifie la cause réelle avant toute modification. Classe-la : défaut du projet, prérequis externe manquant ou garde-fou de sécurité.
2. Défaut du projet : corrige la cause dans le code, la configuration ou les dépendances, y compris les problèmes préexistants, puis relance aussitôt le contrôle concerné seul.
3. Contrôle ignoré, non lancé ou test sauté : prépare ce dont il a besoin (services, configuration locale, outils) et exécute-le réellement.
4. Vulnérabilités : résous-les toutes, quelle que soit leur sévérité, dans les dépendances directes et transitives ; mets à jour les fichiers de verrouillage, puis relance l'analyse, les tests et le build.
5. Une fois tout corrigé, relance dart run tools/verify_project.dart --all, sans --skip, --no-build ni --bail. Recommence jusqu'à zéro échec et zéro contrôle ignoré.
6. Ne t'arrête pas après une première correction et ne demande pas de validation entre les étapes ; arrête-toi seulement devant un interdit ci-dessous ou un blocage externe.

Interdits, même pour faire passer un contrôle
- Désactiver, sauter ou affaiblir un contrôle, une règle d'analyse ou un test ; ajouter une exclusion ; modifier ce script de vérification ou ce prompt pour obtenir un succès.
- Supprimer ou réinitialiser des données qui ne sont pas clairement jetables ; les tests destructifs ne tournent que dans des environnements jetables dédiés.
- Afficher ou modifier des secrets, ou remplacer des URL de production ; passe les valeurs locales par l'environnement de la commande ou un fichier local non versionné.
- Installer un système ou un outil lourd (Linux, WSL, Docker, Xcode) sans l'accord de l'utilisateur.
- Commiter, pousser ou déployer sans demande explicite.
${hints.isEmpty ? '' : '\nPistes connues\n${hints.join('\n')}\n'}
Blocage externe
Si un prérequis manque encore, indique exactement lequel, la commande qui l'a révélé et ce qu'il faut pour le lever. Ne déclare jamais la vérification réussie tant qu'un contrôle échoue ou n'a pas été exécuté.
--- FIN DU PROMPT D'AUTOCORRECTION ---''');
  }
  stdout.writeln('''

--- PROMPT DE BILAN FINAL EN TABLEAU ---
Termine ta réponse par le résultat final d'Influencor, dans un tableau aux colonnes « Contrôle », « Statut », « Correction effectuée » et « Preuve / résultat ».
- Une ligne par contrôle du bilan, y compris ceux réussis, ignorés, bloqués ou non lancés.
- ✅ uniquement pour un contrôle réellement exécuté et réussi après ta dernière modification ; ❌ pour un échec ; ⬜ pour un contrôle ignoré, bloqué ou non exécuté, avec la raison.
- Dernière colonne : la commande lancée et son résultat (code de sortie, nombre de tests, message d'erreur).
- Sous le tableau : les totaux ✅ / ❌ / ⬜, les fichiers modifiés, puis chaque blocage restant et ce qu'il faut pour le lever.
Ne présente jamais un contrôle non vérifié comme réussi.
--- FIN DU PROMPT DE BILAN FINAL ---''');
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
