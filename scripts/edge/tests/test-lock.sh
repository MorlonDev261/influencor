# shellcheck shell=sh
# =============================================================================
# test-lock.sh — verrou partagé des tests du routeur (sourcé par selftest.sh et
# hooks-test.sh ; copie IDENTIQUE dans chaque projet)
#
# Les deux tests créent puis DÉTRUISENT le routeur mi-kandra-edge, son réseau et
# son volume de routes. Lancés en même temps (même dépôt ou deux dépôts), l'un
# démolit le routeur de l'autre. Le verrou est un conteneur Docker jamais démarré,
# nommé mi-kandra-edge-testlock : Docker refuse de créer un nom déjà pris, donc la
# prise est atomique pour tout le démon, quel que soit le dépôt ou le shell.
#
# MI_KANDRA_TEST_LOCK_WAIT : secondes d'attente si le verrou est pris (défaut 900 ;
# 0 = refus immédiat). Un verrou orphelin (test tué par kill -9, machine
# redémarrée) est repris si son processus n'existe plus sur cette machine, ou
# s'il a plus de 2 h. Seul celui qui a pris le verrou le retire (par identifiant).
#
# Utilise : $IMG (image déjà présente). Codes : 0 pris, 2 refusé ou Docker en panne.
# =============================================================================

TESTLOCK=mi-kandra-edge-testlock
TESTLOCK_ID=
TESTLOCK_MAX_AGE=7200

# Espace des PID : un PID n'a de sens que sur la même machine ET le même système
# (Git Bash et WSL partagent le nom de machine et le démon, pas les PID).
testlock_ns() { printf '%s/%s' "$(hostname 2>/dev/null || uname -n)" "$(uname -s)"; }
testlock_label() { docker container inspect -f "{{index .Config.Labels \"org.mi-kandra.testlock.$1\"}}" "$TESTLOCK" 2>/dev/null; }
testlock_owner() { printf '%s (pid %s, %s)' "$(testlock_label owner)" "$(testlock_label pid)" "$(testlock_label ns)"; }

# 0 = verrou orphelin (TL_STALE_ID = son identifiant), 1 = verrou vivant ou absent.
testlock_stale() {
  TL_STALE_ID=$(docker container inspect -f '{{.Id}}' "$TESTLOCK" 2>/dev/null) || return 1
  tl_since=$(testlock_label since); tl_pid=$(testlock_label pid); tl_ns=$(testlock_label ns)
  case "$tl_since" in ''|*[!0-9]*) tl_since=0 ;; esac
  [ $(( $(date +%s) - tl_since )) -gt "$TESTLOCK_MAX_AGE" ] && return 0
  [ "$tl_ns" = "$(testlock_ns)" ] || return 1
  case "$tl_pid" in ''|*[!0-9]*) return 0 ;; esac
  # kill -0 échoue aussi sur le processus d'un autre utilisateur (test lancé en sudo) :
  # /proc puis ps confirment qu'il vit (busybox n'a pas ps -p, /proc suffit).
  kill -0 "$tl_pid" 2>/dev/null && return 1
  [ -d "/proc/$tl_pid" ] && return 1
  ps -p "$tl_pid" >/dev/null 2>&1 && return 1
  return 0
}

testlock_acquire() { # $1 nom du test (affiché aux autres)
  tl_wait=${MI_KANDRA_TEST_LOCK_WAIT:-900}
  case "$tl_wait" in ''|*[!0-9]*) tl_wait=900 ;; esac
  tl_t0=$(date +%s); tl_said=0; tl_err=0
  while :; do
    if TESTLOCK_ID=$(docker create --name "$TESTLOCK" \
        -l "org.mi-kandra.testlock.owner=$1" -l "org.mi-kandra.testlock.pid=$$" \
        -l "org.mi-kandra.testlock.ns=$(testlock_ns)" -l "org.mi-kandra.testlock.since=$(date +%s)" \
        "$IMG" true 2>/dev/null); then
      [ "$tl_said" = 1 ] && echo "Verrou des tests libéré : on démarre." >&2
      return 0
    fi
    TESTLOCK_ID=
    if ! docker container inspect "$TESTLOCK" >/dev/null 2>&1; then
      # Création refusée sans verrou visible : libéré entre-temps (on réessaie) ou Docker en panne.
      tl_err=$((tl_err + 1))
      [ "$tl_err" -ge 3 ] && { echo "Impossible de créer le verrou des tests ($TESTLOCK)." >&2; return 2; }
      sleep 1; continue
    fi
    tl_err=0
    if testlock_stale; then
      echo "Verrou orphelin de $(testlock_owner) : repris." >&2
      # Par identifiant : un autre test qui vient de reprendre le verrou n'est pas touché.
      docker rm -f "$TL_STALE_ID" >/dev/null 2>&1
      continue
    fi
    if [ $(( $(date +%s) - tl_t0 )) -ge "$tl_wait" ]; then
      echo "Un autre test du routeur tourne déjà : $(testlock_owner) — test refusé." >&2
      echo "(MI_KANDRA_TEST_LOCK_WAIT=N pour attendre N secondes)" >&2
      return 2
    fi
    [ "$tl_said" = 1 ] || { echo "En attente : $(testlock_owner) utilise le routeur de test (attente max ${tl_wait} s)…" >&2; tl_said=1; }
    sleep 2
  done
}

testlock_release() {
  [ -n "$TESTLOCK_ID" ] || return 0
  docker rm -f "$TESTLOCK_ID" >/dev/null 2>&1
  TESTLOCK_ID=
}

# Verrou déjà libéré par un sous-shell : on l'oublie sans le retirer.
testlock_forget() {
  TESTLOCK_ID=
}
