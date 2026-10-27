# Builds

[← Documentation développeur](../README.md)

Le modèle de Degany fourni par l'app (clé API, choix laissé ou non à
l'utilisateur) vient de `.env` (voir `.env.example`) : les scripts
`tools/build_*_release.ps1` ajoutent `--dart-define-from-file=.env` quand le
fichier existe (pas pour le web). Détails : [Degany](../architecture/assistant.md).

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

L'AAB (`Influencor.aab` dans `dist/`) est signé avec la clé d'upload
(`android/key.properties` → `android/app/influencor-release.jks`), `targetSdk`
36. Ne jamais perdre ce keystore ni ses mots de passe.

Publication pas à pas (compte, fiche, déclarations, test fermé, production,
mises à jour) : **[Publier sur Google Play — de A à Z](../release/play-store.md)**.

## iOS (App Store)

Sur iPhone, l'App Store est le seul canal de distribution grand public : il
n'existe pas d'équivalent au téléchargement direct d'un APK ou d'un EXE.
`flutter build ipa` ne fonctionne pas sous Windows : l'app est compilée et
envoyée sur TestFlight par Codemagic (`codemagic.yaml`, workflow
`ios-release`).

Publication pas à pas (compte Apple, App ID, Firebase, Codemagic, TestFlight,
fiche, revue, mises à jour) : **[Publier sur l'App Store — de A à Z](../release/app-store.md)**.

### Déjà prêt dans le dépôt

- `ios/Runner/Info.plist` : textes d'autorisation (appareil photo et micro
  pour les envois depuis le WebView revendeur, ajout à Photos depuis la feuille
  de partage, photothèque et musique exigés par les API que file_picker
  embarque), `ITSAppUsesNonExemptEncryption = false` (HTTPS seulement : pas
  de question sur le chiffrement à chaque envoi), dossier de travail visible
  dans l'app Fichiers (`UIFileSharingEnabled`), mode d'arrière-plan
  `remote-notification`, liens profonds gérés par `app_links`
  (`FlutterDeepLinkingEnabled = false`, comme sur Android).
- `ios/Runner/Runner.entitlements` : push (`aps-environment`) et Universal
  Links (`applinks:reseller.poma-original.com`).
- `ios/Runner/PrivacyInfo.xcprivacy` : manifeste de confidentialité (pas de
  pistage, jeton push lié au compte revendeur, horodatage de fichiers).
- Phase Xcode « Copy GoogleService-Info.plist » : copie le fichier Firebase
  dans l'app s'il est présent, sinon l'app se construit sans push.
- `codemagic.yaml` : build signé et envoi sur TestFlight (workflow
  `ios-release`, lancement manuel).

### Choix de fichiers sur iPhone

Le navigateur de fichiers intégré ne voit que le conteneur de l'app. Sur iOS,
`AppFilePicker` passe donc par les sélecteurs du système pour tout sauf le
choix d'un dossier : une feuille « Photothèque / Fichiers » s'ouvre
(PHPicker, sans demande d'autorisation, ou l'app Fichiers). Les photos
arrivent en JPEG et les vidéos en H.264 (copie « compatible » de Photos : le
HEIC n'a pas de miniature dans l'app). L'import dans la bibliothèque copie
toujours (rien à déplacer depuis Photos). Les copies que file_picker laisse
dans `Documents/picked_images` sont déplacées dans le dossier temporaire
(`picked_media_io.dart`) pour ne pas apparaître dans Fichiers. Le choix d'un
dossier (espace de travail, destination) reste dans le navigateur intégré,
qui s'ouvre sur `Documents`.

### Limites connues sur iPhone

- Les noms d'origine des photos sont perdus (PHPicker ne les transmet pas à
  file_picker) : elles sont nommées `IMG_aaaammjj_hhmmss.jpg`.
- Aucun build iOS n'a encore été lancé : le premier passage sur Codemagic
  valide la compilation des plugins natifs (media_kit, super_clipboard,
  WebView, Firebase).

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
build/installer/Influencor Setup.exe
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
