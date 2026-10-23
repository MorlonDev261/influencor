# Page de maintenance Cloudflare — Influencor (app web Flutter)

[← Documentation développeur](../README.md) · [Web Mi Kandra](./web-mi-kandra.md)

Quand le serveur ne répond plus (VPS éteint ou en redémarrage, routeur ou nginx arrêté), Cloudflare
affiche sa page « Error 521 / 522 ». Le Worker partagé `mi-kandra-maintenance` la remplace par une
page « Maintenance en cours » aux couleurs du site. Elle ne réessaie jamais seule : le visiteur clique « Réessayer
maintenant », qui vérifie le site et y retourne s'il répond.

Le code est dans [`scripts/edge/cloudflare/maintenance-worker/`](../../../scripts/edge/cloudflare/maintenance-worker/) : une copie
**identique** dans les 5 projets Mi Kandra. Le Worker est déployé **une seule fois** pour tous.

## Ce que voient les visiteurs d'Influencor (app web Flutter)

| Domaine | Page affichée pendant une panne | État |
|---|---|---|
| un sous-domaine de `mi-kandra.org` contenant « influencor » | Influencor : fond violet nuit, violet | actif s'il est Proxied |
| un autre sous-domaine de `mi-kandra.org` | « Mi Kandra » | actif s'il est Proxied |

| Requête pendant une panne | Réponse |
|---|---|
| Page web (navigation, envoi de formulaire) | page de maintenance, `503`, `Retry-After: 60` ; aucun essai automatique, bouton « Réessayer maintenant » |
| API / appli (`/api/…` ou `Accept: application/json`) | `503` JSON `{"error":"service_unavailable","retryAfter":60}` |
| Image, JS, CSS, téléchargement | l'erreur Cloudflare d'origine, inchangée |
| WebSocket | jamais intercepté |

**Ce qui ne change jamais :** tant que le serveur répond, ses vraies réponses passent intactes
(200, 404, 500, 502, la page 503 de maintenance du serveur…). Seuls les codes que Cloudflare
fabrique lui-même quand il ne joint pas le serveur (520 à 526, 530) sont remplacés.

## Particularités de ce projet

- **Aucun domaine par défaut.** `influencor.mi-kandra.org` sert maintenant le site vitrine (dépôt `influencor-web`, qui a sa propre page). L'app web Flutter n'a de page de maintenance que si elle est remise en ligne sur un `INFLUENCOR_DOMAIN`.
- **Dans une autre zone** que `mi-kandra.org` : ajoutez ses deux routes dans `wrangler.toml` et une entrée dans `BRANDS`, puis redéployez le Worker.
- **Application d'une seule page (SPA).** La navigation reçoit la page de maintenance. Les fichiers du build (`main.dart.js`, `.wasm`, polices) reçoivent l'erreur d'origine. Au retour du serveur, la page recharge l'app entière.
- **Nuage gris = pas de page.** En DNS only, le navigateur joint directement le VPS et affiche « site inaccessible » : choisissez Proxied (étape 1 de [web-mi-kandra.md](./web-mi-kandra.md)).

## Activer (une seule fois pour tous les projets)

1. **DNS** : le domaine doit être en **Proxied** (nuage orange), avec SSL/TLS en **Full (strict)**.
   En DNS only, le Worker ne voit jamais la requête.
2. **Déployer**, depuis n'importe quel dépôt Mi Kandra :
   ```bash
   cd scripts/edge/cloudflare/maintenance-worker
   npx wrangler@4 login
   npx wrangler@4 deploy
   ```
   Les routes (`poma-original.com`, `mga-follow-up.com`, `mi-kandra.org` et leurs sous-domaines)
   sont dans `wrangler.toml`. Le [README](../../../scripts/edge/cloudflare/maintenance-worker/README.md) explique aussi comment faire sans terminal.
3. **Quota gratuit (important)** : le Worker s'exécute sur chaque requête (100 000 par jour en
   offre gratuite). Dans **Workers Routes**, réglez chaque route sur **Fail open (proceed)** : si la
   limite est atteinte, le site continue de marcher sans la page. Routes **None** conseillées
   pour ce projet : `<INFLUENCOR_DOMAIN>/assets/*`.
4. **Vérifier sans couper le site** : enregistrement DNS de test **Proxied**
   `test-maintenance.mi-kandra.org` → `192.0.2.1` (adresse qui ne répond jamais), ouvrez-le
   (page « Mi Kandra », code 522 en bas), puis supprimez-le.

## Vérifier pendant une vraie panne

```bash
curl -sI https://<INFLUENCOR_DOMAIN>/ -H 'Accept: text/html' | grep -iE '^HTTP|x-mi-kandra-maintenance'
# HTTP/2 503 + x-mi-kandra-maintenance: 521  → la page de maintenance est servie
# pas d'en-tête x-mi-kandra-maintenance       → réponse du serveur, ou Worker inactif sur ce domaine
```

## Aperçu et tests en local

```bash
node --test scripts/edge/cloudflare/maintenance-worker/worker.test.mjs    # 16 tests rapides (Worker + script de la page), aucun réseau
node --test scripts/edge/cloudflare/maintenance-worker/workerd.test.mjs   # 3 tests dans le vrai moteur de Cloudflare (wrangler dev)
node scripts/edge/cloudflare/maintenance-worker/preview.mjs              # http://localhost:4410/?site=influencor
```

Dans l'aperçu, `/__origin/up` et `/__origin/down` rallument ou éteignent un faux serveur : la
page reste en maintenance jusqu'au clic sur « Réessayer maintenant », qui ramène au site.

## Modifier la page

Nom, couleurs et logo de chaque site sont dans `BRANDS`, en haut de `worker.js`. Après une
modification : relancer les tests, recopier le dossier à l'identique dans les 5 projets, puis
`npx wrangler@4 deploy`. Pour retirer la page : supprimer les routes (Workers Routes) ou
`npx wrangler@4 delete`.
