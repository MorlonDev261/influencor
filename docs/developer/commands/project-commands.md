# Commandes Du Projet

[← Documentation développeur](../README.md)

Toutes les commandes ci-dessous sont à exécuter à la racine du projet.

## Installation

```bash
flutter pub get
```

Installe les dépendances.

## Analyse

```bash
flutter analyze
```

Lance l'analyse statique Dart/Flutter.

## Formatage

```bash
dart format .
```

Formate les fichiers Dart.

## Tests

```bash
flutter test
```

Lance les tests présents dans [test](../../../test/).

## Lancement local

Windows:

```bash
flutter run -d windows
```

Android:

```bash
flutter run -d android
```

Web:

```bash
flutter run -d chrome
```

## Build Android APK

```bash
flutter build apk --release
```

Génère un APK release.

Sur Windows, commande recommandée pour éviter le warning Java du launcher
Gradle et ranger les artefacts dans `dist/`:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_android_release.ps1
```

## Build Android APK par architecture

```bash
flutter build apk --release --split-per-abi
```

Génère des APK séparés par ABI. Utile pour réduire la taille installée.

Sur Windows, commande recommandée pour éviter le warning Java du launcher
Gradle et ranger les artefacts dans `dist/`:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_android_split_release.ps1
```

## Build Android App Bundle

```bash
flutter build appbundle --release
```

Génère un AAB pour Google Play lorsque la configuration locale le permet.

> Problème connu: sur l'environnement Windows utilisé pendant le développement,
> la génération AAB a déjà échoué sur le stripping de symboles natifs. Vérifier
> ce build avant toute publication Play Store.

## Build Windows

```bash
flutter build windows --release
```

Sortie attendue:

```text
build/windows/x64/runner/Release/
```

## Build complet organisé

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_full_release.ps1
```

Génère Windows, Android split APK, Web, puis collecte les fichiers dans:

```text
dist/latest/
dist/releases/<version-date>/
```

## Collecter les artefacts déjà générés

```powershell
powershell -ExecutionPolicy Bypass -File tools/collect_release_artifacts.ps1
```

À utiliser après un build manuel pour organiser les sorties dans `dist/`.

## Icônes d'application

```bash
dart run flutter_launcher_icons
```

Régénère les icônes à partir de la configuration `flutter_launcher_icons` dans
[pubspec.yaml](../../../pubspec.yaml).

## Splash screen

```bash
dart run flutter_native_splash:create
```

Régénère les écrans de démarrage à partir de
[flutter_native_splash.yaml](../../../flutter_native_splash.yaml).

## Installateur Windows

Après un build Windows release, compiler:

```bash
iscc installer/influencor.iss
```

Sortie attendue:

```text
build/installer/Influencor Setup.exe
```

## Nettoyage

```bash
flutter clean
```

Supprime les artefacts Flutter générés. Relancer ensuite `flutter pub get`.
