#!/bin/sh
# =============================================================================
# mi-kandra-secret.sh — rotation guidée d'un secret INTERNE d'un projet
#
# Copie IDENTIQUE dans chaque projet. Sûr par construction :
#   • dry-run par défaut (rien n'est écrit sans --apply) ;
#   • ne génère QUE des secrets purement internes à l'application (liste blanche) ;
#     les identifiants émis par un fournisseur (Cloudflare, Resend, Stripe,
#     Cloudinary, Google…) et les mots de passe de base/MinIO sont REFUSÉS : ils
#     se font chez le fournisseur ou avec une procédure dédiée ;
#   • sauvegarde horodatée du .env avant écriture (droits 600) ;
#   • n'affiche JAMAIS une valeur : seulement des empreintes tronquées.
#
# Usage :
#   sh scripts/edge/mi-kandra-secret.sh gen [octets]            # imprime un secret aléatoire
#   sh scripts/edge/mi-kandra-secret.sh rotate CLE              # dry-run : impact + plan
#   sh scripts/edge/mi-kandra-secret.sh rotate CLE --apply      # écrit dans ./.env
#   sh scripts/edge/mi-kandra-secret.sh rotate CLE --env /chemin/.env --apply
#
# ⚠ Après --apply : redémarrer l'app (la valeur est lue au démarrage du conteneur)
#   et faire la MÊME rotation sur le serveur de production (son .env est distinct).
# =============================================================================
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

die()  { printf 'ERREUR %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

# Secrets purement internes (la rotation ne dépend de personne d'autre).
INTERNAL_KEYS="AUTH_SECRET NEXTAUTH_SECRET JWT_SECRET BETTER_AUTH_SECRET SOCKET_AUTH_SECRET CRON_SECRET INTERNAL_API_SECRET"

impact() {
  case "$1" in
    AUTH_SECRET|NEXTAUTH_SECRET|BETTER_AUTH_SECRET)
      info "  • toutes les sessions utilisateurs sont invalidées (reconnexion obligatoire) ;"
      info "  • les jetons signés avec cette clé cessent de valider : liens de partage de commande,"
      info "    identité invité, tickets d'upload en cours (selon le projet) ;"
      info "  • aucune donnée stockée n'est chiffrée avec cette clé : rien à migrer." ;;
    JWT_SECRET|SOCKET_AUTH_SECRET|INTERNAL_API_SECRET)
      info "  • les jetons internes / Socket.IO en cours sont invalidés (reconnexion automatique du client) ;" ;;
    CRON_SECRET)
      info "  • le planificateur et l'app doivent redémarrer ensemble (même valeur des deux côtés)." ;;
  esac
}

gen_secret() {
  n=${1:-32}
  printf '%s' "$n" | grep -Eq '^[0-9]{1,3}$' && [ "$n" -ge 16 ] || die "taille invalide (16 à 999 octets)"
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex "$n"
  else od -An -N"$n" -tx1 /dev/urandom | tr -d ' \n'; echo; fi
}

fp() { printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-10; }

# Valeur d'une clé : sans guillemets, sans CR, sans commentaire de fin de ligne.
val_of() {
  awk -v key="$2" '
    { line = $0; sub(/\r$/, "", line) }
    index(line, key "=") == 1 {
      rest = substr(line, length(key) + 2); c = substr(rest, 1, 1)
      if (c == "\"" || c == "\047") { rest = substr(rest, 2); e = index(rest, c); print (e ? substr(rest, 1, e - 1) : rest) }
      else { sub(/[ \t]+#.*$/, "", rest); sub(/[ \t]+$/, "", rest); print rest }
      exit
    }' "$1"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  gen) gen_secret "${1:-32}" ;;
  rotate)
    key=${1:-}; [ $# -gt 0 ] && shift
    printf '%s' "$key" | grep -Eq '^[A-Z][A-Z0-9_]*$' || die "usage : rotate CLE [--env FICHIER] [--apply]"
    envf="$PROJECT_ROOT/.env"; apply=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --apply) apply=1 ;;
        --env) shift; envf=${1:-} ;;
        *) die "option inconnue : $1" ;;
      esac
      shift
    done
    case " $INTERNAL_KEYS " in
      *" $key "*) : ;;
      *) die "$key n'est pas un secret interne géré ici. Les identifiants de fournisseurs (Cloudflare, Resend, Stripe, Cloudinary, Google…) se renouvellent chez le fournisseur ; les mots de passe de base/MinIO demandent une procédure dédiée (ALTER USER / réinitialisation)." ;;
    esac
    [ -f "$envf" ] || die "fichier introuvable : $envf"
    grep -Eq "^$key=" "$envf" || die "$key absent de $envf"
    old=$(val_of "$envf" "$key")
    [ -n "$old" ] || info "(valeur actuelle vide)"
    info "Projet   : $(basename "$PROJECT_ROOT")"
    info "Fichier  : $envf"
    info "Clé      : $key   (empreinte actuelle : $(fp "$old"))"
    info "Impact de la rotation :"; impact "$key"
    if [ "$apply" -ne 1 ]; then
      info ""; info "Dry-run : rien n'a été modifié. Ajoutez --apply pour écrire une nouvelle valeur."
      exit 0
    fi
    new=$(gen_secret 32); [ -n "$new" ] || die "génération impossible"
    # Nom unique : deux rotations dans la même seconde ne doivent JAMAIS s'écraser
    # (la sauvegarde la plus ancienne contient la valeur d'origine).
    ts=$(date +%Y%m%d%H%M%S); bak="$envf.bak-$ts"; n=0
    while [ -e "$bak" ]; do n=$((n + 1)); bak="$envf.bak-$ts-$n"; done
    cp -p "$envf" "$bak" || die "sauvegarde impossible"; chmod 600 "$bak" 2>/dev/null || true
    tmp="$envf.tmp.$$"
    # Remplace la 1re occurrence, en conservant guillemets, commentaires de fin de ligne et CRLF.
    awk -v key="$key" -v val="$new" '
      BEGIN { FS = "="; done = 0 }
      {
        line = $0; cr = ""
        if (sub(/\r$/, "", line)) cr = "\r"
        if (!done && index(line, key "=") == 1) {
          rest = substr(line, length(key) + 2); q = ""; tail = ""
          c = substr(rest, 1, 1)
          if (c == "\"" || c == "\047") { q = c; r2 = substr(rest, 2); e = index(r2, c); tail = (e ? substr(r2, e + 1) : "") }
          else if (match(rest, /[ \t]+#.*$/)) tail = substr(rest, RSTART)
          print key "=" q val q tail cr; done = 1
        } else print line cr
      }' "$envf" > "$tmp" || { rm -f "$tmp"; die "écriture impossible"; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$envf" || die "remplacement impossible (sauvegarde : $bak)"
    chk=$(val_of "$envf" "$key")
    [ "$chk" = "$new" ] && [ "$chk" != "$old" ] || { cp -p "$bak" "$envf"; die "vérification échouée — .env restauré depuis $bak"; }
    info ""; info "OK : $key renouvelé (empreinte $(fp "$old") -> $(fp "$new"))."
    info "Sauvegarde : $bak   (contient l'ANCIENNE valeur : à supprimer une fois la rotation validée)"
    info "À faire maintenant : redémarrer l'app, puis répéter la rotation sur le serveur de production."
    ;;
  *) sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
esac
