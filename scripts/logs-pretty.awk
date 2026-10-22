# =============================================================================
# logs-pretty.awk — Mise en forme lisible de `docker compose logs`.
#
# Lit la sortie de `docker compose logs --no-color --timestamps` (une ligne
# « <conteneur> | <horodatage RFC3339> <message> ») et produit une ligne par
# événement :
#
#   14:32:05  app        ERR   Invalid `prisma.analyticsEvent.createMany()`
#   14:32:06  nginx      GET   200  /api/products   3.2k  41.13.2.7
#
# Reconnaît : les lignes JSON de src/lib/logger.ts (level/message/event/
# context/stack), les accès nginx (format « combined »), les journaux
# d'erreurs nginx, Postgres, Redis et logback (Metarank), le logfmt
# (« level=warn », scheduler) et les préfixes « INFO: »/« WARNING: » (MinIO) ;
# tout le reste est classé par mots-clés (error/warn…). Les lignes de continuation (stack
# traces indentées) héritent du niveau de la ligne précédente du même service.
#
# POSIX awk uniquement (pas d'intervalles {n}, pas de fonctions gawk) : le
# script tourne avec mawk (Debian/Ubuntu), busybox (Alpine) et gawk.
#
# Variables (-v) :
#   color=1       couleurs ANSI (0 = texte brut, pour un pipe ou NO_COLOR)
#   tzoff=10800   décalage horaire en secondes appliqué à l'heure UTC
#   minlevel=0    0 = tout, 1 = avertissements et erreurs, 2 = erreurs seules
#   grep=texte    ne garde que les lignes contenant ce texte (insensible casse)
#   health=0      1 = garde aussi les sondes /api/health (masquées par défaut)
#   scans=0       1 = montre aussi le trafic hors-site (lignes « mk-unmatched »
#                 du vhost par défaut : scans d'IP, domaines d'autres projets)
#   stacklines=12 lignes de stack trace JSON affichées avant troncature
#   prefix=poma-  préfixe retiré des noms de conteneurs (container_name)
#
# Script identique dans chaque projet Mi Kandra (poma-original, mga, artest,
# influencor, influencor-web) : le modifier partout à la fois.
# =============================================================================

BEGIN {
  if (color + 0) {
    R = "\033[0m"; B = "\033[1m"; DIM = "\033[2m"; GRY = "\033[90m"
    RED = "\033[91m"; YEL = "\033[93m"; GRN = "\033[92m"; CYN = "\033[96m"; MAG = "\033[95m"
  }
  if (stacklines == "") stacklines = 12
  grep = tolower(grep)
  # Une couleur stable par service connu ; les autres prennent la suite.
  SVC_COLOR["app"] = "\033[96m";      SVC_COLOR["nginx"] = "\033[92m"
  SVC_COLOR["db"] = "\033[94m";       SVC_COLOR["redis"] = "\033[91m"
  SVC_COLOR["minio"] = "\033[95m";    SVC_COLOR["metarank"] = "\033[93m"
  SVC_COLOR["scheduler"] = "\033[36m"; SVC_COLOR["certbot"] = "\033[37m"
  SVC_COLOR["acme-dns"] = "\033[37m"; SVC_COLOR["web"] = "\033[96m"
  SVC_COLOR["postgres"] = "\033[94m"; SVC_COLOR["socket"] = "\033[95m"
  SVC_COLOR["worker"] = "\033[36m";   SVC_COLOR["hors-site"] = "\033[90m"
  npal = split("\033[34m \033[35m \033[32m \033[33m \033[36m", PAL, " ")
  nextpal = 0
}

# ── Utilitaires ──────────────────────────────────────────────────────────────

function pad(s, n) { while (length(s) < n) s = s " "; return s }

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function svccolor(svc) {
  if (!color) return ""
  if (!(svc in SVC_COLOR)) { nextpal = nextpal % npal + 1; SVC_COLOR[svc] = PAL[nextpal] }
  return SVC_COLOR[svc]
}

function human(b) {
  b += 0
  if (b < 1024) return b "B"
  if (b < 1048576) return sprintf("%.1fk", b / 1024)
  return sprintf("%.1fM", b / 1048576)
}

function rank(lvl) { return lvl == "error" ? 2 : (lvl == "warn" ? 1 : 0) }

# Heure locale « HH:MM:SS » depuis un horodatage RFC3339 UTC.
function clock(ts,    h, m, s, t) {
  h = substr(ts, 12, 2) + 0; m = substr(ts, 15, 2) + 0; s = substr(ts, 18, 2) + 0
  t = (h * 3600 + m * 60 + s + tzoff) % 86400
  if (t < 0) t += 86400
  return sprintf("%02d:%02d:%02d", int(t / 3600), int(t % 3600 / 60), t % 60)
}

function normlevel(l) {
  l = tolower(l)
  if (l ~ /^(err|error|fatal|panic|crit|critical|alert|emerg|50|60)$/) return "error"
  if (l ~ /^(warn|warning|40)$/) return "warn"
  return "info"
}

# Niveau deviné depuis un texte libre.
function guesslevel(s,    l) {
  l = tolower(s)
  if (l ~ /(^|[^a-z])(error|errors|err|fatal|panic|exception|failed|failure|unhandled|uncaught|econnrefused|violated|p[0-9][0-9][0-9][0-9])([^a-z]|$)/) return "error"
  if (l ~ /(^|[^a-z])(warn|warning|deprecated|deprecation)([^a-z]|$)/) return "warn"
  return "info"
}

# Niveau déclaré dans un texte libre, prioritaire sur les mots-clés : logfmt
# (« ts=… level=warn job=… retrying after fetch failed » reste un
# avertissement malgré « failed ») puis préfixes en tête de ligne, éventuellement
# enchaînés (MinIO : « INFO: WARNING: … A host failure … » → warn). Pose
# OWNLVL = 1 si la ligne déclare son niveau (ce n'est alors jamais la suite
# d'un autre événement) et PFXLEN = longueur des préfixes, retirés à l'affichage.
function textlevel(s,    t, w, word) {
  OWNLVL = 1; PFXLEN = 0
  if (match(s, /(^|[ \t])level=[A-Za-z]+/)) {
    t = substr(s, RSTART, RLENGTH); sub(/.*level=/, "", t)
    return normlevel(t)
  }
  t = s; word = ""
  while (match(t, /^(DEBUG|INFO|NOTICE|WARN|WARNING|ERROR|FATAL): +/)) {
    w = substr(t, 1, RLENGTH); sub(/:.*/, "", w); word = w
    PFXLEN += RLENGTH; t = substr(t, RLENGTH + 1)
  }
  if (word != "") return normlevel(word)
  OWNLVL = 0
  return guesslevel(s)
}

function badge(lvl) {
  if (lvl == "error") return RED B "ERR " R
  if (lvl == "warn") return YEL B "WARN" R
  return GRY "info" R
}

function tint(lvl, s) {
  if (lvl == "error") return RED s R
  if (lvl == "warn") return YEL s R
  return s
}

function kv(k, v) {
  if (v ~ /[ \t"]/ || v == "") v = "\"" v "\""
  if (length(v) > 160) v = substr(v, 1, 157) "..."
  return " " GRY k "=" R v
}

# ── Mini-parseur JSON (objets plats ou à un niveau d'imbrication) ────────────
# jobj(texte, K, V, T) : K[i] = clés dans l'ordre, V[clé] = valeur (chaîne
# déséchappée ou texte brut pour objets/nombres), T[clé] = "s"|"o"|"x".
# Renvoie le nombre de clés, ou -1 si ce n'est pas un objet JSON.

function jws() { while (JP <= JL && index(" \t\r\n", substr(JS, JP, 1))) JP++ }

function jstr(    c, e, out) {
  JP++; out = ""
  while (JP <= JL) {
    c = substr(JS, JP, 1)
    if (c == "\"") { JP++; return out }
    if (c == "\\") {
      JP++; e = substr(JS, JP, 1)
      if (e == "n") out = out "\n"
      else if (e == "t") out = out "  "
      else if (e == "u") JP += 4
      else if (e != "r") out = out e
      JP++; continue
    }
    out = out c; JP++
  }
  return out
}

function jraw(    start, c, depth, instr) {
  start = JP; c = substr(JS, JP, 1)
  if (c == "{" || c == "[") {
    depth = 0; instr = 0
    while (JP <= JL) {
      c = substr(JS, JP, 1)
      if (instr) { if (c == "\\") JP++; else if (c == "\"") instr = 0 }
      else if (c == "\"") instr = 1
      else if (c == "{" || c == "[") depth++
      else if (c == "}" || c == "]") { depth--; if (depth == 0) { JP++; return substr(JS, start, JP - start) } }
      JP++
    }
    return substr(JS, start)
  }
  while (JP <= JL && index(",}] \t", substr(JS, JP, 1)) == 0) JP++
  return substr(JS, start, JP - start)
}

function jobj(s, K, V, T,    n, k, c) {
  split("", K); split("", V); split("", T)
  JS = s; JL = length(s); JP = 1
  jws()
  if (substr(JS, JP, 1) != "{") return -1
  JP++; n = 0
  while (JP <= JL) {
    jws(); c = substr(JS, JP, 1)
    if (c == "}") return n
    if (c == ",") { JP++; continue }
    if (c != "\"") return -1
    k = jstr(); jws()
    if (substr(JS, JP, 1) != ":") return -1
    JP++; jws(); c = substr(JS, JP, 1)
    K[++n] = k
    if (c == "\"") { V[k] = jstr(); T[k] = "s" }
    else { V[k] = jraw(); T[k] = (c == "{" || c == "[") ? "o" : "x" }
  }
  return n
}

# Ligne qui prolonge l'événement précédent du même service : indentée,
# « at … », accolade fermante, libellé Postgres (DETAIL/HINT/STATEMENT…), ou
# ligne de texte sans niveau propre juste après une erreur en texte brut
# (Prisma écrit « prisma:error » puis le détail sur les lignes suivantes).
function iscont(msg, svc) {
  if (!(svc in LAST)) return 0
  if (msg ~ /^[ \t]/ || msg ~ /^(at |[])}])/) return 1
  if (msg ~ /^[0-9-]+ [0-9:.]+ [A-Z]+ \[[0-9]+\] (DETAIL|HINT|STATEMENT|CONTEXT|QUERY|LOCATION):/) return 1
  # Bannière en art ASCII (Metarank) : seules ses premières lignes sont
  # indentées, les suivantes commencent par « | » ou « \ ».
  if (msg ~ /^[ \t_|()<>Y.\/\\-]+$/ && msg ~ /[_|\/\\]/) return 1
  if (structured(msg)) return 0
  return PLAIN[svc] && LAST[svc] == "error" && substr(msg, 1, 1) != "{" && textlevel(msg) == "info" && !OWNLVL
}

# Ligne portant son propre en-tête (Postgres, nginx error_log, Redis, logback).
function structured(msg) {
  return msg ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:.]+ [A-Z]+ \[[0-9]+\] [A-Z]+:/ \
    || msg ~ /^[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] [0-9:]+ \[[a-z]+\] / \
    || msg ~ /^[0-9]+:[A-Z] [0-9]+ [A-Za-z]+ [0-9]+ [0-9:.]+ [*#.-] / \
    || msg ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9][.0-9]* +(TRACE|DEBUG|INFO|WARN|ERROR) /
}

# ── Sortie ───────────────────────────────────────────────────────────────────

function emit(lvl, text) {
  print GRY TIME R "  " svccolor(SVC) pad(SVC, 10) R " " badge(lvl) "  " text
  PRINTED = SVC
  fflush()
}

# Suite d'un événement (stack trace…) : alignée sous le message.
function emitcont(lvl, text,    head) {
  if (text ~ /^[ \t]/) text = "  " trim(text)
  # Si un autre service a écrit entre-temps, son nom est rappelé.
  head = (PRINTED == SVC) ? "          " : svccolor(SVC) pad(SVC, 10) R
  print "          " head "       " (lvl == "error" ? RED : GRY) text R
  PRINTED = SVC
  fflush()
}

function jsonline(msg,    n, i, k, lvl, text, extra, nc, j, ck, lines, nl, stack) {
  n = jobj(msg, JK, JV, JT)
  if (n <= 0 || !(("level" in JV) || ("msg" in JV) || ("message" in JV) || ("event" in JV))) return 0
  lvl = ("level" in JV) ? normlevel(JV["level"]) : guesslevel(msg)
  if (rank(lvl) < minlevel + 0) { SHOWN[SVC] = 0; return 1 }
  text = ("message" in JV) ? JV["message"] : (("msg" in JV) ? JV["msg"] : "")
  if ("event" in JV) text = (text == "" ? B JV["event"] R : B JV["event"] R " " text)
  stack = ("stack" in JV) ? JV["stack"] : ""
  extra = ""
  for (i = 1; i <= n; i++) {
    k = JK[i]
    if (k ~ /^(level|message|msg|event|stack|timestamp|time|context|pid|hostname|v)$/) continue
    extra = extra kv(k, JV[k])
  }
  if (("context" in JV) && JT["context"] == "o") {
    nc = jobj(JV["context"], CK, CV, CT)
    for (j = 1; j <= nc; j++) { ck = CK[j]; extra = extra kv(ck, CV[ck]) }
  }
  # Le message d'erreur est en tête de la stack : inutile de le répéter.
  nl = split(stack, lines, "\n")
  emit(lvl, tint(lvl, text) extra)
  SHOWN[SVC] = 1; LAST[SVC] = lvl
  for (i = 2; i <= nl && i <= stacklines + 1; i++) emitcont(lvl, "  " trim(lines[i]))
  if (nl > stacklines + 1) emitcont(lvl, "  … " (nl - stacklines - 1) " ligne(s) de plus")
  return 1
}

# Accès nginx, format « combined » :
# 1.2.3.4 - - [20/Oct/2026:12:00:00 +0000] "GET /p HTTP/1.1" 200 123 "ref" "ua"
# Hors-site (format mi_kandra_unmatched) : même format suivi de "$host", affiché
# en tête du chemin pour savoir quel domaine était visé.
function nginxaccess(msg,    ip, q1, rest, req, after, f, nf, method, path, status, bytes, lvl, sc, host) {
  if (msg !~ /^[0-9a-fA-F.:]+ - [^ ]+ \[[^]]+\] "/) return 0
  ip = substr(msg, 1, index(msg, " ") - 1)
  q1 = index(msg, "\""); rest = substr(msg, q1 + 1)
  req = substr(rest, 1, index(rest, "\"") - 1)
  after = substr(rest, index(rest, "\"") + 2)
  nf = split(req, f, " "); method = f[1]; path = (nf >= 2) ? f[2] : req
  split(after, f, " "); status = f[1]; bytes = f[2]
  if (status !~ /^[0-9][0-9][0-9]$/) return 0
  if (UNMATCHED && match(msg, /"[^"]*"$/)) {
    host = substr(msg, RSTART + 1, RLENGTH - 2)
    if (host == "" || host == "_") host = "sans domaine"
    path = MAG "[" host "]" R " " path
  }
  lvl = status >= 500 ? "error" : (status >= 400 ? "warn" : "info")
  if (rank(lvl) < minlevel + 0) { SHOWN[SVC] = 0; return 1 }
  sc = status >= 500 ? RED B : (status >= 400 ? YEL : (status >= 300 ? CYN : GRN))
  print GRY TIME R "  " svccolor(SVC) pad(SVC, 10) R " " B pad(method, 4) R "  " sc status R "  " path "  " GRY human(bytes) "  " ip R
  PRINTED = SVC
  fflush()
  SHOWN[SVC] = 1; LAST[SVC] = lvl
  return 1
}

# ── Boucle principale ────────────────────────────────────────────────────────

{
  line = $0
  sub(/\r$/, "", line)
  # Fin de l'historique (ligne posée par logs-view.sh) : bilan du hors-site masqué.
  if (line == "mk-history-end") {
    if (HIDDEN) {
      print GRY "… " HIDDEN " requête(s) hors-site masquée(s) : scans de l'IP, domaines d'autres projets (--scans pour les voir)" R
      HIDDEN = 0
      fflush()
    }
    next
  }
  p = index(line, "| ")
  if (p > 0) { SVC = trim(substr(line, 1, p - 1)); msg = substr(line, p + 2) }
  else if (line ~ / \|$/) { SVC = trim(substr(line, 1, length(line) - 1)); msg = "" }
  else { SVC = "-"; msg = line }
  if (prefix != "" && index(SVC, prefix) == 1) SVC = substr(SVC, length(prefix) + 1)
  sub(/-[0-9]+$/, "", SVC)

  TIME = "        "; SEC = ""
  if (msg ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][.0-9]*Z/) {
    SEC = substr(msg, 1, 19)
    sp = index(msg, " ")
    if (sp > 0) { TIME = clock(substr(msg, 1, sp - 1)); msg = substr(msg, sp + 1) }
    else { TIME = clock(msg); msg = "" }
  }
  if (trim(msg) == "") next
  if (!(health + 0) && msg ~ /\/(api\/health|healthz)/) next
  # Sonde de vivacité de Metarank (GET /metrics toutes les ~5 s par l'app) :
  # masquée avec sa réponse, sauf si celle-ci n'est pas un succès.
  if (!(health + 0) && msg ~ / - HTTP\/1\.1 GET \/metrics$/) { PROBE[SVC] = 1; next }
  if (PROBE[SVC]) {
    PROBE[SVC] = 0
    if (msg ~ / - HTTP\/1\.1 2[0-9][0-9]( [A-Za-z ]*)?$/) next
    sub(/ - HTTP\/1\.1 /, " - HTTP/1.1 GET /metrics → ", msg)
  }
  # Trafic hors-site (vhost par défaut, voir nginx/snippets/mi-kandra-unmatched.conf) :
  # il n'appartient pas au projet, masqué sauf --scans, sous le nom « hors-site ».
  UNMATCHED = 0
  if (msg ~ /^mk-unmatched /) {
    if (!(scans + 0)) { HIDDEN++; next }
    msg = substr(msg, 14); SVC = "hors-site"; UNMATCHED = 1
  }

  # Continuation d'un événement multi-lignes (stack trace, erreur Prisma,
  # DETAIL Postgres…) : même service, même seconde que la ligne précédente.
  # Sans ce garde-fou, les lignes indentées du démarrage de Next.js
  # (« ▲ Next.js … ») seraient rattachées à n'importe quelle erreur passée.
  if (SEC != "" && PREVSEC[SVC] == SEC && iscont(msg, SVC)) {
    if (!SHOWN[SVC]) next
    sub(/^[0-9-]+ [0-9:.]+ [A-Z]+ \[[0-9]+\] /, "", msg)
    emitcont(LAST[SVC], msg)
    next
  }
  PREVSEC[SVC] = SEC
  PLAIN[SVC] = 0
  msg = trim(msg)
  # --grep choisit des événements : la stack d'une ligne retenue la suit.
  if (grep != "" && index(tolower(SVC " " msg), grep) == 0) {
    SHOWN[SVC] = 0; LAST[SVC] = textlevel(msg); PLAIN[SVC] = 1
    next
  }

  if (substr(msg, 1, 1) == "{" && jsonline(msg)) next
  if (nginxaccess(msg)) next

  lvl = ""
  # Postgres : « 2026-10-20 12:00:00.123 UTC [57] ERROR:  … »
  if (msg ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:.]+ [A-Z]+ \[[0-9]+\] [A-Z]+:/) {
    sub(/^[0-9-]+ [0-9:.]+ [A-Z]+ \[[0-9]+\] /, "", msg)
    word = msg; sub(/:.*/, "", word)
    lvl = (word ~ /^(ERROR|FATAL|PANIC)$/) ? "error" : (word == "WARNING" ? "warn" : "info")
    if (word ~ /^(LOG|ERROR|WARNING|FATAL|PANIC)$/) { msg = substr(msg, length(word) + 2); sub(/^ +/, "", msg) }
  }
  # nginx error_log : « 2026/10/20 12:00:00 [error] 29#29: *1 … »
  else if (msg ~ /^[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] [0-9:]+ \[[a-z]+\] /) {
    sub(/^[0-9\/]+ [0-9:]+ /, "", msg)
    word = substr(msg, 2, index(msg, "]") - 2)
    msg = substr(msg, index(msg, "]") + 2); sub(/^[0-9]+#[0-9]+: /, "", msg)
    lvl = (word ~ /^(error|crit|alert|emerg)$/) ? "error" : (word == "warn" ? "warn" : "info")
  }
  # Redis : « 1:M 20 Oct 2026 12:00:00.123 # Warning … » (# = avertissement)
  else if (msg ~ /^[0-9]+:[A-Z] [0-9]+ [A-Za-z]+ [0-9]+ [0-9:.]+ [*#.-] /) {
    sub(/^[0-9]+:[A-Z] [0-9]+ [A-Za-z]+ [0-9]+ [0-9:.]+ /, "", msg)
    lvl = (substr(msg, 1, 1) == "#") ? "warn" : "info"
    msg = substr(msg, 3)
    if (guesslevel(msg) == "error") lvl = "error"
  }
  # logback (Metarank) : « 12:00:00.123 INFO  logger - … »
  else if (msg ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9][.0-9]* +(TRACE|DEBUG|INFO|WARN|ERROR) /) {
    sub(/^[0-9:.]+ +/, "", msg)
    word = msg; sub(/ .*/, "", word); sub(/^[A-Z]+ +/, "", msg)
    lvl = normlevel(word)
  }
  if (lvl == "") {
    lvl = textlevel(msg)
    if (PFXLEN > 0) msg = substr(msg, PFXLEN + 1)
  }

  LAST[SVC] = lvl; PLAIN[SVC] = 1
  if (rank(lvl) < minlevel + 0) { SHOWN[SVC] = 0; next }
  SHOWN[SVC] = 1
  emit(lvl, tint(lvl, msg))
}
