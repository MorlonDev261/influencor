// Aperçu local du Worker avec une panne simulée (aucun compte Cloudflare requis) :
//   node scripts/edge/cloudflare/maintenance-worker/preview.mjs   → http://localhost:4410/
// ?site=poma|mga|influencor|developers choisit le site. /__origin/up et /__origin/down
// rallument ou éteignent le faux serveur : « Réessayer maintenant » ramène alors au site.
import http from "node:http";
import worker from "./worker.js";

const PORT = Number(process.env.PORT || 4410);
const SITES = {
  poma: "poma-original.com", mga: "app.mga-follow-up.com",
  influencor: "influencor.mi-kandra.org", developers: "developers.mi-kandra.org",
};
let up = false;
globalThis.fetch = async () => up
  ? new Response("<!doctype html><h1>Site revenu</h1>", { status: 200, headers: { "content-type": "text/html" } })
  : new Response("page Cloudflare 521", { status: 521 });

http.createServer(async (req, res) => {
  const local = new URL(req.url, `http://localhost:${PORT}`);
  if (local.pathname.startsWith("/__origin/")) {
    up = local.pathname === "/__origin/up";
    res.end(`faux serveur : ${up ? "allumé" : "éteint"}\n`);
    return;
  }
  const site = SITES[local.searchParams.get("site")] || SITES.poma;
  const request = new Request(`https://${site}${local.pathname}${local.search}`, {
    method: req.method, headers: Object.entries(req.headers).filter(([k]) => k !== "host"),
  });
  const r = await worker.fetch(request);
  res.writeHead(r.status, Object.fromEntries(r.headers));
  res.end(req.method === "HEAD" ? undefined : Buffer.from(await r.arrayBuffer()));
}).listen(PORT, () => console.log(`Aperçu : http://localhost:${PORT}/  (serveur ${up ? "allumé" : "éteint"})`));
