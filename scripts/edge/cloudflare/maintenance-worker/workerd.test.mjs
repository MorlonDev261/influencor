// Test d'intégration dans le VRAI moteur de Cloudflare (workerd, via `wrangler dev`) :
//   node --test scripts/edge/cloudflare/maintenance-worker/workerd.test.mjs
// Un faux serveur local sert d'origine (--local-upstream) ; on l'éteint pour un serveur
// injoignable. Premier lancement : npx télécharge wrangler@4 (réseau requis, ~1 min).
// Sans npx, sans réseau ou sans certificats racine (image Docker minimale), le test est
// sauté avec la raison, pas en échec.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WIN = process.platform === "win32";

// Sous Windows, npx.cmd ne se lance que par un shell : on lui passe alors une seule ligne de
// commande, car une liste d'arguments avec shell: true déclenche DEP0190 (rien n'est échappé).
// Les arguments sont tous fixes ici, sans espace ni caractère spécial.
const npx = (args) => (WIN ? [["npx.cmd", ...args].join(" "), []] : ["npx", args]);

const freePort = () => new Promise((resolve) => {
  const s = net.createServer().listen(0, "127.0.0.1", () => { const { port } = s.address(); s.close(() => resolve(port)); });
});

// Faux serveur d'origine : /status/N répond N, le reste 200.
let originPort, origin;
const startOrigin = () => new Promise((resolve) => {
  origin = http.createServer((q, s) => {
    const m = q.url.match(/^\/status\/(\d+)/);
    s.writeHead(m ? Number(m[1]) : 200, { "content-type": "text/plain" });
    s.end(`origin ${q.method} ${q.url}`);
  }).listen(originPort, "127.0.0.1", resolve);
});
const stopOrigin = () => new Promise((resolve) => { origin.closeAllConnections?.(); origin.close(() => resolve()); });

let dev, devPort, base, tmp, skip = "", log = "";

// Arrête wrangler ET workerd : sous Windows, seul taskkill /T suit toute l'arborescence.
function killDev() {
  if (!dev || dev.exitCode !== null) return;
  if (WIN) spawnSync("taskkill", ["/pid", String(dev.pid), "/T", "/F"], { stdio: "ignore" });
  else try { process.kill(-dev.pid, "SIGTERM"); } catch { /* déjà arrêté */ }
}

before(async () => {
  if (spawnSync(...npx(["--version"]), { stdio: "ignore", shell: WIN }).status !== 0) { skip = "npx introuvable"; return; }
  // Sous Windows, workerd libère son dossier .wrangler après la fin du test : chaque lancement
  // supprime donc ceux des lancements précédents (il en reste au plus un).
  const parent = path.join(os.tmpdir(), "mi-kandra-maintenance-test");
  fs.mkdirSync(parent, { recursive: true });
  for (const old of fs.readdirSync(parent)) try { fs.rmSync(path.join(parent, old), { recursive: true, force: true }); } catch { /* encore tenu */ }
  tmp = fs.mkdtempSync(path.join(parent, "run-"));
  fs.copyFileSync(path.join(HERE, "worker.js"), path.join(tmp, "worker.js"));
  // Configuration minimale : sans les routes de production, rien ne part vers les vrais domaines.
  fs.writeFileSync(path.join(tmp, "wrangler.toml"), 'name = "mk-maint-test"\nmain = "worker.js"\ncompatibility_date = "2025-09-01"\n');
  originPort = await freePort(); devPort = await freePort();
  await startOrigin();
  base = `http://127.0.0.1:${devPort}`;
  dev = spawn(...npx(["-y", "wrangler@4", "dev", "--port", String(devPort), "--ip", "127.0.0.1",
    "--local-upstream", `127.0.0.1:${originPort}`, "--inspector-port", String(await freePort())]), {
    cwd: tmp, shell: WIN, detached: !WIN, env: { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1" },
  });
  dev.stdout.on("data", (d) => { log += d; });
  dev.stderr.on("data", (d) => { log += d; });
  const t0 = Date.now();
  while (Date.now() - t0 < 180_000) {
    if (dev.exitCode !== null) break;
    try { await fetch(`${base}/`); return; } catch { await new Promise((r) => setTimeout(r, 500)); }
  }
  // Causes vues : pas de réseau (téléchargement de wrangler), système sans certificats racine.
  skip = `wrangler dev n'a pas démarré :\n${log.replace(/\x1b\[[0-9;]*m/g, "").slice(-800)}`;
});

after(async () => {
  const exited = dev && dev.exitCode === null ? new Promise((r) => dev.once("exit", r)) : null;
  killDev();
  if (exited) await Promise.race([exited, new Promise((r) => setTimeout(r, 10_000))]);
  if (origin?.listening) await stopOrigin();
  // Ailleurs que sous Windows, le dossier part tout de suite ; sinon au lancement suivant.
  if (tmp) try { fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 4, retryDelay: 250 }); } catch { /* lancement suivant */ }
});

const get = (p, accept = "text/html", method = "GET") => fetch(`${base}${p}`, { method, headers: { accept } });

test("workerd : réponses du serveur transmises intactes (200, 404, 500, 503)", async (t) => {
  if (skip) return t.skip(skip);
  for (const [p, s] of [["/", 200], ["/status/404", 404], ["/status/500", 500], ["/status/503", 503]]) {
    const r = await get(p);
    assert.equal(r.status, s, p);
    assert.equal(r.headers.get("x-mi-kandra-maintenance"), null, p);
    assert.equal(await r.text(), `origin GET ${p}`, p);
  }
});

test("workerd : erreur Cloudflare 521/522 → page de maintenance, JSON ou erreur d'origine", async (t) => {
  if (skip) return t.skip(skip);
  const page = await get("/status/521");
  assert.equal(page.status, 503);
  assert.equal(page.headers.get("x-mi-kandra-maintenance"), "521");
  assert.equal(page.headers.get("retry-after"), "60");
  assert.match(await page.text(), /<title>Maintenance — Mi Kandra<\/title>[\s\S]*Code 521 /);

  const api = await get("/status/522", "application/json");
  assert.equal(api.status, 503);
  assert.equal((await api.json()).error, "service_unavailable");

  const asset = await get("/status/521", "*/*");
  assert.equal(asset.status, 521);
  assert.equal(await asset.text(), "origin GET /status/521");

  const head = await get("/status/521", "text/html", "HEAD");
  assert.equal(head.status, 503);
  assert.equal(head.headers.get("x-mi-kandra-maintenance"), "521");
  assert.equal(await head.text(), "");
});

test("workerd : serveur injoignable → page de maintenance, puis retour du site", async (t) => {
  if (skip) return t.skip(skip);
  await stopOrigin();
  const down = await get("/");
  assert.equal(down.status, 503);
  assert.equal(down.headers.get("x-mi-kandra-maintenance"), "520");
  assert.match(await down.text(), /Maintenance en cours/);
  const api = await get("/api/orders", "application/json");
  assert.equal(api.status, 503);
  assert.match(api.headers.get("content-type"), /^application\/json/);

  await startOrigin();
  const back = await get("/", "text/html", "HEAD");
  assert.equal(back.status, 200);
  assert.equal(back.headers.get("x-mi-kandra-maintenance"), null);
});
