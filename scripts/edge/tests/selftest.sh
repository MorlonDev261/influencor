#!/bin/sh
# =============================================================================
# selftest.sh — auto-vérification du système de cohabitation (routeur + détection)
#
# Copie IDENTIQUE dans chaque projet. Démarre un VRAI routeur et deux faux projets
# jetables (nginx + certificats auto-signés), puis vérifie routage, isolation,
# refus des entrées hostiles et résilience. Nettoie tout à la fin.
#
# Sûr : REFUSE de tourner si un routeur existe déjà ou si 80/443 sont occupés
# (un serveur réel n'est jamais perturbé). Nécessite docker, curl, openssl.
# Attend (verrou tests/test-lock.sh) qu'un autre test du routeur ait fini.
#
# Usage : sh scripts/edge/tests/selftest.sh
# Code retour : 0 = tout passe, 1 = au moins un échec, 2 = prérequis absents.
# =============================================================================
set -u
MSYS_NO_PATHCONV=1; MSYS2_ARG_CONV_EXCL='*'; export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

HERE=$(cd "$(dirname "$0")" && pwd)
EDGE_DIR=$(cd "$HERE/.." && pwd)
# Fonction (et non variable) : le chemin du projet peut contenir des espaces ("Mi Kandra").
edge() { sh "$EDGE_DIR/mi-kandra-edge.sh" "$@"; }
IMG="nginx:1.27.5-alpine"
NET="mi-kandra-edge"; VOL="mi-kandra-edge-routes"

PASS=0; FAILN=0; DIAG_DONE=0

# Diagnostics affichés UNE fois, au premier échec : sans eux, un échec sur un runner
# de CI ne dit rien de la cause (DNS ? routage ? origin pas prêt ? bascule du routeur ?).
diag_once() {
  [ "$DIAG_DONE" -eq 0 ] || return 0; DIAG_DONE=1
  echo "   ---- diagnostics (premier échec) ----"
  echo "   conteneurs :"; docker ps -a --format '     {{.Names}} | {{.Status}} | {{.Ports}}' 2>&1 | grep -E 'selftest|mi-kandra' | head -8
  echo "   routes du routeur :"; docker exec mi-kandra-edge sh -c 'for f in /etc/mi-kandra-edge/routes.d/*.tls.map; do echo "     $f:"; sed "s/^/       /" "$f"; done' 2>&1 | head -12
  echo "   résolution depuis le routeur :"; for h in a-origin b-origin; do printf '     %s -> %s\n' "$h" "$(docker exec mi-kandra-edge getent hosts "$h" 2>&1 | head -1)"; done
  echo "   journal du routeur (15 dernières lignes) :"; docker logs --tail 15 mi-kandra-edge 2>&1 | sed 's/^/     /' | cut -c1-200
  echo "   journal de l'origin a (8 dernières lignes) :"; docker logs --tail 8 selftest-a 2>&1 | sed 's/^/     /' | cut -c1-200
  echo "   -------------------------------------"
}
check() { if [ "$2" = "$3" ]; then printf '   OK   %s\n' "$1"; PASS=$((PASS + 1)); else printf '   FAIL %s (obtenu=%s attendu=%s)\n' "$1" "$2" "$3"; FAILN=$((FAILN + 1)); diag_once; fi; }

# Attend (max 20 s) qu'une route enregistrée réponde, et AFFICHE le délai : un échec
# transitoire de la toute première connexion (DNS froid, bascule du routeur, origin
# pas encore prêt) est ainsi visible (WARN si > 3 s) sans faire échouer le test à tort ;
# une route qui ne répond jamais échoue, elle, bel et bien.
# $1 = domaine, $2 = libellé affiché (facultatif). Remplace TOUT « sleep N » : sur une
# machine ralentie (CI, Docker chargé) une durée fixe est trop courte, un état attendu non.
wait_route() {
  wr_label=${2:-"$1 : route active"}; wr_t0=$(date +%s); wr_i=0
  while [ "$wr_i" -lt 40 ]; do
    if [ "$(code "$1")" = "200" ]; then
      wr_d=$(( $(date +%s) - wr_t0 ))
      if [ "$wr_d" -gt 3 ]; then printf '   WARN %s (seulement après %ss)\n' "$wr_label" "$wr_d"; else printf '   OK   %s (%ss)\n' "$wr_label" "$wr_d"; fi
      PASS=$((PASS + 1)); return 0
    fi
    wr_i=$((wr_i + 1)); sleep 0.5
  done
  printf '   FAIL %s : toujours inactive après 20 s\n' "$wr_label"; FAILN=$((FAILN + 1)); diag_once; return 1
}

# Attend (max 30 s) qu'un conteneur soit en marche.
wait_running() {
  ww_i=0
  while [ "$ww_i" -lt 60 ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ] && return 0
    ww_i=$((ww_i + 1)); sleep 0.5
  done
  return 1
}
wait_edge_healthy() {
  wh_i=0
  while [ "$wh_i" -lt 60 ]; do
    [ "$(docker container inspect -f '{{.State.Health.Status}}' mi-kandra-edge 2>/dev/null)" = "healthy" ] && return 0
    wh_i=$((wh_i + 1)); sleep 0.5
  done
  return 1
}
native() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }
code() { curl -sk -m 10 -o /dev/null -w '%{http_code}' --resolve "$1:443:127.0.0.1" "https://$1/" 2>/dev/null; }
body() { curl -sk -m 10 --resolve "$1:443:127.0.0.1" "https://$1/" 2>/dev/null | tr -d '\r\n'; }

# Coupure vue par un visiteur : une sonde toutes les 0,2 s pendant une bascule,
# puis la plus longue période sans réponse 200 (du premier échec au retour).
now_ms() { d=$(date +%s%N 2>/dev/null); case "$d" in *N|'') echo $(( $(date +%s) * 1000 )) ;; *) echo $(( d / 1000000 )) ;; esac; }
probe_start() { # $1 domaine, $2 fichier
  rm -f "$2" "$2.stop"
  # -m 2 : une connexion suspendue ne doit pas gonfler la mesure de 10 s.
  ( while [ ! -f "$2.stop" ]; do
      printf '%s %s\n' "$(now_ms)" "$(curl -sk -m 2 -o /dev/null -w '%{http_code}' --resolve "$1:443:127.0.0.1" "https://$1/" 2>/dev/null)" >> "$2"
      sleep 0.2
    done ) &
  PROBE_PID=$!
}
probe_stop() { touch "$1.stop"; wait "$PROBE_PID" 2>/dev/null; }
longest_gap_ms() {
  awk 'BEGIN { s = -1; m = 0 }
       $2 != "200" { if (s < 0) s = $1; l = $1 }
       $2 == "200" { if (s >= 0) { if ($1 - s > m) m = $1 - s; s = -1 } }
       END { if (s >= 0 && l - s > m) m = l - s; print m }' "$1"
}
# Plafond de coupure : sous Linux, une bascule se mesure en centaines de ms (avant
# ces réglages, ~8 s en production) ; sous Docker Desktop (Git Bash ou WSL sous
# Windows), chaque commande docker coûte ~0,5 s et la même bascule prend 3 à 7 s.
# C'est le moteur qui décide : WSL répond « Linux » à uname mais parle à Docker
# Desktop. MI_KANDRA_TEST_MAX_GAP_MS le remplace.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) GAP_ENGINE="Docker Desktop" ;;
  *) GAP_ENGINE=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null) ;;
esac
case "$GAP_ENGINE" in
  *"Docker Desktop"*) GAP_MAX=${MI_KANDRA_TEST_MAX_GAP_MS:-12000} ;;
  *)                  GAP_MAX=${MI_KANDRA_TEST_MAX_GAP_MS:-3000} ;;
esac
# Coupure inférieure au plafond ? Affiche la mesure dans tous les cas.
check_gap() { # $1 libellé, $2 fichier, $3 plafond en ms
  cg=$(longest_gap_ms "$2")
  check "$1 : coupure de ${cg} ms (plafond $3 ms)" "$([ "$cg" -le "$3" ] && echo ok || echo "trop longue")" "ok"
}

for t in docker curl openssl; do command -v "$t" >/dev/null 2>&1 || { echo "Prérequis absent : $t" >&2; exit 2; }; done
docker info >/dev/null 2>&1 || { echo "Docker indisponible" >&2; exit 2; }
docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG" >/dev/null 2>&1 || { echo "Image $IMG indisponible" >&2; exit 2; }
# Verrou AVANT les contrôles : un autre test (hooks-test, selftest d'un autre dépôt)
# détruirait le routeur de celui-ci. Ctrl-C / kill passent par EXIT, qui le libère.
# shellcheck disable=SC1091
. "$HERE/test-lock.sh"
testlock_acquire "selftest $(basename "$(cd "$EDGE_DIR/../.." && pwd)")" || exit 2
trap testlock_release EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
if docker container inspect mi-kandra-edge >/dev/null 2>&1; then echo "Un routeur mi-kandra-edge existe déjà : test refusé pour ne pas perturber un serveur réel." >&2; exit 2; fi
if docker ps --format '{{.Ports}}' | grep -Eq ':(80|443)->'; then echo "80/443 sont occupés : test refusé." >&2; exit 2; fi

TMP=$(mktemp -d); TMPN=$(native "$TMP")
cleanup() {
  docker rm -f selftest-a selftest-b selftest-c selftest-d selftest-evil selftest-p53 sx-nginx-1 sy-nginx-1 >/dev/null 2>&1
  docker compose -p mi-kandra-edge -f "$(native "$EDGE_DIR")/edge-compose.yml" down >/dev/null 2>&1
  docker volume rm "$VOL" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap 'cleanup; testlock_release' EXIT

echo "== Préparation : certificats et faux projets"
# openssl reçoit un chemin natif (sous Git Bash, un chemin /tmp/... serait mal interprété).
for p in a b c d; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=selftest-$p.example.test" \
    -addext "subjectAltName=DNS:selftest-$p.example.test" -keyout "$TMPN/$p.key" -out "$TMPN/$p.crt" >/dev/null 2>&1
  cat > "$TMP/$p.conf" <<EOF
events {}
http {
  server {
    listen 8443 ssl proxy_protocol;
    listen 8080;
    ssl_certificate     /c/$p.crt;
    ssl_certificate_key /c/$p.key;
    location / { default_type text/plain; return 200 "origin-$p\n"; }
  }
}
EOF
done
docker network inspect "$NET" >/dev/null 2>&1 || docker network create --label "com.docker.compose.network=$NET" --label "com.docker.compose.project=mi-kandra-edge" "$NET" >/dev/null
start_origin() { # nom projet alias domaines
  docker run -d --name "$1" --network "$NET" --network-alias "$3" \
    -l org.mi-kandra.role=origin -l "org.mi-kandra.project=$2" -l "org.mi-kandra.origin-alias=$3" -l "org.mi-kandra.domains=$4" \
    -v "$TMPN/$2.conf:/etc/nginx/nginx.conf:ro" -v "$TMPN:/c:ro" "$IMG" >/dev/null 2>&1
}
start_origin selftest-a a a-origin selftest-a.example.test
start_origin selftest-b b b-origin selftest-b.example.test
wait_running selftest-a; wait_running selftest-b

echo "== 1) Routeur et enregistrement"
# ensure-edge rend la main dès que nginx répond ; Docker le déclare sain dans la
# foulée (start_interval 1s dans edge-compose.yml) : moins de 5 s exigées.
edge ensure-edge >/dev/null 2>&1; check "routeur démarré et prêt" "$?" "0"
hs_t0=$(now_ms); wait_edge_healthy
check "routeur déclaré sain par Docker en moins de 5 s" "$([ $(( $(now_ms) - hs_t0 )) -lt 5000 ] && docker container inspect -f '{{.State.Health.Status}}' mi-kandra-edge 2>/dev/null)" "healthy"
edge sync >/dev/null 2>&1; check "sync (code 0)" "$?" "0"
check "routes a et b enregistrées" "$(docker exec mi-kandra-edge sh -c 'ls /etc/mi-kandra-edge/routes.d/*.tls.map | wc -l' | tr -d ' \r')" "2"

echo "== 2) Routage et isolation entre projets"
wait_route selftest-a.example.test
wait_route selftest-b.example.test
check "HTTPS a -> origin a" "$(body selftest-a.example.test)" "origin-a"
check "HTTPS b -> origin b" "$(body selftest-b.example.test)" "origin-b"
check "sous-domaine de a -> a" "$(curl -sk -m 10 --resolve www.selftest-a.example.test:443:127.0.0.1 https://www.selftest-a.example.test/ 2>/dev/null | tr -d '\r\n')" "origin-a"
check "SNI inconnu refusé" "$(code inconnu.example.test)" "000"
# Journal du routeur lisible (sh mi-kandra-edge.sh logs) : la connexion routée et
# le refus ci-dessus y figurent, sans le doublon « connect() failed » d'error_log.
lg=$(NO_COLOR=1 edge logs --no-follow --tail 100 2>&1)
check "logs du routeur : connexion routée vers a" "$([ "$(printf '%s\n' "$lg" | grep -c 'selftest-a.example.test .*→ a-origin:8443')" -ge 1 ] && echo oui)" "oui"
check "logs du routeur : domaine inconnu refusé" "$(printf '%s\n' "$lg" | grep -c 'inconnu.example.test .*refusé (domaine inconnu)')" "1"
check "logs du routeur : pas de doublon d'erreur du refus" "$(printf '%s\n' "$lg" | grep -c 'connect() failed')" "0"
check "logs --refused : seulement les refus" "$(NO_COLOR=1 edge logs --no-follow --refused 2>&1 | grep -c '→')" "0"

echo "== 3) Entrées hostiles refusées, routeur intact"
docker run -d --name selftest-evil --network "$NET" -l org.mi-kandra.role=origin -l org.mi-kandra.project=evil -l org.mi-kandra.origin-alias=evil-origin -l org.mi-kandra.domains=selftest-a.example.test "$IMG" >/dev/null 2>&1
check "vol du domaine de a refusé" "$(edge sync 2>&1 | grep -c 'déjà routé par a')" "1"
docker rm -f selftest-evil >/dev/null 2>&1
docker run -d --name selftest-evil --network "$NET" -l org.mi-kandra.role=origin -l org.mi-kandra.project=evil -l org.mi-kandra.origin-alias=evil-origin -l 'org.mi-kandra.domains=x.com; } server { listen 1234;' "$IMG" >/dev/null 2>&1
check "injection nginx refusée" "$(edge sync 2>&1 | grep -c 'domaine invalide')" "1"
docker rm -f selftest-evil >/dev/null 2>&1
check "config du routeur toujours valide" "$(docker exec mi-kandra-edge nginx -t >/dev/null 2>&1 && echo ok)" "ok"
check "a et b toujours routés" "$(body selftest-a.example.test)/$(body selftest-b.example.test)" "origin-a/origin-b"

echo "== 4) Résilience"
docker stop selftest-a >/dev/null 2>&1
check "a arrêté : b inchangé" "$(body selftest-b.example.test)" "origin-b"
docker restart mi-kandra-edge >/dev/null 2>&1
wait_route selftest-b.example.test "routeur redémarré avec a absent : b répond"
docker start selftest-a >/dev/null 2>&1; wait_running selftest-a
wait_route selftest-a.example.test "a revenu : trafic rétabli sans toucher au routeur"

echo "== 5) Liste de domaines (org.mi-kandra.domains-file)"
# c : fichier seul, sans label de domaines (cas Influencor). d : label + fichier au
# format « domaine état » (cas Pôma) — le fichier AJOUTE au label.
mkdir -p "$TMP/dom-c" "$TMP/dom-d"
printf '%s\n' '# un domaine par ligne' selftest-c.example.test > "$TMP/dom-c/domains.list"
printf '%s\n' '# domaine état' 'extra-d.example.test active' > "$TMP/dom-d/domains.list"
docker run -d --name selftest-c --network "$NET" --network-alias c-origin \
  -l org.mi-kandra.role=origin -l org.mi-kandra.project=c -l org.mi-kandra.origin-alias=c-origin \
  -l org.mi-kandra.domains-file=/dom/domains.list \
  -v "$TMPN/c.conf:/etc/nginx/nginx.conf:ro" -v "$TMPN:/c:ro" -v "$TMPN/dom-c:/dom:ro" "$IMG" >/dev/null 2>&1
docker run -d --name selftest-d --network "$NET" --network-alias d-origin \
  -l org.mi-kandra.role=origin -l org.mi-kandra.project=d -l org.mi-kandra.origin-alias=d-origin \
  -l org.mi-kandra.domains=selftest-d.example.test -l org.mi-kandra.domains-file=/dom/domains.list \
  -v "$TMPN/d.conf:/etc/nginx/nginx.conf:ro" -v "$TMPN:/c:ro" -v "$TMPN/dom-d:/dom:ro" "$IMG" >/dev/null 2>&1
wait_running selftest-c; wait_running selftest-d
edge sync >/dev/null 2>&1; check "sync avec listes de domaines (code 0)" "$?" "0"
wait_route selftest-c.example.test "c : domaine lu dans le fichier, sans label"
wait_route selftest-d.example.test "d : domaine du label"
wait_route extra-d.example.test "d : domaine ajouté par le fichier (« domaine état »)"
check "d : domaine du fichier -> origin d" "$(body extra-d.example.test)" "origin-d"
# Fichier illisible (ici un dossier à sa place) : une erreur passagère ne doit
# retirer aucune route.
rm -f "$TMP/dom-c/domains.list"; mkdir "$TMP/dom-c/domains.list"
check "c : liste illisible -> routes conservées" "$(edge sync 2>&1 | grep -c 'c : routes actuelles conservées')" "1"
check "c : toujours routé" "$(body selftest-c.example.test)" "origin-c"
# Liste lue et vide, sans label : plus aucun domaine, routes retirées.
rmdir "$TMP/dom-c/domains.list"; printf '%s\n' '# plus aucun domaine' > "$TMP/dom-c/domains.list"
edge sync >/dev/null 2>&1; check "liste vide : sync (code 0)" "$?" "0"
check "c : liste vide -> routes retirées" "$(docker exec mi-kandra-edge sh -c '[ -f /etc/mi-kandra-edge/routes.d/c.tls.map ] && echo présentes || echo absentes')" "absentes"
check "c : SNI désormais refusé" "$(code selftest-c.example.test)" "000"
check "d inchangé" "$(body selftest-d.example.test)" "origin-d"
edge sync >/dev/null 2>&1; check "liste toujours vide : sync idempotent (code 0)" "$?" "0"
docker rm -f selftest-c selftest-d >/dev/null 2>&1; edge unregister d >/dev/null 2>&1

echo "== 6) doctor"
check "routeur sain avant doctor" "$(wait_edge_healthy && echo healthy)" "healthy"
edge doctor >/dev/null 2>&1; check "doctor (code 0)" "$?" "0"
out=$(edge doctor --probe 2>&1); rc=$?
check "doctor --probe (code 0)" "$rc" "0"
check "sonde HTTPS de a et b" "$(printf '%s\n' "$out" | grep -c 'répond en HTTPS')" "2"
check "alerte d'expiration du certificat (valide 2 jours)" "$(printf '%s\n' "$out" | grep -c 'expire dans moins de 21 jours')" "2"

echo "== 7) Ordre de démarrage : un projet seul, puis un voisin (dans les deux sens)"
# Deux faux projets Compose (x, y) qui publient 80/443 seuls, comme un vrai projet en
# mode autonome. start_fake rejoue le hook de démarrage des projets : choose, env,
# docker compose up, puis sync (shared) ou adopt (pending + MI_KANDRA_EDGE_AUTOADOPT=1).
# Sans terminal (stdin fermé), comme un déploiement automatisé.
docker rm -f selftest-a selftest-b >/dev/null 2>&1
docker compose -p mi-kandra-edge -f "$(native "$EDGE_DIR")/edge-compose.yml" down >/dev/null 2>&1
docker volume rm "$VOL" >/dev/null 2>&1
for p in x y; do
  mkdir -p "$TMP/proj-$p"
  cat > "$TMP/proj-$p/nginx.conf" <<EOF
events {}
http {
  server {
    listen 80; listen 443 ssl; listen 8080; listen 8443 ssl proxy_protocol;
    ssl_certificate     /c/a.crt;
    ssl_certificate_key /c/a.key;
    location / { default_type text/plain; return 200 "origin-$p\n"; }
  }
}
EOF
  dp=$([ "$p" = x ] && echo 7 || echo 8)
  cat > "$TMP/proj-$p/compose.yaml" <<EOF
services:
  nginx:
    image: $IMG
    labels:
      org.mi-kandra.role: origin
      org.mi-kandra.project: $p
      org.mi-kandra.origin-alias: $p-origin
      org.mi-kandra.domains: selftest-$p.example.test
      org.mi-kandra.edge-capable: "1"
      org.mi-kandra.diag-http: "1809$dp"
      org.mi-kandra.diag-https: "1849$dp"
    ports:
      - "\${MI_KANDRA_HTTP_PUBLISH:-0.0.0.0:80:80}"
      - "\${MI_KANDRA_HTTPS_PUBLISH:-0.0.0.0:443:443}"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - $TMPN:/c:ro
    networks:
      mi-kandra-edge:
        aliases: [$p-origin]
# Même clé que les vrais projets : le label com.docker.compose.network doit
# correspondre, quel que soit le projet qui crée le réseau en premier.
networks:
  mi-kandra-edge:
    name: $NET
EOF
done
start_fake() { # x|y — affiche le mode retenu
  (
    cd "$TMP/proj-$1" || exit 1
    # Ce que project.env fixe dans un vrai projet : nom et ports de diagnostic propres.
    dp=$([ "$1" = x ] && echo 7 || echo 8)
    MI_KANDRA_PROJECT=$1 MI_KANDRA_DIAG_HTTP=1809$dp MI_KANDRA_DIAG_HTTPS=1849$dp MI_KANDRA_COMPOSE_PROJECT=s$1
    MI_KANDRA_EDGE_PREF_FILE="$TMP/proj-$1/.mi-kandra-edge.pref"
    export MI_KANDRA_PROJECT MI_KANDRA_DIAG_HTTP MI_KANDRA_DIAG_HTTPS MI_KANDRA_COMPOSE_PROJECT MI_KANDRA_EDGE_PREF_FILE
    edge choose </dev/null >/dev/null 2>&1
    eval "$(edge env 2>/dev/null)"
    docker compose -p "s$1" -f "$(native "$TMP/proj-$1")/compose.yaml" up -d >/dev/null 2>&1
    case "${MI_KANDRA_EDGE_MODE:-standalone}" in
      shared) edge sync >/dev/null 2>&1 ;;
      pending) [ "${MI_KANDRA_EDGE_AUTOADOPT:-0}" = "1" ] && edge adopt --yes >/dev/null 2>&1 ;;
    esac
    echo "${MI_KANDRA_EDGE_MODE:-standalone}"
  )
}
pref_of() { sed -n 's/^MI_KANDRA_EDGE_PREF=//p' "$TMP/proj-$1/.mi-kandra-edge.pref" 2>/dev/null; }
reset_fakes() {
  docker rm -f sx-nginx-1 sy-nginx-1 >/dev/null 2>&1
  docker compose -p mi-kandra-edge -f "$(native "$EDGE_DIR")/edge-compose.yml" down >/dev/null 2>&1
  docker volume rm "$VOL" >/dev/null 2>&1
  rm -f "$TMP/proj-x/.mi-kandra-edge.pref" "$TMP/proj-y/.mi-kandra-edge.pref"
}

echo "   -- x d'abord, puis y (choix « cohabiter » mémorisé chez y)"
check "x seul : mode autonome" "$(start_fake x)" "standalone"
wait_route selftest-x.example.test "x seul : public en direct"
check "y sans choix ni terminal : reste local" "$(start_fake y)" "pending"
check "y sans choix : pas public" "$(body selftest-y.example.test)" "origin-x"
printf 'MI_KANDRA_EDGE_PREF=cohabit\n' > "$TMP/proj-y/.mi-kandra-edge.pref"
# x reste servi pendant sa propre conversion, à une courte coupure près : le
# routeur est créé d'avance et ses routes posées dès qu'il répond.
probe_start selftest-x.example.test "$TMP/probe-adopt"
check "y relancé avec « cohabiter » : x converti, y partagé" "$(start_fake y)" "shared"
wait_route selftest-x.example.test "x via le routeur (sonde)"
probe_stop "$TMP/probe-adopt"
check_gap "conversion de x" "$TMP/probe-adopt" "$GAP_MAX"
check "routeur démarré par la conversion" "$(wait_edge_healthy && echo healthy)" "healthy"
wait_route selftest-x.example.test "x via le routeur"
wait_route selftest-y.example.test "y via le routeur"
check "x et y chacun chez soi" "$(body selftest-x.example.test)/$(body selftest-y.example.test)" "origin-x/origin-y"
check "x converti : « cohabiter » mémorisé chez lui" "$(pref_of x)" "cohabit"
check "x relancé : partagé, sans question" "$(start_fake x)" "shared"
check "x et y toujours routés" "$(body selftest-x.example.test)/$(body selftest-y.example.test)" "origin-x/origin-y"

reset_fakes
echo "   -- y d'abord, puis x (MI_KANDRA_EDGE_AUTOADOPT=1, sans choix mémorisé)"
check "y seul : mode autonome" "$(start_fake y)" "standalone"
wait_route selftest-y.example.test "y seul : public en direct"
check "x avec AUTOADOPT : démarre en local puis convertit y" "$(MI_KANDRA_EDGE_AUTOADOPT=1 start_fake x)" "pending"
check "routeur démarré par la conversion" "$(wait_edge_healthy && echo healthy)" "healthy"
wait_route selftest-x.example.test "x via le routeur"
wait_route selftest-y.example.test "y via le routeur"
check "x et y chacun chez soi" "$(body selftest-x.example.test)/$(body selftest-y.example.test)" "origin-x/origin-y"
check "« cohabiter » mémorisé chez x et chez y" "$(pref_of x)/$(pref_of y)" "cohabit/cohabit"
check "y relancé : partagé, sans question" "$(start_fake y)" "shared"
reset_fakes

echo "== 8) Le routeur ne démarre pas pendant la conversion : retour arrière"
# Un ancien conteneur arrêté garde le nom mi-kandra-edge : `docker compose up` du
# routeur échoue après la conversion de x. x doit reprendre 80/443 seul.
check "x seul : mode autonome" "$(start_fake x)" "standalone"
wait_route selftest-x.example.test "x seul : public en direct"
docker create --name mi-kandra-edge "$IMG" >/dev/null 2>&1
printf 'MI_KANDRA_EDGE_PREF=cohabit\n' > "$TMP/proj-y/.mi-kandra-edge.pref"
check "y : conversion échouée, reste local" "$(start_fake y)" "pending"
wait_route selftest-x.example.test "x a repris 80/443"
check "x publie de nouveau 80/443" "$(docker port sx-nginx-1 443/tcp 2>/dev/null | grep -c '^0\.0\.0\.0:443$')" "1"
check "x : choix « cohabiter » posé par la conversion retiré" "$(pref_of x)" ""
check "y : choix « cohabiter » conservé" "$(pref_of y)" "cohabit"
docker rm -f mi-kandra-edge >/dev/null 2>&1
check "obstacle levé, y relancé : x converti, y partagé" "$(start_fake y)" "shared"
wait_route selftest-x.example.test "x via le routeur"
wait_route selftest-y.example.test "y via le routeur"
reset_fakes

echo "== 9) Port fixe de l'hôte (check-port, ex. acme-dns sur 53/udp)"
# Port de test plutôt que 53 : sur le poste de développement, 53 peut déjà servir.
TP=15353
check "port libre : code 0" "$(edge check-port $TP udp >/dev/null 2>&1; echo $?)" "0"
docker run -d --name selftest-p53 -p "127.0.0.1:$TP:53/udp" -l com.docker.compose.project=autreprojet "$IMG" >/dev/null 2>&1
wait_running selftest-p53
out=$(edge check-port $TP udp 2>&1); rc=$?
check "tenu par un autre projet : code 1" "$rc" "1"
check "le détenteur est nommé" "$(printf '%s\n' "$out" | grep -c "selftest-p53 (projet autreprojet)")" "1"
check "tenu par ce projet : code 0" "$(MI_KANDRA_COMPOSE_PROJECT=autreprojet edge check-port $TP udp >/dev/null 2>&1; echo $?)" "0"
check "même numéro en tcp : libre" "$(edge check-port $TP tcp >/dev/null 2>&1; echo $?)" "0"
check "argument invalide : code 64" "$(edge check-port abc >/dev/null 2>&1; echo $?)" "64"
docker rm -f selftest-p53 >/dev/null 2>&1

echo "== 10) Retour au mode autonome (release)"
check "x seul : mode autonome" "$(start_fake x)" "standalone"
wait_route selftest-x.example.test "x seul : public en direct"
printf 'MI_KANDRA_EDGE_PREF=cohabit\n' > "$TMP/proj-y/.mi-kandra-edge.pref"
check "y arrive : x converti, y partagé" "$(start_fake y)" "shared"
wait_route selftest-x.example.test "x via le routeur"
check "deux projets derrière le routeur : release refusé" "$(edge release >/dev/null 2>&1; echo $?)" "1"
check "release refusé : routeur toujours là" "$(docker container inspect -f '{{.State.Running}}' mi-kandra-edge 2>/dev/null)" "true"
docker rm -f sy-nginx-1 >/dev/null 2>&1
probe_start selftest-x.example.test "$TMP/probe-release"
check "un seul projet : release (code 0)" "$(edge release >/dev/null 2>&1; echo $?)" "0"
wait_route selftest-x.example.test "x reprend 80/443 en direct"
probe_stop "$TMP/probe-release"
check_gap "retour au mode autonome" "$TMP/probe-release" "$GAP_MAX"
check "routeur retiré" "$(docker container inspect mi-kandra-edge >/dev/null 2>&1 && echo présent || echo absent)" "absent"
check "volume des routes retiré" "$(docker volume inspect "$VOL" >/dev/null 2>&1 && echo présent || echo absent)" "absent"
check "réseau partagé conservé (x y reste rattaché)" "$(docker network inspect "$NET" >/dev/null 2>&1 && echo présent || echo absent)" "présent"
check "x publie de nouveau 80/443" "$(docker port sx-nginx-1 443/tcp 2>/dev/null | grep -c '^0\.0\.0\.0:443$')" "1"
check "x répond en direct" "$(body selftest-x.example.test)" "origin-x"
check "release sans routeur : rien à faire (code 0)" "$(edge release >/dev/null 2>&1; echo $?)" "0"
reset_fakes

echo
echo "Résultat : $PASS OK, $FAILN FAIL"
[ "$FAILN" -eq 0 ]
