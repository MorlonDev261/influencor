#!/bin/sh
# =============================================================================
# mi-kandra-dns.sh — Vérifie que le DNS d'un domaine pointe vers CE serveur, et dit quoi faire sinon.
#
# Cette copie est IDENTIQUE dans chaque projet (poma, mga, artest…), comme mi-kandra-edge.sh.
# Lecture seule : ne modifie ni DNS, ni fichier, ni conteneur. Jamais bloquant par lui-même :
# c'est l'appelant qui décide quoi faire du code de retour.
#
# Usage :
#   mi-kandra-dns.sh ip                  Affiche l'IPv4 publique de ce serveur (détectée, jamais écrite en dur)
#   mi-kandra-dns.sh check <domaine>     Compare le DNS du domaine à l'IP de ce serveur ; si ça ne va pas,
#                                        affiche l'enregistrement exact à créer chez le gestionnaire DNS.
#   mi-kandra-dns.sh probe <domaine> [--path /api/health] [--expect texte]
#                                        Teste le lien public de bout en bout (port 443 de cette machine
#                                        puis URL publique) ; dit qui répond et quoi faire. Codes : 0 joignable,
#                                        1 injoignable, 2 indéterminé.
#
# Codes de retour de `check` :
#   0  OK (le domaine pointe ici, ou passe par le proxy Cloudflare — non vérifiable de l'extérieur)
#   1  le domaine ne se résout pas (aucun enregistrement A)
#   2  le domaine pointe vers une autre adresse que ce serveur
#   3  vérification impossible (domaine local, pas d'outil DNS, IP du serveur introuvable)
#
# Variables : MI_KANDRA_PUBLIC_IP  force l'IP du serveur (NAT, double interface, tests)
#             NO_COLOR             désactive les couleurs
#             MI_KANDRA_DNS_QUIET  =1 : n'affiche rien quand tout va bien (le code de retour suffit)
# =============================================================================
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/project.env" ] && . "$SCRIPT_DIR/project.env"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$(printf '\033[0m'); C_B=$(printf '\033[1m'); C_G=$(printf '\033[92m'); C_Y=$(printf '\033[93m'); C_RED=$(printf '\033[91m'); C_D=$(printf '\033[90m')
else
  C_R=""; C_B=""; C_G=""; C_Y=""; C_RED=""; C_D=""
fi

is_ipv4() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

is_private_ipv4() {
  printf '%s' "$1" | grep -Eq '^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)'
}

# IPv4 publique de ce serveur : variable → services externes → interface de sortie (dernier recours).
detect_public_ip() {
  if [ -n "${MI_KANDRA_PUBLIC_IP:-}" ]; then printf '%s' "$MI_KANDRA_PUBLIC_IP"; return 0; fi
  _dp_ip=""
  if command -v curl >/dev/null 2>&1; then
    for _dp_url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
      _dp_ip=$(curl -4 -fsS --max-time 4 "$_dp_url" 2>/dev/null | tr -d ' \r\n')
      is_ipv4 "$_dp_ip" && { printf '%s' "$_dp_ip"; return 0; }
    done
  elif command -v wget >/dev/null 2>&1; then
    _dp_ip=$(wget -4 -qO- --timeout=4 https://api.ipify.org 2>/dev/null | tr -d ' \r\n')
    is_ipv4 "$_dp_ip" && { printf '%s' "$_dp_ip"; return 0; }
  fi
  _dp_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  is_ipv4 "$_dp_ip" && { printf '%s' "$_dp_ip"; return 0; }
  _dp_ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  is_ipv4 "$_dp_ip" && { printf '%s' "$_dp_ip"; return 0; }
  return 1
}

# Adresses A du domaine, une par ligne. Résolveur public d'abord (évite un cache local périmé).
resolve_a() {
  _ra_out=""
  if command -v dig >/dev/null 2>&1; then
    _ra_out=$(dig +short +time=3 +tries=1 A "$1" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [ -n "$_ra_out" ] || _ra_out=$(dig +short +time=3 +tries=1 A "$1" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
  fi
  if [ -z "$_ra_out" ] && command -v nslookup >/dev/null 2>&1; then
    _ra_out=$(nslookup "$1" 1.1.1.1 2>/dev/null | awk '/^Name:/ {f=1; next} f && /^Address/ {print $NF}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
  fi
  if [ -z "$_ra_out" ] && command -v getent >/dev/null 2>&1; then
    _ra_out=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u)
  fi
  printf '%s' "$_ra_out"
}

# 0 si l'adresse est dans une plage Cloudflare (proxy « nuage orange »).
is_cloudflare_ip() {
  printf '%s' "$1" | awk -F. '
    function ip2n(a,b,c,d) { return ((a*256+b)*256+c)*256+d }
    function inr(n, base, bits,   size) { size = 2 ^ (32 - bits); return (n >= base && n < base + size) }
    { n = ip2n($1,$2,$3,$4); ok = 0
      split("173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22", R, " ")
      for (i in R) { split(R[i], p, "/"); split(p[1], q, "."); if (inr(n, ip2n(q[1],q[2],q[3],q[4]), p[2])) ok = 1 }
      exit ok ? 0 : 1 }'
}

# Découpe domaine → « nom » et « zone » probables pour l'enregistrement (suppose une zone à 2 niveaux).
split_name_zone() {
  _sn_dots=$(printf '%s' "$1" | tr -cd '.' | wc -c | tr -d ' ')
  if [ "$_sn_dots" -ge 2 ]; then
    NAME_PART=${1%%.*}; ZONE_PART=${1#*.}
  else
    NAME_PART="@"; ZONE_PART="$1"
  fi
}

print_fix() {
  # $1 = domaine, $2 = IP du serveur, $3 = état actuel (texte)
  split_name_zone "$1"
  printf '\n  %b✗ DNS : %s ne pointe pas vers ce serveur%b\n' "$C_RED" "$1" "$C_R"
  printf '    Actuellement : %s\n\n' "$3"
  printf '  %bÀ faire chez votre gestionnaire DNS%b (Cloudflare : votre zone %s → DNS → Records) :\n\n' "$C_B" "$C_R" "$ZONE_PART"
  printf '      %bType   Nom                      Contenu            Proxy%b\n' "$C_D" "$C_R"
  printf '      %bA%b      %-24s %b%-18s%b Proxied (nuage orange) conseillé — « DNS only » accepté\n\n' "$C_G" "$C_R" "$NAME_PART" "$C_G" "$2" "$C_R"
  printf '    %b•%b « %s » est l'"'"'adresse publique détectée de CE serveur.\n' "$C_D" "$C_R" "$2"
  [ "$NAME_PART" = "@" ] || printf '    %b•%b Nom « %s » = %s dans la zone %s (si votre zone est %s).\n' "$C_D" "$C_R" "$NAME_PART" "$1" "$ZONE_PART" "$ZONE_PART"
  printf '    %b•%b Nuage orange (proxy) : compatible. Mode SSL Cloudflare : Full (strict). nginx restitue l'"'"'IP réelle des visiteurs\n      (nginx/snippets/mi-kandra-cloudflare.conf, ne croit CF-Connecting-IP que s'"'"'il vient de Cloudflare).\n' "$C_D" "$C_R"
  printf '    %b•%b À garder en « DNS only » (non proxifiable) : tout service qui n'"'"'est pas du HTTP(S) (ex. TURN/WebRTC) ;\n      les requêtes proxifiées sont limitées à 100 Mo et coupées après ~100 s (erreur 524).\n' "$C_D" "$C_R"
  printf '    %b•%b La propagation prend de quelques minutes à quelques heures. Vérifiez : dig +short %s @1.1.1.1\n' "$C_D" "$C_R" "$1"
  printf '    %b•%b Tant que ce n'"'"'est pas fait, le site est injoignable par ce nom même si les services tournent.\n\n' "$C_D" "$C_R"
}

cmd_check() {
  _domain=$(printf '%s' "${1:-}" | tr -d ' \r' | tr '[:upper:]' '[:lower:]')
  _domain=${_domain#http://}; _domain=${_domain#https://}; _domain=${_domain%%/*}
  if [ -z "$_domain" ] || [ "$_domain" = "localhost" ] || ! printf '%s' "$_domain" | grep -q '\.'; then
    printf '  %b→%b DNS : domaine local ou vide, vérification ignorée.\n' "$C_D" "$C_R"; return 3
  fi
  case "$_domain" in *[!a-z0-9.*-]*) printf '  %b→%b DNS : nom de domaine invalide (%s).\n' "$C_Y" "$C_R" "$_domain"; return 3 ;; esac
  # Domaine générique (*.exemple.org) : on contrôle l'apex.
  _domain=${_domain#\*.}

  _server_ip=$(detect_public_ip) || { printf '  %b⚠%b DNS : IP publique de ce serveur introuvable (hors-ligne ?). Définissez MI_KANDRA_PUBLIC_IP.\n' "$C_Y" "$C_R"; return 3; }
  if ! command -v dig >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1 && ! command -v getent >/dev/null 2>&1; then
    printf '  %b⚠%b DNS : aucun outil de résolution (dig, nslookup, getent) — vérification ignorée.\n' "$C_Y" "$C_R"; return 3
  fi

  _found=$(resolve_a "$_domain")
  if [ -z "$_found" ]; then
    print_fix "$_domain" "$_server_ip" "aucun enregistrement A trouvé (le domaine ne se résout pas)"
    is_private_ipv4 "$_server_ip" && printf '  %b⚠%b L'"'"'adresse détectée (%s) est privée : serveur derrière un NAT. Utilisez l'"'"'IP publique indiquée par votre hébergeur.\n\n' "$C_Y" "$C_R" "$_server_ip"
    return 1
  fi

  _all_cf=1; _match=0
  for _ip in $_found; do
    [ "$_ip" = "$_server_ip" ] && _match=1
    is_cloudflare_ip "$_ip" || _all_cf=0
  done

  if [ "$_match" = "1" ]; then
    [ -n "${MI_KANDRA_DNS_QUIET:-}" ] || printf '  %b✓%b DNS : %s → %s (ce serveur)\n' "$C_G" "$C_R" "$_domain" "$_server_ip"; return 0
  fi
  if [ "$_all_cf" = "1" ]; then
    [ -z "${MI_KANDRA_DNS_QUIET:-}" ] || return 0
    printf '  %b✓%b DNS : %s passe par le proxy Cloudflare (%s). L'"'"'adresse du serveur ne peut pas être vérifiée de l'"'"'extérieur ;\n' "$C_G" "$C_R" "$_domain" "$(printf '%s' "$_found" | head -1)"
    printf '    %bvérifiez dans Cloudflare que l'"'"'enregistrement A vise %s et que le mode SSL est Full (strict).%b\n' "$C_D" "$_server_ip" "$C_R"
    return 0
  fi
  print_fix "$_domain" "$_server_ip" "$(printf '%s' "$_found" | tr '\n' ' ') (une autre adresse que ce serveur)"
  return 2
}

# ── probe : le lien public fonctionne-t-il VRAIMENT ? ────────────────────────────────────────────────
# Les contrôles « internes » (conteneurs sains, nginx du projet qui route depuis son propre conteneur) ne
# disent rien de ce que voit un visiteur : un AUTRE nginx peut tenir le port 443 de la machine. On teste le
# chemin réel :
#   1. le port 443 de CETTE machine, pour ce domaine (SNI + Host) : qui répond, et est-ce l'application ?
#   2. l'URL publique, via DNS/Cloudflare éventuel, comme un visiteur.
#   probe <domaine> [--path /api/health] [--expect 'texte attendu dans le corps']
# Codes : 0 joignable · 1 injoignable (cause expliquée, commande à lancer) · 2 indéterminé (curl absent, domaine local).
holders_443() {
  command -v docker >/dev/null 2>&1 || return 0
  docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | awk -F'|' '$2 ~ /:443->/ {print $1}' | tr '\n' ' '
}

cmd_probe() {
  pr_dom=$(printf '%s' "${1:-}" | tr -d ' \r' | tr '[:upper:]' '[:lower:]'); shift
  pr_path=/api/health; pr_expect=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --path) pr_path=${2:-/api/health}; shift 2 ;;
      --expect) pr_expect=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  pr_dom=${pr_dom#http://}; pr_dom=${pr_dom#https://}; pr_dom=${pr_dom%%/*}
  case "$pr_dom" in ''|localhost|*[!a-z0-9.-]*) return 2 ;; esac
  printf '%s' "$pr_dom" | grep -q '\.' || return 2
  command -v curl >/dev/null 2>&1 || { printf '  %b→%b curl absent : accès public non vérifié.\n' "$C_D" "$C_R"; return 2; }
  pr_url="https://${pr_dom}"

  # 1) Port 443 de cette machine, pour ce domaine.
  pr_out=$(curl -sk -m 8 --resolve "${pr_dom}:443:127.0.0.1" -w '\n%{http_code}' "${pr_url}${pr_path}" 2>/dev/null)
  pr_lcode=${pr_out##*
}
  pr_lbody=${pr_out%
*}
  pr_local_ok=0
  if [ "$pr_lcode" = "200" ]; then
    if [ -z "$pr_expect" ] || printf '%s' "$pr_lbody" | grep -qF "$pr_expect"; then pr_local_ok=1; fi
  fi

  # 2) URL publique.
  pr_pcode=$(curl -s -m 15 -o /dev/null -w '%{http_code}' "${pr_url}${pr_path}" 2>/dev/null)

  if [ "$pr_local_ok" = "1" ] && [ "$pr_pcode" = "200" ]; then
    printf '  %b✓%b %bAccès public vérifié%b : %s répond (HTTP 200, %s)\n' "$C_G" "$C_R" "$C_B" "$C_R" "$pr_url" "$pr_path"
    return 0
  fi

  printf '  %b✗%b %b%s n'"'"'est PAS joignable%b — les services tournent, mais le lien public ne mène pas à cette application.\n' "$C_RED" "$C_R" "$C_B" "$pr_url" "$C_R"
  if [ "$pr_local_ok" != "1" ]; then
    case "$pr_lcode" in
      000|'') pr_what="aucune réponse valide (connexion refusée ou échange TLS rejeté)" ;;
      *) pr_what="réponse HTTP ${pr_lcode}, qui n'est pas celle de l'application" ;;
    esac
    printf '    %b•%b Port 443 de ce serveur, pour %s : %s.\n' "$C_D" "$C_R" "$pr_dom" "$pr_what"
    pr_h=$(holders_443)
    if [ -z "$pr_h" ]; then
      printf '    %b➜%b Aucun conteneur ne publie 443 : le nginx du projet est-il démarré ? (docker compose up -d nginx)\n' "$C_Y" "$C_R"
    elif printf '%s' "$pr_h" | grep -q 'mi-kandra-edge'; then
      printf '    %b➜%b Le routeur Mi Kandra tient 443 mais ne route pas ce domaine : %bsh scripts/edge/mi-kandra-edge.sh sync%b puis %bstatus%b\n' "$C_Y" "$C_R" "$C_B" "$C_R" "$C_B" "$C_R"
    elif [ -n "${MI_KANDRA_PROJECT:-}" ] && ! printf '%s' "$pr_h" | grep -q "$MI_KANDRA_PROJECT"; then
      printf '    %b•%b Le port 443 est tenu par : %b%s%b — pas par le nginx de ce projet.\n' "$C_D" "$C_R" "$C_B" "$pr_h" "$C_R"
      printf '    %b➜%b Faites cohabiter les applications, en une commande : %bsh scripts/edge/mi-kandra-edge.sh adopt --pull --yes%b\n' "$C_Y" "$C_R" "$C_B" "$C_R"
      printf '      (met à jour les applications trop anciennes — git pull + recréation de leur seul nginx — puis partage 80/443 ; coupure de quelques secondes)\n'
    else
      printf '    %b➜%b Le nginx de ce projet tient 443 mais ne sert pas ce domaine : vérifiez le domaine configuré et le certificat (diagnostic du projet).\n' "$C_Y" "$C_R"
    fi
  fi
  case "$pr_pcode" in
    200) printf '    %b•%b Depuis Internet : HTTP 200 (la sonde interne a échoué, pas la publique : réessayez).\n' "$C_D" "$C_R" ;;
    000) printf '    %b•%b Depuis Internet : aucune réponse (DNS absent, ou coupure réseau).\n' "$C_D" "$C_R" ;;
    520) printf '    %b•%b Depuis Internet : erreur Cloudflare 520 — le serveur a coupé la connexion ou répondu de façon invalide.\n' "$C_D" "$C_R" ;;
    521) printf '    %b•%b Depuis Internet : erreur Cloudflare 521 — le serveur refuse la connexion (nginx arrêté ou pare-feu).\n' "$C_D" "$C_R" ;;
    522|524) printf '    %b•%b Depuis Internet : erreur Cloudflare %s — le serveur ne répond pas à temps.\n' "$C_D" "$C_R" "$pr_pcode" ;;
    525|526) printf '    %b•%b Depuis Internet : erreur Cloudflare %s — échange TLS avec le serveur impossible : mode SSL « Full (strict) » et certificat valide requis.\n' "$C_D" "$C_R" "$pr_pcode" ;;
    *) printf '    %b•%b Depuis Internet : HTTP %s.\n' "$C_D" "$C_R" "$pr_pcode" ;;
  esac
  return 1
}

case "${1:-}" in
  ip)    detect_public_ip || { echo "IP publique introuvable" >&2; exit 1; }; echo ;;
  check) shift; cmd_check "${1:-}"; exit $? ;;
  probe) shift; cmd_probe "$@"; exit $? ;;
  *)     sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
