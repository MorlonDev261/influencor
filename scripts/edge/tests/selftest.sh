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
native() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }
code() { curl -sk -m 10 -o /dev/null -w '%{http_code}' --resolve "$1:443:127.0.0.1" "https://$1/" 2>/dev/null; }
body() { curl -sk -m 10 --resolve "$1:443:127.0.0.1" "https://$1/" 2>/dev/null | tr -d '\r\n'; }

for t in docker curl openssl; do command -v "$t" >/dev/null 2>&1 || { echo "Prérequis absent : $t" >&2; exit 2; }; done
docker info >/dev/null 2>&1 || { echo "Docker indisponible" >&2; exit 2; }
if docker inspect mi-kandra-edge >/dev/null 2>&1; then echo "Un routeur mi-kandra-edge existe déjà : test refusé pour ne pas perturber un serveur réel." >&2; exit 2; fi
if docker ps --format '{{.Ports}}' | grep -Eq ':(80|443)->'; then echo "80/443 sont occupés : test refusé." >&2; exit 2; fi
docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG" >/dev/null 2>&1 || { echo "Image $IMG indisponible" >&2; exit 2; }

TMP=$(mktemp -d); TMPN=$(native "$TMP")
cleanup() {
  docker rm -f selftest-a selftest-b selftest-evil >/dev/null 2>&1
  docker compose -p mi-kandra-edge -f "$(native "$EDGE_DIR")/edge-compose.yml" down >/dev/null 2>&1
  docker volume rm "$VOL" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

echo "== Préparation : certificats et deux faux projets"
# openssl reçoit un chemin natif (sous Git Bash, un chemin /tmp/... serait mal interprété).
for p in a b; do
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
edge ensure-edge >/dev/null 2>&1; check "routeur démarré et sain" "$(docker inspect -f '{{.State.Health.Status}}' mi-kandra-edge 2>/dev/null)" "healthy"
edge sync >/dev/null 2>&1; check "sync (code 0)" "$?" "0"
check "routes a et b enregistrées" "$(docker exec mi-kandra-edge sh -c 'ls /etc/mi-kandra-edge/routes.d/*.tls.map | wc -l' | tr -d ' \r')" "2"

echo "== 2) Routage et isolation entre projets"
wait_route selftest-a.example.test
wait_route selftest-b.example.test
check "HTTPS a -> origin a" "$(body selftest-a.example.test)" "origin-a"
check "HTTPS b -> origin b" "$(body selftest-b.example.test)" "origin-b"
check "sous-domaine de a -> a" "$(curl -sk -m 10 --resolve www.selftest-a.example.test:443:127.0.0.1 https://www.selftest-a.example.test/ 2>/dev/null | tr -d '\r\n')" "origin-a"
check "SNI inconnu refusé" "$(code inconnu.example.test)" "000"

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

echo "== 5) doctor"
edge doctor >/dev/null 2>&1; check "doctor (code 0)" "$?" "0"
out=$(edge doctor --probe 2>&1); rc=$?
check "doctor --probe (code 0)" "$rc" "0"
check "sonde HTTPS de a et b" "$(printf '%s\n' "$out" | grep -c 'répond en HTTPS')" "2"
check "alerte d'expiration du certificat (valide 2 jours)" "$(printf '%s\n' "$out" | grep -c 'expire dans moins de 21 jours')" "2"

echo
echo "Résultat : $PASS OK, $FAILN FAIL"
[ "$FAILN" -eq 0 ]
