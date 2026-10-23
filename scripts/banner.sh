#!/bin/sh
# =============================================================================
# banner.sh — Carte d'accueil d'Influencor (thème bleu), affichée par ./start.sh
# au démarrage et avant --build.
#
#   sh scripts/banner.sh [domaine...]
#
# Couleurs seulement vers un terminal (désactivées par NO_COLOR). Sous 91
# colonnes, le logo ASCII est remplacé par une carte compacte.
# Ne fait jamais échouer start.sh : toute information introuvable s'affiche « - ».
# =============================================================================
set -u

cd "$(dirname "$0")/.." || exit 0

# ── Couleurs : bleus du logo (lib/app/theme/app_colors.dart : #204DA0, #3B6FD6, #4C86E5) ──
# RVB exact (24 bits) ; console Linux ou terminal minimal : approximation 256 couleurs.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  E=$(printf '\033')
  R="${E}[0m"; BOLD="${E}[1m"
  case "${TERM:-}" in
    linux|vt*|ansi|cons25)
      rgb() { printf '%s[%s38;5;%sm' "$E" "$1" "$5"; } ;;
    *)
      rgb() { printf '%s[%s38;2;%s;%s;%sm' "$E" "$1" "$2" "$3" "$4"; } ;;
  esac
  #                  gras  R   G   B  256
  C_BORDER=$(rgb ""   32  77 160  25)    # #204DA0 — bleu du logo
  C_RULE=$(rgb   ""   32  77 160  25)
  C_SUB=$(rgb    "1;" 76 134 229  68)    # #4C86E5
  C_TITLE="$BOLD"
  C_VER=$(rgb    "1;" 76 134 229  68)
  C_HEAD=$(rgb   "1;" 76 134 229  68)
  C_DOT=$(rgb    ""   59 111 214  26)    # #3B6FD6
  C_LABEL=$(rgb  ""   76 134 229  68)
  C_VAL="$BOLD"
  G1=$(rgb "1;" 110 156 235  75)          # logo : dégradé #6E9CEB → #204DA0
  G2=$(rgb "1;"  76 134 229  68)
  G3=$(rgb "1;"  59 111 214  26)
  G4=$(rgb "1;"  47  95 192  26)
  G5=$(rgb "1;"  40  86 176  25)
  G6=$(rgb "1;"  32  77 160  25)
else
  R=""; BOLD=""; C_BORDER=""; C_RULE=""; C_SUB=""; C_TITLE=""; C_VER=""; C_HEAD=""
  C_DOT=""; C_LABEL=""; C_VAL=""; G1=""; G2=""; G3=""; G4=""; G5=""; G6=""
fi

# ── Mise en page ─────────────────────────────────────────────────────────────
# Largeur affichée : nombre de caractères UTF-8 (indépendant de la locale).
width() { printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '; }
spaces() { [ "$1" -gt 0 ] && printf "%${1}s" '' || true; }

COLS=$(stty size 2>/dev/null </dev/tty | cut -d' ' -f2)
case "$COLS" in ''|*[!0-9]*) COLS=${COLUMNS:-$(tput cols 2>/dev/null || echo 100)} ;; esac
if [ "$COLS" -ge 91 ]; then W=89; else W=56; fi

HR=""; i=0
while [ "$i" -lt "$W" ]; do HR="$HR┈"; i=$((i + 1)); done

border() { printf '%s%s%s%s%s\n' "$C_BORDER" "$1" "$HR" "$2" "$R"; }
# Ligne de la carte. $1 : texte brut (calcul de largeur), $2 : texte affiché (avec couleurs).
row() {
  r_pad=$((W - $(width "$1")))
  printf '%s┊%s%s%s%s┊%s\n' "$C_BORDER" "$R" "${2:-$1}" "$(spaces "$r_pad")" "$C_BORDER" "$R"
}
row_left()   { row "  $1" "  ${2:-$1}"; }
row_center() {
  rc_l=$(( (W - $(width "$1")) / 2 ))
  row "$(spaces "$rc_l")$1" "$(spaces "$rc_l")${2:-$1}"
}
blank() { row ""; }
info() {
  i_val=${2:--}
  # Valeur trop longue pour la carte : tronquée avec « … ».
  i_max=$((W - 20))
  [ "$(width "$i_val")" -le "$i_max" ] || i_val="$(printf '%s' "$i_val" | cut -c1-$((i_max - 1)))…"
  i_lbl="$1 :$(spaces $((12 - $(width "$1"))))"
  row_left "• $i_lbl $i_val" "$C_DOT•$R $C_LABEL$i_lbl$R $C_VAL$i_val$R"
}

# ── Informations serveur ─────────────────────────────────────────────────────
VERSION=$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml 2>/dev/null | head -n 1)

CPU=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)

RAM=""
if [ -r /proc/meminfo ]; then
  RAM=$(awk '/^MemTotal:/ { printf "%d MB", $2 / 1024 }' /proc/meminfo)
elif command -v sysctl >/dev/null 2>&1; then
  RAM=$(sysctl -n hw.memsize 2>/dev/null | awk '{ printf "%d MB", $1 / 1048576 }')
fi

DISK=$(df -Pk . 2>/dev/null | awk 'NR == 2 { printf "%.1f GB", $4 / 1048576 }')

IP=$(sh scripts/edge/mi-kandra-dns.sh ip 2>/dev/null | tr -d ' \r\n')

HOST=$(hostname 2>/dev/null || uname -n)

OS=""
[ -r /etc/os-release ] && OS=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')
[ -n "$OS" ] || OS=$(uname -sr 2>/dev/null)

DOCKER=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
[ -n "$DOCKER" ] || DOCKER=$(docker version --format '{{.Client.Version}}' 2>/dev/null)
[ -n "$DOCKER" ] || DOCKER="absent"

# Domaines : tous s'ils tiennent sur la ligne, sinon le premier et le nombre restant.
DOMAIN=""
if [ $# -gt 0 ]; then
  DOMAIN=$(printf '%s\n' "$@" | paste -sd ',' - | sed 's/,/, /g')
  if [ "$(width "$DOMAIN")" -gt $((W - 21)) ]; then DOMAIN="$1 (+$(($# - 1)))"; fi
else
  DOMAIN="aucun (./start.sh --domain-add <domaine>)"
fi

COMMIT=$(git rev-parse --short HEAD 2>/dev/null)
[ -n "$COMMIT" ] && [ -n "$(git status --porcelain 2>/dev/null | head -n 1)" ] && COMMIT="$COMMIT (modifié)"

# ── Carte ────────────────────────────────────────────────────────────────────
echo
border '┌' '┐'
blank
if [ "$W" -ge 89 ]; then
  n=0
  while IFS= read -r art; do
    n=$((n + 1))
    eval "g=\$G$n"
    row_center "$art" "$g$art$R"
  done <<'EOF'
██╗███╗   ██╗███████╗██╗     ██╗   ██╗███████╗███╗   ██╗ ██████╗ ██████╗ ██████╗
██║████╗  ██║██╔════╝██║     ██║   ██║██╔════╝████╗  ██║██╔════╝██╔═══██╗██╔══██╗
██║██╔██╗ ██║█████╗  ██║     ██║   ██║█████╗  ██╔██╗ ██║██║     ██║   ██║██████╔╝
██║██║╚██╗██║██╔══╝  ██║     ██║   ██║██╔══╝  ██║╚██╗██║██║     ██║   ██║██╔══██╗
██║██║ ╚████║██║     ███████╗╚██████╔╝███████╗██║ ╚████║╚██████╗╚██████╔╝██║  ██║
╚═╝╚═╝  ╚═══╝╚═╝     ╚══════╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝
EOF
else
  row_center "I N F L U E N C O R" "$G3$BOLD""I N F L U E N C O R$R"
fi
blank
RULE="───────────"
row_center "$RULE  M I   K A N D R A  $RULE" "$C_RULE$RULE$R  $C_SUB""M I   K A N D R A$R  $C_RULE$RULE$R"
blank
TITLE="Assistant de déploiement web"
row_left "$TITLE  v${VERSION:-?}" "$C_TITLE$TITLE$R  $C_VER""v${VERSION:-?}$R"
blank
border '├' '┤'
blank
row_left "Ressources serveur :" "$C_HEAD""Ressources serveur :$R"
info "Cœurs CPU" "$CPU"
info "RAM totale" "$RAM"
info "Disque libre" "$DISK"
info "IP publique" "$IP"
info "Hôte" "$HOST"
info "OS" "$OS"
info "Docker" "$DOCKER"
info "Domaine" "$DOMAIN"
info "Commit" "$COMMIT"
blank
border '└' '┘'
echo
