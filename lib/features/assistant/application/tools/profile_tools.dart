import '../../data/user_profile_store.dart';
import '../agent_tool.dart';
import '../assistant_providers.dart';

/// Degany's memory of the user. Its current content is in the system prompt;
/// this tool only changes it. It runs out of sight (see `silentTools`).
List<AgentTool> profileTools() => [
      AgentTool(
        name: 'update_user_profile',
        label: 'Mémoire',
        description:
            "Ajoute, corrige ou retire des faits durables sur l'utilisateur "
            'lui-même dans ta mémoire privée (chiffrée sur cet appareil). '
            'Clés courtes en snake_case, par ex. nom, prenom, surnom, ville, '
            'pays, langues, metier, entreprise, marque, domaine, produits, '
            'cible, facebook, instagram, tiktok, youtube, linkedin, x, '
            'whatsapp, site_web, email, telephone, horaires, ton, '
            'style_ecriture, objectifs, caractere. Valeur vide = retirer. '
            'Jamais de mot de passe, code PIN ou mobile money, numéro de '
            'carte, clé API, ni de donnée sensible (santé, religion, '
            'opinions politiques…).',
        properties: {
          'set': sList(
            'Faits à enregistrer ou corriger.',
            sObj({
              'key': sStr('Clé du fait (ex. "facebook").'),
              'value': sStr('Valeur (ex. "https://facebook.com/ana.shop").'),
            }, required: [
              'key',
              'value'
            ]),
          ),
          'remove': sStrList('Clés des faits à retirer (devenus faux).'),
        },
        run: (a, ctx) async {
          final set = <String, String>{};
          final refused = <String>[];
          for (final raw in a.list('set')) {
            if (raw is! Map) continue;
            final key = '${raw['key'] ?? ''}'.trim();
            final value = '${raw['value'] ?? ''}'.trim();
            if (UserProfile.normalizeKey(key).isEmpty) continue;
            if (UserProfile.isSecret(key, value)) {
              refused.add(key);
            } else {
              set[key] = value;
            }
          }
          final remove = a.strings('remove');
          final controller = ctx.ref.read(userProfileProvider.notifier);
          final before =
              (await ctx.ref.read(userProfileProvider.future)).fields;
          final newKeys = {
            for (final key in set.keys)
              if (!before.containsKey(UserProfile.normalizeKey(key)))
                UserProfile.normalizeKey(key),
          };
          if (before.length + newKeys.length > UserProfile.maxFields) {
            throw ToolError(
                'Mémoire pleine (${UserProfile.maxFields} faits) : regroupe '
                'ou retire des faits moins utiles avant d’en ajouter.');
          }
          final profile = await controller.change(set: set, remove: remove);
          return {
            'saved': set.length,
            'removed': remove.length,
            'facts': profile.fields.length,
            if (refused.isNotEmpty)
              'refused': 'Non enregistré (donnée secrète) : '
                  '${refused.join(', ')}',
          };
        },
      ),
    ];
