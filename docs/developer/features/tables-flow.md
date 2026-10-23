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

## Création et import

Le bouton **Ajouter** de `browse_screen.dart` propose :

- **Nouveau tableau** : `_createTable()` crée un tableau vide (3 colonnes,
  1 ligne) via `LibraryController.createTable()` puis ouvre `tableRoute`.
- **Importer un tableau (JSON)** : `_importTableJson()` ouvre le sélecteur
  natif (`PickMode.jsonFiles`, filtre `.json`), valide chaque fichier avec
  `TableDocument.read()` et recrée les fichiers compatibles dans le dossier
  courant. Les fichiers incompatibles sont ignorés et comptés dans le rapport.

## Lecture

`TableDocument.read(path)` lit le fichier en UTF-8 puis tente de parser le JSON.
Si le format ne correspond pas, le fichier n'est pas considéré comme tableau.

## Édition

L'écran d'édition est:

- [table_screen.dart](../../../lib/features/library/presentation/table_screen.dart)

## Sauvegarde

`LibraryController.saveTable()` écrit le JSON formaté puis invalide:

- `tableDocumentProvider(path)`;
- `directoryProvider(parent)`;
- les index/statistiques.
