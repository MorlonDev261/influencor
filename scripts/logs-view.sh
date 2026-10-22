#!/bin/bash
# =============================================================================
# logs-view.sh — Logs de la stack, lisibles (appelé par `./start.sh --logs`).
#
# Usage : ./start.sh --logs [services...] [options]
#
#   services        app, nginx, db, redis… (défaut : LOGS_DEFAULT_SERVICES,
#                   sinon tous)
#   --all           tous les services, même si le projet a un défaut
#   --errors        erreurs seulement
#   --warn          avertissements et erreurs
#   --grep <texte>  ne garde que les lignes contenant ce texte
#   --since <durée> depuis 10m, 2h, 2026-10-20T08:00… (défaut : 200 lignes)
#   --tail <n>      nombre de lignes d'historique (défaut : 200)
#   --no-follow     affiche l'historique puis rend la main
#   --health        garde les sondes /api/health (et /healthz, masquées par défaut)
#   --scans         montre aussi le trafic hors-site (Host inconnu, accès direct
#                   par l'IP, domaines d'autres projets), masqué par défaut
#   --utc           heures en UTC au lieu de l'heure locale du serveur
#   --raw           sortie brute de `docker compose logs`
#
# Réglages du projet appelant (variables d'environnement, toutes optionnelles) :
#   LOGS_TITLE             nom affiché dans l'en-tête (défaut : dossier du projet)
#   LOGS_PREFIX            préfixe retiré des noms de conteneurs (ex. « poma- »)
#   LOGS_COMPOSE_FILE      fichier compose à utiliser (défaut : celui du dossier)
#   LOGS_DEFAULT_SERVICES  services suivis sans argument (ex. « web socket »)
#
# La mise en forme est faite par scripts/logs-pretty.awk (POSIX awk). Script
# identique dans chaque projet Mi Kandra : le modifier partout à la fois.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AWK_SCRIPT="$SCRIPT_DIR/logs-pretty.awk"
cd "$SCRIPT_DIR/.."

services=()
all=0
follow=1
tail_n=200
since=""
minlevel=0
grep_text=""
health=0
scans=0
utc=0
raw=0

die() { printf 'logs : %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) all=1; shift ;;
    --errors) minlevel=2; shift ;;
    --warn|--warnings) minlevel=1; shift ;;
    --grep) [ -n "${2:-}" ] || die "--grep requiert un texte."; grep_text="$2"; shift 2 ;;
    --since) [ -n "${2:-}" ] || die "--since requiert une durée (ex. 10m, 2h)."; since="$2"; shift 2 ;;
    --tail)
      case "${2:-}" in ''|*[!0-9]*) die "--tail requiert un nombre." ;; esac
      tail_n="$2"; shift 2 ;;
    --no-follow) follow=0; shift ;;
    --health) health=1; shift ;;
    --scans) scans=1; shift ;;
    --utc) utc=1; shift ;;
    --raw) raw=1; shift ;;
    -*) die "option inconnue : $1" ;;
    *) services+=("$1"); shift ;;
  esac
done

if [ "${#services[@]}" -eq 0 ] && [ "$all" -eq 0 ] && [ -n "${LOGS_DEFAULT_SERVICES:-}" ]; then
  read -r -a services <<<"$LOGS_DEFAULT_SERVICES"
fi

compose=(docker compose)
[ -n "${LOGS_COMPOSE_FILE:-}" ] && compose+=(-f "$LOGS_COMPOSE_FILE")

history_args=()
if [ -n "$since" ]; then history_args=(--since "$since"); else history_args=(--tail "$tail_n"); fi
follow_args=()
[ "$follow" -eq 1 ] && follow_args=(-f)

if [ "$raw" -eq 1 ]; then
  exec "${compose[@]}" logs ${follow_args[@]+"${follow_args[@]}"} "${history_args[@]}" ${services[@]+"${services[@]}"}
fi

# Couleurs seulement vers un terminal (et jamais si NO_COLOR est défini).
color=0
[ -t 1 ] && [ -z "${NO_COLOR:-}" ] && color=1

# Décalage horaire du serveur (« +0300 » → 10800 s).
tzoff=0
if [ "$utc" -eq 0 ]; then
  z=$(date +%z 2>/dev/null || echo +0000)
  case "$z" in
    [+-][0-9][0-9][0-9][0-9])
      tzoff=$(( (10#${z:1:2} * 3600 + 10#${z:3:2} * 60) ))
      [ "${z:0:1}" = "-" ] && tzoff=$(( -tzoff ))
      ;;
  esac
fi

# mawk tamponne son entrée lue dans un pipe : -W interactive la lit ligne à
# ligne, sinon le mode -f afficherait les logs par paquets.
awk_cmd=(awk)
if awk -W version 2>&1 | head -n 1 | grep -qi mawk; then awk_cmd+=(-W interactive); fi

if [ "$color" -eq 1 ]; then
  title="${LOGS_TITLE:-$(basename "$PWD")}"
  scope="toute la stack"
  [ "${#services[@]}" -gt 0 ] && scope="${services[*]}"
  filter=""
  [ "$minlevel" -eq 2 ] && filter=" · erreurs seulement"
  [ "$minlevel" -eq 1 ] && filter=" · avertissements et erreurs"
  [ -n "$grep_text" ] && filter="$filter · « $grep_text »"
  [ "$scans" -eq 1 ] && filter="$filter · avec le hors-site"
  tz_label="heure locale"; [ "$utc" -eq 1 ] && tz_label="UTC"
  printf '\033[1m\033[38;2;212;147;6m%s\033[0m \033[1mlogs\033[0m \033[90m· %s%s · %s' "$title" "$scope" "$filter" "$tz_label"
  [ "$follow" -eq 1 ] && printf ' · Ctrl+C pour quitter'
  printf '\033[0m\n\n'
fi

# Ctrl+C arrête docker compose et awk ensemble : on sort proprement.
trap 'exit 0' INT

# `docker compose logs` rend l'historique conteneur par conteneur : sans tri,
# les heures ne se suivent pas d'un service à l'autre. L'historique passe donc
# par un tri stable sur l'horodatage (fraction de seconde complétée à 9
# chiffres pour un tri lexicographique juste) et s'arrête à T0, puis le suivi
# reprend à T0 : ni trou ni doublon à la jonction. Une ligne sans horodatage
# garde la clé de la précédente. La coupure est faite ici et non par
# `--until` : Docker applique --tail AVANT --until et perd alors des lignes.
t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)

sort_by_time() {
  awk -v t0="${t0%Z}.000000000" 'BEGIN { key = "0" }
    {
      p = index($0, "| ")
      if (p > 0) {
        ts = substr($0, p + 2)
        if (ts ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
          frac = substr(ts, 20); sub(/[^.0-9].*$/, "", frac); sub(/^\./, "", frac)
          while (length(frac) < 9) frac = frac "0"
          key = substr(ts, 1, 19) "." substr(frac, 1, 9)
        }
      }
      if (key < t0) print key "\t" $0
    }' | LC_ALL=C sort -s -t "$(printf '\t')" -k1,1 | cut -f2-
}

{
  "${compose[@]}" logs --no-color --timestamps "${history_args[@]}" \
      ${services[@]+"${services[@]}"} 2>&1 | sort_by_time
  # Repère lu par logs-pretty.awk : bilan du trafic hors-site masqué.
  echo "mk-history-end"
  if [ "$follow" -eq 1 ]; then
    "${compose[@]}" logs --no-color --timestamps -f --since "$t0" \
        ${services[@]+"${services[@]}"} 2>&1
  fi
} | "${awk_cmd[@]}" -v color="$color" -v tzoff="$tzoff" -v minlevel="$minlevel" \
      -v grep="$grep_text" -v health="$health" -v scans="$scans" -v prefix="${LOGS_PREFIX:-}" -f "$AWK_SCRIPT"
