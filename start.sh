#!/bin/sh
# =============================================================================
# start.sh — Influencor (web) sur un serveur Mi Kandra.
#
# influencor.mi-kandra.org sert le site vitrine (dépôt influencor-web) : l'app web Flutter
# n'est servie que sur les domaines ajoutés avec --domain-add.
#
#   ./start.sh            démarre nginx (sert build/web), cohabite avec les autres stacks
#   ./start.sh --build    construit d'abord le site (flutter build web --release)
#   ./start.sh --stop     arrête le conteneur
#   ./start.sh --logs     journaux du nginx, lisibles (--errors, --grep <texte>, --since 1h, --raw)
#   ./start.sh --status   état Mi Kandra (mode, routes) + sonde publique de chaque domaine
#
# Domaines — à chaud : l'app n'est jamais redémarrée (nginx -s reload, sans coupure) :
#   ./start.sh --domains                        liste les domaines, l'origine et l'expiration du certificat
#   ./start.sh --domain-add <domaine> [--force] ajoute un domaine : contrôle DNS, test HTTP-01,
#                                               certificat Let's Encrypt, vérification HTTPS.
#                                               Échec = retour arrière complet. --force ignore le DNS.
#   ./start.sh --domain-remove <domaine> [--purge]
#                                               retire un domaine (--purge supprime aussi son
#                                               certificat Let's Encrypt)
#   ./start.sh --renew                          renouvelle les certificats Let's Encrypt (< 30 jours)
#                                               puis recharge nginx. À planifier, par ex. (crontab root) :
#                                               17 3 * * * /chemin/influencor/start.sh --renew >/dev/null
#
# Certificat d'un domaine, par ordre de priorité : nginx/certs/<domaine>/{fullchain,privkey}.pem
# (manuel, ex. Cloudflare Origin Certificate) · Let's Encrypt (nginx/letsencrypt/, émis ici) ·
# ancien certificat unique nginx/certs/fullchain.pem s'il couvre le domaine.
# Liste des domaines : nginx/sites/domains.list (un par ligne) ; vhosts générés : nginx/sites/*.conf.
#
# Modes (détectés par scripts/edge/mi-kandra-edge.sh) : autonome (80/443 libres, nginx les
# publie), partagé (routeur Mi Kandra actif), en attente (80/443 pris par un voisin → `adopt`).
# =============================================================================
set -eu

PROJECT_ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$PROJECT_ROOT"
EDGE="sh scripts/edge/mi-kandra-edge.sh"
DNS="sh scripts/edge/mi-kandra-dns.sh"

# Git Bash (Windows) : pas de réécriture des chemins Unix passés à docker ; chemin natif pour -v.
MSYS_NO_PATHCONV=1; MSYS2_ARG_CONV_EXCL='*'; export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
ROOT_NATIVE=$(pwd -W 2>/dev/null || pwd)

NGINX_CTR=influencor-nginx
NGINX_IMAGE=nginx:1.27.5-alpine
CERTBOT_IMAGE=certbot/certbot:v2.11.0
SITES=nginx/sites
DOMAINS_LIST=$SITES/domains.list
ACME_DIR=nginx/acme
LE_DIR=nginx/letsencrypt
LOCK=$SITES/.lock
# Domaine désormais servi par le site vitrine (dépôt influencor-web).
SITE_DOMAIN=influencor.mi-kandra.org

die()  { printf 'Erreur : %s\n' "$*" >&2; exit 1; }
say()  { printf '→ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }

# Valeur d'une clé du .env (sans guillemets).
env_value() { [ -f .env ] && sed -n "s/^$1=//p" .env | tail -n 1 | tr -d '"\r' || true; }

[ -f .env ] || { cp .env.example .env && chmod 600 .env 2>/dev/null; echo "→ .env créé depuis .env.example (vérifiez-le)."; }
# shellcheck disable=SC1091
. scripts/edge/project.env

command -v docker >/dev/null 2>&1 || die "docker est requis."

# ── Domaines ─────────────────────────────────────────────────────────────────
norm_domain() {
  printf '%s' "$1" | tr -d ' \r' | tr '[:upper:]' '[:lower:]' | sed 's#^http://##;s#^https://##;s#/.*$##;s/\.$//'
}
is_domain() {
  [ "${#1}" -le 253 ] && printf '%s' "$1" | grep -Eq '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$'
}
domains()    { [ -f "$DOMAINS_LIST" ] && sed 's/#.*//' "$DOMAINS_LIST" | tr -d ' \t\r' | grep . || true; }
has_domain() { domains | grep -Fqx "$1"; }

# Dossiers générés + premier passage : l'ancien INFLUENCOR_DOMAIN amorce la liste.
init_sites() {
  mkdir -p "$SITES" "$ACME_DIR/.well-known/acme-challenge" "$LE_DIR" nginx/certs
  [ -f "$DOMAINS_LIST" ] && return 0
  legacy=$(norm_domain "$(env_value INFLUENCOR_DOMAIN)")
  {
    echo "# Domaines servis par Influencor (un par ligne)."
    echo "# Géré par ./start.sh --domain-add / --domain-remove : préférez ces commandes à l'édition manuelle."
    if [ -n "$legacy" ] && [ "$legacy" != "$SITE_DOMAIN" ]; then echo "$legacy"; fi
  } > "$DOMAINS_LIST"
}

# Un seul ajout/retrait à la fois (le routeur partagé et nginx sont rechargés à chaque fois).
lock() {
  mkdir "$LOCK" 2>/dev/null || die "une autre opération sur les domaines est en cours (sinon : rmdir $LOCK)."
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
  trap 'exit 130' INT TERM
}

# ── Certificats ──────────────────────────────────────────────────────────────
# Le certificat Let's Encrypt de $1 existe-t-il ? (live/ et archive/ sont réservés à root :
# hors root, on regarde depuis un conteneur jetable.)
le_has() {
  [ -d "$LE_DIR/live" ] || return 1
  if [ -r "$LE_DIR/live" ] && [ -x "$LE_DIR/live" ]; then
    [ -f "$LE_DIR/live/$1/fullchain.pem" ]; return
  fi
  docker run --rm --entrypoint test -v "$ROOT_NATIVE/$LE_DIR:/le:ro" "$NGINX_IMAGE" \
    -f "/le/live/$1/fullchain.pem" 2>/dev/null
}

# Ancien certificat unique (SSL_CERT_PATH) : utilisé seulement s'il couvre le domaine.
legacy_covers() {
  lc_cert=$(env_value SSL_CERT_PATH); lc_cert=${lc_cert:-/etc/nginx/certs/fullchain.pem}
  lc_file="nginx/certs/$(basename "$lc_cert")"
  [ -f "$lc_file" ] || return 1
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -in "$lc_file" -noout -checkhost "$1" 2>/dev/null | grep -q 'does match'
  else
    [ "$1" = "$(norm_domain "$(env_value INFLUENCOR_DOMAIN)")" ]
  fi
}

# « <source> <cert> <clé> » (chemins dans le conteneur) pour $1, ou rien. Toujours code 0.
cert_for() {
  if [ -f "nginx/certs/$1/fullchain.pem" ] && [ -f "nginx/certs/$1/privkey.pem" ]; then
    echo "manuel /etc/nginx/certs/$1/fullchain.pem /etc/nginx/certs/$1/privkey.pem"
  elif le_has "$1"; then
    echo "letsencrypt /etc/letsencrypt/live/$1/fullchain.pem /etc/letsencrypt/live/$1/privkey.pem"
  elif legacy_covers "$1"; then
    lk=$(env_value SSL_KEY_PATH); lc=$(env_value SSL_CERT_PATH)
    echo "ancien ${lc:-/etc/nginx/certs/fullchain.pem} ${lk:-/etc/nginx/certs/privkey.pem}"
  fi
  return 0
}

certbot() {
  docker run --rm \
    -v "$ROOT_NATIVE/$LE_DIR:/etc/letsencrypt" \
    -v "$ROOT_NATIVE/$ACME_DIR:/var/www/acme" \
    "$CERTBOT_IMAGE" "$@"
}

# ── Vhosts ───────────────────────────────────────────────────────────────────
# nginx/sites/<domaine>.conf. Sans certificat : HTTP seul (challenge ACME, 503 ailleurs).
render_site() {
  rs_d=$1; rs_out="$SITES/$rs_d.conf"
  rs_cert=$(cert_for "$rs_d")
  {
    echo "# Généré par start.sh — ne pas éditer (régénéré à chaque démarrage et à chaque --domain-*)."
    echo "server {"
    echo "    listen 80;"
    echo "    include /etc/nginx/snippets/mi-kandra-listen-http.conf;"
    echo "    server_name $rs_d;"
    echo "    include /etc/nginx/snippets/acme-challenge.conf;"
    if [ -n "$rs_cert" ]; then
      echo '    location / { return 301 https://$host$request_uri; }'
    else
      echo "    # Certificat pas encore émis : seul le challenge ACME répond."
      echo "    location / { return 503; }"
    fi
    echo "}"
    if [ -n "$rs_cert" ]; then
      # shellcheck disable=SC2086
      set -- $rs_cert
      echo ""
      echo "# Certificat : $1"
      echo "server {"
      echo "    listen 443 ssl;"
      echo "    include /etc/nginx/snippets/mi-kandra-listen-tls.conf;"
      echo "    http2 on;"
      echo "    server_name $rs_d;"
      echo "    ssl_certificate     $2;"
      echo "    ssl_certificate_key $3;"
      echo "    include /etc/nginx/snippets/influencor-app.conf;"
      echo "}"
    fi
  } > "$rs_out.tmp"
  mv -f "$rs_out.tmp" "$rs_out"
}

# Régénère tous les vhosts et supprime ceux des domaines retirés de la liste.
render_all() {
  for ra_d in $(domains); do render_site "$ra_d"; done
  for ra_f in "$SITES"/*.conf; do
    [ -f "$ra_f" ] || continue
    has_domain "$(basename "$ra_f" .conf)" || rm -f "$ra_f"
  done
}

# ── nginx & routeur (à chaud) ────────────────────────────────────────────────
nginx_running() { [ "$(docker inspect -f '{{.State.Running}}' "$NGINX_CTR" 2>/dev/null)" = "true" ]; }

# nginx -t puis reload gracieux : les connexions en cours ne sont pas coupées.
reload_nginx() {
  if ! docker exec "$NGINX_CTR" nginx -t >/dev/null 2>&1; then
    docker exec "$NGINX_CTR" nginx -t >&2 || true
    return 1
  fi
  docker exec "$NGINX_CTR" nginx -s reload >/dev/null 2>&1
}

# Juste après `compose up` : attend que nginx serve sa configuration complète (même sonde que le healthcheck).
wait_nginx() {
  wn_i=0
  until docker exec "$NGINX_CTR" wget -q -O /dev/null http://127.0.0.1/healthz 2>/dev/null; do
    wn_i=$((wn_i + 1)); [ "$wn_i" -lt 30 ] || return 1; sleep 1
  done
}

# Le conteneur en marche lit-il bien la liste à chaud ? (Sinon il date d'avant cette fonction.)
require_live_container() {
  [ -n "$(docker inspect -f '{{index .Config.Labels "org.mi-kandra.domains-file"}}' "$NGINX_CTR" 2>/dev/null)" ] \
    || die "le conteneur $NGINX_CTR date d'avant la gestion des domaines : lancez ./start.sh une fois (recréation unique), puis recommencez."
}

# Mode Mi Kandra + ports locaux par lesquels joindre ce nginx.
detect_mode() {
  MODE=${MI_KANDRA_EDGE_MODE:-}
  [ -n "$MODE" ] || MODE=$($EDGE env 2>/dev/null | sed -n 's/^export MI_KANDRA_EDGE_MODE=//p')
  MODE=${MODE:-standalone}
  case "$MODE" in
    pending|isolated) HTTP_PORT=$MI_KANDRA_DIAG_HTTP; HTTPS_PORT=$MI_KANDRA_DIAG_HTTPS ;;
    *)                HTTP_PORT=80; HTTPS_PORT=443 ;;
  esac
}

# Routeur partagé : il relit nginx/sites/domains.list dans le conteneur (aucun redémarrage).
edge_sync() {
  [ "$MODE" = "shared" ] || return 0
  $EDGE register || warn "routeur partagé non mis à jour : sh scripts/edge/mi-kandra-edge.sh doctor"
}

# ── Vérifications ────────────────────────────────────────────────────────────
# Test HTTP-01 avant Let's Encrypt (les échecs y sont limités en nombre) : jeton servi en local,
# puis, à titre indicatif, par l'URL publique.
acme_selftest() {
  command -v curl >/dev/null 2>&1 || { warn "curl absent : test HTTP-01 préalable ignoré."; return 0; }
  at_tok="mk-test-$(date +%s)-$$"; at_file="$ACME_DIR/.well-known/acme-challenge/$at_tok"
  printf '%s' "$at_tok" > "$at_file" 2>/dev/null || { warn "écriture impossible dans $ACME_DIR : test HTTP-01 ignoré."; return 0; }
  at_local=$(curl -s -m 10 --resolve "$1:$HTTP_PORT:127.0.0.1" "http://$1:$HTTP_PORT/.well-known/acme-challenge/$at_tok" 2>/dev/null || true)
  at_pub=$(curl -s -m 15 "http://$1/.well-known/acme-challenge/$at_tok" 2>/dev/null || true)
  rm -f "$at_file"
  if [ "$at_local" != "$at_tok" ]; then
    warn "$1 : le challenge ACME n'est pas servi en local (127.0.0.1:$HTTP_PORT). Routeur : sh scripts/edge/mi-kandra-edge.sh doctor"
    return 1
  fi
  [ "$at_pub" = "$at_tok" ] && say "$1 : challenge HTTP-01 joignable publiquement." \
    || warn "$1 : challenge injoignable par l'URL publique (DNS pas encore propagé ? port 80 fermé ? Cloudflare « Always Use HTTPS » ?). Tentative Let's Encrypt quand même."
  return 0
}

issue_cert() {
  [ -z "$(cert_for "$1")" ] || return 0
  case "$MODE" in
    pending)  warn "$1 : 80/443 sont tenus par un voisin non converti, Let's Encrypt ne peut pas joindre ce nginx → sh scripts/edge/mi-kandra-edge.sh adopt"; return 1 ;;
    isolated) warn "$1 : mode autonome en loopback, Let's Encrypt ne peut pas joindre ce nginx. Placez un certificat dans nginx/certs/$1/ ou cohabitez (mi-kandra-edge.sh choose --reset)."; return 1 ;;
  esac
  acme_selftest "$1" || return 1
  ic_email=$(env_value LETSENCRYPT_EMAIL)
  if [ -n "$ic_email" ]; then set -- "$1" --email "$ic_email"; else set -- "$1" --register-unsafely-without-email; fi
  [ "$(env_value LETSENCRYPT_STAGING)" = "1" ] && set -- "$@" --staging
  ic_d=$1; shift
  say "$ic_d : demande du certificat Let's Encrypt…"
  certbot certonly --webroot -w /var/www/acme -d "$ic_d" --cert-name "$ic_d" \
    --non-interactive --agree-tos --keep-until-expiring "$@" \
    || { warn "$ic_d : Let's Encrypt a refusé (voir ci-dessus)."; return 1; }
  [ -n "$(cert_for "$ic_d")" ] || { warn "$ic_d : certificat introuvable après certbot."; return 1; }
}

# Certificat réellement servi pour $1 (SNI) : « notAfter=… », ou rien.
served_enddate() {
  command -v openssl >/dev/null 2>&1 || return 0
  openssl s_client -connect "127.0.0.1:$HTTPS_PORT" -servername "$1" </dev/null 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null || true
}

# HTTPS de bout en bout en local, chaîne de certificats VÉRIFIÉE (sauf autorité de test).
verify_https() {
  command -v curl >/dev/null 2>&1 || { warn "curl absent : vérification HTTPS ignorée."; return 0; }
  vh_k=""; [ "$(env_value LETSENCRYPT_STAGING)" = "1" ] && vh_k="-k"
  vh_code=$(curl -s $vh_k -m 15 -o /dev/null -w '%{http_code}' --resolve "$1:$HTTPS_PORT:127.0.0.1" "https://$1:$HTTPS_PORT/" 2>/dev/null || true)
  case "$vh_code" in
    2??|3??) say "$1 : HTTPS OK ($vh_code), certificat valide $(served_enddate "$1" | sed 's/^notAfter=/jusqu'"'"'au /')" ;;
    *) warn "$1 : HTTPS en échec en local (code '${vh_code:-aucun}') — certificat invalide pour ce nom ?"; return 1 ;;
  esac
}

# ── Commandes « domaines » ───────────────────────────────────────────────────
cmd_domains() {
  init_sites; detect_mode
  [ -n "$(domains)" ] || { say "Aucun domaine. Ajout : ./start.sh --domain-add exemple.com"; return 0; }
  nginx_running || warn "$NGINX_CTR arrêté : expiration non vérifiable (./start.sh)."
  printf '%-40s %-12s %s\n' DOMAINE CERTIFICAT "EXPIRATION (servie)"
  for cd_d in $(domains); do
    cd_src=$(cert_for "$cd_d" | cut -d' ' -f1)
    cd_end=""; nginx_running && cd_end=$(served_enddate "$cd_d" | sed 's/^notAfter=//')
    printf '%-40s %-12s %s\n' "$cd_d" "${cd_src:-aucun}" "${cd_end:--}"
  done
}

cmd_domain_add() {
  da_d=$(norm_domain "$1")
  [ -n "$da_d" ] || die "usage : ./start.sh --domain-add <domaine> [--force]"
  is_domain "$da_d" || die "nom de domaine invalide : '$da_d' (les domaines génériques *.… ne sont pas pris en charge)."
  [ "$da_d" != "$SITE_DOMAIN" ] || die "$SITE_DOMAIN sert le site vitrine (dépôt influencor-web)."
  init_sites; lock; detect_mode

  if [ "$FORCE" = 1 ]; then
    warn "--force : contrôle DNS ignoré."
  else
    da_rc=0; $DNS check "$da_d" || da_rc=$?
    case "$da_rc" in
      1|2) die "le DNS de $da_d ne pointe pas vers ce serveur (voir ci-dessus). Corrigez-le, ou --force." ;;
    esac
  fi

  da_new=0
  if has_domain "$da_d"; then say "$da_d est déjà dans la liste : vérification du certificat."
  else printf '%s\n' "$da_d" >> "$DOMAINS_LIST"; da_new=1; fi
  render_site "$da_d"

  if ! nginx_running; then
    say "$da_d enregistré. $NGINX_CTR est arrêté : domaine et certificat seront traités au prochain ./start.sh."
    return 0
  fi
  require_live_container

  # Retour arrière : un domaine qui n'obtient pas son certificat ne reste pas à moitié servi.
  rollback() {
    [ "$da_new" = 1 ] || return 0
    warn "retour arrière : $da_d retiré."
    remove_from_list "$da_d"; rm -f "$SITES/$da_d.conf"
    reload_nginx || true; edge_sync
  }

  reload_nginx || { rollback; die "configuration nginx rejetée (voir ci-dessus)."; }
  edge_sync
  issue_cert "$da_d" || { rollback; die "aucun certificat pour $da_d : domaine non ajouté."; }
  render_site "$da_d"
  reload_nginx || { rollback; die "configuration nginx rejetée (voir ci-dessus)."; }
  verify_https "$da_d" || { rollback; die "$da_d ne répond pas correctement en HTTPS : domaine non ajouté."; }
  if [ "$da_new" = 1 ]; then say "$da_d ajouté, sans redémarrage : https://$da_d"
  else say "$da_d vérifié : https://$da_d"; fi
  $DNS probe "$da_d" || true
}

remove_from_list() {
  awk -v d="$1" '{ l = $0; sub(/#.*/, "", l); gsub(/[ \t\r]/, "", l); if (l != d) print }' \
    "$DOMAINS_LIST" > "$DOMAINS_LIST.tmp"
  mv -f "$DOMAINS_LIST.tmp" "$DOMAINS_LIST"
}

cmd_domain_remove() {
  dr_d=$(norm_domain "$1")
  [ -n "$dr_d" ] || die "usage : ./start.sh --domain-remove <domaine> [--purge]"
  init_sites
  has_domain "$dr_d" || die "$dr_d n'est pas dans la liste (./start.sh --domains)."
  lock; detect_mode
  remove_from_list "$dr_d"
  rm -f "$SITES/$dr_d.conf"
  if nginx_running; then
    require_live_container
    reload_nginx || die "configuration nginx rejetée après retrait (voir ci-dessus)."
    edge_sync
  fi
  say "$dr_d retiré, sans redémarrage."
  if [ "$PURGE" = 1 ]; then
    le_has "$dr_d" && certbot delete --cert-name "$dr_d" --non-interactive && say "$dr_d : certificat Let's Encrypt supprimé."
    [ -d "nginx/certs/$dr_d" ] && warn "certificat manuel conservé : nginx/certs/$dr_d/ (à supprimer vous-même)."
  fi
  [ -n "$(domains)" ] || warn "plus aucun domaine : l'app n'est servie nulle part (./start.sh --domain-add …)."
  return 0
}

cmd_renew() {
  init_sites; lock
  certbot renew --webroot -w /var/www/acme --non-interactive || warn "certains renouvellements ont échoué (voir ci-dessus)."
  render_all
  if nginx_running; then reload_nginx && say "certificats rechargés, sans redémarrage."; fi
}

# ── Point d'entrée ───────────────────────────────────────────────────────────
CMD=${1:-}
if [ $# -gt 0 ]; then shift; fi
# --logs a ses propres filtres (scripts/logs-view.sh) : traité avant la lecture
# des options, qui refuserait --errors, --grep…
if [ "$CMD" = "--logs" ]; then
  command -v bash >/dev/null 2>&1 || exec docker compose logs -f --tail=200 nginx
  LOGS_TITLE="Influencor" LOGS_PREFIX="influencor-" LOGS_DEFAULT_SERVICES="nginx" \
    exec bash scripts/logs-view.sh "$@"
fi
FORCE=0; PURGE=0; ARG=""
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --purge) PURGE=1 ;;
    -*) die "option inconnue : $a (voir l'en-tête de ce fichier)" ;;
    *) ARG=$a ;;
  esac
done

case "$CMD" in
  --stop)          exec docker compose down ;;
  --status)        $EDGE status || true; init_sites
                   for d in $(domains); do $DNS probe "$d" || true; done; exit 0 ;;
  --domains)       cmd_domains; exit 0 ;;
  --domain-add)    cmd_domain_add "$ARG"; exit 0 ;;
  --domain-remove) cmd_domain_remove "$ARG"; exit 0 ;;
  --renew)         cmd_renew; exit 0 ;;
  --build)         command -v flutter >/dev/null 2>&1 || die "flutter est requis pour --build."
                   flutter build web --release --no-wasm-dry-run ;;
  "") : ;;
  *) die "option inconnue : $CMD (voir l'en-tête de ce fichier)" ;;
esac

# ── Démarrage ────────────────────────────────────────────────────────────────
init_sites
[ -n "$(domains)" ] || die "aucun domaine : ajoutez-en un avec ./start.sh --domain-add <domaine> (l'app web Flutter n'est plus servie sur $SITE_DOMAIN)."
has_domain "$SITE_DOMAIN" && die "$SITE_DOMAIN sert le site vitrine : ./start.sh --domain-remove $SITE_DOMAIN"
[ -f build/web/index.html ] || die "build/web est absent : lancez ./start.sh --build (ou copiez le build web)."

# Cohabitation : choix mémorisé, puis ports de publication adaptés au mode détecté.
[ -f scripts/edge/mi-kandra-edge.sh ] && {
  $EDGE choose || true
  eval "$($EDGE env 2>/dev/null)" || true
}
detect_mode

render_all
docker compose up -d --remove-orphans

# Enregistre la route dans le routeur partagé (sans effet en mode autonome).
case "$MODE" in
  shared)  $EDGE sync || true ;;
  pending) [ "${MI_KANDRA_EDGE_AUTOADOPT:-0}" = 1 ] && $EDGE adopt --yes || true ;;
esac

# Domaines encore sans certificat : émission maintenant que nginx sert le challenge ACME.
pending_certs=""
for d in $(domains); do [ -n "$(cert_for "$d")" ] || pending_certs="$pending_certs $d"; done
if [ -n "$pending_certs" ]; then
  wait_nginx || die "$NGINX_CTR ne répond pas : docker logs $NGINX_CTR"
  reload_nginx || die "configuration nginx rejetée (voir ci-dessus)."
  for d in $pending_certs; do
    if issue_cert "$d"; then render_site "$d"
    else warn "$d : pas de certificat, servi en HTTP 503 seulement. Corrigez puis : ./start.sh --domain-add $d"; fi
  done
  reload_nginx || die "configuration nginx rejetée (voir ci-dessus)."
fi

for d in $(domains); do
  echo "→ Influencor : https://$d"
  $DNS probe "$d" || true
done
