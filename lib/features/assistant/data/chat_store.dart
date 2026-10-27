import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/services/atomic_file.dart';

/// A saved conversation, as listed in Degany's history.
class ChatSummary {
  const ChatSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
}

/// Keeps Degany's conversations between launches, one JSON file per
/// conversation in `assistant_chats/` of the app support directory (on this
/// device only, never in the workspace), plus `current.json` naming the one
/// open in the chat.
class ChatStore {
  ChatStore({Future<Directory> Function()? directory})
      : _dirOverride = directory;

  final Future<Directory> Function()? _dirOverride;

  /// Older conversations beyond this are deleted.
  static const maxChats = 50;

  static const _dirName = 'assistant_chats';
  static const _currentName = 'current.json';

  /// The single conversation saved by earlier versions.
  static const _legacyName = 'assistant_chat.json';

  static final _validId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  Future<Directory> _dir() async {
    if (_dirOverride case final override?) return override();
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, _dirName));
  }

  Future<File?> _file(String id) async => _validId.hasMatch(id)
      ? File(p.join((await _dir()).path, '$id.json'))
      : null;

  Future<Map<String, dynamic>?> _read(File file) async {
    try {
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString(encoding: utf8));
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  var _migrated = false;

  /// Moves the conversation of an older version into the history, once.
  Future<void> _migrate(Directory dir) async {
    if (_migrated) return;
    _migrated = true;
    final legacy = File(p.join(dir.parent.path, _legacyName));
    final data = await _read(legacy);
    if (data == null) return;
    try {
      final id = 'c${(await legacy.lastModified()).microsecondsSinceEpoch}';
      await save(id, data);
      await setCurrent(id);
      await legacy.delete();
    } catch (_) {}
  }

  /// The conversation open in the chat, or null (none, or unreadable).
  Future<String?> currentId() async {
    final dir = await _dir();
    await _migrate(dir);
    final data = await _read(File(p.join(dir.path, _currentName)));
    final id = data?['id'];
    return id is String && _validId.hasMatch(id) ? id : null;
  }

  /// Best effort, like every write here: a failure never disturbs the chat.
  Future<void> setCurrent(String? id) async {
    try {
      final dir = await _dir();
      final file = File(p.join(dir.path, _currentName));
      if (id == null) {
        if (await file.exists()) await file.delete();
        return;
      }
      await dir.create(recursive: true);
      await writeStringAtomic(file, jsonEncode({'id': id}));
    } catch (_) {}
  }

  /// The conversation [id], or null if there is none (or it is unreadable).
  Future<Map<String, dynamic>?> load(String id) async {
    final file = await _file(id);
    return file == null ? null : _read(file);
  }

  Future<void> save(String id, Map<String, dynamic> data) async {
    try {
      final file = await _file(id);
      if (file == null) return;
      await file.parent.create(recursive: true);
      await writeStringAtomic(file, jsonEncode(data));
      await _prune();
    } catch (_) {}
  }

  Future<void> delete(String id) async {
    try {
      final file = await _file(id);
      if (file != null && await file.exists()) await file.delete();
      if (await currentId() == id) await setCurrent(null);
    } catch (_) {}
  }

  /// Saved conversations, most recent first.
  Future<List<ChatSummary>> list() async {
    final out = <ChatSummary>[];
    try {
      final dir = await _dir();
      await _migrate(dir);
      if (!await dir.exists()) return out;
      await for (final e in dir.list()) {
        final name = p.basename(e.path);
        if (e is! File || name == _currentName || !name.endsWith('.json')) {
          continue;
        }
        final id = p.basenameWithoutExtension(name);
        final data = await _read(e);
        if (data == null || !_validId.hasMatch(id)) continue;
        out.add(ChatSummary(
          id: id,
          title: data['title'] is String ? data['title'] as String : '',
          updatedAt: DateTime.tryParse('${data['updatedAt']}') ??
              await e.lastModified(),
        ));
      }
    } catch (_) {}
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<void> _prune() async {
    final all = await list();
    for (final old in all.skip(maxChats)) {
      final file = await _file(old.id);
      if (file != null && await file.exists()) await file.delete();
    }
  }
}
