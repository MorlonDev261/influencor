#!/bin/sh
# =============================================================================
# lock-test.sh — teste le verrou partagé des tests du routeur (tests/test-lock.sh)
#
# Copie IDENTIQUE dans chaque projet. Vérifie qu'un second test est refusé ou
# attend, que selftest.sh et hooks-test.sh respectent le verrou sans toucher au
# routeur de l'autre, qu'un verrou orphelin est repris, et qu'un test arrêté
# (kill) libère le verrou et nettoie.
#
# Sûr sur un serveur réel : ne crée jamais de routeur ; les scénarios qui lancent
# hooks-test.sh en entier sont sautés si un routeur existe ou si 80/443 sont pris.
# Usage : sh scripts/edge/tests/lock-test.sh
# Code retour : 0 tout passe, 1 échec, 2 prérequis absents.
# =============================================================================
set -u
MSYS_NO_PATHCONV=1; MSYS2_ARG_CONV_EXCL='*'; export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

HERE=$(cd "$(dirname "$0")" && pwd)
IMG="nginx:1.27.5-alpine"
PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then printf '   OK   %s\n' "$1"; PASS=$((PASS + 1)); else printf '   FAIL %s (obtenu=%s attendu=%s)\n' "$1" "$2" "$3"; FAILN=$((FAILN + 1)); fi; }
lock_id() { docker container inspect -f '{{.Id}}' mi-kandra-edge-testlock 2>/dev/null; }
# Exécute $1 dans un AUTRE processus (pas un sous-shell : $$ y resterait celui de ce script).
other() { sh -c '. "$1"; IMG="$2"; eval "$3"' other "$HERE/test-lock.sh" "$IMG" "$1"; }
# Pose un verrou « étranger » : $1 pid, $2 espace de PID, $3 date de prise (epoch).
fake_lock() {
  docker create --name mi-kandra-edge-testlock -l org.mi-kandra.testlock.owner=faux \
    -l "org.mi-kandra.testlock.pid=$1" -l "org.mi-kandra.testlock.ns=$2" \
    -l "org.mi-kandra.testlock.since=$3" "$IMG" true >/dev/null 2>&1
}

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "Docker indisponible" >&2; exit 2; }
docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG" >/dev/null 2>&1 || { echo "Image $IMG indisponible" >&2; exit 2; }
if [ -n "$(lock_id)" ]; then echo "Un test du routeur tourne déjà (verrou présent) : test refusé." >&2; exit 2; fi
FREE=1
docker container inspect mi-kandra-edge >/dev/null 2>&1 && FREE=0
docker ps --format '{{.Ports}}' | grep -Eq ':(80|443)->' && FREE=0

# shellcheck disable=SC1091
. "$HERE/test-lock.sh"
TMP=$(mktemp -d)
cleanup() { docker rm -f mi-kandra-edge-testlock >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
NS=$(testlock_ns)

echo "== 1) Prise et refus"
testlock_acquire "lock-test"; check "verrou pris" "$?" "0"
held=$(lock_id)
check "verrou à notre nom (pid $$)" "$(testlock_label pid)" "$$"
MI_KANDRA_TEST_LOCK_WAIT=0 other 'testlock_acquire autre' > "$TMP/o" 2>&1; rc=$?
check "second preneur refusé (code 2)" "$rc" "2"
check "le refus nomme le détenteur" "$(grep -c 'lock-test (pid' "$TMP/o")" "1"
check "verrou intact après le refus" "$(lock_id)" "$held"

echo "== 2) Les vrais tests respectent le verrou"
MI_KANDRA_TEST_LOCK_WAIT=0 bash "$HERE/hooks-test.sh" > "$TMP/h" 2>&1; rc=$?
check "hooks-test.sh refusé (code 2)" "$rc" "2"
check "hooks-test.sh : message clair" "$(grep -c 'Un autre test du routeur tourne déjà' "$TMP/h")" "1"
MI_KANDRA_TEST_LOCK_WAIT=0 sh "$HERE/selftest.sh" > "$TMP/s" 2>&1; rc=$?
check "selftest.sh refusé (code 2)" "$rc" "2"
check "selftest.sh : message clair" "$(grep -c 'Un autre test du routeur tourne déjà' "$TMP/s")" "1"
check "leur nettoyage n'a pas retiré notre verrou" "$(lock_id)" "$held"
check "aucun routeur créé" "$(docker container inspect mi-kandra-edge >/dev/null 2>&1 && echo oui || echo non)" "$([ "$FREE" = 1 ] && echo non || echo oui)"

echo "== 3) Attente puis passage"
( sleep 4; testlock_release ) &
t0=$(date +%s)
MI_KANDRA_TEST_LOCK_WAIT=60 other 'testlock_acquire attente && testlock_release' > "$TMP/w" 2>&1; rc=$?; t1=$(date +%s); wait
check "le second attend puis passe (code 0)" "$rc" "0"
check "il a bien attendu (>= 2 s)" "$([ $((t1 - t0)) -ge 2 ] && echo oui || echo non)" "oui"
check "il annonce l'attente" "$(grep -c '^En attente' "$TMP/w")" "1"
check "verrou libre ensuite" "$(lock_id)" ""
testlock_forget

echo "== 4) Verrous orphelins"
sh -c 'exit 0' & dead=$!; wait "$dead"
fake_lock "$dead" "$NS" "$(date +%s)"
MI_KANDRA_TEST_LOCK_WAIT=0 other 'testlock_acquire repreneur' > "$TMP/o" 2>&1; rc=$?
check "processus mort sur cette machine : repris" "$rc" "0"
check "reprise annoncée" "$(grep -c 'Verrou orphelin' "$TMP/o")" "1"
docker rm -f mi-kandra-edge-testlock >/dev/null 2>&1
fake_lock 1 "autre-machine/Linux" "$(date +%s)"
MI_KANDRA_TEST_LOCK_WAIT=0 other 'testlock_acquire repreneur' > "$TMP/o" 2>&1; rc=$?
check "autre machine, verrou récent : respecté (code 2)" "$rc" "2"
docker rm -f mi-kandra-edge-testlock >/dev/null 2>&1
fake_lock 1 "autre-machine/Linux" "$(( $(date +%s) - 8000 ))"
MI_KANDRA_TEST_LOCK_WAIT=0 other 'testlock_acquire repreneur' > "$TMP/o" 2>&1; rc=$?
check "verrou de plus de 2 h : repris" "$rc" "0"
docker rm -f mi-kandra-edge-testlock >/dev/null 2>&1
fake_lock "$$" "$NS" "$(date +%s)"
MI_KANDRA_TEST_LOCK_WAIT=0 other 'testlock_acquire repreneur' > "$TMP/o" 2>&1; rc=$?
check "processus vivant : respecté (code 2)" "$rc" "2"
docker rm -f mi-kandra-edge-testlock >/dev/null 2>&1

echo "== 5) Test complet : verrou libéré à la fin et après un kill"
if [ "$FREE" = 1 ]; then
  bash "$HERE/hooks-test.sh" > "$TMP/h" 2>&1; rc=$?
  check "hooks-test.sh passe verrou libre (code 0)" "$rc" "0"
  check "verrou retiré à la fin" "$(lock_id)" ""
  bash "$HERE/hooks-test.sh" > "$TMP/h" 2>&1 & hp=$!
  i=0; while [ -z "$(lock_id)" ] && [ "$i" -lt 60 ]; do i=$((i + 1)); sleep 0.5; done
  sleep 2; kill -TERM "$hp" 2>/dev/null
  i=0; while kill -0 "$hp" 2>/dev/null && [ "$i" -lt 120 ]; do i=$((i + 1)); sleep 0.5; done
  check "hooks-test.sh arrêté par kill" "$(kill -0 "$hp" 2>/dev/null && echo vivant || echo arrêté)" "arrêté"
  wait "$hp" 2>/dev/null
  check "verrou libéré après le kill" "$(lock_id)" ""
  check "routeur nettoyé après le kill" "$(docker container inspect mi-kandra-edge >/dev/null 2>&1 && echo présent || echo absent)" "absent"
else
  echo "   SAUT routeur présent ou 80/443 pris : scénario complet non joué"
fi

echo
echo "Résultat : $PASS OK, $FAILN FAIL"
[ "$FAILN" -eq 0 ]
