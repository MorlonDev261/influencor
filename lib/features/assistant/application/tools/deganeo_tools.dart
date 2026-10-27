import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../cleaner/application/metadata_cleaner_service.dart';
import '../../../cleaner/domain/clean_report.dart';
import '../agent_tool.dart';

/// The cleaner used by the assistant. Overridden in tests.
final metadataCleanerProvider =
    Provider<MetadataCleanerService>((ref) => const MetadataCleanerService());

/// Where a cleaned copy goes.
const _saveModes = ['copy', 'replace', 'library'];

Map<String, Object?> _finding(MetadataFinding f) => {
      'category': f.category.name,
      'label': f.label,
      if (!f.sensitive) 'sensitive': false,
      if (f.entries.isNotEmpty)
        'values': {
          for (final e in f.entries.take(20)) e.name: e.value,
        },
    };

String _saveMode(ToolArgs a) {
  // `replace_original` is the older spelling of save=replace.
  if (a.flag('replace_original')) return 'replace';
  final mode = a.optStr('save') ?? 'copy';
  if (!_saveModes.contains(mode)) {
    throw ToolError(
        'save inconnu : $mode (attendu : ${_saveModes.join(', ')})');
  }
  return mode;
}

/// Deganeo: the metadata cleaner (EXIF/GPS/device… removal before publishing).
List<AgentTool> deganeoTools() => [
      AgentTool(
        name: 'deganeo_inspect',
        label: 'Deganeo — analyse',
        description:
            "Deganeo : liste les métadonnées d'une image, vidéo ou PDF (GPS, "
            'appareil, dates, EXIF/XMP/IPTC, commentaires…) sans rien modifier. '
            'Uniquement pour un fichier du dossier de travail.',
        properties: {'path': sStr(pathHint)},
        required: ['path'],
        run: (a, ctx) async {
          final path = ctx.resolve(a.str('path'));
          if (!await File(path).exists()) {
            throw ToolError('Fichier introuvable : ${a.str('path')}');
          }
          final r = await ctx.ref.read(metadataCleanerProvider).inspect(path);
          return {
            'path': ctx.rel(path),
            'format': r.format.name,
            if (r.error != null) 'error': r.error,
            'sensitive_count': r.findings.where((f) => f.sensitive).length,
            'findings': [for (final f in r.findings) _finding(f)],
          };
        },
      ),
      AgentTool(
        name: 'deganeo_clean',
        label: 'Deganeo — nettoyage',
        description:
            'Deganeo : supprime les métadonnées (GPS, appareil, dates…) de '
            'fichiers avant publication ; chaque résultat est vérifié par une '
            'nouvelle analyse. save : "copy" = copie « _clean » à côté de '
            "l'original (défaut) ; \"replace\" = remplace l'original ; "
            '"library" = copie « _clean » rangée dans le dossier `folder` de la '
            "bibliothèque. Si l'utilisateur n'a pas dit où enregistrer, "
            'demande-le d’abord avec ask_user.',
        properties: {
          'paths':
              sStrList('Fichiers du dossier de travail à nettoyer. $pathHint'),
          'save': sStr('Où enregistrer le résultat (défaut copy).',
              values: _saveModes),
          'folder': sStr('Pour save=library : dossier de destination. '
              '$pathHint'),
        },
        required: ['paths'],
        confirm: (a, ctx) => _saveMode(a) == 'replace'
            ? "Nettoyer et REMPLACER l'original de :\n"
                '${a.strings('paths').map((s) => '• $s').join('\n')}'
            : null,
        run: (a, ctx) async {
          final mode = _saveMode(a);
          final folder =
              mode == 'library' ? ctx.resolve(a.optStr('folder')) : null;
          final cleaner = ctx.ref.read(metadataCleanerProvider);
          final results = <Map<String, Object?>>[];
          for (final raw in a.strings('paths')) {
            String? temp;
            try {
              final path = ctx.resolve(raw);
              if (!await File(path).exists()) {
                throw ToolError('Fichier introuvable : $raw');
              }
              final report = await cleaner.clean(path);
              temp = report.outputPath;
              final out = <String, Object?>{
                'file': p.basename(path),
                'status': report.status.name,
                'format': report.format.name,
                'removed': [for (final f in report.removed) f.label],
                if (report.remaining.isNotEmpty)
                  'still_present': [for (final f in report.remaining) f.label],
                if (report.caveats.isNotEmpty)
                  'caveats': [for (final c in report.caveats) c.name],
                if (report.errorMessage != null) 'error': report.errorMessage,
              };
              if (report.hasOutput && report.isClean) {
                final saved = folder != null
                    ? await ctx.library.storeCleanedIn(folder, path, temp!)
                    : await ctx.library
                        .storeCleaned(path, temp!, replace: mode == 'replace');
                out['saved_as'] = ctx.rel(saved);
                out['save'] = mode;
              }
              results.add(out);
            } catch (e) {
              results.add({'file': raw, 'status': 'failed', 'error': '$e'});
            } finally {
              if (temp != null) {
                try {
                  await File(temp).delete();
                } catch (_) {}
              }
            }
          }
          return results;
        },
      ),
    ];
