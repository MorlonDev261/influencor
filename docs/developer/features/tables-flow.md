# Flux Tableaux

[← Fonctionnalités développeur](./README.md)

## Format

Les tableaux sont stockés dans des fichiers JSON compatibles avec le schéma
défini dans:

- [table_document.dart](../../../lib/features/library/domain/table_document.dart)

Le type attendu est:

```text
influencor.table
```

## Création

Le bouton **Ajouter** de `browse_screen.dart` propose **Nouveau tableau** :
`_createTable()` crée un tableau vide (3 colonnes, 1 ligne) via
`LibraryController.createTable()` puis ouvre `tableRoute`.

## Lecture

`TableDocument.read(path)` lit le fichier en UTF-8 puis tente de parser le JSON.
Si le format ne correspond pas, le fichier n'est pas considéré comme tableau.

## Édition

L'écran d'édition est:

- [table_screen.dart](../../../lib/features/library/presentation/table_screen.dart)

### Réorganiser (glisser-déposer)

En édition, chaque ligne a une poignée (et un bouton supprimer, sans numéro) ;
chaque colonne a sa poignée dans le titre. Le glisser est façon kanban
(`_TableCanvasState`) :

- l'aperçu (`feedback`) est la ligne ou la colonne entière, tenue là où elle a
  été saisie (`dragAnchorStrategy`) et bloquée sur son axe ;
- pendant le glisser, `_dragIndex` place la ligne / colonne sous le pointeur
  et les autres se décalent tout de suite ; sa place reste visible (case
  teintée). Elle ne bouge que si elle resterait sous le pointeur une fois
  déplacée, pour éviter les allers-retours entre lignes de hauteurs
  différentes ;
- au lâcher, `onMoveRow` / `onMoveColumn` appliquent l'ordre (les formules
  sont réécrites par `TableFormula.rewriteReferences`).

Les lignes (`TableRow.key`) et cellules ont des clés uniques dans tout le
tableau, pour que l'élément glissé garde son état pendant qu'il change de
place ; `_Probe` enregistre la cellule poignée de chaque ligne et le titre de
chaque colonne pour les mesurer.

## Sauvegarde

`LibraryController.saveTable()` écrit le JSON formaté puis invalide:

- `tableDocumentProvider(path)`;
- `directoryProvider(parent)`;
- les index/statistiques.
