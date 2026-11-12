# Crédits des visuels Play Store

- `icone-512.png` : icône de l'app (`assets/icon/icon_blue.png`), 512 × 512, PNG 32 bits.
- `presentation-1024x500.png` : bannière bleue (logo, nom, slogan du site influencor-web,
  captures « iPhone 15 Pro Max » et Degany), PNG 24 bits sans transparence.
- Captures d'écran : vrais écrans de l'app, rendus par le moteur Flutter avec la police
  d'Android (Roboto), sur une copie de l'espace de travail « Pôma Original » du téléphone
  (photos, notes, tâches et comptabilité réelles). Seuls quelques favoris et la conversation
  Degany ont été ajoutés pour l'occasion. Cadres (téléphone, tablette, fenêtre, XR) dessinés
  en CSS aux couleurs du site.

Pour les refaire (voir [Publier sur Google Play](../play-store.md), section E) :

```powershell
# 1. Copier le dossier du téléphone dans build/store_shots/phone/Pôma Original
# 2. Captures brutes (build/store_shots/raw/)
flutter test tools/store_shots/store_shots_test.dart
# 3. Cadres, icône et bannière (ce dossier)
node tools/store_shots/play_store_shots.mjs
```

Sans copie du téléphone, l'étape 2 utilise un espace de démonstration inventé ; ses photos
viennent de `node tools/store_shots/make_photos.mjs`.
