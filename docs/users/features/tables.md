# Tableaux

[← Fonctionnalités](./README.md)

## Description

Influencor peut ouvrir et éditer des tableaux compatibles stockés dans des
fichiers `.json`.

## Créer

Depuis le bouton **Ajouter** d'un dossier, **Nouveau tableau** : donnez un
nom, un tableau vide (3 colonnes, 1 ligne) est créé puis ouvert.

Un fichier `.json` compatible déposé dans la bibliothèque (import de fichiers,
copie depuis l'ordinateur) s'ouvre aussi comme tableau, par exemple :

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
4. Pour réorganiser, saisissez la poignée ⋮⋮ d'une ligne (à gauche) ou d'une
   colonne (dans son titre) : toute la ligne ou la colonne suit le doigt et
   les autres se décalent tout de suite pour lui faire de la place. Lâchez
   pour la poser (sur téléphone, gardez le doigt un instant sur la poignée
   avant de glisser).
5. Enregistrez.

## Résultat attendu

Le tableau est sauvegardé dans le fichier correspondant.

## Limitations

- Les fichiers JSON non compatibles ne sont pas affichés comme tableaux.
- Les cellules acceptent des valeurs simples sous forme de texte.
- Les tableaux ne remplacent pas un tableur complet.
