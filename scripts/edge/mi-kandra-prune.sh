#!/bin/sh
# =============================================================================
# mi-kandra-prune.sh — nettoyage Docker SÛR et réversible (dry-run par défaut)
#
# Copie IDENTIQUE dans chaque projet. Ne supprime JAMAIS :
#   • un conteneur (en marche ou non),
#   • une image utilisée par un conteneur,
#   • un volume (donc ni base de données, ni médias MinIO, ni certificats).
# Il retire seulement ce qui se reconstruit : images orphelines (dangling) et
# cache de build ancien. Les tags de rollback restent : à vous de décider.
#
# Usage :
#   sh scripts/edge/mi-kandra-prune.sh                 # montre ce qui serait libéré
#   sh scripts/edge/mi-kandra-prune.sh --apply         # nettoie
#   sh scripts/edge/mi-kandra-prune.sh --apply --days 14   # cache plus récent que 14 j conservé
# =============================================================================
set -u
MSYS_NO_PATHCONV=1; export MSYS_NO_PATHCONV

APPLY=0; DAYS=7
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --days) shift; DAYS=${1:-7} ;;
    *) printf 'usage: %s [--apply] [--days N]\n' "$0" >&2; exit 64 ;;
  esac
  shift
done
printf '%s' "$DAYS" | grep -Eq '^[0-9]{1,3}$' || { echo "--days doit être un entier" >&2; exit 64; }

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "Docker indisponible" >&2; exit 1; }

echo "== Avant"; docker system df | sed 's/^/   /'
echo
echo "== Images orphelines (dangling) :"
docker images -f dangling=true --format '   {{.ID}}  {{.Size}}  créée {{.CreatedSince}}' | head -20
echo "   (total : $(docker images -f dangling=true -q | wc -l | tr -d ' '))"
echo
echo "== Tags de rollback/patch conservés (non supprimés automatiquement) :"
docker images --format '{{.Repository}}:{{.Tag}}|{{.Size}}' | awk -F'|' '$1 ~ /-(hotfix|patch-validation|old|backup|tmp)$/ { printf "   %s  %s\n", $1, $2; n++ } END { if (!n) print "   (aucun)" }'
echo "   (suppression manuelle : docker rmi <nom:tag>, après vérification qu'aucun rollback n'en a besoin)"
echo
echo "== Cache de build (tout ce qui est plus ancien que ${DAYS} jours sera retiré avec --apply) :"
docker system df | awk '/Build Cache/ { printf "   total %s, récupérable %s\n", $5, $6 }'

if [ "$APPLY" -ne 1 ]; then
  echo; echo "Dry-run : rien n'a été supprimé. Relancez avec --apply pour nettoyer."; exit 0
fi

echo; echo "== Nettoyage"
docker image prune -f | tail -1
docker builder prune -f --filter "until=$((DAYS * 24))h" | tail -1
echo; echo "== Après"; docker system df | sed 's/^/   /'
