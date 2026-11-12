# Navigation Et Routing

[← Documentation développeur](../README.md)

Le routing est défini dans [lib/app/router.dart](../../../lib/app/router.dart)
avec GoRouter.

## Routes existantes

| Route | Écran |
| --- | --- |
| `/` | HomeScreen |
| `/browse?path=<path>` | BrowseScreen |
| `/note?path=<path>` | NoteScreen en édition d'une note existante |
| `/note?dir=<dir>` | NoteScreen pour nouvelle note |
| `/preview?path=<path>` | PreviewScreen |
| `/table?path=<path>` | TableScreen |
| `/search` | SearchScreen |
| `/favorites` | FavoritesScreen |
| `/assistant` | AssistantScreen |
| `/trash` | TrashScreen |
| `/menu` | MenuScreen (comptabilité, tâches, réglages) |
| `/accounting` | AccountingScreen |
| `/task` | TasksScreen |
| `/task/edit?id=<id>[&edit=1]` | TaskEditorScreen (`edit=1`: ouverte en modification) |
| `/settings` | SettingsScreen |

## Helpers de navigation

Les helpers sont dans [lib/app/nav.dart](../../../lib/app/nav.dart).

## Shell applicatif

Le shell est dans [lib/app/widgets/app_shell.dart](../../../lib/app/widgets/app_shell.dart).

Il choisit:

- une barre inférieure sur mobile;
- une NavigationRail sur desktop/tablette.

Le dernier onglet est le **Menu** (icône à trois barres, `/menu`); il reste sélectionné sur `/accounting`, `/task*`, `/settings` et `/about`. Voir [Comptabilité, tâches et menu](./accounting-and-tasks.md).
