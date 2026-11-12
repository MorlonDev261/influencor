# Publier sur Google Play — de A à Z

[← Documentation développeur](../README.md) · Guide jumeau : [App Store](./app-store.md)

Ce guide suit l'ordre réel des opérations, de la création du compte à la mise en
production, puis aux mises à jour. Chaque étape dit **où** cliquer, **quoi**
remplir et **ce qui bloque** si on la saute.

| | |
|---|---|
| Identifiant de l'app | `com.influencor.app` |
| Fichier à envoyer | `dist/latest/android/Influencor.aab` |
| Clé de signature (envoi et Play) | `android/app/influencor-release.jks` (via `android/key.properties`, jamais commités), la même que les APK du site — voir G |
| Politique de confidentialité | <https://influencor.mi-kandra.org/confidentialite/> |
| Suppression des données | <https://influencor.mi-kandra.org/confidentialite/#suppression> |
| Contact | support@poma-original.com |
| Durée totale à prévoir | 3 à 4 semaines pour un compte personnel (test fermé de 14 jours obligatoire) |

---

## A. Avant de commencer

- [ ] La politique de confidentialité est **en ligne** (dépôt `influencor-web` :
      commit + push, le serveur la publie en 5 minutes). Ouvrir les deux
      adresses du tableau ci-dessus pour vérifier.
- [ ] Le keystore `android/app/influencor-release.jks` et `android/key.properties`
      sont sauvegardés **hors de l'ordinateur** (clé USB, coffre de mots de
      passe). Sans eux, plus aucune mise à jour possible sans passer par le
      support Google.
- [ ] Un compte de **démonstration revendeur** existe sur
      `reseller.poma-original.com` (identifiant + mot de passe) pour l'équipe de
      revue.
- [ ] 12 adresses Gmail de testeurs sont prêtes (étape H), si le compte Play
      est personnel.

## B. Créer le compte Play Console

1. Aller sur <https://play.google.com/console> et se connecter avec le compte
   Google qui possédera l'app.
2. Choisir le type de compte :
   - **Personnel** : plus simple, mais impose le test fermé de 14 jours (étape H).
   - **Organisation** : demande un numéro D-U-N-S (gratuit, quelques jours à
     obtenir) et dispense du test fermé.
3. Payer les **25 $** (une seule fois).
4. Faire la **vérification d'identité** (pièce d'identité, parfois justificatif
   d'adresse) et vérifier le numéro de téléphone. Compter 1 à 3 jours.

> Bloquant : tant que l'identité n'est pas vérifiée, impossible de publier.

## C. Créer l'application

Play Console → **Créer une application** :

| Champ | Valeur |
|---|---|
| Nom de l'application | Influencor |
| Langue par défaut | Français (France) – fr-FR |
| Application ou jeu | Application |
| Gratuite ou payante | Gratuite (définitif : une app gratuite ne peut plus devenir payante) |

Cocher les déclarations (règles du programme, lois d'export) puis **Créer**.

## D. Construire l'AAB signé

Sur le PC Windows, à la racine du dépôt `influencor` :

1. Vérifier que `pubspec.yaml` contient `version: 1.0.0+2`. Les APK déjà
   distribués par le site sont en `+1` : Play ne propose la mise à jour à ces
   téléphones que si le numéro de build est supérieur (et la clé identique,
   étape G).
2. Vérifier la qualité :

   ```bash
   flutter analyze
   ```

   ```bash
   flutter test
   ```

3. Construire (APK + AAB + Windows, artefacts copiés dans `dist/`) :

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools/build_full_release.ps1 -SkipWeb -SkipWebsite
   ```

   `-SkipWebsite` évite que le script commite et pousse les nouveaux APK sur le
   site : à retirer quand on veut aussi mettre à jour les téléchargements.

4. Le fichier à envoyer est `dist/latest/android/Influencor.aab`. Il
   est signé avec `influencor-release.jks`, la même clé que les APK du site
   (le build échoue volontairement si `android/key.properties` manque).

> Si `flutter build appbundle` affiche « failed to strip debug symbols » :
> installer **Android SDK Command-line Tools** (voir [Builds](../build/builds.md#android-aab)).

## E. Fiche du Store (Croissance → Présence sur le Store → Fiche principale)

| Champ | Limite | Contenu |
|---|---|---|
| Nom | 30 caractères | Influencor |
| Description courte | 80 caractères | ex. « Vos notes, photos et vidéos rangées, prêtes à publier, avec l'assistant IA Degany. » |
| Description complète | 4 000 caractères | Reprendre le site vitrine : bibliothèque, recherche, partage, nettoyage Deganeo, Degany, espace revendeur. |
| Icône | 512 × 512 PNG, 32 bits | [`play-store/icone-512.png`](play-store/icone-512.png) |
| Image de présentation | 1024 × 500 PNG/JPEG | **Obligatoire** : [`play-store/presentation-1024x500.png`](play-store/presentation-1024x500.png) |
| Captures téléphone | 2 à 8, côté 320–3840 px, ratio 9:16 | `play-store/mobile/` (8 images, dans l'ordre) |
| Captures tablette 7" et 10" | facultatif | `play-store/tablette-7/`, `play-store/tablette-10/` |
| Chromebook / Android XR | facultatif | `play-store/ordinateur/`, `play-store/android-xr/` |

Les visuels de [`play-store/`](play-store/) sont générés à partir des vrais
écrans de l'app : la procédure pour les refaire est dans
[`play-store/CREDITS.md`](play-store/CREDITS.md).

Puis **Paramètres de la fiche** : catégorie **Productivité**, adresse e-mail de
contact support@poma-original.com, site web
<https://influencor.mi-kandra.org>.

Ajouter une fiche **anglaise** (Traductions → English (United States)) si l'on
vise aussi les anglophones.

## F. Contenu de l'application (Règles → Contenu de l'application)

Chaque rubrique doit être au statut « Terminé » avant toute publication.

### F1. Politique de confidentialité
URL : <https://influencor.mi-kandra.org/confidentialite/>

### F2. Accès à l'application
**L'AAB Play ne contient pas l'espace revendeur** (décision du 08/11/2026) : il
est construit avec `--dart-define=INFLUENCOR_RESELLER=false`
(`tools/build_full_release.ps1`), ce qui retire l'entrée « Accès
professionnel », l'accueil revendeur, les liens `reseller.poma-original.com`
(alias `.ResellerLinks` désactivé dans le manifeste) et les notifications
revendeur. Seul l'APK du site le garde.

Réponse : « Toutes les fonctionnalités sont disponibles sans restriction ».
Degany demande la clé API de l'utilisateur ; il est facultatif (à préciser si
la console le demande).

> Un téléphone qui a l'APK du site et reçoit la mise à jour Play perd l'espace
> revendeur (même identifiant d'app, build plus élevé).

### F3. Annonces
« Non, mon application ne contient pas d'annonces. »

### F4. Classification du contenu
Remplir le questionnaire IARC (catégorie : *Toutes les autres applications*).
Réponses : pas de violence, sexualité, langage grossier, drogues, jeux
d'argent ; **pas** d'échanges entre utilisateurs dans l'app ; pas de partage de
position. Résultat attendu : *Tout public / PEGI 3*.

### F5. Public cible et contenu
Tranche d'âge : **18 ans et plus** (outil pour créateurs et revendeurs ; évite
les exigences du programme Familles). Pas d'attrait particulier pour les
enfants.

### F6. Sécurité des données
Questionnaire à remplir ainsi (cohérent avec la politique de confidentialité) :

| Question | Réponse |
|---|---|
| L'app collecte-t-elle ou partage-t-elle des données ? | Oui |
| Données chiffrées en transit ? | Oui |
| Création de compte | Mon appli ne permet pas aux utilisateurs de créer un compte |

Version Play (sans espace revendeur, voir F2) : un seul type de données, déclaré
comme **collecté** (pas « partagé ») :

| Type | Facultatif ? | Éphémère ? | Finalité | Pourquoi |
|---|---|---|---|---|
| Activité dans les applis → Autre contenu généré par l'utilisateur | Oui | Oui | Fonctionnement de l'appli | Demandes envoyées au fournisseur d'IA choisi (Degany), traitées à la volée |

Le nom, l'e-mail, le téléphone (compte revendeur) et le jeton de notification
(push revendeur) ne concernent que l'APK du site : **ne pas** les déclarer tant
que la version Play n'a pas l'espace revendeur.

Les fichiers de la bibliothèque, les tâches et la comptabilité restent sur
l'appareil : **ne pas** les déclarer.

### F7. Autres déclarations
- **Applications gouvernementales** : Non.
- **Fonctionnalités financières** : aucune (l'app calcule des frais mobile money
  et tient une comptabilité locale, sans service financier).
- **Santé** : aucune.
- **Actualités** : Non.

### F8. Autorisation « Accès à tous les fichiers » (`MANAGE_EXTERNAL_STORAGE`)
Se remplit au moment du premier envoi de l'AAB (Play le demande). Texte,
catégorie et vidéo à fournir : [android-storage-permission.md](../android-storage-permission.md).

> Risque : Google refuse souvent cette autorisation. En cas de refus, il faut
> une version sans elle (l'app sait déjà fonctionner dans son dossier privé,
> voir la fin de [android-storage-permission.md](../android-storage-permission.md)).

## G. Signature d'application par Google Play

**Décision (30/10/2026) : la clé de signature de l'application est
`android/app/influencor-release.jks`, la même que celle des APK du site.**
Android n'accepte une mise à jour que si elle est signée avec la même clé que
l'app installée : avec une clé générée par Google, les téléphones qui ont
installé l'APK ne pourraient jamais passer par Play (il faudrait désinstaller).
Avec la même clé et un numéro de build supérieur (`+2`, étape D), Play propose
simplement la mise à jour.

Ce choix se fait **au premier envoi de l'AAB et ne se change plus ensuite** :

1. Quand la console propose Play App Signing, **ne pas accepter la clé générée
   par Google** : choisir **Utiliser une autre clé → Exporter et importer une
   clé depuis un keystore Java**.
2. Télécharger l'outil `pepk.jar` et la clé de chiffrement fournie par la
   console, lancer la commande indiquée avec `android/app/influencor-release.jks`
   et son alias (voir `android/key.properties`), puis importer le `.zip` produit.
3. Sauvegarder le keystore et ses mots de passe dans au moins deux coffres :
   c'est désormais la clé de l'app (perte = plus aucune mise à jour hors Play,
   fuite = fausse version publiable).

Ensuite, Test et publication → Configuration → **Intégrité de l'application** →
Signature d'application : vérifier que l'empreinte **SHA-256 de la clé de
signature d'application** est celle déjà présente dans
`https://reseller.poma-original.com/.well-known/assetlinks.json` (dépôt
`poma-original`, `docs/03-mobile/deep-links.md`). Si elle diffère (clé Google
acceptée par erreur), l'y ajouter.

> Sinon : les liens revendeur ne s'ouvrent plus dans l'app installée depuis Play.

## H. Test fermé (compte personnel : 12 testeurs × 14 jours)

1. Test et publication → Tests → **Test fermé** → Gérer la piste → Créer une
   release.
2. Déposer `Influencor.aab` (premier envoi : choisir la clé comme décrit en
   **G**, **pas** l'option par défaut « clé générée par Google »), nom de
   release `1.0.0 (2)`, notes de
   version en français.
3. Onglet **Testeurs** → créer une liste avec au moins **12 adresses Gmail** →
   copier le **lien d'inscription** et l'envoyer aux testeurs.
4. Envoyer la release en examen (Vue d'ensemble de la publication → Envoyer
   les modifications). Première revue : quelques heures à 7 jours.
5. Chaque testeur ouvre le lien, accepte, installe depuis Play et **garde l'app
   installée 14 jours d'affilée**.

Checklist de test sur téléphone :

- [ ] choix du dossier de travail (avec et sans « Accès à tous les fichiers ») ;
- [ ] import d'images et vidéos, création de note, partage vers WhatsApp ;
- [ ] nettoyage Deganeo ;
- [ ] Degany avec une clé API ;
- [ ] connexion revendeur, ouverture d'un lien `reseller.poma-original.com`
      depuis WhatsApp, notification ;
- [ ] écran À propos → Politique de confidentialité ;
- [ ] mise à jour depuis l'APK : sur un téléphone où l'APK du site (`+1`) est
      installé, ouvrir la page Play de l'app. Play doit proposer **Mettre à
      jour** (pas « Installer ») et les données de l'app restent. Si Play
      refuse, la clé de signature n'est pas la bonne (section G).

## I. Demander l'accès à la production

Après 14 jours avec 12 testeurs actifs : Tableau de bord → **Demander l'accès
à la production**. Répondre au questionnaire (comment le test s'est passé,
retours reçus, corrections faites). Réponse de Google : jusqu'à 7 jours.

## J. Publier en production

1. Test et publication → **Production** → Pays/régions : ajouter Madagascar et
   les autres pays visés.
2. Créer une release → « Ajouter depuis la bibliothèque » le même AAB (ou un
   plus récent).
3. Choisir un **déploiement progressif** (par ex. 20 %), puis l'augmenter les
   jours suivants si aucun problème n'apparaît dans Qualité → Android vitals.
4. Envoyer en examen. Une fois publiée, l'app est visible sur
   <https://play.google.com/store/apps/details?id=com.influencor.app>.

## K. Basculer le site vers Google Play

Sur le serveur du site (dépôt `influencor-web`) :

```bash
./start.sh --play-store on
```

Le bouton Android du site pointe alors vers Google Play et le lien APK
disparaît (`./start.sh --play-store off` pour revenir en arrière).

## L. Mettre à jour l'application

1. Corriger, puis `flutter analyze` et `flutter test`.
2. Play refuse tout AAB dont le numéro de build (le nombre après `+` dans
   `pubspec.yaml`, aujourd'hui `2`) n'est pas **supérieur** au précédent : il
   faut donc le changer avant chaque nouvel envoi.
3. Reconstruire (étape D), puis Production → Créer une release → déposer l'AAB
   → déploiement progressif.

Pas de retour arrière possible vers un ancien AAB : en cas de problème, on
publie une nouvelle version corrigée.

## Problèmes fréquents

| Message | Cause | Solution |
|---|---|---|
| « Vous devez utiliser un code de version différent » | Numéro de build déjà utilisé | Augmenter le nombre après `+` |
| « Votre APK ou Android App Bundle a été signé en mode débogage » | `key.properties` absent | Restaurer `android/key.properties` et le keystore |
| Refus de l'autorisation « Accès à tous les fichiers » | Usage jugé non essentiel | Faire appel avec la vidéo, ou publier sans cette autorisation (F8) |
| Refus « Accès aux applications » | Compte de démo invalide | Vérifier l'identifiant/mot de passe de F2 |
| Liens revendeur ouverts dans le navigateur | Empreinte Play absente d'`assetlinks.json` | Étape G |
