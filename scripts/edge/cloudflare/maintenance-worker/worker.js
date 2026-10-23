// =============================================================================
// mi-kandra-maintenance — Worker Cloudflare : page de maintenance quand le serveur
// ne répond pas (copie IDENTIQUE dans chaque projet, déployée UNE fois)
//
// Chaque requête part normalement vers le serveur. Seules les erreurs que
// Cloudflare fabrique lui-même quand il ne joint pas le serveur (520-526, 530 :
// serveur éteint, port fermé, délai dépassé, TLS en échec) sont remplacées :
//   - navigation (page HTML)   → page de maintenance aux couleurs du site, 503 ;
//   - API / JSON (applis)      → JSON 503 { error: "service_unavailable" } ;
//   - le reste (images, JS)    → l'erreur d'origine, inchangée.
// Une vraie réponse du serveur (200, 404, 503 de la maintenance nginx…) n'est
// JAMAIS modifiée. La page ne réessaie jamais seule : le bouton « Réessayer
// maintenant » vérifie le site et y retourne s'il répond.
// Activation et coûts : voir README.md à côté.
// =============================================================================

// Codes propres à Cloudflare : le serveur, lui, ne les renvoie jamais.
const ORIGIN_DOWN = new Set([520, 521, 522, 523, 524, 525, 526, 530]);
const RETRY_AFTER = 60;

const POMA_LOGO = "data:image/jpeg;base64,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";

// Premier motif qui correspond au nom d'hôte. Couleurs modifiables ici.
const BRANDS = [
  { match: /(^|\.)poma-original\.com$/, name: "Pôma Original", logo: POMA_LOGO, serif: true,
    bg: "#051e1e", glow: "#114141", accent: "#cfa85c", text: "#f0ebe3", muted: "#c7d1cd" },
  { match: /(^|\.)mga-follow-up\.com$/, name: "MGA Follow-up",
    bg: "#0b1220", glow: "#16233d", accent: "#3b82f6", text: "#e8edf5", muted: "#aab4c3" },
  { match: /influencor[^.]*\.mi-kandra\.org$/, name: "Influencor",
    bg: "#140d1f", glow: "#2a1640", accent: "#c084fc", text: "#f1eaf8", muted: "#c3b6d3" },
  { match: /^developers\.mi-kandra\.org$/, name: "Mi Kandra Developers",
    bg: "#0f1412", glow: "#1c2a24", accent: "#34d399", text: "#e9f1ed", muted: "#b3c2bb" },
  { match: /./, name: "Mi Kandra",
    bg: "#0f1412", glow: "#1c2a24", accent: "#34d399", text: "#e9f1ed", muted: "#b3c2bb" },
];

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

function page(brand, code) {
  const when = new Date().toISOString().slice(0, 16).replace("T", " ");
  const mark = brand.logo
    ? `<img src="${brand.logo}" alt="">`
    : `<span>${esc(brand.name.charAt(0))}</span>`;
  return `<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>Maintenance — ${esc(brand.name)}</title>
<style>
:root{color-scheme:dark;font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:${brand.bg};color:${brand.text}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;padding:16px;background:radial-gradient(circle at 50% 40%,${brand.glow},${brand.bg} 65%)}
main{text-align:center;max-width:420px;width:100%}
.mark{margin:auto;width:76px;height:76px;display:grid;place-items:center;border:1px solid ${brand.accent};border-radius:50%;overflow:hidden;color:${brand.accent};font-size:32px;font-weight:600}
.mark img{width:100%;height:100%;object-fit:cover}
h1{font-family:${brand.serif ? "Georgia,serif" : "inherit"};font-size:24px;margin:24px 0 12px;color:${brand.text}}
p{color:${brand.muted};line-height:1.6;font-size:15px;margin:0 0 12px}
button{margin-top:12px;font:inherit;font-size:14px;color:${brand.bg};background:${brand.accent};border:0;border-radius:999px;padding:10px 20px;cursor:pointer}
button:disabled{opacity:.6;cursor:default}
button:focus-visible{outline:2px solid ${brand.text};outline-offset:3px}
.meta{margin-top:28px;font-size:12px;opacity:.7}
</style>
</head>
<body>
<main>
<div class="mark">${mark}</div>
<h1>Maintenance en cours</h1>
<p>${esc(brand.name)} est momentanément indisponible pendant notre intervention sur le serveur. Vos données sont en sécurité.</p>
<p id="status" aria-live="polite">Réessayez dans quelques instants.</p>
<button id="retry" type="button">Réessayer maintenant</button>
<p class="meta">Code ${code} · ${when} UTC</p>
</main>
<script>
// Aucun essai automatique : seul le bouton vérifie si le site est revenu.
(function () {
  var busy = false, status = document.getElementById("status"), btn = document.getElementById("retry");
  function again() {
    busy = false; btn.disabled = false;
    status.textContent = "Toujours indisponible. Réessayez dans quelques instants.";
  }
  btn.addEventListener("click", function () {
    if (busy) return; busy = true; btn.disabled = true;
    status.textContent = "Vérification…";
    fetch(location.href, { method: "HEAD", cache: "no-store", headers: { Accept: "text/html" } })
      .then(function (r) {
        if (r.status < 500 && !r.headers.get("x-mi-kandra-maintenance")) { location.replace(location.href); return; }
        again();
      })
      .catch(again);
  });
})();
</script>
</body>
</html>`;
}

function maintenance(request, code, original) {
  const url = new URL(request.url);
  const accept = request.headers.get("accept") || "";
  const headers = {
    "cache-control": "no-store",
    "retry-after": String(RETRY_AFTER),
    "x-mi-kandra-maintenance": String(code),
  };
  // API d'abord : un appel d'appli ne doit jamais recevoir une page HTML.
  if (accept.includes("application/json") || url.pathname.startsWith("/api/")) {
    const body = JSON.stringify({
      error: "service_unavailable",
      message: "Service momentanément indisponible (maintenance). Réessayez dans un instant.",
      status: 503,
      retryAfter: RETRY_AFTER,
    });
    return new Response(request.method === "HEAD" ? null : body,
      { status: 503, headers: { ...headers, "content-type": "application/json; charset=utf-8" } });
  }
  // Navigation, y compris l'envoi d'un formulaire (POST) : la page revient ensuite en GET.
  if (accept.includes("text/html")) {
    const brand = BRANDS.find((x) => x.match.test(url.hostname));
    const body = request.method === "HEAD" ? null : page(brand, code);
    return new Response(body, { status: 503, headers: { ...headers, "content-type": "text/html; charset=utf-8" } });
  }
  return original || new Response("Service indisponible", { status: 503, headers });
}

const worker = {
  async fetch(request) {
    // WebSocket : on ne touche pas à la poignée de main.
    if ((request.headers.get("upgrade") || "").toLowerCase() === "websocket") return fetch(request);
    let response;
    try {
      response = await fetch(request);
    } catch {
      return maintenance(request, 520);
    }
    return ORIGIN_DOWN.has(response.status) ? maintenance(request, response.status, response) : response;
  },
};

export default worker;
