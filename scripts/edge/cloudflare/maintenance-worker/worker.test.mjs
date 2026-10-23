// Tests du Worker de maintenance et du script de sa page :
//   node --test scripts/edge/cloudflare/maintenance-worker/worker.test.mjs
// fetch est remplacé par un faux serveur : aucun appel réseau. Le moteur réel de Cloudflare
// est testé à part : workerd.test.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import worker from "./worker.js";

let origin; // (request) => Response | throw
globalThis.fetch = async (request) => origin(request);
const reply = (status, body = "origin", headers = {}) => () => new Response(body, { status, headers });

const HTML = { accept: "text/html,application/xhtml+xml,*/*;q=0.8" };
const call = (url, { method = "GET", headers = HTML } = {}) =>
  worker.fetch(new Request(url, { method, headers }));

test("réponse normale du serveur : renvoyée telle quelle", async () => {
  const sent = new Response("ok", { status: 200 });
  origin = () => sent;
  assert.equal(await call("https://poma-original.com/"), sent);
});

test("vraies erreurs du serveur (404, 500, 502, 503 nginx) : jamais remplacées", async () => {
  for (const s of [404, 500, 502, 503]) {
    origin = reply(s, "page du serveur");
    const r = await call("https://poma-original.com/");
    assert.equal(r.status, s);
    assert.equal(await r.text(), "page du serveur");
    assert.equal(r.headers.get("x-mi-kandra-maintenance"), null);
  }
});

test("serveur injoignable (520-526, 530) : page de maintenance 503 pour une navigation", async () => {
  for (const s of [520, 521, 522, 523, 524, 525, 526, 530]) {
    origin = reply(s, "page Cloudflare");
    const r = await call("https://poma-original.com/produits");
    assert.equal(r.status, 503, `code ${s}`);
    assert.equal(r.headers.get("x-mi-kandra-maintenance"), String(s));
    assert.equal(r.headers.get("cache-control"), "no-store");
    assert.equal(r.headers.get("retry-after"), "60");
    assert.match(r.headers.get("content-type"), /^text\/html/);
    const body = await r.text();
    assert.match(body, /Maintenance en cours/);
    assert.match(body, new RegExp(`Code ${s} `));
  }
});

test("chaque site a son nom et ses couleurs", async () => {
  origin = reply(521);
  const cases = [
    ["https://poma-original.com/", "Pôma Original", "#cfa85c"],
    ["https://www.poma-original.com/", "Pôma Original", "#cfa85c"],
    ["https://app.mga-follow-up.com/", "MGA Follow-up", "#3b82f6"],
    ["https://influencor.mi-kandra.org/", "Influencor", "#c084fc"],
    ["https://developers.mi-kandra.org/", "Mi Kandra Developers", "#34d399"],
    ["https://mi-kandra.org/", "Mi Kandra", "#34d399"],
    ["https://inconnu.example/", "Mi Kandra", "#34d399"],
  ];
  for (const [url, name, accent] of cases) {
    const body = await (await call(url)).text();
    assert.match(body, new RegExp(`<title>Maintenance — ${name}</title>`), url);
    assert.ok(body.includes(accent), `${url} : couleur ${accent}`);
  }
  const poma = await (await call("https://poma-original.com/")).text();
  // Logo complet : l'ancienne version, tronquée, s'affichait comme une image cassée.
  const [, type, b64] = poma.match(/<img src="data:image\/(jpeg|png);base64,([A-Za-z0-9+/=]+)"/);
  const img = Buffer.from(b64, "base64");
  if (type === "jpeg") {
    assert.deepEqual([...img.subarray(0, 2)], [0xff, 0xd8], "début JPEG");
    assert.deepEqual([...img.subarray(-2)], [0xff, 0xd9], "fin JPEG : image complète");
  } else {
    assert.ok(img.includes(Buffer.from("IEND")), "fin PNG : image complète");
  }
  assert.doesNotMatch(poma, /__POMA_LOGO__/);
});

test("API et applis : JSON 503 lisible", async () => {
  origin = reply(522);
  for (const [url, headers] of [
    ["https://app.mga-follow-up.com/api/sync", { accept: "*/*" }],
    ["https://influencor.mi-kandra.org/v1/feed", { accept: "application/json" }],
  ]) {
    const r = await call(url, { headers });
    assert.equal(r.status, 503);
    assert.match(r.headers.get("content-type"), /^application\/json/);
    const j = await r.json();
    assert.equal(j.error, "service_unavailable");
    assert.equal(j.retryAfter, 60);
  }
});

test("fichiers statiques : l'erreur d'origine est renvoyée inchangée", async () => {
  const sent = new Response("page Cloudflare", { status: 521 });
  origin = () => sent;
  assert.equal(await call("https://poma-original.com/_next/static/app.js", { headers: { accept: "*/*" } }), sent);
});

test("HEAD (utilisé par la page pour savoir si le site est revenu) : en-têtes sans corps", async () => {
  origin = reply(521);
  const r = await call("https://poma-original.com/", { method: "HEAD" });
  assert.equal(r.status, 503);
  assert.equal(r.headers.get("x-mi-kandra-maintenance"), "521");
  assert.equal(await r.text(), "");
  origin = reply(200, "");
  const back = await call("https://poma-original.com/", { method: "HEAD" });
  assert.equal(back.status, 200);
  assert.equal(back.headers.get("x-mi-kandra-maintenance"), null);
});

test("POST pendant la panne : JSON pour une API, page (revenant en GET) pour un formulaire", async () => {
  origin = reply(521);
  const r = await call("https://poma-original.com/api/orders", { method: "POST", headers: { accept: "text/html" } });
  assert.equal(r.status, 503);
  assert.match(r.headers.get("content-type"), /^application\/json/);
  const form = await call("https://poma-original.com/contact", { method: "POST", headers: { accept: "text/html" } });
  assert.equal(form.status, 503);
  assert.match(form.headers.get("content-type"), /^text\/html/);
  assert.match(await form.text(), /location\.replace\(location\.href\)/);
});

test("fetch qui lève une exception : page de maintenance (code 520)", async () => {
  origin = () => { throw new TypeError("network"); };
  const r = await call("https://poma-original.com/");
  assert.equal(r.status, 503);
  assert.equal(r.headers.get("x-mi-kandra-maintenance"), "520");
});

test("WebSocket : transmis sans interception", async () => {
  const sent = new Response(null, { status: 521 });
  origin = () => sent;
  assert.equal(await call("https://poma-original.com/ws", { headers: { upgrade: "websocket" } }), sent);
});

// --- Script de la page : exécuté dans un faux navigateur (DOM, minuteries et réseau simulés).
const flush = () => new Promise((r) => setImmediate(r));
const PAGE_URL = "https://poma-original.com/produits?tri=prix";

async function openPage() {
  origin = reply(521);
  const html = await (await call(PAGE_URL)).text();
  const src = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const els = {};
  const el = (id, text = "") => (els[id] = {
    id, disabled: false, listeners: {}, _text: text,
    get textContent() { return this._text; },
    set textContent(v) { this._text = String(v); }, // comme un vrai DOM
    addEventListener(type, fn) { this.listeners[type] = fn; },
    click() { this.listeners.click?.(); },
  });
  el("status", html.match(/<p id="status"[^>]*>([^<]*)<\/p>/)[1]);
  el("retry");
  const page = { els, html, calls: [], replaced: [], timers: [] };
  const timer = (kind) => (fn, ms) => { page.timers.push({ kind, fn, ms }); return page.timers.length; };
  vm.runInNewContext(src, {
    document: { getElementById: (id) => els[id] || null },
    location: { href: PAGE_URL, replace: (u) => page.replaced.push(u), reload: () => page.replaced.push("reload") },
    fetch: (url, opts) => { page.calls.push({ url, opts }); return new Promise((res, rej) => { page.pending = { res, rej }; }); },
    setInterval: timer("setInterval"), setTimeout: timer("setTimeout"),
    requestAnimationFrame: timer("requestAnimationFrame"),
  });
  page.answer = async (status, headers = {}) => {
    page.pending.res({ status, headers: { get: (k) => headers[k.toLowerCase()] ?? null } }); await flush(); await flush();
  };
  page.cut = async () => { page.pending.rej(new TypeError("réseau coupé")); await flush(); await flush(); };
  return page;
}

test("page : aucun essai automatique (ni minuterie, ni rafraîchissement, ni appel réseau seul)", async () => {
  const p = await openPage();
  assert.deepEqual(p.timers, [], "aucune minuterie posée");
  assert.equal(p.calls.length, 0, "aucun appel sans clic");
  assert.doesNotMatch(p.html, /http-equiv=["']?refresh/i, "pas de <meta refresh>");
  const visible = p.html.replace(/<(script|style)[\s\S]*?<\/\1>/g, "").replace(/<[^>]+>/g, " ");
  assert.doesNotMatch(visible, /automatique|Nouvel essai dans/i, "aucun texte annonçant un essai automatique");
  assert.equal(p.els.status.textContent, "Réessayez dans quelques instants.");
  await flush();
  assert.equal(p.calls.length, 0);
});

test("page : le bouton vérifie la même adresse en HEAD, sans cache, en demandant du HTML", async () => {
  const p = await openPage();
  p.els.retry.click();
  assert.equal(p.calls.length, 1);
  const { url, opts } = p.calls[0];
  assert.equal(url, PAGE_URL);
  assert.equal(opts.method, "HEAD");
  assert.equal(opts.cache, "no-store");
  assert.equal(opts.headers.Accept, "text/html");
  assert.equal(p.els.retry.disabled, true, "bouton désactivé pendant la vérification");
  assert.equal(p.els.status.textContent, "Vérification…");
});

test("page : toujours en maintenance → message, bouton réactivé, et rien ne se relance seul", async () => {
  const p = await openPage();
  p.els.retry.click();
  await p.answer(503, { "x-mi-kandra-maintenance": "521" });
  assert.equal(p.els.status.textContent, "Toujours indisponible. Réessayez dans quelques instants.");
  assert.equal(p.els.retry.disabled, false);
  assert.deepEqual(p.replaced, []);
  assert.deepEqual(p.timers, [], "pas de nouvel essai programmé");
  assert.equal(p.calls.length, 1);
});

test("page : site revenu (200 ou 404 du serveur) → retour à la même adresse, en GET", async () => {
  for (const status of [200, 404]) {
    const p = await openPage();
    p.els.retry.click();
    await p.answer(status);
    assert.deepEqual(p.replaced, [PAGE_URL], `statut ${status}`);
  }
});

test("page : serveur qui répond 5xx, ou réseau coupé → on reste, sans nouvel essai", async () => {
  const p = await openPage();
  p.els.retry.click();
  await p.answer(502);
  assert.deepEqual(p.replaced, []);
  assert.match(p.els.status.textContent, /^Toujours indisponible/);
  p.els.retry.click();
  await p.cut();
  assert.deepEqual(p.replaced, []);
  assert.equal(p.els.retry.disabled, false);
  assert.equal(p.calls.length, 2);
  assert.deepEqual(p.timers, []);
});

test("page : un seul appel à la fois, même avec plusieurs clics", async () => {
  const p = await openPage();
  p.els.retry.click();
  p.els.retry.click();
  p.els.retry.click();
  assert.equal(p.calls.length, 1, "pas de second appel tant que le premier n'a pas répondu");
  await p.answer(503, { "x-mi-kandra-maintenance": "521" });
  p.els.retry.click();
  assert.equal(p.calls.length, 2);
  await p.answer(200);
  assert.deepEqual(p.replaced, [PAGE_URL]);
});
