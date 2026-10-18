# Builds

[← Documentation développeur](../README.md)

## Android APK release

À la racine:

```bash
flutter build apk --release
```

Commande Windows recommandée pour éviter le warning Java du launcher Gradle:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_android_release.ps1
```

Cette commande collecte aussi les artefacts dans `dist/`.

Sortie attendue:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## Android APK par ABI

À la racine:

```bash
flutter build apk --release --split-per-abi
```

Commande Windows recommandée pour éviter le warning Java du launcher Gradle:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_android_split_release.ps1
```

Cette commande collecte aussi les artefacts dans `dist/`.

Sorties attendues:

```text
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
build/app/outputs/flutter-apk/app-x86_64-release.apk
```

## Android AAB

À la racine:

```bash
flutter build appbundle --release
```

Sortie attendue si le build réussit:

```text
build/app/outputs/bundle/release/app-release.aab
```

Les symboles de débogage du moteur Flutter et du code de l'app sont retirés
des bibliothèques et rangés dans `BUNDLE-METADATA` de l'AAB. Seules les deux
bibliothèques compilées par cargokit (`libsuper_native_extensions.so`,
`libirondash_engine_context_native.so`) gardent leurs symboles (voir
`packaging.jniLibs.keepDebugSymbols` dans `android/app/build.gradle.kts`).

Flutter vérifie ce point avec `apkanalyzer`, fourni par le composant
**Android SDK Command-line Tools**. Sans lui, `flutter build appbundle`
affiche « failed to strip debug symbols » même quand l'AAB est correct :
installer ce composant (Android Studio → SDK Manager → SDK Tools), puis
`flutter doctor --android-licenses`.

## Google Play

Un APK téléchargé depuis le site déclenche les avertissements Android
(« sources inconnues », Play Protect). Installée depuis Google Play,
l'application n'en affiche aucun.

L'AAB (`Influencor-release.aab` dans `dist/`) est déjà prêt pour Play : signé
avec la clé d'upload (`android/key.properties` → `android/app/influencor-release.jks`),
`targetSdk` 36. Ne jamais perdre ce keystore ni ses mots de passe : sans eux,
plus de mise à jour possible sans passer par le support Google.

Configuration une seule fois :

1. Créer un compte Play Console (<https://play.google.com/console>, 25 $ une
   fois, vérification d'identité).
2. Créer l'application (nom « Influencor », application gratuite) et accepter
   **Play App Signing** : Google re-signe l'app avec sa propre clé, la clé
   d'upload ne sert qu'à envoyer les AAB.
3. **App Links** : copier l'empreinte SHA-256 de la *clé de signature d'app*
   (Play Console → Test et publication → Intégrité de l'app → Signature
   d'application) et l'ajouter dans `assetlinks.json` de
   `reseller.poma-original.com`, à côté de celle de la clé d'upload. Sinon,
   les liens revendeur ne s'ouvrent plus dans l'app installée depuis Play.
4. Compléter « Contenu de l'application » : politique de confidentialité (URL
   obligatoire), sécurité des données (l'app envoie des données aux
   fournisseurs IA configurés par l'utilisateur et reçoit des notifications
   Firebase), classification du contenu, public cible.

### Accès à tous les fichiers (`MANAGE_EXTERNAL_STORAGE`)

Permission restreinte par Google Play : il faut remplir la déclaration
(Contenu de l'application → Autorisations « Accès à tous les fichiers ») et
Google peut la refuser. Justification à fournir (usage cœur : gestion de
documents) :

> Influencor est une bibliothèque de contenus pour créateurs et
> gestionnaires de réseaux sociaux. L'utilisateur choisit un dossier de travail
> dans le stockage partagé (par ex. Documents/Influencor) qui contient ses
> images, vidéos et textes organisés par projet ; ce dossier reste lisible par
> les autres applications (galerie, WhatsApp, Facebook) pour la publication et
> survit à la désinstallation. L'application intègre un explorateur de fichiers
> pour importer des médias depuis n'importe quel dossier de l'appareil.
> L'accès est demandé uniquement quand l'utilisateur choisit un dossier hors de
> l'espace privé de l'app ; s'il refuse, l'app fonctionne dans son dossier
> privé.

Joindre une courte vidéo montrant le choix du dossier de travail et
l'import de médias.

Si Google refuse : l'app sait déjà fonctionner sans cette permission (dossier
privé, `WorkspaceService.appFolderPath`). Il faudrait alors une variante Play
sans la permission dans le manifeste, au prix d'un dossier de travail effacé à
la désinstallation et invisible dans la galerie.

### Tests obligatoires (comptes personnels)

Un compte Play Console **personnel** récent doit faire un **test fermé avec au
moins 12 testeurs pendant 14 jours consécutifs** avant de pouvoir demander la
production. Un compte **organisation** (avec numéro D-U-N-S) n'a pas cette
obligation.

Publication :

1. Test et publication → Tests → Test fermé → créer une release → déposer
   `Influencor-release.aab` → ajouter les testeurs (liste d'e-mails Google).
2. Après les 14 jours : Production → demander l'accès, puis créer une release
   avec le même AAB (ou un plus récent).

Chaque nouvel AAB doit avoir un `versionCode` supérieur (le nombre après `+`
dans `version:` de `pubspec.yaml`).

## iOS (App Store)

Sur iPhone, l'App Store est le seul canal de distribution grand public : il
n'existe pas d'équivalent au téléchargement direct d'un APK ou d'un EXE.

Prérequis :

- compte Apple Developer Program (99 $/an) ;
- un Mac avec Xcode, ou un service de build cloud (Codemagic, GitHub Actions
  avec runner macOS), car `flutter build ipa` ne fonctionne pas sous Windows.

Le bundle id est déjà `com.influencor.app`. Étapes : créer l'app dans App
Store Connect, `flutter build ipa --release` (signature automatique Xcode),
envoyer avec Transporter ou Xcode, tester via TestFlight, puis soumettre à la
revue Apple.

## Windows release

À la racine:

```bash
flutter build windows --release
```

Sortie attendue:

```text
build/windows/x64/runner/Release/
```

Exécutable principal:

```text
build/windows/x64/runner/Release/influencor.exe
```

## Installateur Windows

Prérequis:

- build Windows release généré;
- Inno Setup installé;
- commande `iscc` disponible.

Commande:

```bash
iscc installer/influencor.iss
```

Sortie attendue:

```text
build/installer/InfluencorSetup.exe
```

L'installateur n'est pas signé : Windows SmartScreen affiche « Windows a
protégé votre ordinateur » (Informations complémentaires → Exécuter quand
même). Pour une installation sans avertissement, passer par le Microsoft Store
(section suivante).

## Microsoft Store (MSIX)

Le Store signe lui-même le paquet : pas de certificat à acheter, pas
d'avertissement SmartScreen pour les installations depuis le Store.

Configuration une seule fois :

1. Créer un compte développeur individuel (gratuit) sur
   <https://storedeveloper.microsoft.com>, puis ouvrir Partner Center.
2. Apps et jeux → Nouveau produit → Application MSIX ou PWA → réserver le nom
   « Influencor ».
3. Dans l'application → Gestion des produits → Identité du produit, copier les
   trois valeurs dans `msix_config` de `pubspec.yaml` :
   - `Package/Identity/Name` → `identity_name`
   - `Package/Identity/Publisher` (`CN=...`) → `publisher`
   - `Package/Properties/PublisherDisplayName` → `publisher_display_name`

Build (après le build Windows release) :

```bash
dart run msix:create
```

Sortie attendue :

```text
build/msix/Influencor.msix
```

`tools/build_full_release.ps1` construit ce paquet automatiquement dès que
`identity_name` est renseigné, et `tools/collect_release_artifacts.ps1` le
copie dans `dist/`.

Version du paquet : version du pubspec suivie de `.0` (`1.0.0+4004` →
`1.0.0.0`). Le Store refuse une soumission dont la version n'est pas
supérieure à la précédente : augmenter au moins le patch avant chaque
soumission.

Soumission : Partner Center → l'application → Démarrer la soumission →
Packages → déposer `Influencor.msix`, compléter la fiche (description,
captures d'écran, classification d'âge, politique de confidentialité), puis
soumettre. La certification prend en général de quelques heures à quelques
jours.

## Web

Le projet contient un dossier `web/`. Build Flutter standard:

```bash
flutter build web --release
```

Commande Windows recommandée pour éviter le message informatif du dry-run Wasm:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_web_release.ps1
```

Cette commande collecte aussi les artefacts dans `dist/`.

Sortie attendue:

```text
build/web/
```

Vérifier manuellement les limites navigateur liées à l'accès aux fichiers locaux.

## Dossier de distribution officiel

Tous les artefacts prêts à partager doivent être collectés dans:

```text
dist/latest/
dist/releases/<version-date>/
```

Commande de collecte:

```powershell
powershell -ExecutionPolicy Bypass -File tools/collect_release_artifacts.ps1
```

Commande complète recommandée (Windows, APK par ABI, APK universel, AAB, web):

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_full_release.ps1
```

Android et Windows seulement:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_full_release.ps1 -SkipWeb
```
