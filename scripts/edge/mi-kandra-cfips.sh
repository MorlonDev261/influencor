#!/bin/sh
# =============================================================================
# mi-kandra-cfips.sh — Tient à jour les plages d'IP Cloudflare de nginx/snippets/mi-kandra-cloudflare.conf.
#
# Cette copie est IDENTIQUE dans chaque projet (poma, mga, artest…), comme mi-kandra-edge.sh.
# Les plages servent à ne croire l'en-tête CF-Connecting-IP QUE s'il vient de Cloudflare. Elles changent
# très rarement, et un oubli est sans danger (on retombe sur l'IP de Cloudflare, jamais sur une IP
# falsifiée) — mais autant les garder à jour.
#
# Usage :
#   mi-kandra-cfips.sh check    Compare le fichier aux listes officielles (code 1 si différent)
#   mi-kandra-cfips.sh update   Réécrit le bloc généré du fichier (rien d'autre n'est touché)
#                               puis indique comment recharger nginx
# =============================================================================
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SNIPPET="${MI_KANDRA_CF_SNIPPET:-$SCRIPT_DIR/../../nginx/snippets/mi-kandra-cloudflare.conf}"
BEGIN='# >>> cloudflare-ips'
END='# <<< cloudflare-ips'

fetch() { curl -fsS --max-time 15 "$1" 2>/dev/null || wget -qO- --timeout=15 "$1" 2>/dev/null; }

live_ranges() {
  _v4=$(fetch https://www.cloudflare.com/ips-v4 | tr -d '\r' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$')
  _v6=$(fetch https://www.cloudflare.com/ips-v6 | tr -d '\r' | grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$')
  # Garde-fou : une réponse vide ou tronquée ne doit jamais vider la liste.
  [ "$(printf '%s\n' "$_v4" | grep -c .)" -ge 5 ] && [ "$(printf '%s\n' "$_v6" | grep -c .)" -ge 3 ] || return 1
  printf '%s\n%s\n' "$_v4" "$_v6"
}

current_ranges() { sed -n "/$BEGIN/,/$END/p" "$SNIPPET" | grep -E '^[[:space:]]*[0-9a-fA-F:.]+/[0-9]+ 1;' | sed 's/^[[:space:]]*//; s/ 1;$//'; }

case "${1:-}" in
  check|update)
    [ -f "$SNIPPET" ] || { echo "Fichier introuvable : $SNIPPET" >&2; exit 2; }
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || { echo "curl ou wget requis." >&2; exit 2; }
    NEW=$(live_ranges) || { echo "Listes Cloudflare injoignables ou invalides : fichier inchangé." >&2; exit 2; }
    OLD=$(current_ranges)
    if [ "$(printf '%s\n' "$NEW" | sort)" = "$(printf '%s\n' "$OLD" | sort)" ]; then
      echo "Plages Cloudflare à jour ($(printf '%s\n' "$NEW" | grep -c .) entrées)."; exit 0
    fi
    echo "Différences (- fichier, + officiel) :"
    { printf '%s\n' "$OLD" | sort | sed 's/^/- /'; printf '%s\n' "$NEW" | sort | sed 's/^/+ /'; } | sort -k2 | uniq -u -f1 | sort
    [ "$1" = "check" ] && exit 1
    TMP=$(mktemp)
    { sed -n "1,/$BEGIN/p" "$SNIPPET"
      printf '%s\n' "$NEW" | sed 's#^#    #; s#$# 1;#'
      sed -n "/$END/,\$p" "$SNIPPET"; } > "$TMP" && cat "$TMP" > "$SNIPPET" && rm -f "$TMP"
    echo "Fichier mis à jour. Rechargez nginx : docker compose exec nginx nginx -s reload"
    ;;
  *) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
