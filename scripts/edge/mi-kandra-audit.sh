#!/bin/sh
# =============================================================================
# mi-kandra-audit.sh — audit continu de sécurité / hygiène d'un serveur Mi Kandra
#
# Copie IDENTIQUE dans chaque projet. Lecture seule : ne modifie rien, n'affiche
# JAMAIS une valeur secrète (seulement des noms de variables et des empreintes
# tronquées). Code retour : 0 = rien de critique, 1 = au moins un FAIL.
#
# Contrôles :
#   1. Secrets IDENTIQUES entre projets voisins (une fuite d'un projet
#      compromettrait les autres — c'était le cas d'AUTH_SECRET).
#   2. Secrets faibles / valeurs par défaut connues.
#   3. Fichiers .env (ou sauvegardes) suivis par git, ou présents dans
#      l'historique (secrets déjà divulgués à toute personne ayant le dépôt).
#   4. Permissions du .env (Linux).
#   5. Ports sensibles (Postgres, Redis, MinIO, Grafana…) publiés sur 0.0.0.0.
#   6. Images en ":latest" parmi les conteneurs en marche.
#   7. Gaspillage Docker récupérable (images/cache/volumes orphelins).
#
# Usage : sh scripts/edge/mi-kandra-audit.sh [dossier-projet ...]
#   Sans argument : projet courant + projets voisins détectés via les labels
#   org.mi-kandra.* des conteneurs en marche.
# =============================================================================
set -u

MSYS_NO_PATHCONV=1; MSYS2_ARG_CONV_EXCL='*'; export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SELF_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

FAILS=0; WARNS=0
ok()   { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
hdr()  { printf '\n== %s\n' "$*"; }

sha() { printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-12; }

# Valeur d'une clé du .env (sans guillemets ni CR).
env_val() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"; }

is_secret_key() {
  # Exclut les réglages numériques qui ressemblent à des secrets (LLM_MAX_TOKENS…).
  printf '%s' "$1" | grep -Eiq '(MAX_TOKENS|TOKEN_LIMIT|TOKENS$|_TTL$|_EXPIRY$|_EXPIRES)' && return 1
  printf '%s' "$1" | grep -Eiq '(SECRET|PASSWORD|PASSWD|TOKEN|PRIVATE|_KEY$|API_KEY|ACCESS_KEY)'
}
is_public_key() { printf '%s' "$1" | grep -Eiq '^(NEXT_PUBLIC_|.*PUBLIC_KEY|.*SITE_KEY|.*_KEY_ID$|VAPID_PUBLIC)'; }

# ── Projets à auditer ────────────────────────────────────────────────────────
# Liste dans un fichier (un chemin par ligne) : les chemins peuvent contenir des
# espaces ("Mi Kandra") et les compteurs FAIL/WARN doivent rester dans CE shell.
LIST=$(mktemp 2>/dev/null || echo "/tmp/mi-kandra-audit-list.$$"); : > "$LIST"
if [ $# -gt 0 ]; then
  for a in "$@"; do (cd "$a" && pwd) >> "$LIST"; done
else
  printf '%s\n' "$SELF_ROOT" >> "$LIST"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker ps --filter "label=org.mi-kandra.role=origin" --format '{{.Names}}' 2>/dev/null | while IFS= read -r c; do
      wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null)
      [ -d "$wd" ] && (cd "$wd" && pwd) >> "$LIST"
    done
  fi
fi
awk '!seen[$0]++' "$LIST" > "$LIST.u" && mv "$LIST.u" "$LIST"

printf 'Projets audités :\n'; while IFS= read -r p; do printf '  - %s\n' "$p"; done < "$LIST"

# ── 1 & 2. Secrets partagés / faibles ────────────────────────────────────────
hdr "Secrets : réutilisation entre projets et robustesse"
TMP=$(mktemp 2>/dev/null || echo "/tmp/mi-kandra-audit.$$"); : > "$TMP"
while IFS= read -r p; do
  f="$p/.env"; [ -f "$f" ] || { warn "$(basename "$p") : pas de .env lisible"; continue; }
  name=$(basename "$p")
  for k in $(grep -E '^[A-Z][A-Z0-9_]*=' "$f" | cut -d= -f1); do
    is_secret_key "$k" || continue; is_public_key "$k" && continue
    v=$(env_val "$f" "$k"); [ -n "$v" ] || continue
    printf '%s|%s|%s\n' "$(sha "$v")" "$name" "$k" >> "$TMP"
    len=${#v}
    case "$v" in
      admin|password|changeme|secret|poma|mga|artest|test|demo|root|minioadmin|*local_dev*|*changeme*|*change-me*|*CHANGE_ME*)
        fail "$name : $k a une valeur par défaut/évidente" ;;
      *) [ "$len" -lt 16 ] && printf '%s' "$k" | grep -Eiq '(SECRET|PASSWORD|TOKEN)' \
           && warn "$name : $k est court ($len caractères) — recommandé : 32+ aléatoires" ;;
    esac
  done
done < "$LIST"
# Partage ENTRE projets uniquement (une même valeur répétée dans un seul projet,
# ex. SMTP_PASSWORD = EMAIL_PASSWORD, n'élargit pas le rayon d'une fuite).
dups=$(cut -d'|' -f1,2 "$TMP" | sort -u | cut -d'|' -f1 | sort | uniq -d)
if [ -z "$dups" ]; then ok "aucun secret identique entre projets"; else
  for h in $dups; do
    who=$(grep "^$h|" "$TMP" | cut -d'|' -f2,3 | tr '|' ':' | tr '\n' ' ')
    fail "même valeur partagée entre projets (empreinte $h) : $who — un secret par projet (et par usage)"
  done
fi
rm -f "$TMP"

# ── 3 & 4. .env dans git / permissions ───────────────────────────────────────
hdr "Git : fichiers de secrets suivis ou présents dans l'historique"
while IFS= read -r p; do
  name=$(basename "$p"); [ -d "$p/.git" ] || continue
  tracked=$(git -C "$p" ls-files 2>/dev/null | grep -E '(^|/)\.env($|\.)|\.pem$|\.jks$|\.keystore$|key\.properties' | grep -Ev '\.example$|ota-public-key\.pem$')
  [ -z "$tracked" ] && ok "$name : aucun fichier de secret suivi" || fail "$name : suivi par git : $(echo "$tracked" | tr '\n' ' ')"
  hist=$(git -C "$p" log --all --diff-filter=A --name-only --format= 2>/dev/null | grep -E '(^|/)\.env($|\.)|\.pem$|\.jks$|\.keystore$' | grep -Ev '\.example$|ota-public-key\.pem$' | sort -u | head -5)
  [ -z "$hist" ] && ok "$name : historique propre" \
    || fail "$name : secrets présents dans l'historique ($(echo "$hist" | tr '\n' ' ')…) — faire TOURNER ces secrets (réécrire l'historique ne suffit pas)"
  # Permissions POSIX : sans objet sous Git Bash / Windows (toujours 644).
  if [ -f "$p/.env" ] && stat -c %a "$p/.env" >/dev/null 2>&1 && ! uname -s | grep -qiE 'mingw|msys|cygwin'; then
    perm=$(stat -c %a "$p/.env"); case "$perm" in 600|400) ok "$name : .env en $perm";; *) warn "$name : .env en $perm — chmod 600 recommandé";; esac
  fi
done < "$LIST"
rm -f "$LIST"

# ── 5, 6, 7. Docker ──────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  hdr "Docker : ports publiés"
  bad=$(docker ps --format '{{.Names}}|{{.Ports}}' | awk -F'|' '$2 ~ /(0\.0\.0\.0|\[::\]):(5432|5433|5434|6379|9000|9001|3000|4000|4300|3100|9090|8080|11434)->/ {print $1" -> "$2}')
  [ -z "$bad" ] && ok "aucun service interne publié sur toutes les interfaces" \
    || printf '%s\n' "$bad" | while IFS= read -r l; do printf 'FAIL  exposé publiquement : %s\n' "$l"; done
  [ -n "$bad" ] && FAILS=$((FAILS + 1))

  # Les compose ont des valeurs par défaut (ex. POSTGRES_PASSWORD=poma, GRAFANA admin) :
  # on ne peut pas les interdire dans le fichier (interpolé même pour les services
  # désactivés), donc on contrôle ce qui TOURNE réellement. Noms seulement, jamais de valeurs.
  hdr "Docker : secrets faibles dans les conteneurs en marche"
  weak=0
  for c in $(docker ps --format '{{.Names}}' | grep -v '^mi-kandra-edge$'); do
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null | grep -E '^[A-Za-z_]*(PASSWORD|SECRET|SECRET_KEY|ACCESS_KEY)[A-Za-z_]*=' | while IFS= read -r kv; do
      k=${kv%%=*}; v=${kv#*=}
      is_public_key "$k" && continue
      case "$v" in
        ""|admin|password|changeme|secret|poma|mga|artest|test|demo|root|minioadmin|*local_dev*|*changeme*|*CHANGE_ME*)
          [ -n "$v" ] && printf 'FAIL  %s : %s a une valeur faible/par défaut\n' "$c" "$k" ;;
      esac
    done
  done > "$LIST.weak"
  if [ -s "$LIST.weak" ]; then cat "$LIST.weak"; weak=$(wc -l < "$LIST.weak" | tr -d ' '); FAILS=$((FAILS + weak)); else ok "aucun secret faible/par défaut dans les conteneurs en marche"; fi
  rm -f "$LIST.weak"

  hdr "Docker : images non figées (:latest)"
  # L'image de l'app du projet est construite localement et porte le label
  # org.opencontainers.image.revision (commit empaqueté, posé par le Dockerfile) :
  # ce n'est pas une image tierce à figer. (Le critère « sans digest » n'est pas
  # fiable : avec le stockage containerd, les images locales ont aussi un digest.)
  latest=$(docker ps --format '{{.Names}}|{{.Image}}' | awk -F'|' '$2 ~ /:latest$/ || $2 !~ /:/ {print $1"|"$2}' | while IFS='|' read -r n i; do
    [ -n "$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$i" 2>/dev/null)" ] && continue
    printf '%s (%s)\n' "$n" "$i"
  done | grep -v '^mi-kandra-edge')
  [ -z "$latest" ] && ok "toutes les images en marche sont versionnées" \
    || printf '%s\n' "$latest" | while IFS= read -r l; do printf 'WARN  image non figée : %s\n' "$l"; done
  [ -n "$latest" ] && WARNS=$((WARNS + 1))

  hdr "Docker : espace récupérable"
  docker system df 2>/dev/null | sed 's/^/      /'
  extra=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E -- '-(hotfix|patch-validation|old|backup|tmp)$' | tr '\n' ' ')
  [ -z "$extra" ] || warn "images de patch/rollback anciennes : $extra (sh scripts/edge/mi-kandra-prune.sh)"
else
  hdr "Docker"; warn "Docker indisponible : contrôles de ports/images/espace ignorés"
fi

printf '\n== Bilan : %s FAIL, %s WARN\n' "$FAILS" "$WARNS"
[ "$FAILS" -eq 0 ]
