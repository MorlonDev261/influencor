# Degany, l'assistant IA

[← Fonctionnalités](./README.md)

L'assistant agit dans l'application à votre place : il cherche, range, écrit,
nettoie vos photos avec Deganeo, gère vos tâches et votre comptabilité.

## Connecter votre IA

1. Menu → Réglages → **Assistant IA** (ou l'icône de réglages dans l'onglet
   Assistant).
2. Choisissez un fournisseur : ChatGPT (OpenAI), Claude (Anthropic), Gemini
   (Google), DeepSeek, Mistral, Grok, Groq, OpenRouter, Qwen, Ollama (local)
   ou « Autre » (tout service compatible OpenAI).
3. Collez votre clé API (bouton « Obtenir une clé »), choisissez un modèle
   (bouton nuage : liste les modèles de votre compte).
4. **Enregistrer** (les réglages s'enregistrent aussi tout seuls pendant la
   saisie), puis **Tester la connexion**.

La clé reste sur votre appareil, dans le coffre sécurisé du système. Vos messages et les données que l'assistant
lit pour répondre sont envoyés au fournisseur choisi.

## Exemples de demandes

- « Qu'y a-t-il dans ma bibliothèque ? »
- « Trouve mes notes qui parlent des prix et ajoute le tag tarifs »
- « Crée une note Légende Instagram dans Clients/Ana avec 3 propositions »
- « Nettoie les métadonnées de toutes les photos du dossier Shooting »
- « Ajoute une vente de 25 000 Ar sur MVola » / « Bilan de ce mois »
- « Combien de frais pour retirer 120 000 Ar ? Quelle est la meilleure découpe ? »
- « Crée une tâche Shooting avec : lumière, robe, maquillage »

La réponse s'écrit mot à mot. Pendant le travail, vous voyez :

- **✻ Réflexion** : le raisonnement du modèle, en direct, puis replié (touchez
  pour le relire). Disponible avec Claude, Gemini, DeepSeek, Qwen, et les
  modèles qui la publient.
- **● Action(…)** : chaque action réalisée (point vert = réussie, rouge =
  échec), avec son résultat en dessous. Touchez une action pour voir le
  détail exact.
- Une fois une étape de travail terminée, ses actions (et la réflexion entre
  elles) se replient en une ligne, comme la réflexion :
  **● 4 actions · 12 s**, avec leurs noms en dessous. Touchez-la pour revoir
  chaque action.

Les fichiers cités apparaissent comme des boutons : appui = ouvrir, appui long =
copier le chemin. Touchez une ligne d'outil pour voir ce qui a été fait.

## Mémoire de Degany

Degany retient au fil des conversations ce qu'il apprend sur vous : nom,
activité, marque, domaine, public visé, pages Facebook / Instagram / TikTok…,
site, e-mail, numéros, ton d'écriture préféré, et ce qu'il trouve dans vos
propres contenus (signature, bio). Il s'en sert sans le répéter : il vous
appelle par votre nom, met vos liens dans vos légendes, et répond à
« quelle est ma page Facebook ? » (sinon il la cherche dans votre
bibliothèque).

- Cette mémoire reste sur votre appareil, chiffrée dans le coffre sécurisé
  du système ; seule l'application peut la lire. Elle accompagne vos
  messages vers le fournisseur d'IA choisi, comme le reste de la
  conversation.
- Degany n'y garde jamais de mot de passe, code PIN ou mobile money, numéro
  de carte ni clé API.
- Demandez-lui « que sais-tu de moi ? » pour la voir.
- Réglages de l'assistant → **Mémoire de Degany** : désactiver, ou
  **Effacer la mémoire**. « Nouvelle conversation » ne l'efface pas.

## Nettoyer des photos avec l'assistant

1. Touchez le trombone dans la zone de saisie : **Photos et vidéos** ou
   **Fichiers** (sur ordinateur, vous pouvez aussi glisser les fichiers sur le
   chat).
2. Envoyez, avec ou sans message (« nettoie pour Instagram »…).
3. L'assistant analyse les métadonnées avec Deganeo, puis vous demande où
   enregistrer : **Copie à côté de l'original**, **Remplacer l'original** ou
   **Ranger dans un autre dossier** (et lequel). Touchez un choix ou écrivez
   votre réponse.

## Ce que l'assistant peut atteindre

Degany travaille **uniquement dans votre dossier de travail**. Il ne lit, ne
modifie et ne nettoie aucun fichier ailleurs sur l'appareil, même si on le lui
demande. Le trombone n'affiche que les fichiers du dossier de travail ; un
fichier venu d'ailleurs (glissé sur le chat) est ignoré. Pour le confier à
Degany, importez-le d'abord dans la bibliothèque.

## Sécurité

Avant de mettre à la corbeille, supprimer définitivement ou remplacer un
original, l'assistant vous demande d'**Autoriser** ou **Refuser**. Quand il
réécrit une note, l'ancienne version est gardée dans la corbeille.
Le bouton ■ arrête l'assistant à tout moment.

La conversation est conservée quand vous fermez l'app. « Nouvelle
conversation » en commence une autre sans effacer la précédente : le bouton
**historique**, juste à droite, liste vos conversations précédentes. Touchez-en
une pour la reprendre là où vous l'aviez laissée, ou la corbeille pour la
supprimer. Les conversations restent sur votre appareil.
