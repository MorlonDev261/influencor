# Publier sur l'App Store — de A à Z

[← Documentation développeur](../README.md) · Guide jumeau : [Google Play](./play-store.md)

Ce guide suit l'ordre réel des opérations, du compte Apple à la mise en vente,
puis aux mises à jour. Il n'y a pas de Mac : l'app est compilée et envoyée par
**Codemagic** (build cloud), à partir du fichier [`codemagic.yaml`](../../../codemagic.yaml).

| | |
|---|---|
| Bundle ID | `com.influencor.app` |
| Version / build | lus dans `pubspec.yaml` (`1.0.0+1`) |
| Build cloud | Codemagic, workflow `ios-release` (lancement manuel) |
| Politique de confidentialité | <https://influencor.mi-kandra.org/privacy/> (FR : `/confidentialite/`) |
| Contact | support@poma-original.com |
| Durée totale à prévoir | 1 à 2 semaines (compte, premier build, TestFlight, revue de 1 à 3 jours) |

Déjà prêt dans le dépôt (rien à faire) : `ios/Runner/Info.plist` (textes
d'autorisation, chiffrement, app Fichiers), `ios/Runner/Runner.entitlements`
(push, Universal Links), `ios/Runner/PrivacyInfo.xcprivacy`, la copie
automatique de `GoogleService-Info.plist`, l'import depuis Photos et le lien
vers la politique dans l'écran À propos. Détails : [Builds → iOS](../build/builds.md#ios-app-store).

---

## A. Avant de commencer

- [ ] La politique de confidentialité est **en ligne** (dépôt `influencor-web` :
      commit + push, le serveur la publie en 5 minutes).
- [ ] Le code est **poussé sur GitHub** (`MorlonDev261/influencor`, branche
      `main`) : Codemagic compile ce qui est sur GitHub, pas ce qui est sur le PC.
- [ ] Un compte de **démonstration revendeur** existe (identifiant + mot de
      passe) pour la revue Apple.
- [ ] Un iPhone (ou iPad) est disponible pour tester avec TestFlight.

## B. Créer le compte Apple Developer

1. Créer ou utiliser un **identifiant Apple** avec la double authentification
   activée.
2. S'inscrire sur <https://developer.apple.com/programs/enroll/> :
   - **Individuel** : le nom de la personne apparaît comme vendeur sur l'App Store ;
   - **Organisation** : le nom de la structure apparaît, demande un numéro
     D-U-N-S (gratuit, quelques jours).
3. Payer **99 $ par an**. Validation : de quelques heures à quelques jours.
4. Noter le **Team ID** (10 caractères) : <https://developer.apple.com/account>
   → Membership details. Il sert aux étapes C et G.

## C. Créer l'identifiant de l'app (App ID)

<https://developer.apple.com/account/resources/identifiers/list> → **+** →
App IDs → App :

| Champ | Valeur |
|---|---|
| Description | Influencor |
| Bundle ID | Explicit — `com.influencor.app` |
| Capabilities | cocher **Push Notifications** et **Associated Domains** |

**Register**.

> Bloquant : sans ces deux capacités, le profil de signature ne correspond pas
> aux entitlements de l'app et le build Codemagic échoue.

## D. Notifications push (Firebase + APNs)

À faire si l'on veut les notifications revendeur ; sans cette étape, l'app
fonctionne mais sans push.

1. **Clé APNs** : <https://developer.apple.com/account/resources/authkeys/list>
   → **+** → nom « Influencor APNs », cocher **Apple Push Notifications
   service (APNs)** → Continue → Register → **télécharger le fichier `.p8`**
   (une seule fois possible) et noter le **Key ID**.
2. **Firebase** : console Firebase, projet `poma-original` → Ajouter une
   application → iOS → bundle `com.influencor.app` → télécharger
   **`GoogleService-Info.plist`**.
3. Firebase → Paramètres du projet → **Cloud Messaging** → application iOS →
   Clé d'authentification APNs → envoyer le `.p8` avec le Key ID et le Team ID.

## E. Créer l'app dans App Store Connect

<https://appstoreconnect.apple.com> → Apps → **+** → Nouvelle app :

| Champ | Valeur |
|---|---|
| Plateformes | iOS |
| Nom | Influencor (30 caractères max, unique sur l'App Store) |
| Langue principale | Français |
| Bundle ID | `com.influencor.app` |
| SKU | `influencor-ios` (interne, libre) |
| Accès utilisateur | Accès complet |

## F. Clé API App Store Connect (pour Codemagic)

App Store Connect → Utilisateurs et accès → **Intégrations** → App Store
Connect API → Clés d'équipe → **+** :

- Nom : Codemagic
- Accès : **App Manager**

Télécharger la clé `.p8` (une seule fois possible), noter l'**Issuer ID** et
le **Key ID**.

## G. Préparer le serveur pour les liens revendeur (Universal Links)

Dans le dépôt `poma-original`, servir ce fichier à l'adresse
`https://reseller.poma-original.com/.well-known/apple-app-site-association`
(type `application/json`, sans redirection, sans extension) :

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["TEAMID.com.influencor.app"],
        "components": [{ "/": "/*" }]
      }
    ]
  }
}
```

Remplacer `TEAMID` par le Team ID (étape B). Si l'app Pôma Original existe
aussi sur iOS, ajouter son appID **après** celui d'Influencor.

> Sinon : les liens revendeur reçus par WhatsApp/SMS s'ouvrent dans Safari au
> lieu de l'app. Pas bloquant pour la revue.

## H. Configurer Codemagic

1. Créer un compte sur <https://codemagic.io> avec GitHub et ajouter le dépôt
   `MorlonDev261/influencor` (type : Flutter App, configuration par
   `codemagic.yaml`).
2. Team settings → Integrations → **Developer Portal** → Connect → nom
   **`Influencor ASC`** (exactement celui de `codemagic.yaml`), puis Issuer ID,
   Key ID et le `.p8` de l'étape F.
3. Pour les notifications (si l'étape D est faite) :
   - Application → Environment variables → groupe **`firebase`** → variable
     `GOOGLE_SERVICE_INFO_PLIST`, valeur = le fichier encodé en base64, cochée
     *Secret*. Pour l'encoder sous Windows (PowerShell) :

     ```powershell
     [Convert]::ToBase64String([IO.File]::ReadAllBytes("GoogleService-Info.plist")) | Set-Clipboard
     ```

   - Dans `codemagic.yaml`, décommenter les lignes `groups:` / `- firebase`,
     commiter et pousser.
4. Codemagic crée lui-même le certificat de distribution et le profil
   (`ios_signing` dans `codemagic.yaml`) : rien à faire dans Xcode.

## I. Premier build et envoi sur TestFlight

1. Codemagic → l'application → **Start new build** → branche `main`, workflow
   **iOS → TestFlight**.
2. Durée : 15 à 30 minutes. En cas d'échec, lire le log de l'étape en rouge
   (voir « Problèmes fréquents » plus bas).
3. En fin de build, l'IPA est envoyée automatiquement à App Store Connect.
   Apple la traite (10 à 30 minutes) puis l'affiche dans l'onglet
   **TestFlight**.

C'est ce premier build qui valide la compilation iOS des plugins natifs
(media_kit, super_clipboard, WebView, Firebase) : il n'a jamais été fait.

## J. Tester avec TestFlight

1. App Store Connect → TestFlight → **Test interne** → créer un groupe →
   ajouter les membres de l'équipe (jusqu'à 100, sans revue Apple).
2. Sur l'iPhone : installer l'app **TestFlight**, accepter l'invitation,
   installer Influencor.
3. (Facultatif) **Test externe** : jusqu'à 10 000 testeurs par lien public,
   après une courte revue Apple de la version bêta.

Checklist de test sur iPhone :

- [ ] premier lancement → dossier de travail (« Utiliser le dossier de l'app ») ;
- [ ] import depuis **Photothèque** et depuis **Fichiers** ; les photos
      s'affichent en miniature ;
- [ ] le dossier apparaît dans l'app Fichiers → Sur mon iPhone → Influencor ;
- [ ] note, partage vers WhatsApp, « Enregistrer l'image » depuis le partage ;
- [ ] lecture vidéo, nettoyage Deganeo ;
- [ ] Degany avec une clé API ;
- [ ] connexion revendeur, photo envoyée depuis le site (appareil photo),
      notification, lien `reseller.poma-original.com` ouvert depuis Notes ou
      WhatsApp ;
- [ ] iPad : affichage et rotation ;
- [ ] Réglages → Influencor → Politique de confidentialité.

## K. Remplir la fiche App Store

App Store Connect → l'app → onglet **Distribution**.

### K1. Informations sur l'app
- Sous-titre (30 caractères) : ex. « Contenu prêt à publier ».
- Catégorie principale : **Productivité** ; secondaire : **Photo et vidéo**.
- Droits sur le contenu : l'app n'affiche pas de contenu tiers.
- **Classification par âge** : répondre « Aucun » partout. « Accès Web non
  restreint » : **Non** (le WebView est limité aux sites Pôma Original ; Degany
  ne fait que lire le texte des pages demandées).

### K2. Tarifs et disponibilité
Gratuit, pays : Madagascar + autres pays visés.

### K3. Confidentialité de l'app
- URL de la politique : <https://influencor.mi-kandra.org/privacy/>.
- **Collecte de données** → Oui, et déclarer :

| Type | Lié à l'identité | Pistage | Finalité | Pourquoi |
|---|---|---|---|---|
| Coordonnées → Nom, Adresse e-mail, Numéro de téléphone | Oui | Non | Fonctionnalité de l'app | Compte revendeur (WebView) |
| Identifiants → ID d'appareil | Oui | Non | Fonctionnalité de l'app | Jeton de notification |

Degany envoie les demandes au fournisseur d'IA de l'utilisateur, avec sa propre
clé, sans passer par nous : ce n'est pas une collecte au sens d'Apple. Garder
ces réponses cohérentes avec `ios/Runner/PrivacyInfo.xcprivacy`.

### K4. Page de la version 1.0.0
| Champ | Limite | Contenu |
|---|---|---|
| Captures iPhone 6,9" | 1 à 10, 1320 × 2868 (ou 1290 × 2796) | **Obligatoires** |
| Captures iPad 13" | 1 à 10, 2064 × 2752 | **Obligatoires** (l'app accepte l'iPad) |
| Texte promotionnel | 170 caractères | modifiable sans nouvelle version |
| Description | 4 000 caractères | reprendre le site vitrine |
| Mots-clés | 100 caractères, séparés par des virgules | ex. `bibliothèque,contenu,notes,photos,réseaux sociaux,créateur,community manager,IA,revendeur` |
| URL d'assistance | | <https://influencor.mi-kandra.org> |
| Copyright | | `2026 Mi Kandra` |
| Build | | choisir le build TestFlight de l'étape I |

Les captures se font sur l'iPhone de test (TestFlight) ou depuis un simulateur
sur Codemagic.

### K5. Informations pour la revue (App Review Information)
- **Connexion requise** : cocher, puis identifiant et mot de passe du compte de
  démonstration revendeur.
- Coordonnées : nom, téléphone, support@poma-original.com.
- Notes (en anglais) :

  > Influencor is a local content library: notes, images and videos stay in a
  > folder on the device, no account is needed. The demo account is only for the
  > optional reseller space: Settings → Influencor (bottom) → Professional
  > access → Sign in. The AI assistant (Degany) is optional and uses the user's
  > own API key from an AI provider; no key is bundled.

  Si l'on veut qu'Apple teste Degany, fournir une clé API de test à quota
  limité dans ces notes.

### K6. Chiffrement
Rien à répondre : `ITSAppUsesNonExemptEncryption = false` est déjà dans
l'Info.plist.

## L. Soumettre à la revue

1. Page de la version → **Ajouter pour vérification** → **Soumettre**.
2. Choisir la mise en ligne : **manuelle** (recommandé pour la première
   version) ou automatique dès l'approbation.
3. Revue : en général 24 à 48 heures. Apple répond dans App Store Connect
   (onglet « App Review ») : répondre par écrit ou corriger et renvoyer un
   build.

## M. Après l'approbation

1. Si la mise en ligne est manuelle : **Publier cette version**.
2. L'app apparaît sur l'App Store sous quelques heures :
   `https://apps.apple.com/app/id<APPLE_ID>` (Apple ID numérique visible dans
   App Store Connect → Informations sur l'app).
3. Ajouter le bouton App Store sur le site vitrine. Sur le serveur du site
   (dépôt `influencor-web`) :

   ```bash
   ./start.sh --app-store on 'https://apps.apple.com/app/id<APPLE_ID>'
   ```

   Le site affiche alors un bouton « App Store » et une carte iPhone/iPad à
   côté d'Android et Windows (`./start.sh --app-store off` pour les retirer).

## N. Mettre à jour l'application

1. Corriger, `flutter analyze`, `flutter test`, pousser sur GitHub.
2. App Store Connect refuse un build dont le numéro (le nombre après `+` dans
   `pubspec.yaml`, aujourd'hui `1`) a déjà été envoyé pour la même version : le
   changer avant chaque nouvel envoi. Pour une nouvelle version visible,
   changer aussi `1.0.0`.
3. Relancer le workflow Codemagic → nouveau build dans TestFlight.
4. App Store Connect → **+ Version** → choisir le build → notes de version →
   soumettre.

## Problèmes fréquents

| Message / situation | Cause | Solution |
|---|---|---|
| Codemagic : « No matching profiles found » / entitlements | Push ou Associated Domains non cochés sur l'App ID | Étape C |
| Codemagic : erreur d'intégration App Store Connect | Nom différent de `Influencor ASC` ou clé sans rôle App Manager | Étapes F et H |
| « The bundle version must be higher than the previously uploaded version » | Numéro de build déjà utilisé | Étape N |
| « ITMS-90683: Missing purpose string » | Texte d'autorisation manquant | Ajouter la clé dans `ios/Runner/Info.plist` |
| Rejet 2.1 « Information Needed » | Compte de démo invalide ou absent | Étape K5 |
| Rejet 5.1.1(v) « Account deletion » | Compte créable dans l'app sans moyen de le supprimer | Page de suppression de compte sur le site revendeur, ou demande par e-mail décrite dans la politique |
| Rejet 4.2 « Minimum functionality » | Apple pense que l'app n'est qu'un site web | Montrer dans les notes la bibliothèque locale, le nettoyage, Degany |
| Pas de notifications | `GoogleService-Info.plist` absent ou clé APNs non envoyée | Étapes D et H3 |
| Liens revendeur ouverts dans Safari | Fichier AASA absent ou Team ID erroné | Étape G |
