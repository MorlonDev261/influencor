# Menu, comptabilité et tâches

[← Fonctionnalités](./README.md)

## Le menu

Le dernier onglet de la barre de navigation (icône à trois barres) ouvre le **Menu**
(`/menu`). Il donne accès à:

- **Comptabilité**;
- **Tâches**;
- **Réglages**.

« Powered by Morlon Rnd » s'affiche en bas de la page.

## Comptabilité

Suivez vos entrées et sorties d'argent.

- **Solde disponible** en haut de la page, avec le solde de chaque compte.
- **Comptes**: Orange Money, MVola, Airtel Money, Cash. Les puces permettent de filtrer la liste par compte.
- Chaque opération a une **date**, une **note**, un **compte**, un **montant** (en Ar), un **sens**
  (crédit ou débit) et un **type** (achat, vente, dépense).
- Une vente est proposée en crédit, un achat ou une dépense en débit; vous pouvez changer le sens.
- Le bouton **Nouvelle opération** est toujours visible (sur la fiche en cours).
- Touchez une opération pour voir son détail (montant mis en avant, en vert ou rouge);
  l'icône crayon ouvre le formulaire de modification.
- Le bouton **⋮** de chaque opération propose **Modifier** et **Supprimer** (avec confirmation).

Les données sont enregistrées dans le dossier de travail: `.clipboard/accounting.json`.

## Tâches

Créez autant de tâches que nécessaire (page `/task`).

- Une tâche a un titre et des **blocs**: **bloc de texte** libre ou **checklist** (titre + éléments à cocher).
- La liste affiche la progression de chaque tâche (éléments cochés / total).
- Le bouton **Nouvelle tâche** est toujours visible.
- Touchez une tâche pour l'ouvrir sur sa page, en **vue simple**: le titre et le texte
  s'affichent comme une page à lire, et vous cochez les éléments en les touchant. Rien n'y
  ressemble à un champ de saisie.
- L'icône crayon passe en **modification**: la barre du haut se colore et affiche
  « Modifier la tâche » avec le bouton **Terminé**; chaque champ devient une case à remplir,
  chaque bloc est encadré avec son bouton supprimer, et les boutons d'ajout apparaissent.
- Le bouton **⋮** de chaque tâche propose **Modifier** (ouvre la page prête à modifier) et
  **Supprimer** (avec confirmation).
- L'enregistrement est automatique.

Chaque tâche est un fichier JSON dans le dossier de travail: `.clipboard/tasks/<id>.json`.

## Où sont les données ?

Dans votre **dossier de travail**, jamais dans l'application. Sauvegarder ou déplacer ce
dossier sauvegarde ou déplace aussi la comptabilité et les tâches. Sans dossier de travail choisi,
ces pages demandent d'en choisir un depuis l'Accueil.
