#!/bin/sh
# =============================================================================
# mi-kandra-backup.sh — sauvegarde des données critiques d'UN projet
#
# Copie IDENTIQUE dans chaque projet. Sauvegarde ce qui ne se reconstruit pas :
#   • volumes MinIO (médias), Let's Encrypt (certificats + clés), acme-dns ;
#   • base PostgreSQL LOCALE via pg_dump (cohérent, contrairement à une copie
#     brute du volume) — ignorée si la base est externe (Neon, Supabase…).
# Exclus volontairement : cloudflare_ini (jeton API), Redis/cache, Prometheus/
# Grafana/Loki/Ollama (volumineux et reconstructibles).
#
# ⚠ Les sauvegardes contiennent des SECRETS (clés privées TLS, données). Droits 600,
#   chiffrement AES-256 si MI_KANDRA_BACKUP_PASSPHRASE est défini, et à STOCKER HORS
#   DU SERVEUR. Une sauvegarde sur le même disque ne protège pas d'une perte du disque.
# Les volumes sont copiés à chaud (cohérence « crash ») : pour une cohérence stricte
# des médias, arrêtez MinIO le temps de la copie.
#
# Usage :
#   sh scripts/edge/mi-kandra-backup.sh list                      # ce qui serait sauvegardé
#   sh scripts/edge/mi-kandra-backup.sh backup [--dir D] [--keep N]
#   sh scripts/edge/mi-kandra-backup.sh verify [--dir D]          # relit chaque archive
#   Variables : MI_KANDRA_BACKUP_PASSPHRASE (chiffrement), MI_KANDRA_BACKUP_DIR ; option --project NOM
#   Dossier par défaut : <dossier parent du projet>/mi-kandra-backups/<projet compose> (hors dépôt)
#
# Restauration d'un volume (exemple) :
#   docker run --rm -v VOLUME:/v -v "$PWD/backups":/b alpine sh -c 'tar xzf /b/FICHIER.tgz -C /v'
# Restauration de la base : pg_restore -U USER -d DB --clean --if-exists FICHIER.dump
#   (déchiffrer d'abord : openssl enc -d -aes-256-cbc -pbkdf2 -in F.enc -out F -pass env:MI_KANDRA_BACKUP_PASSPHRASE)
# =============================================================================
set -u
MSYS_NO_PATHCONV=1; MSYS2_ARG_CONV_EXCL='*'; export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/project.env" ] && . "$SCRIPT_DIR/project.env"
PROJ_COMPOSE="${MI_KANDRA_COMPOSE_PROJECT:-}"

die() { printf 'ERREUR %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
native() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || die "Docker indisponible."

cmd=${1:-}; [ $# -gt 0 ] && shift
dir=""; keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) shift; dir=${1:-} ;;
    --keep) shift; keep=${1:-0} ;;
    --project) shift; PROJ_COMPOSE=${1:-} ;;
    *) die "option inconnue : $1" ;;
  esac
  shift
done
printf '%s' "$keep" | grep -Eq '^[0-9]{1,3}$' || die "--keep doit être un entier"
# Dossier par défaut HORS du projet (à côté de lui) : jamais dans un `git add -A`
# ni dans le contexte de build Docker. Surchargeable par MI_KANDRA_BACKUP_DIR ou --dir.
[ -n "$dir" ] || dir="${MI_KANDRA_BACKUP_DIR:-$(dirname "$PROJECT_ROOT")/mi-kandra-backups/$PROJ_COMPOSE}"
[ -n "$PROJ_COMPOSE" ] || die "projet Compose inconnu : ajoutez MI_KANDRA_COMPOSE_PROJECT à scripts/edge/project.env ou passez --project NOM"
printf '%s' "$PROJ_COMPOSE" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' || die "nom de projet Compose invalide"

# Volumes à sauvegarder : sur le label Compose du projet, par motif de nom.
volumes() {
  docker volume ls --filter "label=com.docker.compose.project=$PROJ_COMPOSE" --format '{{.Name}}' \
    | grep -E '(miniodata|letsencrypt|acmedns_data|acmedns_creds)$' | sort
}
# Conteneur PostgreSQL local du projet (en marche) : image postgres/pgvector.
pg_container() {
  docker ps --filter "label=com.docker.compose.project=$PROJ_COMPOSE" --format '{{.Names}}|{{.Image}}' \
    | awk -F'|' '$2 ~ /(postgres|pgvector)/ { print $1; exit }'
}

case "$cmd" in
  list)
    say "Projet Compose : $PROJ_COMPOSE"
    say "Dossier       : $dir"
    say "Volumes :"
    v=$(volumes); [ -n "$v" ] || say "   (aucun volume critique trouvé)"
    for n in $v; do printf '   - %s (%s)\n' "$n" "$(docker run --rm -v "$n":/v:ro alpine du -sh /v 2>/dev/null | cut -f1)"; done
    pg=$(pg_container); [ -n "$pg" ] && say "Base locale : $pg (pg_dump)" || say "Base locale : aucune (base externe ou arrêtée)"
    [ -n "${MI_KANDRA_BACKUP_PASSPHRASE:-}" ] && say "Chiffrement  : AES-256 activé" || say "Chiffrement  : désactivé (définissez MI_KANDRA_BACKUP_PASSPHRASE)"
    ;;

  backup)
    mkdir -p "$dir" || die "dossier impossible : $dir"; chmod 700 "$dir" 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S); ok=0; ko=0
    enc() { # filtre : chiffre si une phrase de passe est définie
      if [ -n "${MI_KANDRA_BACKUP_PASSPHRASE:-}" ]; then openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:MI_KANDRA_BACKUP_PASSPHRASE; else cat; fi
    }
    sfx=""; [ -n "${MI_KANDRA_BACKUP_PASSPHRASE:-}" ] && sfx=".enc"
    [ -z "$sfx" ] || command -v openssl >/dev/null 2>&1 || die "openssl requis pour le chiffrement"
    for n in $(volumes); do
      out="$dir/$n-$ts.tgz$sfx"
      if docker run --rm -v "$n":/v:ro alpine tar czf - -C /v . 2>/dev/null | enc > "$out" && [ -s "$out" ]; then
        chmod 600 "$out" 2>/dev/null || true; say "OK    volume $n -> $(basename "$out") ($(du -h "$out" | cut -f1))"; ok=$((ok + 1))
      else rm -f "$out"; say "FAIL  volume $n"; ko=$((ko + 1)); fi
    done
    pg=$(pg_container)
    if [ -n "$pg" ]; then
      out="$dir/$PROJ_COMPOSE-postgres-$ts.dump$sfx"
      if docker exec "$pg" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' 2>/dev/null | enc > "$out" && [ -s "$out" ]; then
        chmod 600 "$out" 2>/dev/null || true; say "OK    base  $pg -> $(basename "$out") ($(du -h "$out" | cut -f1))"; ok=$((ok + 1))
      else rm -f "$out"; say "FAIL  base $pg (pg_dump)"; ko=$((ko + 1)); fi
    else say "INFO  pas de PostgreSQL local en marche : base non sauvegardée ici (base externe : utilisez les sauvegardes du fournisseur)"; fi
    [ "$ok" -gt 0 ] || [ "$ko" -gt 0 ] || say "WARN  rien à sauvegarder pour le projet $PROJ_COMPOSE"
    # Rotation : garde les N plus récentes PAR type de fichier.
    if [ "$keep" -gt 0 ]; then
      for pre in $(ls "$dir" | sed -E 's/-[0-9]{8}-[0-9]{6}\..*$//' | sort -u); do
        ls -1t "$dir"/"$pre"-[0-9]*-[0-9]* 2>/dev/null | tail -n +$((keep + 1)) | while IFS= read -r old; do rm -f "$old" && say "ROT   supprimé $(basename "$old")"; done
      done
    fi
    say "Bilan : $ok sauvegarde(s), $ko échec(s). N'oubliez pas de copier $dir HORS du serveur."
    [ "$ko" -eq 0 ]
    ;;

  verify)
    [ -d "$dir" ] || die "dossier introuvable : $dir"
    bad=0; n=0
    for f in "$dir"/*; do
      [ -f "$f" ] || continue; n=$((n + 1)); b=$(basename "$f"); src="$f"; tmp=""
      case "$b" in *.enc)
        [ -n "${MI_KANDRA_BACKUP_PASSPHRASE:-}" ] || { say "SKIP  $b (chiffré : définissez MI_KANDRA_BACKUP_PASSPHRASE)"; continue; }
        # Redirections du shell (et non -in/-out) : un openssl natif Windows
        # interpréterait mal un chemin de type /c/Users/...
        tmp=$(mktemp); openssl enc -d -aes-256-cbc -pbkdf2 -pass env:MI_KANDRA_BACKUP_PASSPHRASE < "$f" > "$tmp" 2>/dev/null || { say "FAIL  $b (déchiffrement impossible)"; bad=$((bad + 1)); rm -f "$tmp"; continue; }
        src=$tmp ;;
      esac
      case "$b" in
        *.tgz*) if cnt=$(tar tzf "$src" 2>/dev/null | wc -l) && [ "$cnt" -gt 0 ]; then say "OK    $b ($cnt entrées)"; else say "FAIL  $b (archive illisible ou vide)"; bad=$((bad + 1)); fi ;;
        *.dump*) if docker run --rm -i postgres:16-alpine pg_restore -l < "$src" >/dev/null 2>&1 || docker run --rm -i pgvector/pgvector:pg17 pg_restore -l < "$src" >/dev/null 2>&1; then say "OK    $b (dump lisible)"; else say "FAIL  $b (dump illisible)"; bad=$((bad + 1)); fi ;;
        *) say "SKIP  $b" ;;
      esac
      [ -z "$tmp" ] || rm -f "$tmp"
    done
    [ "$n" -gt 0 ] || say "(aucune sauvegarde dans $dir)"
    [ "$bad" -eq 0 ]
    ;;

  *) sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
esac
