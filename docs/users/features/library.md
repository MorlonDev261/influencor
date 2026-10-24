# Bibliothèque Et Dossiers

[← Fonctionnalités](./README.md)

## Description

La bibliothèque affiche le contenu du dossier de travail: sous-dossiers,
notes, images, vidéos, tableaux et fichiers reconnus.

## Actions disponibles

- créer un dossier;
- créer une note;
- importer des fichiers;
- déplacer des fichiers dans la bibliothèque;
- glisser-déposer des fichiers sur desktop;
- trier les éléments;
- filtrer par type;
- passer de la vue grille à la vue liste;
- ouvrir, renommer, déplacer, dupliquer, supprimer ou taguer un élément;
- ajouter ou retirer un élément des favoris.

## Créer un dossier

1. Ouvrez la bibliothèque.
2. Appuyez sur **Ajouter**.
3. Choisissez **Nouveau dossier**.
4. Saisissez le nom.
5. Validez.

Résultat attendu: un dossier apparaît dans la bibliothèque.

## Importer des fichiers

1. Appuyez sur **Ajouter**.
2. Choisissez **Importer des fichiers**.
3. Sélectionnez les fichiers.
4. Validez.

Les fichiers acceptés sont copiés dans le dossier courant. Les fichiers non
acceptés sont ignorés et signalés.

## Déplacer des fichiers dans l'app

L'action **Déplacer des fichiers** importe les fichiers puis supprime les
originaux si la copie a réussi.

## Dossiers index (Pro)

Un dossier nommé `index.note` affiche **Toutes les notes** : chaque note du
dossier où il se trouve et de tous ses sous-dossiers, quelle que soit leur
profondeur. `index.img` fait de même avec les images (grille, on fait défiler
toutes les images de l'index). Ils apparaissent comme des dossiers colorés.

1. Dans le dossier voulu, **Ajouter** → **Nouveau dossier**.
2. Nommez-le `index.note` (ou `index.img`).
3. Ouvrez-le : la liste se met à jour (tirez vers le bas ou bouton
   actualiser pour relire le disque).

Degany sait aussi les créer et les ouvrir.

## Cas particuliers

- Les fichiers `.txt` importés sont convertis en notes `.md`.
- Les fichiers structurés incompatibles ne sont pas affichés comme tableaux.
- Les fichiers cachés qui commencent par `.` ne sont pas affichés.
- Les noms invalides sont nettoyés automatiquement.
