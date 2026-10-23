#!/bin/sh
# =============================================================================
# mi-kandra-edge.sh — détection mutuelle + routage partagé entre stacks Mi Kandra
#
# Cette copie est IDENTIQUE dans chaque projet (poma, mga, artest…). Chaque
# projet reste autonome : sans routeur d'entrée et sans voisin, rien ne change
# (le nginx du projet publie 80/443 comme avant). Dès qu'un voisin est
# détecté, ce script permet de cohabiter sur le même serveur sans conflit de
# ports, sans partager de certificats, de base de données ni de secrets.
#
# Détection : chaque nginx "origin" porte des labels Docker (org.mi-kandra.*) qui
# le décrivent (projet, alias réseau, domaines, ports de diagnostic). Le
# script lit ces labels : aucun fichier de configuration central à tenir à jour.
# Facultatif : org.mi-kandra.domains-file désigne un fichier DANS l'origin listant
# des domaines supplémentaires (un par ligne), relu à chaque sync/register. Liste
# vide sans label de domaines = routes du projet retirées ; fichier illisible =
# routes conservées.
#
# Commandes :
#   env           Affiche les `export` à injecter avant `docker compose`
#                 (ports de publication selon le mode détecté).
#   status        État du routeur, des origins détectés et des routes.
#   sync          (Re)enregistre dans le routeur tous les origins en marche.
#   register      Idem, limité au projet courant.
#   unregister P  Retire les routes du projet P.
#   ensure-edge   Démarre le routeur d'entrée (nécessite 80/443 libres).
#   adopt [--yes] [--pull]
#                 Convertit les voisins qui publient déjà 80/443, démarre le routeur puis
#                 synchronise (coupure de quelques secondes). --pull met d'abord à jour (git pull +
#                 recréation de leur nginx) les voisins trop anciens pour être convertis.
#   choose        Premier démarrage : demande comment cohabiter avec les autres applications du
#                 serveur (cohabiter · autonome · plus tard) et mémorise le choix. `--reset` repose la
#                 question, `--status` affiche le choix.
#   doctor        Diagnostic complet (code retour ≠ 0 si anomalie).
#                 --probe : sonde HTTPS réelle de chaque domaine + expiration du
#                 certificat (à lancer sur le serveur).
#   release [--force]
#                 Retour au mode autonome : le routeur s'arrête et le seul projet encore
#                 en marche reprend 80/443 (coupure de quelques secondes). Refusé si
#                 plusieurs projets passent par le routeur, sauf --force (les autres
#                 restent alors en local, non publics).
#   logs [--since <durée>] [--tail <n>] [--no-follow] [--refused]
#                 Journal du routeur, lisible : heure locale, domaine demandé → projet,
#                 statut, octets, IP. --refused : seulement les connexions refusées
#                 (domaine inconnu) et les projets injoignables.
#   check-port P [tcp|udp]
#                 Qui tient le port P de l'hôte ? Code 0 = libre ou tenu par ce projet,
#                 1 = tenu par le conteneur d'un autre projet, 2 = tenu hors Docker.
#                 À appeler avant un service à port fixe (acme-dns : 53/udp).
#
# Modes : standalone (aucun voisin) · shared (routeur actif) · pending
# (80/443 pris par un voisin non encore converti → lancer `adopt`) · isolated (choix « autonome »
# alors que 80/443 sont pris : loopback seulement, rien n'est converti).
# =============================================================================
set -u

# Git Bash (Windows) : empêche la réécriture des chemins Unix passés à docker.
MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# Chemin passé à docker.exe : natif sous Git Bash/Windows (pwd -W), inchangé sous Linux.
SCRIPT_DIR_NATIVE=$(cd "$SCRIPT_DIR" && pwd -W 2>/dev/null || pwd)
EDGE_NAME="mi-kandra-edge"
EDGE_NET="mi-kandra-edge"
EDGE_ROUTES="/etc/mi-kandra-edge/routes.d"
EDGE_VOL="mi-kandra-edge-routes"

# Valeurs propres au projet d'abord, valeurs génériques ensuite (ordre important :
# un défaut posé avant la lecture de project.env le masquerait).
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/project.env" ] && . "$SCRIPT_DIR/project.env"
MI_KANDRA_PROJECT="${MI_KANDRA_PROJECT:-}"
MI_KANDRA_DIAG_HTTP="${MI_KANDRA_DIAG_HTTP:-18080}"
MI_KANDRA_DIAG_HTTPS="${MI_KANDRA_DIAG_HTTPS:-18443}"

# ── Sorties ──────────────────────────────────────────────────────────────────
# `env` doit n'écrire QUE des `export` sur stdout (il est passé à eval) : tous
# les messages vont donc sur stderr.
say()  { printf '[mi-kandra-edge] %s\n' "$*" >&2; }
ok()   { printf '[mi-kandra-edge] OK    %s\n' "$*" >&2; }
warn() { printf '[mi-kandra-edge] WARN  %s\n' "$*" >&2; }
fail() { printf '[mi-kandra-edge] FAIL  %s\n' "$*" >&2; }

# ── Validation stricte (les labels sont une entrée non fiable : un label
#    malveillant ne doit jamais pouvoir injecter de directive nginx) ──────────
is_project() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,31}$'; }
is_alias()   { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,62}$'; }
is_domain()  { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; }
is_port()    { printf '%s' "$1" | grep -Eq '^[0-9]{2,5}$'; }
# Domaine validé (lettres, chiffres, tirets, points) → motif grep littéral.
regex_escape() { printf '%s' "$1" | sed 's/\./\\./g'; }

# ── Docker ───────────────────────────────────────────────────────────────────
docker_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# "En marche" = réellement up : un conteneur en boucle de redémarrage a
# State.Running=true par intermittence, il ne doit pas compter comme actif.
edge_running() {
  [ "$(docker container inspect -f '{{.State.Status}}/{{.State.Restarting}}' "$EDGE_NAME" 2>/dev/null)" = "running/false" ]
}

edge_healthy() {
  [ "$(docker container inspect -f '{{.State.Health.Status}}' "$EDGE_NAME" 2>/dev/null)" = "healthy" ]
}

edge_exec() { docker exec -i "$EDGE_NAME" sh -c "$1"; }

# PID des workers nginx du routeur qui NE sont PAS en cours d'arrêt.
edge_worker_pids() {
  docker exec "$EDGE_NAME" sh -c "ps | grep 'nginx: worker process' | grep -v 'shutting down' | grep -v grep | awk '{print \$1}'" 2>/dev/null | sort | tr '\n' ' '
}

# Recharge le routeur ET attend que la nouvelle configuration soit réellement servie.
# `nginx -s reload` rend la main dès l'envoi du signal : tant que les nouveaux workers
# ne sont pas là, une nouvelle route est encore inconnue de ceux qui acceptent les
# connexions. Les anciens workers, eux, peuvent rester longtemps (WebSocket d'1 h) :
# on n'attend donc PAS leur fin, seulement l'apparition d'un worker neuf.
reload_edge() {
  re_old=$(edge_worker_pids)
  docker exec "$EDGE_NAME" nginx -s reload >/dev/null 2>&1 || return 1
  re_i=0
  while [ "$re_i" -lt 50 ]; do
    for re_p in $(edge_worker_pids); do
      case " $re_old " in *" $re_p "*) : ;; *) return 0 ;; esac
    done
    re_i=$((re_i + 1)); sleep 0.1
  done
  return 0   # configuration valide (nginx -t a passé) : le basculement est seulement en retard
}

# Le réseau est créé avec les labels que Compose attend : un réseau créé par un
# simple `docker network create` fait échouer `docker compose up` (label
# com.docker.compose.network manquant), alors qu'un réseau portant ce label mais
# appartenant à un autre projet Compose ne produit qu'un avertissement bénin.
ensure_network() {
  docker network inspect "$EDGE_NET" >/dev/null 2>&1 \
    || docker network create \
         --label "com.docker.compose.network=$EDGE_NET" \
         --label "com.docker.compose.project=mi-kandra-edge" \
         "$EDGE_NET" >/dev/null 2>&1 \
    || docker network inspect "$EDGE_NET" >/dev/null 2>&1
}

label() { docker inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null; }
# Label présent, même vide (label() ne distingue pas « vide » de « absent »).
has_label() { docker inspect -f '{{json .Config.Labels}}' "$1" 2>/dev/null | grep -q "\"$2\":"; }

# Domaines d'un origin : label org.mi-kandra.domains + fichier facultatif désigné
# par org.mi-kandra.domains-file (premier mot de chaque ligne, # = commentaire).
# Le fichier AJOUTE des domaines au label, il ne le remplace pas : Pôma y liste
# ses seuls domaines supplémentaires (« domaine état »), Influencor, sans label,
# tous les siens. Le fichier vit DANS le conteneur origin : un projet peut ainsi
# ajouter/retirer des domaines à chaud, sans recréer son nginx pour changer un
# label. Entrée non fiable : chemin et domaines sont validés, une ligne invalide
# est ignorée (elle ne doit pas priver le domaine principal de sa route).
#
# Code retour : 0 = liste complète (fichier lu, ou absent = aucun domaine en
# plus) ; 2 = fichier illisible (conteneur arrêté, droits…) : la liste affichée
# n'a que le label, l'appelant ne doit pas s'en servir pour retirer des routes.
origin_domains() {
  od_ctr=$1; od_rc=0
  od_list=$(label "$od_ctr" org.mi-kandra.domains)
  od_file=$(label "$od_ctr" org.mi-kandra.domains-file)
  if [ -n "$od_file" ]; then
    if printf '%s' "$od_file" | grep -Eq '^/[A-Za-z0-9._/-]+$' && ! printf '%s' "$od_file" | grep -q '\.\.'; then
      # 3 = fichier absent (aucun domaine supplémentaire), à distinguer d'un
      # échec de docker exec ou de cat.
      od_txt=$(docker exec "$od_ctr" sh -c '[ -e "$1" ] || exit 3; cat "$1"' sh "$od_file" 2>/dev/null)
      case $? in
        0)
          for od_d in $(printf '%s\n' "$od_txt" | sed 's/#.*//' | awk 'NF {print $1}'); do
            if is_domain "$od_d"; then od_list="$od_list $od_d"
            else warn "$(label "$od_ctr" org.mi-kandra.project) : domaine invalide '$od_d' ignoré ($od_file)"; fi
          done ;;
        3) ;;
        *)
          od_rc=2
          warn "$(label "$od_ctr" org.mi-kandra.project) : $od_file illisible dans $od_ctr" ;;
      esac
    else
      warn "$(label "$od_ctr" org.mi-kandra.project) : chemin org.mi-kandra.domains-file invalide ignoré"
    fi
  fi
  printf '%s' "$od_list" | sed 's/^ *//'
  return $od_rc
}

# nginx >= 1.27.3 : le paramètre `resolve` des upstreams (résolution DNS dynamique)
# n'existe pas avant. Un serveur qui garde en cache une vieille image « 1.27 »
# refuserait de démarrer nginx : on le détecte AVANT. Codes : 0 ok, 1 trop
# ancien, 2 version illisible.
nginx_version_ok() {
  nv_v=$(docker exec "$1" nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p')
  [ -n "$nv_v" ] || return 2
  nv_ma=${nv_v%%.*}; nv_r=${nv_v#*.}; nv_mi=${nv_r%%.*}; nv_pa=${nv_r#*.}; nv_pa=${nv_pa%%.*}
  [ "$nv_ma" -gt 1 ] && return 0
  [ "$nv_ma" -lt 1 ] && return 1
  [ "$nv_mi" -gt 27 ] && return 0
  [ "$nv_mi" -lt 27 ] && return 1
  [ "${nv_pa:-0}" -ge 3 ]
}

# Conteneurs en marche qui publient 80 ou 443 sur l'hôte : "nom|projet|rôle".
port_holders() {
  docker ps --format '{{.Names}}|{{.Label "org.mi-kandra.project"}}|{{.Label "org.mi-kandra.role"}}|{{.Ports}}' 2>/dev/null \
    | awk -F'|' '$4 ~ /:(80|443)->/ { print $1 "|" $2 "|" $3 }'
}

# Même chose, sans le projet courant (son propre nginx n'est pas un conflit).
foreign_port_holders() {
  port_holders | awk -F'|' -v me="$MI_KANDRA_PROJECT" '$2 != me || me == ""'
}

# Processus hors Docker qui écoute sur 80/443 (Linux avec `ss`, au mieux).
external_port_holder() {
  command -v ss >/dev/null 2>&1 || return 1
  [ -n "$(port_holders)" ] && return 1
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)(80|443)$'
}

list_origins() {
  docker ps --filter "label=org.mi-kandra.role=origin" --format '{{.Names}}' 2>/dev/null
}

# ── Préférence de cohabitation (choisie une fois, au premier démarrage) ─────
# Fichier local au projet, non versionné : MI_KANDRA_EDGE_PREF=cohabit | standalone.
#   cohabit     partager 80/443 avec les autres applications via le routeur Mi Kandra
#   standalone  « autonome » : ignorer les autres applications (ne rien convertir, ne rien enregistrer)
# Absent = la question sera posée au prochain démarrage interactif (commande `choose`).
PREF_FILE="${MI_KANDRA_EDGE_PREF_FILE:-$SCRIPT_DIR/../../.mi-kandra-edge.pref}"
pref_get() { [ -f "$PREF_FILE" ] && sed -n 's/^MI_KANDRA_EDGE_PREF=//p' "$PREF_FILE" 2>/dev/null | head -1 | tr -d ' \r"'; }
pref_set() { printf 'MI_KANDRA_EDGE_PREF=%s\n' "$1" > "$PREF_FILE" 2>/dev/null && chmod 600 "$PREF_FILE" 2>/dev/null; }

# ── Décision de mode ────────────────────────────────────────
# standalone  aucun voisin : le nginx du projet publie 80/443
# shared      un routeur Mi Kandra est actif : le projet s'y enregistre
# pending     80/443 pris par un voisin non converti : loopback seulement, en attendant `adopt`
# isolated    choix « autonome » alors que 80/443 sont pris : loopback seulement, rien n'est converti
decide_mode() {
  docker_ok || { echo standalone; return; }
  if [ "$(pref_get)" = "standalone" ]; then
    if edge_running || [ -n "$(foreign_port_holders)" ] || external_port_holder; then echo isolated; else echo standalone; fi
    return
  fi
  if edge_running; then echo shared; return; fi
  if [ -n "$(foreign_port_holders)" ] || external_port_holder; then echo pending; return; fi
  echo standalone
}

cmd_env() {
  mode=$(decide_mode)
  case "$mode" in
    standalone) : ;;
    shared|pending|isolated)
      # Le nginx du projet n'occupe plus 80/443 : il n'expose qu'un port de
      # diagnostic en loopback ; le trafic public arrive par le routeur.
      printf 'export MI_KANDRA_HTTP_PUBLISH=127.0.0.1:%s:80\n' "$MI_KANDRA_DIAG_HTTP"
      printf 'export MI_KANDRA_HTTPS_PUBLISH=127.0.0.1:%s:443\n' "$MI_KANDRA_DIAG_HTTPS"
      ;;
  esac
  printf 'export MI_KANDRA_EDGE_MODE=%s\n' "$mode"
  if [ "$mode" = "pending" ]; then
    warn "80/443 sont déjà occupés par un autre projet : ce projet démarre en loopback uniquement."
    warn "Pour le rendre public : sh scripts/edge/mi-kandra-edge.sh adopt"
  elif [ "$mode" = "isolated" ]; then
    say "Mode autonome : 80/443 sont occupés par d'autres applications, ce projet n'écoute qu'en local (127.0.0.1)."
    say "Pour cohabiter : sh scripts/edge/mi-kandra-edge.sh choose --reset"
  fi
}

# ── Premier démarrage : relation avec les autres applications du serveur ───────
# Silencieux s'il n'y a rien à décider (aucun voisin, ou choix déjà fait). Sinon, pose UNE question et
# mémorise la réponse. À lancer directement (jamais dans un $(…)) : il écrit sur le terminal.
#   choose           pose la question si nécessaire
#   choose --reset   oublie le choix précédent et repose la question
#   choose --status  affiche le choix mémorisé
neighbours_list() {
  {
    foreign_port_holders | while IFS='|' read -r n p r; do printf '%s|%s\n' "$n" "${p:-?}"; done
    for c in $(list_origins); do
      p=$(label "$c" org.mi-kandra.project)
      [ "$p" = "$MI_KANDRA_PROJECT" ] || printf '%s|%s\n' "$c" "${p:-?}"
    done
    if edge_running; then printf '%s|routeur\n' "$EDGE_NAME"; fi
  } | sort -u
}

cmd_choose() {
  case "${1:-}" in
    --status) say "choix mémorisé : $(pref_get || true)  (fichier : $PREF_FILE)"; return 0 ;;
    --reset)  rm -f "$PREF_FILE" ;;
  esac
  docker_ok || return 0
  # ASK=0 : commande annexe (logs, statut…), ni question ni conversion.
  [ "${MI_KANDRA_EDGE_ASK:-1}" != "0" ] || return 0
  cur=$(pref_get)
  # « Cohabiter » déjà choisi : un voisin qui tient 80/443 sans routeur (premier
  # voisin, ou routeur supprimé) est converti sans reposer la question. Sans ce
  # passage, le projet resterait en loopback (mode pending) malgré le choix.
  if [ "$cur" = "cohabit" ]; then
    if ! edge_running && [ -n "$(foreign_port_holders)" ]; then
      say "Choix mémorisé : cohabiter. Un voisin occupe 80/443 sans routeur : conversion …"
      cmd_adopt --yes || warn "Conversion impossible : ce projet démarre en local. Corrigez ci-dessus, puis  sh scripts/edge/mi-kandra-edge.sh adopt --pull --yes"
    fi
    return 0
  fi
  [ -z "$cur" ] || return 0
  nb=$(neighbours_list)
  if [ -z "$nb" ] && ! external_port_holder; then return 0; fi     # personne d'autre : rien à demander
  if ! { [ -t 0 ] && [ -t 1 ]; }; then
    # Sans terminal, rien n'est converti sans accord (la conversion coupe les
    # voisins quelques secondes) : si 80/443 sont pris, ce projet reste local.
    warn "D'autres applications sont sur ce serveur et aucun terminal ne permet de demander comment cohabiter."
    if ! edge_running && { [ -n "$(foreign_port_holders)" ] || external_port_holder; }; then
      warn "80/443 sont pris : ce projet ne sera PAS public. Pour cohabiter sans question :"
      warn "  MI_KANDRA_EDGE_AUTOADOPT=1 ./start.sh   (ou une fois : sh scripts/edge/mi-kandra-edge.sh adopt --yes)"
    fi
    warn "Pour mémoriser le choix : sh scripts/edge/mi-kandra-edge.sh choose (dans un terminal)."
    return 0
  fi

  printf '\n' >&2
  say "D'autres applications sont déjà installées sur ce serveur :"
  if [ -n "$nb" ]; then echo "$nb" | while IFS='|' read -r n p; do say "  • $n  (projet : $p)"; done
  else say "  • un processus hors Docker occupe 80/443"; fi
  printf '\n  Comment « %s » doit-elle se comporter ?\n\n' "${MI_KANDRA_PROJECT:-cette application}"
  printf '    1) Cohabiter (recommandé)  partager les ports 80/443 via le routeur Mi Kandra.\n'
  printf '                               Les applications déjà en place sont converties (coupure de quelques secondes).\n'
  printf "    2) Autonome                ignorer les autres applications : rien n'est converti ni enregistré.\n"
  printf '                               Si 80/443 sont déjà pris, cette application reste en local (127.0.0.1)\n'
  printf "                               tant que vous n'avez pas libéré les ports.\n"
  printf '    3) Plus tard               ne rien décider maintenant (la question sera reposée).\n\n'
  while :; do
    printf '  Votre choix [1/2/3, Entrée = 3] : ' >&2
    IFS= read -r ans || ans=3
    case "${ans:-3}" in
      1)
        pref_set cohabit
        say "Choix mémorisé : cohabiter. Conversion des applications existantes …"
        if ! cmd_adopt --yes; then
          printf '\n  Des applications sont trop anciennes pour être converties. Les mettre à jour maintenant ?\n' >&2
          printf '  (git pull dans leur dossier + recréation de leur seul nginx ; rien d'"'"'autre ne change)  [o/N] : ' >&2
          IFS= read -r upd || upd=n
          case "$upd" in
            o|O|oui|OUI|y|Y) cmd_adopt --pull --yes || warn "Conversion incomplète : suivez les consignes ci-dessus, puis  sh scripts/edge/mi-kandra-edge.sh adopt --yes" ;;
            *) warn "Conversion reportée :  sh scripts/edge/mi-kandra-edge.sh adopt --pull --yes" ;;
          esac
        fi
        return 0 ;;
      2)
        pref_set standalone
        say "Choix mémorisé : autonome. Pour changer d'avis : sh scripts/edge/mi-kandra-edge.sh choose --reset"
        return 0 ;;
      3|"") say "Choix reporté."; return 0 ;;
      *) printf '  Répondez 1, 2 ou 3.\n' >&2 ;;
    esac
  done
}


# ── Routes ───────────────────────────────────────────────────────────────────
# Écrit (de façon atomique avec retour arrière) les routes d'un projet.
# $1=projet  $2=alias réseau  $3=domaines (séparés par des espaces)
write_routes() {
  w_project=$1; w_alias=$2; w_domains=$3
  is_project "$w_project" || { fail "nom de projet invalide : '$w_project'"; return 1; }
  is_alias "$w_alias"     || { fail "alias réseau invalide : '$w_alias'"; return 1; }
  [ -n "$w_domains" ]     || { fail "$w_project : aucun domaine (label org.mi-kandra.domains vide — variable .env manquante ?)"; return 1; }

  tls_map=""; http_map=""
  for d in $w_domains; do
    d=${d#\*.}; d=${d#.}
    is_domain "$d" || { fail "$w_project : domaine invalide '$d' ignoré"; return 1; }
    # `.exemple.com` = le domaine ET tous ses sous-domaines (option hostnames).
    key=".$d"
    # Points échappés : dans une regex, « a.b.com » reconnaîtrait aussi « axb.com ».
    owner=$(edge_exec "grep -l '^$(regex_escape "$key") ' $EDGE_ROUTES/*.tls.map 2>/dev/null" | head -1)
    if [ -n "$owner" ] && [ "$owner" != "$EDGE_ROUTES/$w_project.tls.map" ]; then
      fail "$w_project : le domaine $d est déjà routé par $(basename "$owner" .tls.map) — refusé."
      return 1
    fi
    tls_map="${tls_map}${key} ${w_alias}:8443;
"
    http_map="${http_map}${key} ${w_alias}:8080;
"
  done

  cur_tls=$(edge_exec "cat $EDGE_ROUTES/$w_project.tls.map 2>/dev/null" || true)
  cur_http=$(edge_exec "cat $EDGE_ROUTES/$w_project.http.map 2>/dev/null" || true)
  new_tls_cmp=$(printf '%s' "$tls_map"); new_http_cmp=$(printf '%s' "$http_map")
  if [ "$cur_tls" = "$new_tls_cmp" ] && [ "$cur_http" = "$new_http_cmp" ]; then
    ok "$w_project : routes déjà à jour ($w_domains → $w_alias)"
    return 0
  fi

  # Configuration déjà cassée AVANT notre écriture (fichier étranger, volume
  # corrompu…) : on n'y touche pas, sinon on ne saurait plus qui est fautif.
  docker exec "$EDGE_NAME" nginx -t >/dev/null 2>&1 \
    || { fail "$w_project : la configuration du routeur est déjà invalide avant modification (docker exec $EDGE_NAME nginx -t)."; return 1; }

  edge_exec "mkdir -p $EDGE_ROUTES/.bak && for s in tls http; do [ -f $EDGE_ROUTES/$w_project.\$s.map ] && cp $EDGE_ROUTES/$w_project.\$s.map $EDGE_ROUTES/.bak/$w_project.\$s.map; done; true"
  printf '%s\n' "$tls_map"  | edge_exec "cat > $EDGE_ROUTES/$w_project.tls.map"
  printf '%s\n' "$http_map" | edge_exec "cat > $EDGE_ROUTES/$w_project.http.map"

  if docker exec "$EDGE_NAME" nginx -t >/dev/null 2>&1; then
    reload_edge || { fail "reload nginx du routeur impossible"; return 1; }
    ok "$w_project : routes enregistrées ($w_domains → $w_alias)"
    return 0
  fi

  # Configuration invalide : retour arrière immédiat — un projet défaillant ne
  # doit JAMAIS casser le routage des autres.
  fail "$w_project : configuration rejetée par nginx -t, retour arrière."
  edge_exec "for s in tls http; do if [ -f $EDGE_ROUTES/.bak/$w_project.\$s.map ]; then cp $EDGE_ROUTES/.bak/$w_project.\$s.map $EDGE_ROUTES/$w_project.\$s.map; else rm -f $EDGE_ROUTES/$w_project.\$s.map; fi; done"
  docker exec "$EDGE_NAME" nginx -t >&2 || true
  return 1
}

# Enregistre un conteneur origin d'après ses labels.
register_origin() {
  r_ctr=$1
  r_project=$(label "$r_ctr" org.mi-kandra.project)
  r_alias=$(label "$r_ctr" org.mi-kandra.origin-alias)
  r_domains=$(origin_domains "$r_ctr"); r_od=$?
  is_project "$r_project" || { fail "nom de projet invalide : '$r_project'"; return 1; }
  r_routed=0
  edge_exec "[ -f $EDGE_ROUTES/$r_project.tls.map ]" </dev/null && r_routed=1
  # Fichier de domaines illisible : la liste n'aurait que le label. Réécrire les
  # routes retirerait les domaines du fichier (ou toutes les routes d'un projet
  # sans label) sur une simple erreur passagère : on garde celles en place.
  if [ "$r_od" -eq 2 ] && [ "$r_routed" -eq 1 ]; then
    warn "$r_project : routes actuelles conservées (liste de domaines illisible)"
    return 0
  fi
  # Liste lue et vide, sans label de domaines : le projet n'a plus (ou pas
  # encore) de domaine, ses routes sont retirées. Un label présent mais vide
  # (variable .env manquante) reste une erreur, signalée par write_routes.
  if [ -z "$r_domains" ] && [ -n "$(label "$r_ctr" org.mi-kandra.domains-file)" ] \
     && ! has_label "$r_ctr" org.mi-kandra.domains; then
    if [ "$r_od" -eq 2 ]; then warn "$r_project : liste de domaines illisible, aucune route"; return 0; fi
    [ "$r_routed" -eq 1 ] || { ok "$r_project : aucun domaine, aucune route"; return 0; }
    cmd_unregister "$r_project"; return $?
  fi
  # Filet de sécurité si la stack n'a pas (encore) rejoint le réseau partagé.
  if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$r_ctr" 2>/dev/null | grep -q "\"$EDGE_NET\""; then
    is_alias "$r_alias" && docker network connect --alias "$r_alias" "$EDGE_NET" "$r_ctr" >/dev/null 2>&1 \
      && ok "$r_project : $r_ctr rattaché au réseau $EDGE_NET"
  fi
  write_routes "$r_project" "$r_alias" "$r_domains"
}

cmd_sync() {
  only=${1:-}
  docker_ok || { fail "Docker indisponible."; return 1; }
  edge_running || { warn "Routeur $EDGE_NAME absent : rien à synchroniser (mode autonome)."; return 0; }
  rc=0; n=0
  for c in $(list_origins); do
    p=$(label "$c" org.mi-kandra.project)
    [ -z "$only" ] || [ "$only" = "$p" ] || continue
    n=$((n + 1))
    register_origin "$c" || rc=1
  done
  [ "$n" -gt 0 ] || warn "Aucun origin détecté (label org.mi-kandra.role=origin)."
  return $rc
}

cmd_register() {
  [ -n "$MI_KANDRA_PROJECT" ] || { fail "MI_KANDRA_PROJECT inconnu (scripts/edge/project.env)."; return 1; }
  cmd_sync "$MI_KANDRA_PROJECT"
}

cmd_unregister() {
  u_project=${1:-}
  is_project "$u_project" || { fail "usage : unregister <projet>"; return 1; }
  edge_running || { fail "routeur absent."; return 1; }
  edge_exec "rm -f $EDGE_ROUTES/$u_project.tls.map $EDGE_ROUTES/$u_project.http.map"
  docker exec "$EDGE_NAME" nginx -t >/dev/null 2>&1 && reload_edge \
    && ok "$u_project : routes retirées" || { fail "reload impossible"; return 1; }
}

# ── Routeur ──────────────────────────────────────────────────────────────────
cmd_ensure_edge() {
  docker_ok || { fail "Docker indisponible."; return 1; }
  # Sain : on n'y touche pas (un `up` depuis la copie d'un autre projet pourrait
  # recréer le conteneur et couper 80/443 pour rien). Malade ou absent : on
  # reconverge vers la configuration versionnée.
  if edge_running && edge_healthy; then ok "routeur $EDGE_NAME déjà actif et sain"; return 0; fi
  if ! docker container inspect "$EDGE_NAME" >/dev/null 2>&1; then
    if [ -n "$(port_holders)" ] || external_port_holder; then
      fail "80/443 sont occupés ($(port_holders | cut -d'|' -f1 | tr '\n' ' ')) : lancez d'abord 'adopt'."
      return 1
    fi
  fi
  ensure_network || { fail "création du réseau $EDGE_NET impossible"; return 1; }
  if [ "${EDGE_PRECREATED:-0}" = "1" ] && ! edge_running; then
    # Créé à l'instant par edge_precreate, depuis la configuration versionnée :
    # un simple démarrage, sans les secondes de `docker compose up`.
    docker start "$EDGE_NAME" >/dev/null 2>&1 || { fail "démarrage du routeur impossible"; return 1; }
  else
    docker compose -f "$SCRIPT_DIR_NATIVE/edge-compose.yml" up -d >&2 || { fail "démarrage du routeur impossible"; return 1; }
  fi
  # Prêt dès que nginx répond, sans attendre le statut « healthy » de Docker :
  # chaque seconde passée ici, le routeur tient déjà 80/443 sans aucune route
  # (connexions refusées, erreur 525 côté Cloudflare). L'appelant enregistre
  # les routes aussitôt après.
  i=0
  while [ "$i" -lt 150 ]; do
    edge_answers && { ok "routeur $EDGE_NAME prêt"; return 0; }
    i=$((i + 1)); sleep 0.2
  done
  fail "le routeur ne répond pas après 30 s (docker logs $EDGE_NAME)"
  return 1
}

# Routeur démarré ET nginx qui répond sur sa sonde interne.
edge_answers() {
  edge_running && docker exec "$EDGE_NAME" wget -q -O /dev/null http://127.0.0.1/__mi_kandra_edge_health >/dev/null 2>&1
}

# Crée le conteneur du routeur SANS le démarrer (image prête, aucun port pris) :
# au moment où les voisins libèrent 80/443, il ne reste qu'à le lancer.
edge_precreate() {
  docker container inspect "$EDGE_NAME" >/dev/null 2>&1 && return 0
  ensure_network || return 1
  docker compose -f "$SCRIPT_DIR_NATIVE/edge-compose.yml" up --no-start >&2 2>&1 || return 1
  EDGE_PRECREATED=1
}

# Pose les routes d'un origin dans le volume du routeur AVANT son démarrage :
# il prend 80/443 avec ses routes déjà en place, au lieu de refuser le trafic
# (525) le temps de l'enregistrement. Mêmes lignes que write_routes, qui les
# revalide ensuite au `sync` (« routes déjà à jour »). Code ≠ 0 : rien d'écrit,
# le `sync` habituel prendra le relais.
seed_routes() { # $1 = conteneur origin
  sr_project=$(label "$1" org.mi-kandra.project); sr_alias=$(label "$1" org.mi-kandra.origin-alias)
  is_project "$sr_project" && is_alias "$sr_alias" || return 1
  sr_tls=""; sr_http=""
  for sr_d in $(origin_domains "$1" 2>/dev/null); do
    sr_d=${sr_d#\*.}; sr_d=${sr_d#.}
    is_domain "$sr_d" || return 1
    sr_tls="${sr_tls}.${sr_d} ${sr_alias}:8443;
"
    sr_http="${sr_http}.${sr_d} ${sr_alias}:8080;
"
  done
  [ -n "$sr_tls" ] || return 1
  sr_img=$(docker container inspect -f '{{.Config.Image}}' "$EDGE_NAME" 2>/dev/null) || return 1
  printf '%s\n' "$sr_tls" | docker run --rm -i -v "$EDGE_VOL:/r" --entrypoint sh "$sr_img" -c "cat > /r/$sr_project.tls.map" \
    && printf '%s\n' "$sr_http" | docker run --rm -i -v "$EDGE_VOL:/r" --entrypoint sh "$sr_img" -c "cat > /r/$sr_project.http.map"
}

# Met à jour UN voisin trop ancien pour être converti (nginx sans labels Mi Kandra) : git pull dans son
# dossier Compose, puis recréation de son seul service nginx — ce qui lui pose les labels. Toutes les
# informations viennent des labels Compose du conteneur (projet, dossier, fichiers, service), jamais
# d'une saisie. Refus (sans rien modifier) si ce n'est pas un dépôt Git ou si des fichiers suivis ont des
# modifications locales. fast-forward uniquement : aucun commit de fusion, aucun conflit.
update_neighbor() {
  un_n=$1
  un_proj=$(label "$un_n" com.docker.compose.project)
  un_wd=$(label "$un_n" com.docker.compose.project.working_dir)
  un_cfg=$(label "$un_n" com.docker.compose.project.config_files)
  un_svc=$(label "$un_n" com.docker.compose.service)
  { [ -n "$un_proj" ] && [ -n "$un_wd" ] && [ -n "$un_cfg" ] && [ -n "$un_svc" ]; } \
    || { fail "$un_n : pas lancé par Docker Compose (labels absents) — mise à jour manuelle nécessaire"; return 1; }
  [ -d "$un_wd/.git" ] || { fail "$un_n : $un_wd n'est pas un dépôt Git — mise à jour manuelle nécessaire"; return 1; }
  if [ -n "$(git -C "$un_wd" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    fail "$un_n : des fichiers suivis ont des modifications locales dans $un_wd — rien n'est écrasé."
    fail "  Sauvegardez-les (git stash) ou annulez-les, puis relancez."
    return 1
  fi
  say "$un_n : git pull dans $un_wd …"
  un_log=$(mktemp)
  if ! git -C "$un_wd" pull --ff-only --quiet >"$un_log" 2>&1; then
    sed 's/^/    /' "$un_log" >&2; rm -f "$un_log"
    fail "$un_n : git pull impossible (historique divergent, pas de branche suivie, dépôt distant injoignable ?) — mise à jour manuelle nécessaire"
    return 1
  fi
  rm -f "$un_log"
  set --
  old_ifs=$IFS; IFS=','; for f in $un_cfg; do set -- "$@" -f "$f"; done; IFS=$old_ifs
  say "$un_n : recréation du service $un_svc (labels Mi Kandra) …"
  ( cd "$un_wd" && docker compose -p "$un_proj" "$@" up -d --no-deps --force-recreate "$un_svc" >&2 ) \
    || { fail "$un_n : recréation impossible — relancez la stack de ce projet à la main"; return 1; }
  sleep 2
  [ "$(label "$un_n" org.mi-kandra.edge-capable)" = "1" ] \
    && { ok "$un_n : à jour, convertible"; return 0; }
  fail "$un_n : toujours sans label org.mi-kandra.edge-capable après mise à jour — ce projet n'a pas la version Mi Kandra de nginx/compose."
  return 1
}

# adopt [--yes] [--pull]
#   --yes   confirme la conversion (recrée le nginx de chaque projet listé : coupure de quelques secondes)
#   --pull  met d'abord à jour (git pull + recréation de nginx) les voisins trop anciens pour être convertis
# Retour arrière d'une conversion inachevée : les voisins listés (« projet|dossier|
# fichiers|service|pref créée », une ligne chacun) republient 80/443 comme avant,
# et le choix « cohabiter » posé pour eux par cette conversion est retiré. Un
# routeur démarré mais malade est d'abord arrêté : il tiendrait encore les ports.
adopt_rollback() {
  [ -n "$1" ] || return 0
  warn "Retour arrière : les projets convertis reprennent 80/443."
  if edge_running && ! edge_healthy; then
    docker stop "$EDGE_NAME" >/dev/null 2>&1 && warn "routeur $EDGE_NAME (malade) arrêté"
  fi
  printf '%s' "$1" | while IFS='|' read -r rb_proj rb_wd rb_cfg rb_svc rb_pref; do
    [ -n "$rb_proj" ] || continue
    set --
    rb_ifs=$IFS; IFS=','; for f in $rb_cfg; do set -- "$@" -f "$f"; done; IFS=$rb_ifs
    # </dev/null : docker compose ne doit pas lire les lignes suivantes de la boucle.
    if ( cd "$rb_wd" && unset MI_KANDRA_HTTP_PUBLISH MI_KANDRA_HTTPS_PUBLISH \
         && docker compose -p "$rb_proj" "$@" up -d --no-deps --force-recreate "$rb_svc" >&2 </dev/null ); then
      ok "$rb_proj : 80/443 rétablis"
    else
      fail "$rb_proj : retour arrière impossible — relancez sa stack : cd '$rb_wd' && ./start.sh"
    fi
    [ "$rb_pref" = "1" ] && rm -f "$rb_wd/.mi-kandra-edge.pref"
  done
}

cmd_adopt() {
  assume=""; pull=0
  for a in "$@"; do
    case "$a" in --yes) assume=--yes ;; --pull) pull=1 ;; esac
  done
  docker_ok || { fail "Docker indisponible."; return 1; }
  holders=$(port_holders | grep -v "^$EDGE_NAME|" || true)
  if edge_running && [ -z "$holders" ]; then ok "rien à adopter : le routeur est actif"; cmd_sync; return $?; fi
  if [ -z "$holders" ]; then
    external_port_holder && { fail "un processus hors Docker occupe 80/443 : arrêtez-le d'abord."; return 1; }
    cmd_ensure_edge && cmd_sync
    return $?
  fi

  say "Conteneurs publiant 80/443 à convertir :"
  echo "$holders" | while IFS='|' read -r n p r; do say "  - $n (projet=${p:-?} rôle=${r:-?})"; done
  # Tous doivent être des origins capables — sinon on ne touche à rien.
  bad=""
  for n in $(echo "$holders" | cut -d'|' -f1); do
    [ "$(label "$n" org.mi-kandra.edge-capable)" = "1" ] || bad="$bad $n"
  done

  if [ -n "$bad" ] && [ "$pull" = "1" ]; then
    if [ "$assume" != "--yes" ] && [ "${MI_KANDRA_EDGE_AUTOADOPT:-0}" != "1" ]; then
      warn "--pull modifie les projets voisins (git pull + recréation de leur nginx) : ajoutez --yes pour confirmer."
      return 2
    fi
    say "Mise à jour des voisins trop anciens :$bad"
    for n in $bad; do update_neighbor "$n" || return 1; done
    # Les labels sont maintenant posés : on réévalue.
    holders=$(port_holders | grep -v "^$EDGE_NAME|" || true)
    bad=""
    for n in $(echo "$holders" | cut -d'|' -f1); do
      [ "$(label "$n" org.mi-kandra.edge-capable)" = "1" ] || bad="$bad $n"
    done
  fi

  if [ -n "$bad" ]; then
    fail "non convertibles automatiquement (pas de label org.mi-kandra.edge-capable=1) :$bad"
    for n in $bad; do
      wd=$(label "$n" com.docker.compose.project.working_dir)
      say "  • $n — ancienne version, créée avant les labels Mi Kandra."
      [ -z "$wd" ] || say "      dossier : $wd"
    done
    say "Deux façons de continuer :"
    say "  1) Automatique : sh scripts/edge/mi-kandra-edge.sh adopt --pull --yes"
    say "     (git pull dans le dossier de chaque projet listé, recréation de son seul nginx, puis conversion)"
    for n in $bad; do
      wd=$(label "$n" com.docker.compose.project.working_dir); pj=$(label "$n" com.docker.compose.project); sv=$(label "$n" com.docker.compose.service)
      [ -n "$wd" ] && say "  2) À la main (${n}) : cd '$wd' && git pull && docker compose -p ${pj:-<projet>} up -d --no-deps --force-recreate ${sv:-<service>}"
    done
    say "     puis : sh scripts/edge/mi-kandra-edge.sh adopt --yes"
    return 1
  fi
  if [ "$assume" != "--yes" ] && [ "${MI_KANDRA_EDGE_AUTOADOPT:-0}" != "1" ]; then
    warn "Cela recrée le nginx de chaque projet listé (coupure de quelques secondes)."
    warn "Relancez avec : sh scripts/edge/mi-kandra-edge.sh adopt --yes"
    return 2
  fi

  ensure_network || { fail "création du réseau $EDGE_NET impossible"; return 1; }
  # Routeur créé (image prête, aucun port pris) AVANT de toucher aux voisins : entre
  # le moment où ils libèrent 80/443 et celui où le routeur les prend, il ne reste
  # que son démarrage. Un échec ici n'a encore rien changé.
  edge_precreate || { fail "création du routeur impossible : aucun projet n'a été modifié"; return 1; }
  if [ "${EDGE_PRECREATED:-0}" = "1" ]; then
    for n in $(echo "$holders" | cut -d'|' -f1); do
      seed_routes "$n" || warn "$n : routes non posées d'avance (enregistrées au démarrage du routeur)"
    done
  fi
  # Voisins déjà convertis (« projet|dossier|fichiers|service|pref créée ») : en cas
  # d'échec, adopt_rollback leur rend 80/443 au lieu de laisser le serveur sans
  # personne pour répondre.
  converted=""
  for n in $(echo "$holders" | cut -d'|' -f1); do
    proj=$(label "$n" com.docker.compose.project)
    wd=$(label "$n" com.docker.compose.project.working_dir)
    cfg=$(label "$n" com.docker.compose.project.config_files)
    svc=$(label "$n" com.docker.compose.service)
    dh=$(label "$n" org.mi-kandra.diag-http); dhs=$(label "$n" org.mi-kandra.diag-https)
    is_port "$dh" && is_port "$dhs" && [ -n "$proj" ] && [ -n "$wd" ] && [ -n "$cfg" ] && [ -n "$svc" ] \
      || { fail "$n : labels de conversion incomplets"; adopt_rollback "$converted"; return 1; }
    # Paramètres positionnels (et non une chaîne) : les chemins peuvent contenir
    # des espaces (ex. "Mi Kandra").
    set --
    old_ifs=$IFS; IFS=','; for f in $cfg; do set -- "$@" -f "$f"; done; IFS=$old_ifs
    say "Conversion de $n ($proj/$svc) …"
    if ! ( cd "$wd" \
      && MI_KANDRA_HTTP_PUBLISH="127.0.0.1:$dh:80" MI_KANDRA_HTTPS_PUBLISH="127.0.0.1:$dhs:443" \
         docker compose -p "$proj" "$@" up -d --no-deps --force-recreate "$svc" >&2 ); then
      fail "$n : conversion impossible"
      # Lui aussi : son conteneur a pu être supprimé sans être recréé.
      adopt_rollback "$converted$proj|$wd|$cfg|$svc|0
"
      return 1
    fi
    # Le voisin converti cohabite désormais : son prochain ./start.sh ne doit pas
    # reposer la question. Un choix déjà mémorisé chez lui n'est pas touché.
    pc=0
    if [ ! -e "$wd/.mi-kandra-edge.pref" ]; then
      if { printf 'MI_KANDRA_EDGE_PREF=cohabit\n' > "$wd/.mi-kandra-edge.pref" && chmod 600 "$wd/.mi-kandra-edge.pref"; } 2>/dev/null; then pc=1
      else warn "$n : choix « cohabiter » non mémorisé dans $wd (la question lui sera reposée)"; fi
    fi
    converted="$converted$proj|$wd|$cfg|$svc|$pc
"
  done
  cmd_ensure_edge || { adopt_rollback "$converted"; return 1; }
  [ -n "$(pref_get)" ] || pref_set cohabit
  # Aussitôt : chaque seconde sans route, le routeur refuse le trafic (525).
  cmd_sync
}

# ── Diagnostic ───────────────────────────────────────────────────────────────
cmd_status() {
  docker_ok || { fail "Docker indisponible."; return 1; }
  say "Projet courant : ${MI_KANDRA_PROJECT:-?}   mode : $(decide_mode)"
  if edge_running; then
    ok "routeur : actif ($(docker container inspect -f '{{.State.Health.Status}}' "$EDGE_NAME" 2>/dev/null))"
    edge_exec "for f in $EDGE_ROUTES/*.tls.map; do [ -f \"\$f\" ] && { echo \"  -- \$(basename \$f .tls.map)\"; sed 's/^/     /' \"\$f\"; }; done; true" >&2
  else
    say "routeur : absent"
  fi
  say "origins détectés :"
  for c in $(list_origins); do
    say "  - $c  projet=$(label "$c" org.mi-kandra.project) alias=$(label "$c" org.mi-kandra.origin-alias) domaines='$(origin_domains "$c")'"
  done
  [ -n "$(list_origins)" ] || say "  (aucun)"
  say "conteneurs publiant 80/443 : $(port_holders | cut -d'|' -f1 | tr '\n' ' ')"
}

# Sonde réelle d'un domaine (--probe) : handshake TLS + requête HTTPS sur
# 127.0.0.1:443, donc à lancer SUR le serveur qui héberge le routeur/le nginx.
# Contrôle aussi l'expiration du certificat (alerte à 21 jours).
probe_domain() {
  pd_p=$1; pd_d=$2
  command -v curl >/dev/null 2>&1 || { warn "$pd_p : curl absent, sonde de $pd_d ignorée"; return 0; }
  pd_code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' --resolve "$pd_d:443:127.0.0.1" "https://$pd_d/" 2>/dev/null)
  case "$pd_code" in
    2??|3??|4??) ok "$pd_p : $pd_d répond en HTTPS ($pd_code)" ;;
    5??) warn "$pd_p : $pd_d répond $pd_code (routage OK, application indisponible ?)" ;;
    *) fail "$pd_p : $pd_d injoignable en HTTPS sur 127.0.0.1:443"; return 1 ;;
  esac
  command -v openssl >/dev/null 2>&1 || return 0
  pd_pem=$(openssl s_client -connect 127.0.0.1:443 -servername "$pd_d" </dev/null 2>/dev/null | openssl x509 2>/dev/null)
  if [ -z "$pd_pem" ]; then warn "$pd_p : certificat de $pd_d illisible"; return 0; fi
  printf '%s\n' "$pd_pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1 \
    || { fail "$pd_p : certificat de $pd_d EXPIRÉ"; return 1; }
  if printf '%s\n' "$pd_pem" | openssl x509 -noout -checkend 1814400 >/dev/null 2>&1; then
    ok "$pd_p : certificat de $pd_d valide (plus de 21 jours)"
  else
    warn "$pd_p : certificat de $pd_d expire dans moins de 21 jours"
  fi
}

cmd_doctor() {
  rc=0; probe=0; [ "${1:-}" = "--probe" ] && probe=1
  docker_ok && ok "Docker joignable" || { fail "Docker indisponible"; return 1; }
  mode=$(decide_mode); say "mode : $mode"
  origins=$(list_origins)
  [ -n "$origins" ] || warn "aucun origin détecté (stack arrêtée, ou labels absents)"

  # Version de nginx (paramètre `resolve` ⇒ >= 1.27.3) : origins ET routeur.
  for c in $origins $(edge_running && echo "$EDGE_NAME"); do
    nginx_version_ok "$c"; nv_rc=$?
    case "$nv_rc" in
      0) ok "$c : nginx compatible (>= 1.27.3)" ;;
      1) fail "$c : nginx < 1.27.3 — 'resolve' non supporté, nginx ne démarrera pas. Faites : docker compose pull nginx puis recréez-le."; rc=1 ;;
      *) warn "$c : version de nginx illisible" ;;
    esac
  done

  if [ "$mode" = "pending" ]; then fail "80/443 occupés par un voisin non converti → sh scripts/edge/mi-kandra-edge.sh adopt"; rc=1; fi
  if edge_running; then
    [ "$(docker container inspect -f '{{.State.Health.Status}}' "$EDGE_NAME" 2>/dev/null)" = "healthy" ] \
      && ok "routeur sain" || { fail "routeur non sain"; rc=1; }
    docker exec "$EDGE_NAME" nginx -t >/dev/null 2>&1 && ok "configuration du routeur valide" || { fail "nginx -t du routeur en échec"; rc=1; }
    for c in $origins; do
      p=$(label "$c" org.mi-kandra.project); a=$(label "$c" org.mi-kandra.origin-alias); d=$(origin_domains "$c")
      st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null)
      case "$st" in healthy|running) ok "$p : origin $st";; *) fail "$p : origin $st"; rc=1;; esac
      for dom in $d; do
        dom=${dom#\*.}; dom=${dom#.}
        if edge_exec "grep -q '^$(regex_escape ".$dom") ' $EDGE_ROUTES/$p.tls.map 2>/dev/null"; then ok "$p : route $dom présente"
        else fail "$p : route $dom absente → sh scripts/edge/mi-kandra-edge.sh sync"; rc=1; fi
      done
      docker exec "$EDGE_NAME" getent hosts "$a" >/dev/null 2>&1 \
        && ok "$p : alias $a résolu depuis le routeur" || { fail "$p : alias $a injoignable depuis le routeur"; rc=1; }
    done
  elif [ "$mode" = "isolated" ]; then
    ok "mode autonome (choix mémorisé) : cette application ignore les autres, en local uniquement"
  elif [ "$mode" = "standalone" ]; then
    ok "mode autonome : aucun routeur nécessaire"
    for c in $origins; do
      st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null)
      case "$st" in healthy|running) ok "$(label "$c" org.mi-kandra.project) : origin $st";; *) fail "$(label "$c" org.mi-kandra.project) : origin $st"; rc=1;; esac
    done
  fi
  if [ "$probe" -eq 1 ]; then
    for c in $origins; do
      pr_p=$(label "$c" org.mi-kandra.project)
      for pr_d in $(origin_domains "$c"); do
        pr_d=${pr_d#\*.}; pr_d=${pr_d#.}
        probe_domain "$pr_p" "$pr_d" || rc=1
      done
    done
  fi
  # Deux projets qui revendiquent le même domaine = détournement de trafic.
  dup=$(for c in $origins; do origin_domains "$c"; echo; done | tr ' ' '\n' | sed 's/^\*\.//;s/^\.//' | grep . | sort | uniq -d)
  [ -z "$dup" ] && ok "aucun domaine revendiqué par deux projets" || { fail "domaines en double : $dup"; rc=1; }
  return $rc
}

# ── Retour au mode autonome ──────────────────────────────────────────────────
# Inverse d'adopt. Le réseau partagé est gardé (le nginx du projet y est
# rattaché) ; le volume des routes n'est retiré qu'une fois 80/443 repris. En
# cas d'échec, le routeur est relancé avec ses routes : le site reste servi.
cmd_release() {
  rl_force=0; [ "${1:-}" = "--force" ] && rl_force=1
  docker_ok || { fail "Docker indisponible."; return 1; }
  docker container inspect "$EDGE_NAME" >/dev/null 2>&1 || { ok "aucun routeur : déjà en mode autonome"; return 0; }
  rl_origins=$(list_origins)
  rl_n=$(printf '%s\n' "$rl_origins" | grep -c .)
  if [ "$rl_n" -gt 1 ] && [ "$rl_force" -ne 1 ]; then
    fail "$rl_n projets passent par le routeur ($(printf '%s ' $rl_origins)) : un seul peut reprendre 80/443."
    say "Arrêtez d'abord les autres projets, ou : sh scripts/edge/mi-kandra-edge.sh release --force (seul $(printf '%s\n' "$rl_origins" | head -1) redeviendra public)."
    return 1
  fi
  rl_ctr=$(printf '%s\n' "$rl_origins" | head -1)
  if [ -z "$rl_ctr" ]; then
    docker rm -f "$EDGE_NAME" >/dev/null 2>&1
    docker volume rm "$EDGE_VOL" >/dev/null 2>&1
    ok "aucun projet en marche : routeur retiré"
    return 0
  fi
  rl_proj=$(label "$rl_ctr" com.docker.compose.project)
  rl_wd=$(label "$rl_ctr" com.docker.compose.project.working_dir)
  rl_cfg=$(label "$rl_ctr" com.docker.compose.project.config_files)
  rl_svc=$(label "$rl_ctr" com.docker.compose.service)
  [ -n "$rl_proj" ] && [ -n "$rl_wd" ] && [ -n "$rl_cfg" ] && [ -n "$rl_svc" ] \
    || { fail "$rl_ctr : labels Compose incomplets, recréation impossible — rien n'a été modifié"; return 1; }
  set --
  rl_ifs=$IFS; IFS=','; for f in $rl_cfg; do set -- "$@" -f "$f"; done; IFS=$rl_ifs
  say "Retour au mode autonome : $rl_ctr ($rl_proj/$rl_svc) reprend 80/443 …"
  # Routeur ET ancien nginx arrêtés ensemble, 1 s chacun au plus : nginx
  # s'arrête en douceur (SIGQUIT) et attendrait la fin de ses connexions
  # longues — mesuré en production : ~10 s sans personne sur 80/443 quand la
  # recréation arrêtait elle-même l'ancien conteneur, une fois le routeur coupé.
  docker stop -t 1 "$EDGE_NAME" "$rl_ctr" >/dev/null 2>&1
  if ! ( cd "$rl_wd" && unset MI_KANDRA_HTTP_PUBLISH MI_KANDRA_HTTPS_PUBLISH \
         && docker compose -p "$rl_proj" "$@" up -d --no-deps --force-recreate "$rl_svc" >&2 </dev/null ); then
    fail "$rl_ctr : recréation sur 80/443 impossible — routeur relancé ; si le site ne répond pas, relancez la stack : cd '$rl_wd' && ./start.sh"
    docker start "$rl_ctr" "$EDGE_NAME" >/dev/null 2>&1
    return 1
  fi
  docker rm -f "$EDGE_NAME" >/dev/null 2>&1
  docker volume rm "$EDGE_VOL" >/dev/null 2>&1
  [ "$rl_n" -gt 1 ] && warn "projets restés en local (non publics) : $(printf '%s\n' "$rl_origins" | tail -n +2 | tr '\n' ' ')"
  ok "$rl_proj : 80/443 repris, routeur retiré (mode autonome)"
}

# ── Journal du routeur ───────────────────────────────────────────────────────
# Le routeur n'apparaît dans le --logs d'aucun projet. Lignes d'origine (format
# mi_kandra_tls d'edge-nginx.conf) : « IP [date] sni=… backend=… status=… sent=…
# recv=… ». backend=127.0.0.1:9 = domaine inconnu, refusé exprès : son erreur
# « connect() failed » côté error_log est un doublon, masqué.
cmd_logs() {
  lg_follow=1; lg_since=""; lg_tail=200; lg_ref=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ -n "${2:-}" ] || { fail "--since requiert une durée (ex. 10m, 2h)"; return 64; }; lg_since=$2; shift 2 ;;
      --tail) printf '%s' "${2:-}" | grep -Eq '^[0-9]+$' || { fail "--tail requiert un nombre"; return 64; }; lg_tail=$2; shift 2 ;;
      --no-follow) lg_follow=0; shift ;;
      --refused) lg_ref=1; shift ;;
      *) fail "logs : option inconnue « $1 » (--since, --tail, --no-follow, --refused)"; return 64 ;;
    esac
  done
  docker_ok || { fail "Docker indisponible."; return 1; }
  docker container inspect "$EDGE_NAME" >/dev/null 2>&1 || { ok "aucun routeur : mode autonome, chaque projet a ses propres logs (./start.sh --logs)"; return 0; }
  set -- logs --timestamps
  if [ -n "$lg_since" ]; then set -- "$@" --since "$lg_since"; else set -- "$@" --tail "$lg_tail"; fi
  [ "$lg_follow" -eq 1 ] && set -- "$@" -f
  lg_color=0; [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && lg_color=1
  docker "$@" "$EDGE_NAME" 2>&1 | awk -v color="$lg_color" -v refused="$lg_ref" -v z="$(date +%z 2>/dev/null)" '
    BEGIN {
      if (color + 0) { R = "\033[0m"; B = "\033[1m"; GRY = "\033[90m"; RED = "\033[91m"; YEL = "\033[93m"; GRN = "\033[92m" }
      off = 0
      if (z ~ /^[+-][0-9][0-9][0-9][0-9]$/) { off = substr(z, 2, 2) * 3600 + substr(z, 4, 2) * 60; if (substr(z, 1, 1) == "-") off = -off }
    }
    function clock(ts,    t) {
      t = (substr(ts, 12, 2) * 3600 + substr(ts, 15, 2) * 60 + substr(ts, 18, 2) + off) % 86400
      if (t < 0) t += 86400
      return sprintf("%02d:%02d:%02d", int(t / 3600), int(t % 3600 / 60), t % 60)
    }
    function human(b) { b += 0; if (b < 1024) return b "B"; if (b < 1048576) return sprintf("%.1fk", b / 1024); return sprintf("%.1fM", b / 1048576) }
    function kv(k,    i) { i = index(msg, " " k "="); if (!i) return ""; v = substr(msg, i + length(k) + 2); sub(/ .*/, "", v); return v }
    function pad(s, n) { while (length(s) < n) s = s " "; return s }
    {
      ts = $1; msg = substr($0, length($1) + 2)
      if (ts !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/) { ts = ""; msg = $0 }
      t = (ts == "") ? "        " : clock(ts)
      if (msg ~ / sni=/ && msg ~ / backend=/) {
        ip = msg; sub(/ .*/, "", ip)
        sni = kv("sni"); be = kv("backend"); st = kv("status")
        if (sni == "") sni = "(sans SNI)"
        if (be == "127.0.0.1:9") {
          print GRY t R "  " YEL pad(sni, 32) R " " YEL "✗ refusé (domaine inconnu)" R "  " GRY ip R; n_ref++
        } else if (st != "200") {
          print GRY t R "  " RED pad(sni, 32) R " " RED "✗ " be " injoignable (" st ")" R "  " GRY ip R; n_ko++
        } else {
          n_ok++
          if (!(refused + 0)) print GRY t R "  " pad(sni, 32) " " GRN "→" R " " pad(be, 24) " " GRY human(kv("sent")) " / " human(kv("recv")) "  " ip R
        }
        fflush(); next
      }
      # error_log de nginx : le refus volontaire (port 9) est déjà affiché ci-dessus.
      if (msg ~ /upstream: "127\.0\.0\.1:9"/ || msg ~ /127\.0\.0\.1:9[^0-9]/) next
      if (refused + 0 && msg !~ /\[(error|crit|alert|emerg)\]/) next
      lvl = (msg ~ /\[(error|crit|alert|emerg)\]/) ? RED B "ERR " R : (msg ~ /\[warn\]/ ? YEL B "WARN" R : GRY "info" R)
      print GRY t R "  " lvl "  " msg; fflush()
    }
    END { if (n_ok + n_ref + n_ko) print GRY "… " n_ok " connexion(s) routée(s), " n_ref " refusée(s), " n_ko " vers un projet injoignable" R }'
}

# ── Ports fixes de l'hôte ────────────────────────────────────────────────────
# Certains services publient un port qu'on ne peut pas déplacer (acme-dns : 53,
# imposé par la délégation DNS). Deux projets qui l'activent sur le même serveur
# se le disputent : le second échoue au démarrage, sans dire pourquoi. Ce
# contrôle nomme le détenteur avant que le projet ne lance son service.
cmd_check_port() {
  cp_port=${1:-}; cp_proto=${2:-tcp}
  printf '%s' "$cp_port" | grep -Eq '^[0-9]{1,5}$' || { fail "usage : check-port <port> [tcp|udp]"; return 64; }
  case "$cp_proto" in tcp|udp) ;; *) fail "usage : check-port <port> [tcp|udp]"; return 64 ;; esac
  docker_ok || return 0
  # « 0.0.0.0:53->53/udp, [::]:53->53/udp » : seul le port côté hôte compte.
  cp_holders=$(docker ps --format '{{.Names}}|{{.Label "com.docker.compose.project"}}|{{.Ports}}' 2>/dev/null \
    | awk -F'|' -v re=":$cp_port->[0-9]+/$cp_proto" '$3 ~ re { print $1 "|" $2 }')
  if [ -n "$cp_holders" ]; then
    cp_foreign=$(printf '%s\n' "$cp_holders" | awk -F'|' -v me="${MI_KANDRA_COMPOSE_PROJECT:-}" 'me == "" || $2 != me')
    [ -n "$cp_foreign" ] || return 0
    printf '%s\n' "$cp_foreign" | while IFS='|' read -r cp_n cp_p; do
      fail "port $cp_port/$cp_proto déjà tenu par le conteneur $cp_n (projet ${cp_p:-inconnu})"
    done
    return 1
  fi
  # Hors Docker (systemd-resolved, dnsmasq…). Pas avant : le docker-proxy d'un
  # conteneur apparaîtrait ici aussi.
  if command -v ss >/dev/null 2>&1; then
    cp_flag=t; [ "$cp_proto" = udp ] && cp_flag=u
    cp_addr=$(ss -ln"$cp_flag" 2>/dev/null | awk -v p=":$cp_port" 'substr($4, length($4) - length(p) + 1) == p { print $4 }' | sort -u | tr '\n' ' ')
    if [ -n "$cp_addr" ]; then
      warn "port $cp_port/$cp_proto déjà ouvert hors Docker sur : $cp_addr(ex. stub DNS de systemd-resolved)"
      return 2
    fi
  fi
  return 0
}

# ── Point d'entrée ───────────────────────────────────────────────────────────
cmd=${1:-status}
[ $# -gt 0 ] && shift
case "$cmd" in
  env)         cmd_env ;;
  status)      cmd_status ;;
  sync)        cmd_sync "$@" ;;
  register)    cmd_register ;;
  unregister)  cmd_unregister "$@" ;;
  ensure-edge) cmd_ensure_edge ;;
  adopt)       cmd_adopt "$@" ;;
  choose)      cmd_choose "$@" ;;
  doctor)      cmd_doctor "$@" ;;
  release)     cmd_release "$@" ;;
  logs)        cmd_logs "$@" ;;
  check-port)  cmd_check_port "$@" ;;
  # Aide : tout l'en-tête, jusqu'à la ligne de « = » qui le ferme.
  *) awk 'NR > 2 && /^# =+$/ { exit } NR > 2' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
esac
