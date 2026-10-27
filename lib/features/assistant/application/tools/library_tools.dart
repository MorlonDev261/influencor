import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../library/application/library_providers.dart';
import '../../../library/domain/library_entry.dart';
import '../../../library/domain/table_document.dart';
import '../../../library/domain/table_formula.dart';
import '../../../search/application/entry_search.dart';
import '../../../tasks/application/task_providers.dart';
import '../../../accounting/application/accounting_providers.dart';
import '../agent_tool.dart';

const _uuid = Uuid();
const _kinds = ['folder', 'note', 'image', 'video', 'table', 'other'];
const _maxTextChars = 30000;

EntryKind? _kind(String? name) {
  for (final k in EntryKind.values) {
    if (k.name == name) return k;
  }
  return null;
}

Future<FileSystemEntityType> _type(String path) => FileSystemEntity.type(path);

Future<void> _mustExist(String path, String shown) async {
  if (await _type(path) == FileSystemEntityType.notFound) {
    throw ToolError('Introuvable : $shown');
  }
}

Future<List<LibraryEntry>> _all(AgentToolContext ctx) =>
    ctx.repo.listAllEntries();

/// Matches every word of [query] in the name, tags or [extra] text.
bool _matches(LibraryEntry e, List<String> words, [String extra = '']) {
  final hay = foldForSearch('${e.displayName} ${e.tags.join(' ')} $extra');
  return words.every(hay.contains);
}

String _snippet(String text, String word) {
  final folded = foldForSearch(text);
  final i = folded.indexOf(word);
  if (i < 0) return '';
  final start = (i - 60).clamp(0, text.length);
  final end = (i + word.length + 80).clamp(0, text.length);
  return '${start > 0 ? '…' : ''}${text.substring(start, end).replaceAll('\n', ' ')}'
      '${end < text.length ? '…' : ''}';
}

Future<String?> _searchableText(LibraryEntry e) async {
  if (!(e.isNote || e.isTable) || e.size > 2 * 1024 * 1024) return null;
  try {
    final text = await File(e.path).readAsString(encoding: utf8);
    if (e.isNote) return text;
    final table = TableDocument.tryParse(jsonDecode(text));
    if (table == null) return null;
    return [
      for (final c in table.columns) c.title,
      for (final r in table.rows) ...r.cells.values,
    ].join(' ');
  } catch (_) {
    return null;
  }
}

/// Moves a copy of [path] to the trash, so an overwrite can always be undone.
Future<void> _backupToTrash(AgentToolContext ctx, String path) async {
  final copy = await ctx.repo.duplicate(path);
  await ctx.library.moveToTrash(copy);
}

Future<String> _readNote(String path) async {
  try {
    return await File(path).readAsString(encoding: utf8);
  } on FileSystemException {
    throw ToolError('Lecture impossible : ${p.basename(path)}');
  }
}

Future<TableDocument> _readTable(AgentToolContext ctx, String path) async {
  final table = await TableDocument.read(path);
  if (table == null) {
    throw ToolError(
        "Ce fichier n'est pas un tableau Influencor : ${ctx.rel(path)}");
  }
  return table;
}

Map<String, Object?> _tableJson(
    AgentToolContext ctx, String path, TableDocument t,
    {int limit = 500}) {
  final evaluator = TableEvaluator(t);
  final formulas = evaluator.hasFormulas;
  return {
    'path': ctx.rel(path),
    'columns': [for (final c in t.columns) c.title],
    'row_count': t.rows.length,
    'rows': [
      for (final (i, r) in t.rows.take(limit).indexed)
        {
          'row': i + 1,
          'values': [for (final c in t.columns) r.cells[c.id] ?? ''],
          // What the app shows once formulas are computed.
          if (formulas)
            'computed': [
              for (final (j, _) in t.columns.indexed) evaluator.displayAt(i, j),
            ],
        },
    ],
    if (t.rows.length > limit) 'truncated': true,
  };
}

TableColumnDef _column(TableDocument t, String name) {
  final folded = foldForSearch(name.trim());
  for (final c in t.columns) {
    if (foldForSearch(c.title.trim()) == folded) return c;
  }
  final n = int.tryParse(name.trim());
  if (n != null && n >= 1 && n <= t.columns.length) return t.columns[n - 1];
  throw ToolError('Colonne inconnue : $name (colonnes : '
      '${t.columns.map((c) => c.title).join(', ')})');
}

TableRowData _row(TableDocument t, List<Object?> values) {
  final cells = <String, String>{};
  for (final (i, c) in t.columns.indexed) {
    cells[c.id] = i < values.length && values[i] != null ? '${values[i]}' : '';
  }
  return TableRowData(id: _uuid.v4(), cells: cells);
}

const _formulaHelp = 'Formules comme dans Excel : une cellule qui '
    'commence par "=" est calculée ("=B1*C1", "=SOMME(D1:D9)", "=SI(C1>B1;'
    '"gain";"perte")") ; un titre de colonne avec "=" calcule toute la '
    'colonne, une lettre seule voulant dire « même ligne » ("Bénéfice =C-B"). '
    'Colonnes A, B, C… et lignes numérotées à partir de 1 ; arguments séparés '
    'par ";". Fonctions : SOMME, MOYENNE, MIN, MAX, NB, NBVAL, PRODUIT, '
    'ARRONDI, ABS, RACINE, ENT, MOD, SI, ET, OU, NON.';

List<AgentTool> libraryTools() => [
      AgentTool(
        name: 'workspace_overview',
        label: 'Aperçu du dossier de travail',
        description:
            "Résumé de l'espace de travail : chemin racine, nombre de dossiers, "
            'notes, images, vidéos, tableaux, favoris, éléments en corbeille, '
            'tâches et opérations comptables. À appeler en premier si besoin de '
            'contexte.',
        run: (a, ctx) async {
          final all = await _all(ctx);
          final trash = await ctx.repo.listTrash();
          final tasks = await ctx.ref.read(taskListProvider.future);
          final ledger = await ctx.ref.read(ledgerProvider.future);
          return {
            'root': ctx.root,
            'counts': {
              for (final k in EntryKind.values)
                k.name: all.where((e) => e.kind == k).length,
            },
            'total_size_bytes': all.fold<int>(0, (s, e) => s + e.size),
            'favorites': all.where((e) => e.isFavorite).length,
            'trash': trash.length,
            'tasks': tasks.length,
            'accounting_entries': ledger.currentEntries.length,
            'top_level': [
              for (final e in await ctx.repo.listEntries(ctx.root))
                ctx.entryJson(e),
            ],
          };
        },
      ),
      AgentTool(
        name: 'list_folder',
        label: 'Lecture du dossier',
        description: "Liste le contenu d'un dossier (dossiers d'abord). "
            'recursive=true parcourt aussi les sous-dossiers.',
        properties: {
          'path': sStr(pathHint),
          'recursive': sBool('Inclure les sous-dossiers (défaut false).'),
          'kind': sStr('Filtrer par type.', values: _kinds),
          'limit': sInt('Maximum renvoyé (défaut 200).'),
        },
        run: (a, ctx) async {
          final dir = ctx.resolve(a.optStr('path'));
          if (await _type(dir) != FileSystemEntityType.directory) {
            throw ToolError("Ce n'est pas un dossier : ${a.optStr('path')}");
          }
          // An index folder shows every note / image of the folder it sits
          // in, sub-folders included: list that, as the app does.
          final index = indexKindOfFolderName(p.basename(dir));
          var entries = index != null
              ? [
                  for (final e in await ctx.repo
                      .listAllUnder(p.dirname(dir), includeAttachments: true))
                    if (e.kind == index) e,
                ]
              : a.flag('recursive')
                  ? await ctx.repo.listAllUnder(dir)
                  : await ctx.repo.listEntries(dir);
          final kind = _kind(a.optStr('kind'));
          if (kind != null) {
            entries = entries.where((e) => e.kind == kind).toList();
          }
          final limit = (a.optInt('limit') ?? 200).clamp(1, 1000);
          return {
            'folder': ctx.rel(dir),
            if (index != null)
              'index_of': '${index.name}s de ${ctx.rel(p.dirname(dir))}',
            'total': entries.length,
            'entries': [for (final e in entries.take(limit)) ctx.entryJson(e)],
            if (entries.length > limit) 'truncated': true,
          };
        },
      ),
      AgentTool(
        name: 'search_library',
        label: 'Recherche',
        description:
            'Recherche dans toute la bibliothèque (ou un dossier) par nom, tags '
            'et, par défaut, dans le texte des notes et des tableaux. Insensible '
            'aux accents et à la casse ; tous les mots doivent correspondre. '
            'Sans query, liste selon les filtres (ex. tous les favoris).',
        properties: {
          'query': sStr('Mots recherchés (optionnel).'),
          'kind': sStr('Filtrer par type.', values: _kinds),
          'folder': sStr('Limiter à ce dossier. $pathHint'),
          'tag': sStr('Uniquement les éléments portant ce tag.'),
          'favorites_only': sBool('Uniquement les favoris.'),
          'in_content': sBool('Chercher aussi dans le contenu (défaut true).'),
          'limit': sInt('Maximum renvoyé (défaut 50).'),
        },
        run: (a, ctx) async {
          final folder =
              a.has('folder') ? ctx.resolve(a.optStr('folder')) : null;
          var entries = folder == null
              ? await _all(ctx)
              : await ctx.repo.listAllUnder(folder, includeAttachments: true);
          final kind = _kind(a.optStr('kind'));
          if (kind != null) {
            entries = entries.where((e) => e.kind == kind).toList();
          }
          if (a.flag('favorites_only')) {
            entries = entries.where((e) => e.isFavorite).toList();
          }
          final tag = a.optStr('tag');
          if (tag != null) {
            final t = foldForSearch(tag.trim());
            entries = entries
                .where((e) => e.tags.any((x) => foldForSearch(x) == t))
                .toList();
          }
          final words = foldForSearch(a.optStr('query') ?? '')
              .split(RegExp(r'\s+'))
              .where((w) => w.isNotEmpty)
              .toList();
          final limit = (a.optInt('limit') ?? 50).clamp(1, 500);
          final inContent = a.flag('in_content', fallback: true);
          final results = <Map<String, Object?>>[];
          var total = 0;
          for (final e in entries) {
            if (words.isEmpty || _matches(e, words)) {
              total++;
              if (results.length < limit) results.add(ctx.entryJson(e));
              continue;
            }
            if (!inContent) continue;
            final text = await _searchableText(e);
            if (text == null || !_matches(e, words, text)) continue;
            total++;
            if (results.length < limit) {
              results.add({
                ...ctx.entryJson(e),
                'match': _snippet(text, words.first),
              });
            }
          }
          return {'total': total, 'results': results};
        },
      ),
      AgentTool(
        name: 'list_tags',
        label: 'Liste des tags',
        description: 'Tous les tags utilisés, avec leur nombre d’éléments.',
        run: (a, ctx) async {
          final counts = <String, int>{};
          for (final e in await _all(ctx)) {
            for (final t in e.tags) {
              counts[t] = (counts[t] ?? 0) + 1;
            }
          }
          final sorted = counts.entries.toList()
            ..sort((x, y) => y.value.compareTo(x.value));
          return {for (final e in sorted) e.key: e.value};
        },
      ),
      AgentTool(
        name: 'get_item_info',
        label: 'Détails',
        description: "Détails d'un fichier ou dossier : type, taille, date, "
            'favori, tags ; pour un dossier, le nombre de chaque type de contenu.',
        properties: {'path': sStr(pathHint)},
        required: ['path'],
        run: (a, ctx) async {
          final path = ctx.resolve(a.str('path'));
          final type = await _type(path);
          if (type == FileSystemEntityType.notFound) {
            throw ToolError('Introuvable : ${a.str('path')}');
          }
          final stat = await FileStat.stat(path);
          final meta = await ctx.repo.getMeta(path);
          final isDir = type == FileSystemEntityType.directory;
          final info = <String, Object?>{
            'path': ctx.rel(path),
            'absolute_path': path,
            'kind': isDir ? 'folder' : (await kindForFilePath(path)).name,
            'modified': stat.modified.toIso8601String(),
            if (!isDir) 'size': stat.size,
            'favorite': meta.favorite,
            'tags': meta.tags,
          };
          if (isDir) {
            final all =
                await ctx.repo.listAllUnder(path, includeAttachments: true);
            info['contains'] = {
              for (final k in EntryKind.values)
                k.name: all.where((e) => e.kind == k).length,
            };
          }
          return info;
        },
      ),
      AgentTool(
        name: 'read_note',
        label: 'Lecture de la note',
        description: "Lit le texte (Markdown) d'une note.",
        properties: {'path': sStr(pathHint)},
        required: ['path'],
        run: (a, ctx) async {
          final path = ctx.resolve(a.str('path'));
          await _mustExist(path, a.str('path'));
          final text = await _readNote(path);
          return {
            'path': ctx.rel(path),
            'content': text.length > _maxTextChars
                ? text.substring(0, _maxTextChars)
                : text,
            if (text.length > _maxTextChars) 'truncated': true,
            'characters': text.length,
          };
        },
      ),
      AgentTool(
        name: 'create_note',
        label: 'Création de la note',
        description: 'Crée une note Markdown (.md) dans un dossier. Le nom est '
            'rendu unique automatiquement.',
        properties: {
          'folder': sStr('Dossier de destination. $pathHint'),
          'title': sStr('Titre = nom du fichier, sans extension.'),
          'content': sStr('Texte de la note (Markdown).'),
        },
        required: ['title', 'content'],
        run: (a, ctx) async {
          final dir = ctx.resolve(a.optStr('folder'));
          await Directory(dir).create(recursive: true);
          final path = await ctx.library.createNote(dir,
              title: a.str('title'), content: a.text('content'));
          return {'created': ctx.rel(path)};
        },
      ),
      AgentTool(
        name: 'edit_note',
        label: 'Modification de la note',
        description:
            "Modifie le texte d'une note : remplacer tout, ajouter à la "
            'fin ou au début. En mode replace, l’ancienne version est '
            'conservée dans la corbeille.',
        properties: {
          'path': sStr(pathHint),
          'content': sStr('Nouveau texte (ou texte à ajouter).'),
          'mode':
              sStr('Défaut replace.', values: ['replace', 'append', 'prepend']),
        },
        required: ['path', 'content'],
        run: (a, ctx) async {
          final path = ctx.resolve(a.str('path'));
          await _mustExist(path, a.str('path'));
          if (!noteExtensions.contains(p.extension(path).toLowerCase())) {
            throw const ToolError("Ce fichier n'est pas une note.");
          }
          final old = await _readNote(path);
          final add = a.text('content');
          final mode = a.optStr('mode') ?? 'replace';
          final String next;
          switch (mode) {
            case 'append':
              next = old.isEmpty
                  ? add
                  : '$old${old.endsWith('\n') ? '' : '\n'}$add';
            case 'prepend':
              next = old.isEmpty ? add : '$add\n$old';
            default:
              if (old.trim().isNotEmpty) await _backupToTrash(ctx, path);
              next = add;
          }
          await ctx.library.saveNote(path, next);
          ctx.ref.invalidate(directoryProvider(p.dirname(path)));
          ctx.ref.invalidate(libraryIndexProvider);
          return {
            'saved': ctx.rel(path),
            'mode': mode,
            if (mode == 'replace' && old.trim().isNotEmpty)
              'previous_version': 'dans la corbeille',
          };
        },
      ),
      AgentTool(
        name: 'read_table',
        label: 'Lecture du tableau',
        description: 'Lit un tableau Influencor (.json) : colonnes et lignes '
            '(numérotées à partir de 1). Avec des formules, "computed" donne '
            'les valeurs calculées affichées dans l’app.',
        properties: {'path': sStr(pathHint)},
        required: ['path'],
        run: (a, ctx) async {
          final path = ctx.resolve(a.str('path'));
          await _mustExist(path, a.str('path'));
          return _tableJson(ctx, path, await _readTable(ctx, path));
        },
      ),
      AgentTool(
        name: 'create_table',
        label: 'Création du tableau',
        description: 'Crée un tableau. Une colonne dont le titre est entre '
            'crochets, ex. "[Mot de passe]", est masquée par défaut dans l’app. '
            '$_formulaHelp',
        properties: {
          'folder': sStr('Dossier de destination. $pathHint'),
          'name': sStr('Nom du tableau (sans extension).'),
          'columns': sStrList('Titres des colonnes.'),
          'rows': sList(
              'Lignes : chaque ligne est la liste des valeurs dans '
              "l'ordre des colonnes.",
              sStrList('Valeurs')),
        },
        required: ['name', 'columns'],
        run: (a, ctx) async {
          final titles = a.strings('columns').where((t) => t.trim().isNotEmpty);
          if (titles.isEmpty) throw const ToolError('Au moins une colonne.');
          final columns = [
            for (final t in titles)
              TableColumnDef(id: _uuid.v4(), title: t.trim()),
          ];
          var table = TableDocument(columns: columns, rows: const []);
          table = TableDocument(columns: columns, rows: [
            for (final r in a.list('rows'))
              if (r is List) _row(table, r),
          ]);
          final dir = ctx.resolve(a.optStr('folder'));
          await Directory(dir).create(recursive: true);
          final path = await ctx.library
              .createTable(dir, name: a.str('name'), table: table);
          return {'created': ctx.rel(path), 'rows': table.rows.length};
        },
      ),
      AgentTool(
        name: 'edit_table',
        label: 'Modification du tableau',
        description: 'Modifie un tableau existant. Actions : add_rows (rows), '
            'update_cells (updates : [{row, column, value}]), delete_rows (row_numbers), '
            'add_column (column), rename_column (column, new_name), delete_column '
            '(column). Les suppressions gardent l’ancienne version dans la corbeille. '
            '$_formulaHelp',
        properties: {
          'path': sStr(pathHint),
          'action': sStr('Action.', values: [
            'add_rows',
            'update_cells',
            'delete_rows',
            'add_column',
            'rename_column',
            'delete_column',
          ]),
          'rows': sList('Pour add_rows : valeurs dans l’ordre des colonnes.',
              sStrList('Valeurs')),
          'updates': sList(
            'Pour update_cells.',
            sObj({
              'row': sInt('Numéro de ligne (1 = première).'),
              'column': sStr('Titre (ou numéro) de colonne.'),
              'value': sStr('Nouvelle valeur.'),
            }, required: [
              'row',
              'column',
              'value'
            ]),
          ),
          'row_numbers': sList('Pour delete_rows.', {'type': 'integer'}),
          'column': sStr('Titre (ou numéro) de colonne.'),
          'new_name': sStr('Pour rename_column.'),
        },
        required: ['path', 'action'],
        run: (a, ctx) async {
          final path = ctx.resolve(a.str('path'));
          await _mustExist(path, a.str('path'));
          final t = await _readTable(ctx, path);
          var columns = [...t.columns];
          var rows = [...t.rows];
          final action = a.str('action');
          int rowIndex(Object? n) {
            final i = (n is num ? n.round() : int.tryParse('$n') ?? 0) - 1;
            if (i < 0 || i >= rows.length) {
              throw ToolError('Ligne inexistante : $n');
            }
            return i;
          }

          switch (action) {
            case 'add_rows':
              rows.addAll([
                for (final r in a.list('rows'))
                  if (r is List) _row(t, r),
              ]);
            case 'update_cells':
              for (final u in a.list('updates')) {
                if (u is! Map) continue;
                final i = rowIndex(u['row']);
                final col = _column(t, '${u['column']}');
                rows[i] = TableRowData(
                  id: rows[i].id,
                  cells: {...rows[i].cells, col.id: '${u['value'] ?? ''}'},
                );
              }
            case 'delete_rows':
              final drop = {for (final n in a.list('row_numbers')) rowIndex(n)};
              await _backupToTrash(ctx, path);
              rows = [
                for (final (i, r) in rows.indexed)
                  if (!drop.contains(i)) r,
              ];
            case 'add_column':
              columns
                  .add(TableColumnDef(id: _uuid.v4(), title: a.str('column')));
            case 'rename_column':
              final col = _column(t, a.str('column'));
              columns = [
                for (final c in columns)
                  c.id == col.id
                      ? TableColumnDef(
                          id: c.id, title: a.str('new_name'), type: c.type)
                      : c,
              ];
            case 'delete_column':
              final col = _column(t, a.str('column'));
              if (columns.length == 1) {
                throw const ToolError('Un tableau garde au moins une colonne.');
              }
              await _backupToTrash(ctx, path);
              columns.removeWhere((c) => c.id == col.id);
              rows = [
                for (final r in rows)
                  TableRowData(
                    id: r.id,
                    cells: {...r.cells}..remove(col.id),
                  ),
              ];
            default:
              throw ToolError('Action inconnue : $action');
          }
          // Deleting rows / columns shifts the cells: formulas follow.
          final next = TableFormula.rewriteReferences(
              t, TableDocument(columns: columns, rows: rows));
          await ctx.library.saveTable(path, next);
          return {
            'saved': ctx.rel(path),
            'columns': columns.length,
            'rows': rows.length
          };
        },
      ),
      AgentTool(
        name: 'create_folder',
        label: 'Création du dossier',
        description: 'Crée un dossier (et ses parents si besoin).',
        properties: {
          'parent': sStr('Dossier parent. $pathHint'),
          'name': sStr('Nom du nouveau dossier.'),
        },
        required: ['name'],
        run: (a, ctx) async {
          final parent = ctx.resolve(a.optStr('parent'));
          await Directory(parent).create(recursive: true);
          final path = await ctx.library.createFolder(parent, a.str('name'));
          return {'created': ctx.rel(path)};
        },
      ),
      AgentTool(
        name: 'rename_item',
        label: 'Renommage',
        description:
            "Renomme un fichier ou un dossier (l'extension est conservée).",
        properties: {
          'path': sStr(pathHint),
          'new_name': sStr('Nouveau nom.'),
        },
        required: ['path', 'new_name'],
        run: (a, ctx) async {
          final path = ctx.resolve(a.str('path'));
          if (p.equals(path, ctx.root)) {
            throw const ToolError('La racine ne peut pas être renommée.');
          }
          await _mustExist(path, a.str('path'));
          final out = await ctx.library
              .rename(path, a.str('new_name'), parentDir: p.dirname(path));
          return {'renamed': ctx.rel(out)};
        },
      ),
      AgentTool(
        name: 'move_items',
        label: 'Déplacement',
        description: 'Déplace des fichiers/dossiers vers un dossier '
            '(créé s’il n’existe pas). Rien n’est écrasé.',
        properties: {
          'paths': sStrList('Éléments à déplacer.'),
          'destination': sStr('Dossier de destination. $pathHint'),
        },
        required: ['paths', 'destination'],
        run: (a, ctx) async {
          final dest = ctx.resolve(a.optStr('destination'));
          await Directory(dest).create(recursive: true);
          final moved = <String>[];
          final failed = <String, String>{};
          for (final raw in a.strings('paths')) {
            try {
              final path = ctx.resolve(raw);
              await _mustExist(path, raw);
              await ctx.library.move(path, dest, parentDir: p.dirname(path));
              moved.add(raw);
            } catch (e) {
              failed[raw] = '$e';
            }
          }
          return {
            'destination': ctx.rel(dest),
            'moved': moved,
            if (failed.isNotEmpty) 'failed': failed,
          };
        },
      ),
      AgentTool(
        name: 'duplicate_item',
        label: 'Duplication',
        description: 'Crée une copie « (copie) » à côté de l’original.',
        properties: {'path': sStr(pathHint)},
        required: ['path'],
        run: (a, ctx) async {
          final path = ctx.resolve(a.str('path'));
          await _mustExist(path, a.str('path'));
          final copy = await ctx.repo.duplicate(path);
          ctx.ref.invalidate(directoryProvider(p.dirname(path)));
          ctx.ref.invalidate(libraryIndexProvider);
          return {'copy': ctx.rel(copy)};
        },
      ),
      AgentTool(
        name: 'set_favorite',
        label: 'Favoris',
        description: 'Ajoute ou retire des éléments des favoris.',
        properties: {
          'paths': sStrList('Éléments concernés.'),
          'favorite': sBool('true = ajouter, false = retirer.'),
        },
        required: ['paths', 'favorite'],
        run: (a, ctx) async {
          final value = a.flag('favorite', fallback: true);
          final done = <String>[];
          for (final raw in a.strings('paths')) {
            final path = ctx.resolve(raw);
            await _mustExist(path, raw);
            await ctx.library
                .setFavorite(path, value, parentDir: p.dirname(path));
            done.add(ctx.rel(path));
          }
          return {'favorite': value, 'items': done};
        },
      ),
      AgentTool(
        name: 'set_tags',
        label: 'Tags',
        description:
            "Modifie les tags d'un élément : set (remplace), add, remove.",
        properties: {
          'path': sStr(pathHint),
          'tags': sStrList('Tags.'),
          'mode': sStr('Défaut set.', values: ['set', 'add', 'remove']),
        },
        required: ['path', 'tags'],
        run: (a, ctx) async {
          final path = ctx.resolve(a.str('path'));
          await _mustExist(path, a.str('path'));
          final current = (await ctx.repo.getMeta(path)).tags;
          final given = [
            for (final t in a.strings('tags'))
              if (t.trim().isNotEmpty) t.trim(),
          ];
          final next = switch (a.optStr('mode') ?? 'set') {
            'add' => {...current, ...given}.toList(),
            'remove' => [
                for (final t in current)
                  if (!given.any((g) => foldForSearch(g) == foldForSearch(t)))
                    t,
              ],
            _ => given.toSet().toList(),
          };
          await ctx.library.setTags(path, next, parentDir: p.dirname(path));
          return {'path': ctx.rel(path), 'tags': next};
        },
      ),
      AgentTool(
        name: 'move_to_trash',
        label: 'Mise à la corbeille',
        description: 'Met des fichiers/dossiers à la corbeille (restaurables).',
        properties: {'paths': sStrList('Éléments à supprimer.')},
        required: ['paths'],
        confirm: (a, ctx) =>
            'Mettre à la corbeille :\n${a.strings('paths').map((s) => '• $s').join('\n')}',
        run: (a, ctx) async {
          final done = <String>[];
          final failed = <String, String>{};
          for (final raw in a.strings('paths')) {
            try {
              final path = ctx.resolve(raw);
              if (p.equals(path, ctx.root)) {
                throw const ToolError('La racine ne peut pas être supprimée.');
              }
              await _mustExist(path, raw);
              await ctx.library.moveToTrash(path, parentDir: p.dirname(path));
              done.add(raw);
            } catch (e) {
              failed[raw] = '$e';
            }
          }
          return {'trashed': done, if (failed.isNotEmpty) 'failed': failed};
        },
      ),
      AgentTool(
        name: 'list_trash',
        label: 'Corbeille',
        description:
            'Liste la corbeille (id, nom, emplacement d’origine, date).',
        run: (a, ctx) async => [
          for (final t in await ctx.repo.listTrash())
            {
              'id': t.id,
              'name': t.name,
              'original_path': ctx.rel(t.originalPath),
              'is_folder': t.isDir,
              'deleted_at': t.deletedAt.toIso8601String(),
            },
        ],
      ),
      AgentTool(
        name: 'restore_from_trash',
        label: 'Restauration',
        description: 'Restaure des éléments de la corbeille à leur place.',
        properties: {'ids': sStrList('Ids donnés par list_trash.')},
        required: ['ids'],
        run: (a, ctx) async {
          for (final id in a.strings('ids')) {
            await ctx.library.restoreFromTrash(id);
          }
          return {'restored': a.strings('ids').length};
        },
      ),
      AgentTool(
        name: 'delete_forever',
        label: 'Suppression définitive',
        description: 'Supprime définitivement des éléments de la corbeille '
            '(irréversible). all=true vide toute la corbeille.',
        properties: {
          'ids': sStrList('Ids donnés par list_trash.'),
          'all': sBool('Vider toute la corbeille.'),
        },
        confirm: (a, ctx) => a.flag('all')
            ? 'Vider DÉFINITIVEMENT toute la corbeille ? Action irréversible.'
            : 'Supprimer DÉFINITIVEMENT ${a.strings('ids').length} élément(s) '
                'de la corbeille ? Action irréversible.',
        run: (a, ctx) async {
          if (a.flag('all')) {
            await ctx.library.emptyTrash();
            return {'emptied': true};
          }
          for (final id in a.strings('ids')) {
            await ctx.library.deleteForever(id);
          }
          return {'deleted': a.strings('ids').length};
        },
      ),
    ];
