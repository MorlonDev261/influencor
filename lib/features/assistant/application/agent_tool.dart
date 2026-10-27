import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/providers/workspace_providers.dart';
import '../../library/application/library_providers.dart';
import '../../library/data/library_repository.dart';
import '../../library/domain/library_entry.dart';
import '../domain/chat_message.dart';

/// A failure explained to the model (and so to the user), never a crash.
class ToolError implements Exception {
  const ToolError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Asks the user to approve a destructive action. Returns true when allowed.
typedef ConfirmAction = Future<bool> Function(String title, String message);

/// Shows a route of the app (`push` keeps the chat underneath).
typedef NavigateAction = void Function(String route, {required bool push});

/// Asks the user a question in the chat, offering [options] as buttons; the
/// user may also type a free answer. Resolves to null when unanswered
/// (stopped).
typedef AskUser = Future<String?> Function(
    String question, List<String> options);

/// What a tool can reach: the app's providers, the workspace, the user.
class AgentToolContext {
  AgentToolContext({
    required this.ref,
    required this.confirm,
    this.navigator,
    this.ask,
    this.protectedDirs = const [],
  });

  final Ref ref;

  /// The app's own data (settings, API keys, conversation): no tool may
  /// read, import or touch anything in there, whatever the model asks.
  final List<String> protectedDirs;
  final ConfirmAction confirm;
  final NavigateAction? navigator;
  final AskUser? ask;

  void navigate(String route, {bool push = false}) {
    final nav = navigator;
    if (nav == null) throw const ToolError("L'écran n'est pas disponible.");
    nav(route, push: push);
  }

  String get root {
    final root = ref.read(workspaceRootProvider);
    if (root == null) {
      throw const ToolError(
          "Aucun dossier de travail n'est choisi. Demandez à l'utilisateur d'en "
          'choisir un (Réglages → Dossier de travail).');
    }
    return root;
  }

  String? get rootOrNull => ref.read(workspaceRootProvider);

  LibraryRepository get repo {
    root; // throws the friendly error when no workspace is chosen
    return ref.read(libraryRepositoryProvider)!;
  }

  LibraryController get library => ref.read(libraryControllerProvider);

  /// Resolves a path given by the model: relative to the workspace root, or
  /// absolute. Either way it must stay inside the current workspace (also
  /// once symbolic links are followed) and out of the hidden `.clipboard`
  /// metadata folder: Degany never reaches anything else on the device.
  String resolve(String? input) {
    final raw = (input ?? '').trim().replaceAll('\\', '/');
    String abs;
    if (raw.isEmpty || raw == '/' || raw == '.' || raw == './') {
      abs = root;
    } else if (p.isAbsolute(raw) || RegExp(r'^[A-Za-z]:/').hasMatch(raw)) {
      abs = p.normalize(raw);
    } else {
      // Relative: needs a workspace ([root] throws the friendly error).
      abs = p.normalize(
          p.join(root, raw.startsWith('/') ? raw.substring(1) : raw));
    }
    final r = root;
    // "/Clients/Ana" usually means "Clients/Ana" in the workspace.
    if (!p.equals(abs, r) && !p.isWithin(r, abs) && raw.startsWith('/')) {
      abs = p.normalize(p.join(r, raw.substring(1)));
    }
    if (!p.equals(abs, r) && !p.isWithin(r, abs)) {
      throw ToolError('Chemin hors du dossier de travail : $input');
    }
    final parts = p.split(p.relative(abs, from: r));
    if (parts.any((s) => s == '..' || s == '.clipboard')) {
      throw ToolError('Chemin non autorisé : $input');
    }
    _guardLinks(abs, input);
    _guardPrivate(abs, input);
    return abs;
  }

  /// A symbolic link inside the workspace must not lead out of it (or into
  /// `.clipboard`): the real target is checked against the real workspace.
  void _guardLinks(String abs, String? input) {
    // A file about to be created: its nearest existing folder decides.
    var existing = abs;
    final tail = <String>[];
    while (FileSystemEntity.typeSync(existing, followLinks: false) ==
            FileSystemEntityType.notFound &&
        !p.equals(p.dirname(existing), existing)) {
      tail.insert(0, p.basename(existing));
      existing = p.dirname(existing);
    }
    final real = p.joinAll([_realPath(existing), ...tail]);
    if (p.equals(real, abs)) return;
    final realRoot = _realPath(root);
    final inside = p.equals(real, realRoot) || p.isWithin(realRoot, real);
    if (!inside ||
        p.split(p.relative(real, from: realRoot)).contains('.clipboard')) {
      throw ToolError('Chemin hors du dossier de travail : $input');
    }
  }

  /// Refuses [abs] when it is in one of [protectedDirs] (also through a
  /// symbolic link). The user's workspace stays reachable even if it was
  /// chosen inside such a folder.
  void _guardPrivate(String abs, String? input) {
    if (protectedDirs.isEmpty) return;
    final candidates = {abs, _realPath(abs)};
    final workspace = rootOrNull;
    bool inside(String dir, String path) =>
        p.equals(dir, path) || p.isWithin(dir, path);
    for (final path in candidates) {
      if (workspace != null &&
          (inside(workspace, path) || inside(_realPath(workspace), path))) {
        continue;
      }
      for (final dir in protectedDirs) {
        if (inside(dir, path) || inside(_realPath(dir), path)) {
          throw ToolError(
              "Accès refusé : ce chemin est dans les données internes de l'app "
              '(réglages, clés, conversation) : $input');
        }
      }
    }
  }

  static String _realPath(String path) {
    try {
      return FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound
          ? path
          : File(path).resolveSymbolicLinksSync();
    } catch (_) {
      return path;
    }
  }

  /// Path shown to the model and the user: relative to the workspace when
  /// inside it (forward slashes), absolute otherwise.
  String rel(String abs) {
    final r = rootOrNull;
    if (r == null) return abs;
    if (p.equals(abs, r)) return '';
    if (!p.isWithin(r, abs)) return abs;
    return p.relative(abs, from: r).replaceAll('\\', '/');
  }

  Map<String, Object?> entryJson(LibraryEntry e) => {
        'path': rel(e.path),
        'name': e.displayName,
        'kind': e.kind.name,
        if (!e.isFolder) 'size': e.size,
        'modified': e.modified.toIso8601String(),
        if (e.isFavorite) 'favorite': true,
        if (e.tags.isNotEmpty) 'tags': e.tags,
      };
}

/// Typed accessors over the JSON arguments of a tool call.
class ToolArgs {
  const ToolArgs(this.raw);

  final Map<String, dynamic> raw;

  bool has(String k) => raw[k] != null;

  String str(String k) {
    final v = raw[k];
    if (v == null || (v is String && v.trim().isEmpty)) {
      throw ToolError('Paramètre manquant : $k');
    }
    return '$v';
  }

  String? optStr(String k) {
    final v = raw[k];
    if (v == null) return null;
    final s = '$v';
    return s.trim().isEmpty ? null : s;
  }

  /// Raw text (may be empty): note bodies, cell values…
  String text(String k, {String fallback = ''}) {
    final v = raw[k];
    return v == null ? fallback : '$v';
  }

  int? optInt(String k) {
    final v = raw[k];
    if (v is num) return v.round();
    if (v is String) {
      return int.tryParse(v.replaceAll(RegExp(r'[\s_.,]'), ''));
    }
    return null;
  }

  int int_(String k) => optInt(k) ?? (throw ToolError('Nombre attendu : $k'));

  bool flag(String k, {bool fallback = false}) {
    final v = raw[k];
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return fallback;
  }

  List<String> strings(String k) {
    final v = raw[k];
    if (v is List) {
      return [
        for (final e in v)
          if (e != null) '$e',
      ];
    }
    if (v is String && v.trim().isNotEmpty) return [v];
    return const [];
  }

  List<Object?> list(String k) => raw[k] is List ? raw[k] as List : const [];
}

typedef ToolRun = Future<Object?> Function(ToolArgs args, AgentToolContext ctx);

/// Returns the confirmation question for this call, or null if none needed.
typedef ToolConfirm = String? Function(ToolArgs args, AgentToolContext ctx);

/// One capability of the app exposed to the model.
class AgentTool {
  const AgentTool({
    required this.name,
    required this.label,
    required this.description,
    required this.run,
    this.properties = const {},
    this.required = const [],
    this.confirm,
  });

  final String name;

  /// Short human label shown in the chat while it runs.
  final String label;
  final String description;
  final Map<String, Map<String, dynamic>> properties;
  final List<String> required;
  final ToolRun run;

  /// Set for actions that destroy or overwrite data.
  final ToolConfirm? confirm;

  ToolSchema get schema => ToolSchema(
        name: name,
        description: description,
        parameters: {
          'type': 'object',
          'properties': properties,
          if (required.isNotEmpty) 'required': required,
        },
      );
}

// Schema helpers -------------------------------------------------------------

Map<String, dynamic> sStr(String description, {List<String>? values}) => {
      'type': 'string',
      'description': description,
      if (values != null) 'enum': values,
    };

Map<String, dynamic> sInt(String description) =>
    {'type': 'integer', 'description': description};

Map<String, dynamic> sBool(String description) =>
    {'type': 'boolean', 'description': description};

Map<String, dynamic> sStrList(String description) => {
      'type': 'array',
      'description': description,
      'items': {'type': 'string'},
    };

Map<String, dynamic> sList(String description, Map<String, dynamic> items) =>
    {'type': 'array', 'description': description, 'items': items};

Map<String, dynamic> sObj(
  Map<String, Map<String, dynamic>> properties, {
  List<String> required = const [],
  String? description,
}) =>
    {
      'type': 'object',
      if (description != null) 'description': description,
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
    };

const pathHint =
    'Chemin relatif au dossier de travail (ex. "Clients/Ana/brief.md"); '
    '"" = racine.';
