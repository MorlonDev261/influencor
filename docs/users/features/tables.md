# Tableaux

[← Fonctionnalités](./README.md)

## Description

Influencor peut ouvrir et éditer des tableaux compatibles stockés dans des
fichiers `.json`.

## Créer ou importer

Depuis le bouton **Ajouter** d'un dossier :

- **Nouveau tableau** : donnez un nom, un tableau vide (3 colonnes, 1 ligne)
  est créé puis ouvert.
- **Importer un tableau (JSON)** : choisissez un ou plusieurs fichiers `.json`.
  Seuls les fichiers au format compatible sont importés, par exemple :

```json
{
  "type": "influencor.table",
  "version": 1,
  "columns": [
    { "id": "c1", "title": "Nom" },
    { "id": "c2", "title": "Prix" }
  ],
  "rows": [
    { "id": "r1", "cells": { "c1": "Produit A", "c2": "15000" } }
  ]
}
```

## Utilisation

1. Ouvrez un fichier tableau compatible.
2. Modifiez les cellules.
3. Ajoutez une ligne ou une colonne si nécessaire.
4. Enregistrez.

## Résultat attendu

Le tableau est sauvegardé dans le fichier correspondant.

## Limitations

- Les fichiers JSON non compatibles ne sont pas affichés comme tableaux.
- Les cellules acceptent des valeurs simples sous forme de texte.
- Les tableaux ne remplacent pas un tableur complet.
