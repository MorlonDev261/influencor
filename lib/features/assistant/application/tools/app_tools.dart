import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../../../app/nav.dart';
import '../../../../core/formatting/note_separator.dart';
import '../../../../core/providers/settings_providers.dart';
import '../../../../core/services/content_share_service.dart';
import '../../../../core/services/content_share_ui.dart';
import '../../../../shared/enums/enums.dart';
import '../../../library/domain/library_entry.dart';
import '../agent_tool.dart';

const _screens = {
  'home': '/',
  'search': '/search',
  'favorites': '/favorites',
  'trash': '/trash',
  'tasks': '/task',
  'accounting': '/accounting',
  'fees': '/fees',
  'deganeo': '/deganeo',
  'settings': '/settings',
  'about': '/about',
  'menu': '/menu',
};

/// Route that opens [path] in the right screen (folder, note, table, media).
Future<String> routeForPath(String path) async {
  if (await FileSystemEntity.isDirectory(path)) return directoryRoute(path);
  return switch (await kindForFilePath(path)) {
    EntryKind.note => noteRoute(path),
    EntryKind.table => tableRoute(path),
    _ => previewRoute(path),
  };
}

String _htmlToText(String html) {
  var s = html
      .replaceAll(
          RegExp(r'<(script|style|noscript)[^>]*>[\s\S]*?</\1>',
              caseSensitive: false),
          ' ')
      .replaceAll(
          RegExp(r'<br\s*/?>|</(p|div|li|h[1-6]|tr)>', caseSensitive: false),
          '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  const entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
  };
  entities.forEach((k, v) => s = s.replaceAll(k, v));
  return s
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n+'), '\n\n')
      .trim();
}

List<AgentTool> appTools() => [
      AgentTool(
        name: 'ask_user',
        label: 'Question',
        description:
            "Pose une question à l'utilisateur et attend sa réponse, avec des "
            'choix proposés en boutons (il peut aussi écrire une autre réponse). '
            'À utiliser quand une décision lui revient : où enregistrer un '
            'fichier nettoyé, quel dossier, quelle option… Une seule question '
            'à la fois, 2 à 4 choix courts.',
        properties: {
          'question': sStr('La question, courte et claire.'),
          'options': sStrList('Les choix proposés (2 à 4, courts).'),
        },
        required: ['question'],
        run: (a, ctx) async {
          final ask = ctx.ask;
          if (ask == null) {
            throw const ToolError("La conversation n'est pas affichée.");
          }
          final options = [
            for (final o in a.strings('options'))
              if (o.trim().isNotEmpty) o.trim(),
          ].take(6).toList();
          final answer = await ask(a.str('question'), options);
          if (answer == null) {
            return {
              'answer': null,
              'note': "Pas de réponse : l'utilisateur a arrêté."
            };
          }
          return {'answer': answer};
        },
      ),
      AgentTool(
        name: 'open_item',
        label: "Ouverture dans l'app",
        description: 'Ouvre un dossier, une note, un tableau ou un média à '
            "l'écran (quitte la conversation, qui reste disponible). À utiliser "
            "seulement si l'utilisateur veut voir l'élément.",
        properties: {'path': sStr(pathHint)},
        required: ['path'],
        run: (a, ctx) async {
          final path = ctx.resolve(a.str('path'));
          if (await FileSystemEntity.type(path) ==
              FileSystemEntityType.notFound) {
            throw ToolError('Introuvable : ${a.str('path')}');
          }
          ctx.navigate(await routeForPath(path), push: true);
          return {'opened': ctx.rel(path)};
        },
      ),
      AgentTool(
        name: 'open_screen',
        label: 'Navigation',
        description: "Affiche un écran de l'app. search accepte query ; tasks "
            'accepte task_id pour ouvrir une tâche.',
        properties: {
          'screen': sStr('Écran.', values: _screens.keys.toList()),
          'query': sStr('Pour search : texte pré-rempli.'),
          'task_id': sStr('Pour tasks : tâche à ouvrir.'),
        },
        required: ['screen'],
        run: (a, ctx) async {
          final screen = a.str('screen');
          var route =
              _screens[screen] ?? (throw ToolError('Écran inconnu : $screen'));
          if (screen == 'search') route = searchRoute(a.optStr('query'));
          if (screen == 'tasks' && a.optStr('task_id') != null) {
            route = Uri(
                path: '/task/edit',
                queryParameters: {'id': a.str('task_id')}).toString();
          }
          ctx.navigate(route);
          return {'opened': screen};
        },
      ),
      AgentTool(
        name: 'get_settings',
        label: 'Réglages',
        description: "Réglages de l'app : thème, vue par défaut, langue, "
            'séparateur de notes, dossier de travail.',
        run: (a, ctx) async {
          final s = ctx.ref.read(settingsProvider);
          return {
            'theme': s.themeMode.name,
            'view_mode': s.viewMode.name,
            'language': s.languageCode,
            'note_separator': s.noteSeparator ?? NoteSeparator.defaultSeparator,
            'workspace': ctx.rootOrNull,
          };
        },
      ),
      AgentTool(
        name: 'update_settings',
        label: 'Modification des réglages',
        description: "Change des réglages de l'app. note_separator vide = "
            'séparateur par défaut. (Le dossier de travail se change dans '
            'Réglages par l’utilisateur.)',
        properties: {
          'theme': sStr('Thème.', values: ['system', 'light', 'dark']),
          'view_mode': sStr('Vue par défaut.', values: ['grid', 'list']),
          'language': sStr('Langue.', values: ['fr', 'en', 'mg']),
          'note_separator': sStr('Séparateur de notes.'),
        },
        run: (a, ctx) async {
          final c = ctx.ref.read(settingsControllerProvider.notifier);
          final changed = <String>[];
          if (a.optStr('theme') case final t?) {
            await c.setThemeMode(ThemeMode.values.byName(t));
            changed.add('theme');
          }
          if (a.optStr('view_mode') case final v?) {
            await c.setViewMode(ViewMode.values.byName(v));
            changed.add('view_mode');
          }
          if (a.optStr('language') case final l?) {
            await c.setLanguage(l);
            changed.add('language');
          }
          if (a.has('note_separator')) {
            await c.setNoteSeparator(a.optStr('note_separator'));
            changed.add('note_separator');
          }
          return {'changed': changed};
        },
      ),
      AgentTool(
        name: 'copy_to_clipboard',
        label: 'Copie',
        description: 'Copie un texte dans le presse-papiers (ex. une légende '
            'prête à coller sur un réseau social).',
        properties: {'text': sStr('Texte à copier.')},
        required: ['text'],
        run: (a, ctx) async {
          await Clipboard.setData(ClipboardData(text: a.text('text')));
          return {'copied_characters': a.text('text').length};
        },
      ),
      AgentTool(
        name: 'share',
        label: 'Partage',
        description: 'Ouvre la feuille de partage du système avec un texte '
            'et/ou des médias de la bibliothèque (WhatsApp, Facebook…).',
        properties: {
          'text': sStr('Texte à partager.'),
          'paths': sStrList('Images ou vidéos à joindre. $pathHint'),
        },
        run: (a, ctx) async {
          final paths = [for (final s in a.strings('paths')) ctx.resolve(s)];
          final result = await contentShareService.shareContent(
            text: a.optStr('text'),
            localMediaPaths: paths,
          );
          return {
            'outcome': result.outcome.name,
            if (result.outcome == ShareOutcome.mixedMediaNeedsChoice)
              'note': 'Images et vidéos ne partent pas ensemble : partager '
                  'les images, puis les vidéos.',
          };
        },
      ),
      AgentTool(
        name: 'fetch_web_page',
        label: 'Lecture web',
        description: "Récupère le texte d'une page web (http/https) donnée "
            "par l'utilisateur ou trouvée dans le contexte.",
        properties: {'url': sStr('Adresse complète.')},
        required: ['url'],
        run: (a, ctx) async {
          final uri = Uri.tryParse(a.str('url'));
          if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
            throw const ToolError('Adresse http(s) attendue.');
          }
          final res = await http.get(uri, headers: {
            'user-agent': 'Mozilla/5.0 Influencor'
          }).timeout(const Duration(seconds: 30));
          final body = utf8.decode(res.bodyBytes, allowMalformed: true);
          final type = res.headers['content-type'] ?? '';
          var text = type.contains('html') ? _htmlToText(body) : body;
          const max = 20000;
          final truncated = text.length > max;
          if (truncated) text = text.substring(0, max);
          return {
            'status': res.statusCode,
            'url': uri.toString(),
            'text': text,
            if (truncated) 'truncated': true,
          };
        },
      ),
    ];
