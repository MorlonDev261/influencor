# Web — app Flutter (retirée de influencor.mi-kandra.org)

[← Documentation développeur](../README.md)

> **Retirée de `influencor.mi-kandra.org`.** Ce domaine sert désormais le site vitrine et
> les téléchargements (dépôt [`influencor-web`](https://github.com/MorlonDev261/influencor-web)).
> L'app web Flutter n'est plus déployée par défaut : `start.sh` refuse de démarrer tant que
> `INFLUENCOR_DOMAIN` est vide ou vaut `influencor.mi-kandra.org`. Sur un serveur où elle
> tourne encore : `./start.sh --stop`, puis lancer `influencor-web`.

Le build web Flutter (`build/web`) est servi par un nginx Docker « origin » Mi Kandra,
comme `poma-original` et `mga-follow-up-v1` : mêmes scripts `scripts/edge/`, mêmes labels
`org.mi-kandra.*`, même cohabitation sur un serveur.

| Élément | Valeur |
|---|---|
| Domaine | aucun par défaut (variable `INFLUENCOR_DOMAIN`, autre que `influencor.mi-kandra.org`) |
| Projet / alias origin | `influencor` / `influencor-origin` |
| Ports de diagnostic (loopback) | `18084` (HTTP) · `18447` (HTTPS) |
| Projet Compose | `influencor` |

## Fichiers

* `docker-compose.yml` — nginx durci (read-only, capacités réduites), labels Mi Kandra.
* `nginx/templates/influencor.conf.template` — vhost (HTTP→HTTPS, cache, repli SPA sur `index.html`).
* `nginx/snippets/` — IP réelle (routeur + Cloudflare) et TLS, identiques aux autres projets.
* `nginx/certs/` — `fullchain.pem` + `privkey.pem` (jamais versionnés).
* `scripts/edge/` — copie identique des autres projets ; seul `project.env` diffère.
* `start.sh` — démarrage (`--build`, `--stop`, `--status`).
* `.env.example` — `INFLUENCOR_DOMAIN` (vide par défaut), chemins des certificats.

## Mise en service (sur un autre domaine)

1. **Cloudflare — DNS** : zone `mi-kandra.org`, enregistrement du sous-domaine choisi (A vers l'IP du VPS, ou le
   même que Pôma), nuage orange accepté.
2. **Cloudflare — SSL/TLS** : mode **Full (strict)**. Créer un *Origin Certificate* pour
   ce domaine (ou `*.mi-kandra.org`) et le déposer dans `nginx/certs/`
   (`fullchain.pem`, `privkey.pem`, droits 600).
3. Sur le serveur : `./start.sh --build` (ou copier un `build/web` déjà construit), puis `./start.sh`.
4. Cohabitation avec Pôma/MGA : `start.sh` pose la question une fois (`choose`). Si 80/443 sont pris :
   `sh scripts/edge/mi-kandra-edge.sh adopt --yes`. Seul, le nginx publie 80/443 lui-même (mode autonome).

## Vérification

```bash
sh scripts/edge/mi-kandra-edge.sh doctor --probe   # mode, routes, certificat
sh scripts/edge/mi-kandra-dns.sh probe <INFLUENCOR_DOMAIN>         # chemin réel d'un visiteur
sh scripts/edge/mi-kandra-cfips.sh update          # plages IP Cloudflare à jour
sh scripts/edge/mi-kandra-audit.sh
```

## Logs

`./start.sh --logs` ne montre que le trafic de ce projet, mis en forme par `scripts/logs-view.sh`
et `scripts/logs-pretty.awk` (copies identiques dans chaque projet) :

- le trafic qui ne vise aucun de ses domaines (scanners, domaine d'un voisin dont le DNS pointe
  déjà ici) est marqué `mk-unmatched`, masqué et compté à la fin ; `--logs --scans` le montre ;
- la routine (sondages réussis, sauvegardes…) est masquée avec un total ; `--logs --all` montre tout ;
- les scans du vrai domaine (`/.env`, `/phpinfo`, `wp-*`…) sont coupés par nginx avant le site,
  sans journal (`nginx/snippets/mi-kandra-scan-block.conf`).

Journal du routeur partagé : `sh scripts/edge/mi-kandra-edge.sh logs` (`--since 1h`,
`--no-follow`, `--refused` pour les domaines inconnus et les projets injoignables).

## Tests du routeur

```bash
sh scripts/edge/tests/selftest.sh       # vrai routeur + faux projets jetables (HORS production : refuse si 80/443 sont pris)
bash scripts/edge/tests/hooks-test.sh   # vrai code de cohabitation de start.sh
sh scripts/edge/tests/lock-test.sh      # verrou entre les deux tests ci-dessus
```

Les deux premiers détruisent le routeur à la fin : un verrou partagé (`tests/test-lock.sh`,
conteneur jamais démarré `mi-kandra-edge-testlock`) les empêche de tourner en même temps, même
depuis deux dépôts. Le second attend (`MI_KANDRA_TEST_LOCK_WAIT`, 900 s par défaut ; 0 = refus
immédiat, code 2).

## Page de maintenance

Quand le serveur ne répond pas, un Worker Cloudflare partagé affiche une page aux couleurs
d'Influencor à la place de l'erreur 521 : voir [page-maintenance-cloudflare.md](./page-maintenance-cloudflare.md).
Elle ne s'applique que si l'app web est en ligne sur un `INFLUENCOR_DOMAIN` en nuage orange.

Voir aussi la documentation Mi Kandra de `poma-original`
(`docs/07-deployment/mi-kandra-multi-stack.md`, `dns-cloudflare-registrar.md`).
