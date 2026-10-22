# Signature, Versioning Et Releases

[← Documentation développeur](../README.md)

## Version de l'application

La version est dans [pubspec.yaml](../../../pubspec.yaml):

```yaml
version: 1.0.0+1
```

Format Flutter:

- `1.0.0`: version visible;
- `+1`: build number.

## Modifier la version

1. Ouvrir [pubspec.yaml](../../../pubspec.yaml).
2. Modifier `version`.
3. Lancer:

```bash
flutter pub get
```

4. Rebuilder les artefacts nécessaires.

## Signature Android

La configuration release lit:

```text
android/key.properties
```

Ce fichier ne doit pas être committé.

Format attendu:

```properties
storePassword=<KEYSTORE_PASSWORD>
keyPassword=<KEY_PASSWORD>
keyAlias=<KEY_ALIAS>
storeFile=<PATH_TO_KEYSTORE>
```

Le fichier Gradle concerné:

- [android/app/build.gradle.kts](../../../android/app/build.gradle.kts)

Si `key.properties` n'existe pas, le build release utilise la signature debug.
Cela peut suffire pour tester localement, mais pas pour une distribution
officielle.

## Secrets

Ne jamais documenter ni committer:

- mots de passe keystore;
- clés privées;
- tokens;
- fichiers `.jks`;
- fichiers `key.properties` réels.

Utiliser uniquement des placeholders comme:

```text
<KEYSTORE_PASSWORD>
<KEY_ALIAS>
<SIGNING_KEY>
```

## Checklist release

- [ ] Version mise à jour dans `pubspec.yaml`.
- [ ] `flutter analyze` sans erreur.
- [ ] `flutter test` sans échec.
- [ ] APK ou build plateforme généré.
- [ ] Artefacts collectés dans `dist/latest/` et `dist/releases/<version-date>/`.
- [ ] Signature vérifiée si distribution externe.
- [ ] Test manuel du lancement.
- [ ] Test création note.
- [ ] Test import.
- [ ] Test partage image.
- [ ] Test corbeille.
- [ ] Documentation mise à jour.
