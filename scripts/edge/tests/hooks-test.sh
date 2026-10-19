#!/bin/bash
# =============================================================================
# hooks-test.sh — teste le VRAI code des hooks de démarrage de CE projet
#
# Extrait les fonctions mi_kandra_* de start.sh (ou le bloc de
# scripts/init-letsencrypt.sh pour ArTest) et les exécute dans 4 situations :
# autonome, voisin sur 80/443, routeur actif, pannes (scripts absents, Docker
# introuvable). Vérifie surtout que le projet peut TOUJOURS démarrer seul.
#
# Sûr : refuse de tourner si un routeur existe ou si 80/443 sont occupés.
# Usage : bash scripts/edge/tests/hooks-test.sh      (depuis n'importe où)
# Code retour : 0 tout passe, 1 échec, 2 prérequis absents.
# =============================================================================
# Voulu : le code des hooks est « sourcé » dynamiquement (SC1090), PROJECT_ROOT est
# lu par ce code sourcé (SC2034) et PATH est volontairement vidé pour simuler
# l'absence de Docker (SC2123) ; les cd sont gardés par le sous-shell.
# shellcheck disable=SC1090,SC2034,SC2123,SC2164
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
native() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }
# shellcheck disable=SC1091
. "$ROOT/scripts/edge/project.env"; PROJ=${MI_KANDRA_PROJECT:-?}
if grep -q '^mi_kandra_edge_prepare()' "$ROOT/start.sh" 2>/dev/null; then SRC=start.sh; else SRC=init-letsencrypt.sh; fi

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "Docker indisponible" >&2; exit 2; }
if docker inspect mi-kandra-edge >/dev/null 2>&1; then echo "Un routeur mi-kandra-edge existe déjà : test refusé." >&2; exit 2; fi
if docker ps --format '{{.Ports}}' | grep -Eq ':(80|443)->'; then echo "80/443 sont occupés : test refusé." >&2; exit 2; fi
IMG="nginx:1.27.5-alpine"; docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG" >/dev/null 2>&1 || { echo "Image $IMG indisponible" >&2; exit 2; }

PASS=0; FAILN=0
# Attend (max 30 s) qu'un conteneur soit en marche : pas de « sleep N » fixe, trop court
# sur une machine ralentie.
wait_running() {
  ww_i=0
  while [ "$ww_i" -lt 60 ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ] && return 0
    ww_i=$((ww_i + 1)); sleep 0.5
  done
  return 1
}
check() { if [ "$2" = "$3" ]; then echo "   OK   $1"; PASS=$((PASS+1)); else echo "   FAIL $1 (obtenu='$2' attendu='$3')"; FAILN=$((FAILN+1)); fi; }
cleanup() {
  docker rm -f ktest-hold80 ktest-origin >/dev/null 2>&1
  docker compose -p mi-kandra-edge -f "$(native "$ROOT/scripts/edge")/edge-compose.yml" down >/dev/null 2>&1
  docker volume rm mi-kandra-edge-routes >/dev/null 2>&1; docker network rm mi-kandra-edge >/dev/null 2>&1
  rm -f "$HOOKS"
}
HOOKS=$(mktemp)
trap cleanup EXIT INT TERM

# --- extraction du code réel
if [ "$SRC" = "start.sh" ]; then
  { sed -n '/^mi_kandra_edge_prepare() {/,/^}/p' "$ROOT/start.sh"; sed -n '/^mi_kandra_edge_sync() {/,/^}/p' "$ROOT/start.sh"; } > "$HOOKS"
  PREP="mi_kandra_edge_prepare"; SYNC="mi_kandra_edge_sync"
else
  sed -n '/^# Cohabitation Mi Kandra/,/^}/p' "$ROOT/scripts/init-letsencrypt.sh" > "$HOOKS"
  PREP=":"; SYNC="mi_kandra_sync"
fi
echo "== $PROJ : $(wc -l < "$HOOKS") lignes de hook extraites de $SRC"
[ -s "$HOOKS" ] || { echo "   FAIL extraction vide"; exit 1; }

run() { # exécute les hooks dans un sous-shell propre
  ( PROJECT_ROOT="$ROOT"; log_ok() { echo "LOG:$*"; }; log() { echo "LOG:$*"; }
    unset MI_KANDRA_HTTP_PUBLISH MI_KANDRA_HTTPS_PUBLISH MI_KANDRA_EDGE_MODE
    cd "$ROOT" && . "$HOOKS" && eval "$1" )
}
labels="-l org.mi-kandra.role=origin -l org.mi-kandra.project=$PROJ -l org.mi-kandra.origin-alias=$PROJ-origin -l org.mi-kandra.domains=hooktest-$PROJ.example.com"
scenario='[ "'"$SRC"'" = start.sh ] && '"$PREP"'; echo "MODE=${MI_KANDRA_EDGE_MODE:-}"; echo "PUB=${MI_KANDRA_HTTP_PUBLISH:-}"; '"$SYNC"'; echo "SYNC_RC=$?"'

echo "-- S1 autonome (aucun routeur, 80/443 libres)"
out=$(run "$scenario" 2>&1)
[ "$SRC" = start.sh ] && check "mode standalone" "$(echo "$out" | sed -n 's/^MODE=//p')" "standalone"
check "aucune redirection de port" "$(echo "$out" | sed -n 's/^PUB=//p')" ""
check "sync sans effet (code 0)" "$(echo "$out" | sed -n 's/^SYNC_RC=//p')" "0"

echo "-- S2 un voisin occupe 80/443 (mode pending)"
docker run -d --name ktest-hold80 -p 80:80 -l org.mi-kandra.role=origin -l org.mi-kandra.project=autreprojet "$IMG" >/dev/null 2>&1; wait_running ktest-hold80
out=$(run "$scenario" 2>&1)
[ "$SRC" = start.sh ] && check "mode pending détecté" "$(echo "$out" | sed -n 's/^MODE=//p')" "pending"
check "ports redirigés en loopback" "$(echo "$out" | sed -n 's/^PUB=//p' | cut -d: -f1)" "127.0.0.1"
check "sync sans AUTOADOPT ne touche à rien (code 0)" "$(echo "$out" | sed -n 's/^SYNC_RC=//p')" "0"
check "le voisin tourne toujours, ports intacts" "$(docker ps --filter name=ktest-hold80 --format '{{.Ports}}' | grep -c '0.0.0.0:80->80')" "1"
docker rm -f ktest-hold80 >/dev/null 2>&1

echo "-- S3 routeur actif (mode shared) + enregistrement réel"
sh "$ROOT/scripts/edge/mi-kandra-edge.sh" ensure-edge >/dev/null 2>&1
# shellcheck disable=SC2086
docker run -d --name ktest-origin --network mi-kandra-edge --network-alias "$PROJ-origin" $labels "$IMG" >/dev/null 2>&1; wait_running ktest-origin
out=$(run "$scenario" 2>&1)
[ "$SRC" = start.sh ] && check "mode shared détecté" "$(echo "$out" | sed -n 's/^MODE=//p')" "shared"
check "ports en loopback" "$(echo "$out" | sed -n 's/^PUB=//p' | cut -d: -f1)" "127.0.0.1"
check "sync code 0" "$(echo "$out" | sed -n 's/^SYNC_RC=//p')" "0"
check "route enregistrée par le hook" "$(docker exec mi-kandra-edge sh -c "grep -c 'hooktest-$PROJ.example.com' /etc/mi-kandra-edge/routes.d/$PROJ.tls.map" 2>/dev/null)" "1"
check "routeur valide après enregistrement" "$(docker exec mi-kandra-edge nginx -t >/dev/null 2>&1 && echo ok)" "ok"

echo "-- S4 pannes : le projet doit TOUJOURS pouvoir démarrer seul"
out=$( ( PROJECT_ROOT=/chemin/inexistant; log_ok() { :; }; cd "$ROOT"; . "$HOOKS"; unset MI_KANDRA_EDGE_MODE; [ "$SRC" = start.sh ] && $PREP; $SYNC; echo "RC=$?" ) 2>&1 )
check "scripts/edge absent : code 0" "$(echo "$out" | sed -n 's/^RC=//p')" "0"
out=$( ( PROJECT_ROOT="$ROOT"; log_ok() { :; }; cd "$ROOT"; . "$HOOKS"; PATH=/nonexistent; unset MI_KANDRA_EDGE_MODE; [ "$SRC" = start.sh ] && $PREP; $SYNC; echo "RC=$?" ) 2>&1 )
check "docker introuvable : code 0" "$(echo "$out" | sed -n 's/^RC=//p')" "0"

echo "== $PROJ : $PASS OK, $FAILN FAIL"
[ "$FAILN" -eq 0 ]
