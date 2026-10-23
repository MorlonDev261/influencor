# Documentation Développeur

[← Retour à la documentation](../README.md)

Cette documentation explique le fonctionnement réel du projet Influencor pour
les développeurs qui doivent le maintenir, le modifier, le tester, le builder et
préparer des releases.

## Sections

- [Architecture](./architecture/overview.md)
- [Données et état](./architecture/data-and-state.md)
- [Navigation et routing](./architecture/routing.md)
- [Environnement de développement](./setup/development-environment.md)
- [Commandes du projet](./commands/project-commands.md)
- [Fonctionnalités](./features/README.md)
- [Tests](./tests.md)
- [Builds](./build/builds.md)
- [Signature et versioning](./release/signing-and-versioning.md)
- [Publier sur Google Play — de A à Z](./release/play-store.md)
- [Publier sur l'App Store — de A à Z](./release/app-store.md)
- [Publication](./deployment/publishing.md)
- [Web : app Flutter (retirée de influencor.mi-kandra.org)](./deployment/web-mi-kandra.md)
- [Page de maintenance Cloudflare](./deployment/page-maintenance-cloudflare.md)
- [`start.sh` : étapes et commandes](./deployment/start-sh.md)
- [Comptabilité, tâches et menu](./architecture/accounting-and-tasks.md)
- [Degany, l'assistant IA (agent)](./architecture/assistant.md)
- [Dépannage développeur](./troubleshooting/README.md)
- [Checklist de maintenance](./maintenance-checklist.md)

## Technologies réellement utilisées

- Flutter et Dart.
- Riverpod pour l'état.
- GoRouter pour la navigation.
- Fichiers locaux comme source de vérité.
- `share_plus` pour le partage natif.
- `desktop_drop` pour le glisser-déposer desktop.
- `media_kit` pour la prévisualisation vidéo.
- `super_clipboard` et `pasteboard` pour les opérations de copie avancées.

## Dossiers principaux

- [Application](../../lib/app/)
- [Core](../../lib/core/)
- [Features](../../lib/features/)
- [Tests](../../test/)
- [Android](../../android/)
- [Windows](../../windows/)
- [Installateur Windows](../../installer/)
- [Scripts](../../tools/)
