# Page de maintenance Mi Kandra (Worker Cloudflare)

Quand le VPS ne répond plus (éteint, redémarrage, routeur arrêté), Cloudflare affiche sa page
« Error 521 / 522 ». Ce Worker la remplace par une page aux couleurs du site. Elle ne réessaie
jamais seule : le bouton « Réessayer maintenant » vérifie le site et y retourne s'il répond. Tant que le serveur répond, **rien ne change** : ses vraies
réponses (200, 404, la page 503 de maintenance nginx pendant un déploiement…) passent intactes.

| Requête pendant une panne | Réponse |
|---|---|
| Page web (navigation, formulaire) | page de maintenance du site, `503`, `Retry-After: 60` |
| API / appli (`/api/…` ou `Accept: application/json`) | `503` JSON `{"error":"service_unavailable", "retryAfter":60}` |
| Image, JS, CSS | l'erreur Cloudflare d'origine, inchangée |
| WebSocket | jamais intercepté |

Sites reconnus (nom, couleurs, logo dans `BRANDS` en haut de `worker.js`) : Pôma Original
(`*.poma-original.com`), MGA Follow-up (`*.mga-follow-up.com`), Influencor
(`influencor*.mi-kandra.org`), Mi Kandra Developers (`developers.mi-kandra.org`), et
« Mi Kandra » pour tout le reste.

> Un domaine en **DNS only (nuage gris)** ne passe pas par Cloudflare : le Worker ne le voit
> jamais et le navigateur affiche « site inaccessible ». C'est le cas aujourd'hui de
> `influencor.mi-kandra.org` → passez-le en **Proxied (nuage orange)** d'abord (étape 1).

## Activer

### 1. Mettre les domaines derrière Cloudflare
Cloudflare → domaine `mi-kandra.org` → **DNS** → enregistrement `influencor` → **Proxied**.
Vérifiez **SSL/TLS → Overview = Full (strict)** (le certificat Let's Encrypt du serveur convient).
Les autres domaines (Pôma, developers) sont déjà en nuage orange.

### 2. Déployer le Worker (une seule fois, depuis n'importe quel dépôt)
```bash
cd scripts/edge/cloudflare/maintenance-worker
npx wrangler@4 login
npx wrangler@4 deploy
```
`wrangler.toml` crée les routes `poma-original.com/*`, `*.poma-original.com/*`,
`mga-follow-up.com/*`, `*.mga-follow-up.com/*`, `mi-kandra.org/*` et `*.mi-kandra.org/*`.
Un domaine absent de votre compte Cloudflare fait échouer le déploiement : retirez ses deux
lignes de `routes`.

Sans terminal : **Workers & Pages → Create → Worker** (« Hello world »), nommez-le
`mi-kandra-maintenance`, **Edit code**, collez tout `worker.js`, **Deploy** ; puis
**Settings → Domains & Routes → Add → Route** pour chacune des six routes ci-dessus.

### 3. Régler la limite gratuite (important)
Le Worker s'exécute sur **chaque** requête de ces domaines, pas seulement pendant une panne.
L'offre gratuite inclut 100 000 requêtes par jour. Pour chaque domaine, dans
**Workers Routes**, choisissez le mode **Fail open (proceed)** : si la limite est atteinte,
les requêtes vont directement au serveur (le site marche, seule la page de maintenance manque
jusqu'au lendemain). Ne laissez pas « Fail closed », qui bloquerait les visiteurs.

Pour économiser des requêtes, ajoutez des routes **sans Worker** (« None ») sur les fichiers
lourds, qui n'ont jamais besoin de la page : par exemple `poma-original.com/_next/static/*`,
`poma-original.com/models/*`, `uploads.poma-original.com/*`. La route la plus précise gagne.
Suivez le volume dans **Workers & Pages → mi-kandra-maintenance → Metrics**.

### 4. Vérifier sans couper de site
Créez un enregistrement DNS de test **Proxied** qui pointe vers une adresse qui ne répond
jamais :

| Type | Nom | Contenu | Proxy |
|---|---|---|---|
| A | `test-maintenance` (dans `mi-kandra.org`) | `192.0.2.1` | Proxied |

Ouvrez `https://test-maintenance.mi-kandra.org/` : la page « Maintenance en cours — Mi Kandra »
doit s'afficher (code 522 en bas), et
`curl -sI https://test-maintenance.mi-kandra.org/ -H 'Accept: text/html'` doit montrer
`HTTP/2 503` et `x-mi-kandra-maintenance: 522`. Supprimez ensuite l'enregistrement.

## Désactiver
Retirez les routes (Workers Routes) ou `npx wrangler@4 delete`. Cloudflare réaffiche alors
ses propres pages d'erreur.

## Développer
```bash
node --test scripts/edge/cloudflare/maintenance-worker/worker.test.mjs   # 16 tests rapides, aucun réseau
node --test scripts/edge/cloudflare/maintenance-worker/workerd.test.mjs  # 3 tests dans le vrai moteur de Cloudflare (wrangler dev)
node scripts/edge/cloudflare/maintenance-worker/preview.mjs              # aperçu : http://localhost:4410/?site=poma|mga|influencor|developers
```
- `worker.test.mjs` : le Worker (réponses transmises ou remplacées, JSON, HEAD, formulaires,
  WebSocket, nom et couleurs de chaque site) et le **script de la page**, exécuté dans un faux
  navigateur : aucun essai automatique (ni minuterie, ni `<meta refresh>`), vérification en
  HEAD au clic, message « Toujours indisponible », un seul appel à la fois, retour à la même
  adresse en GET.
- `workerd.test.mjs` : lance `wrangler dev` (le moteur workerd de Cloudflare) devant un faux
  serveur local, puis l'éteint : réponses transmises, erreurs 521/522 remplacées, serveur
  injoignable (code 520) puis retour du site. Il télécharge `wrangler@4` au premier lancement
  (~1 min) et il est **sauté**, avec la raison, sans réseau ou sans certificats racine (image
  Docker minimale : prendre `node:22-bookworm`, pas `-slim`).
Dans l'aperçu, `/__origin/up` et `/__origin/down` rallument ou éteignent le faux serveur :
la page ouverte reste en maintenance jusqu'au clic sur « Réessayer maintenant », qui ramène
au site s'il répond.
Copie identique dans les 5 dépôts : après une modification, recopiez le dossier partout.
