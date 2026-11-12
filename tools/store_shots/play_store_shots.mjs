/**
 * play_store_shots — Google Play images of Influencor (same layout as Pôma's
 * docs/03-mobile/play-store): framed screenshots per device, the 512 px icon
 * and the 1024×500 feature graphic.
 *
 * 1. node tools/store_shots/make_photos.mjs   (demo photos, only without phone data)
 * 2. flutter test tools/store_shots/store_shots_test.dart   (raw app screens)
 * 3. node tools/store_shots/play_store_shots.mjs [appareil…]  (this script)
 *
 * Writes docs/developer/release/play-store/<appareil>/<appareil>-capture-<n>.png,
 * icone-512.png and presentation-1024x500.png. Each device's images follow
 * each other in the Play Console as one continuous strip.
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { openBrowser } from './browser.mjs';

const ROOT = process.cwd();
const RAW = path.join(ROOT, 'build', 'store_shots', 'raw');
const OUT = path.join(ROOT, 'docs', 'developer', 'release', 'play-store');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// [raw file, title (second half highlighted)]
const SHOTS = [
  ['1-accueil', 'Tout votre contenu|au même endroit'],
  ['8-dossier', 'Photos et vidéos|rangées par dossier'],
  ['2-note', 'Vos textes prêts|à copier-coller'],
  ['3-degany', 'Degany, votre|assistant IA'],
  ['5-frais', 'Frais Mobile Money|calculés pour vous'],
  ['6-comptabilite', 'Votre caisse|toujours à jour'],
  ['7-taches', 'Vos tâches|bien organisées'],
  ['4-favoris', 'Vos favoris|en un geste'],
];

const DEVICES = {
  mobile: { raw: 'mobile', frame: 'phone', panel: [1080, 1920], dpr: 1 },
  'tablette-7': { raw: 'tablette-7', frame: 'tablet', panel: [1080, 1920], dpr: 1 },
  'tablette-10': { raw: 'tablette-10', frame: 'tablet', panel: [1080, 1920], dpr: 1.5 },
  ordinateur: { raw: 'ordinateur', frame: 'desk', panel: [1920, 1080], dpr: 1 },
  'android-xr': { raw: 'ordinateur', frame: 'xr', panel: [1920, 1080], dpr: 1, only: ['1-accueil', '8-dossier', '3-degany', '6-comptabilite'] },
};

const wanted = process.argv.slice(2);
for (const d of wanted) if (!DEVICES[d] && d !== 'brand') throw new Error(`Appareil inconnu : ${d} (${Object.keys(DEVICES).join(', ')}, brand)`);
const devices = wanted.length ? wanted.filter((d) => d !== 'brand') : Object.keys(DEVICES);
const brand = !wanted.length || wanted.includes('brand');

// ── Charte (site influencor-web) ─────────────────────────────────────────────
const BLUE = '#204da0';
const BRIGHT = '#4c86e5';
const DEEP = '#0f2a63';
const INK = '#0f172a';
const ORANGE = '#f26b1d';
const FONTS = '<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:ital,wght@0,500;0,700;0,800;1,800&display=block" rel="stylesheet">';
const SPARK = (fill) => `<symbol id="spark" viewBox="-10 -10 20 20"><path d="M0-10C1-3 3-1 10 0C3 1 1 3 0 10C-1 3-3 1-10 0C-3-1-1-3 0-10Z" fill="${fill}"/></symbol>`;
const BARS = '<svg width="40" height="26" viewBox="0 0 40 26"><rect x="0" y="17" width="7" height="9" rx="2"/><rect x="11" y="12" width="7" height="14" rx="2"/><rect x="22" y="6" width="7" height="20" rx="2"/><rect x="33" y="0" width="7" height="26" rx="2"/></svg>';
const WIFI = '<svg width="36" height="26" viewBox="0 0 24 17"><path d="M12 3.5c3.2 0 6.1 1.2 8.3 3.3l1.5-1.6C19.2 2.7 15.8 1.2 12 1.2S4.8 2.7 2.2 5.2l1.5 1.6C5.9 4.7 8.8 3.5 12 3.5zm0 4.6c2 0 3.8.8 5.1 2l1.6-1.6C17 6.8 14.6 5.8 12 5.8s-5 1-6.7 2.7l1.6 1.6c1.3-1.2 3.1-2 5.1-2zm0 4.6c.8 0 1.5.3 2 .8L12 15.7l-2-2.2c.5-.5 1.2-.8 2-.8z"/></svg>';
const BATT = '<svg width="58" height="27" viewBox="0 0 58 27"><rect x="1.5" y="1.5" width="49" height="24" rx="7" fill="none" stroke="#000" stroke-opacity=".4" stroke-width="3"/><rect x="5" y="5" width="42" height="17" rx="4"/><rect x="53" y="9" width="4" height="9" rx="2" opacity=".4"/></svg>';
const LOCK = '<svg viewBox="0 0 24 24"><path d="M6 10V8a6 6 0 1 1 12 0v2h1a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V11a1 1 0 0 1 1-1h1zm2 0h8V8a4 4 0 1 0-8 0v2z"/></svg>';
const title = (t, br) => { const [a, b] = t.split('|'); return `${a}${br ? '<br>' : ' '}<em>${b}</em>`; };
const LIGHT_BG = 'linear-gradient(100deg,#f5f8ff 0%,#e7eefc 22%,#f8faff 45%,#e3ecfb 68%,#f5f8ff 85%,#dfe8fa 100%)';

/** Portrait strip (1080×1920 per image): blue ribbon, halos and sparkles running across images. */
function portraitArt(W, n) {
  let blobs = '';
  let sparks = '';
  for (let k = 0; k <= n; k += 1) {
    const x = k * 1080;
    blobs += `<circle cx="${x}" cy="${k % 2 ? 520 : 1250}" r="600" fill="url(#blob)"/><circle cx="${x + 540}" cy="${k % 2 ? 1750 : 1700}" r="500" fill="url(#blob2)"/>`;
    sparks += `<use href="#spark" x="${x + 880}" y="${k % 2 ? 1000 : 380}" width="${k % 2 ? 50 : 70}" height="${k % 2 ? 50 : 70}"/>`
      + `<use href="#spark" x="${x + 40}" y="${k % 2 ? 420 : 1100}" width="54" height="54"/>`;
  }
  let d = 'M-100 1500';
  for (let k = 0; k < n; k += 1) {
    const x = k * 1080;
    d += ` C ${x + 300} ${k % 2 ? 1700 : 1150}, ${x + 700} ${k % 2 ? 1150 : 1750}, ${x + 1180} ${k % 2 ? 1250 : 1350}`;
  }
  return `<svg class="art" width="${W}" height="1920" viewBox="0 0 ${W} 1920"><defs>
  <linearGradient id="g1" x1="0" x2="1"><stop offset="0" stop-color="${BRIGHT}"/><stop offset=".5" stop-color="${BLUE}"/><stop offset="1" stop-color="${BRIGHT}"/></linearGradient>
  <radialGradient id="blob"><stop offset="0" stop-color="#9dbcf3" stop-opacity=".7"/><stop offset="1" stop-color="#9dbcf3" stop-opacity="0"/></radialGradient>
  <radialGradient id="blob2"><stop offset="0" stop-color="#ffffff" stop-opacity=".95"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></radialGradient>
  ${SPARK(BLUE)}</defs>${blobs}
 <path d="${d}" fill="none" stroke="url(#g1)" stroke-width="150" stroke-linecap="round" opacity=".35"/>
 <path d="${d}" fill="none" stroke="#fff" stroke-width="10" opacity=".9" transform="translate(0,-30)"/>
 <path d="M-100 900 C 500 700, 900 1150, 1500 850 S 2500 500, 3000 800 S 3900 1200, 4500 850 S 5600 450, 6600 750 S 7900 1100, 9000 800" fill="none" stroke="${BLUE}" stroke-width="5" stroke-dasharray="2 22" stroke-linecap="round" opacity=".55"/>
 ${sparks}</svg>`;
}

const PORTRAIT_CSS = `body{background:${LIGHT_BG}}
.title{position:absolute;top:118px;left:60px;right:60px;text-align:center;font-family:'Plus Jakarta Sans',sans-serif;font-weight:800;font-size:84px;line-height:1.1;color:${INK};letter-spacing:-1.5px}
.title em{color:${BLUE};font-style:normal}
.status{display:flex;align-items:center;justify-content:space-between;background:#fff}
.status .r{display:flex;align-items:center}
.status svg{fill:#000}`;

const FRAMES = {
  // Punch-hole phone, slightly tilted.
  phone: {
    css: `${PORTRAIT_CSS}
.phone{position:absolute;left:50%;top:440px;width:768px;height:1638px;transform:translateX(-50%) rotate(var(--r));border-radius:110px;
 background:linear-gradient(135deg,#3b4258 0%,#1f2433 30%,#353c50 60%,#171b26 100%);
 box-shadow:0 60px 120px rgba(15,42,99,.35),0 18px 40px rgba(0,0,0,.22),inset 0 0 0 3px rgba(255,255,255,.18)}
.phone::before,.phone::after{content:"";position:absolute;background:#262b38;border-radius:6px}
.phone::before{right:-9px;top:330px;width:10px;height:120px;box-shadow:0 160px 0 #262b38}
.phone::after{right:-9px;top:620px;width:10px;height:190px}
.screen{position:absolute;inset:24px;border-radius:88px;overflow:hidden;background:#fff}
.status{height:96px;padding:0 64px 0 76px;font:500 34px/1 Roboto,'Plus Jakarta Sans',sans-serif;color:#000}.status .r{gap:12px}
.hole{position:absolute;top:30px;left:50%;transform:translateX(-50%);width:40px;height:40px;border-radius:50%;background:#000;z-index:2}`,
    tilt: ['-3deg', '2deg', '-2deg', '3deg', '-2deg', '2deg', '-3deg', '2deg'],
    panel: (src, t, r) => `<div class="title">${title(t, true)}</div><div class="phone" style="--r:${r}"><div class="screen"><div class="hole"></div>
 <div class="status"><span>9:41</span><span class="r">${BARS}${WIFI}${BATT}</span></div><img class="shot" src="${src}"></div></div>`,
    art: portraitArt,
  },
  // Tablet, thin bezels.
  tablet: {
    css: `${PORTRAIT_CSS}
.phone{position:absolute;left:50%;top:430px;width:960px;height:1540px;transform:translateX(-50%) rotate(var(--r)) scale(.9);transform-origin:50% 0;border-radius:58px;
 background:linear-gradient(135deg,#363b48 0%,#1b1e26 40%,#2a2f3a 70%,#14161c 100%);
 box-shadow:0 60px 120px rgba(15,42,99,.33),0 18px 40px rgba(0,0,0,.2),inset 0 0 0 3px rgba(255,255,255,.14)}
.phone::before{content:"";position:absolute;top:13px;left:50%;width:10px;height:10px;margin-left:-5px;border-radius:50%;background:#0b0b10;box-shadow:inset 0 0 0 2px #2b2b38}
.phone::after{content:"";position:absolute;right:-7px;top:180px;width:8px;height:110px;background:#26262c;border-radius:4px;box-shadow:0 150px 0 #26262c}
.screen{position:absolute;inset:30px;border-radius:26px;overflow:hidden;background:#fff}
.status{height:40px;padding:0 26px;font:500 20px/1 Roboto,sans-serif;color:#222}.status .r{gap:9px}.status svg{height:16px;width:auto}`,
    tilt: ['-2deg', '2deg', '-2deg', '2deg', '-2deg', '2deg', '-2deg', '2deg'],
    panel: (src, t, r) => `<div class="title">${title(t, true)}</div><div class="phone" style="--r:${r}"><div class="screen">
 <div class="status"><span>9:41</span><span class="r">${BARS}${WIFI}${BATT}</span></div><img class="shot" src="${src}"></div></div>`,
    art: portraitArt,
  },
};

/** Landscape 1920×1080: app window on light blue (computer) or floating panel on deep blue (XR). */
function landscape(xr) {
  const accent = xr ? '#8fb4f5' : BLUE;
  return {
    css: `body{background:${xr
      ? `radial-gradient(ellipse 1400px 900px at 30% 40%,#1d3f86 0%,rgba(29,63,134,0) 70%),radial-gradient(ellipse 1600px 900px at 75% 70%,#16336f 0%,rgba(22,51,111,0) 70%),linear-gradient(180deg,#0b1736 0%,#060d22 100%)`
      : LIGHT_BG}}
.title{position:absolute;top:70px;left:0;right:0;text-align:center;font-family:'Plus Jakarta Sans',sans-serif;font-weight:800;font-size:64px;letter-spacing:-1px;line-height:1.1;color:${xr ? '#fff' : INK}}
.title em{color:${accent};font-style:normal}
.win{position:absolute;left:50%;top:230px;width:1500px;transform:translateX(-50%);border-radius:18px;overflow:hidden;background:#fff;
 box-shadow:0 50px 110px rgba(15,42,99,.30),0 12px 30px rgba(0,0,0,.14),0 0 0 1px rgba(0,0,0,.06)}
.bar{height:46px;background:#eef2f9;display:flex;align-items:center;gap:14px;padding:0 18px;border-bottom:1px solid #dde4f0;font:600 17px/1 'Plus Jakarta Sans',sans-serif;color:#334155}
.bar img{width:24px;height:24px;border-radius:6px}.bar .sp{flex:1}
.bar i{display:block;width:14px;height:2px;background:#64748b;margin-left:22px}.bar i.sq{width:12px;height:12px;background:none;border:2px solid #64748b;border-radius:2px}
${xr ? `.win{top:250px;width:1340px;border-radius:40px;transform:translateX(-50%) perspective(2400px) rotateY(var(--r));
 box-shadow:0 70px 160px rgba(0,0,0,.65),0 0 0 2px rgba(255,255,255,.18),0 0 90px rgba(76,134,229,.25)}
.bar{display:none}.win .shot{height:754px;object-fit:cover;object-position:top}
.orb{position:absolute;left:50%;top:1028px;transform:translateX(-50%);display:flex;gap:14px;padding:10px 18px;border-radius:30px;background:rgba(255,255,255,.14);box-shadow:0 0 0 1px rgba(255,255,255,.18)}
.orb i{display:block;width:26px;height:26px;border-radius:50%;background:rgba(255,255,255,.55)}
.orb b{display:block;width:120px;height:8px;margin:9px 0;border-radius:4px;background:rgba(255,255,255,.7)}` : ''}`,
    tilt: ['5deg', '-5deg', '5deg', '-5deg', '5deg', '-5deg', '5deg', '-5deg'],
    panel: (src, t, r) => `<div class="title">${title(t, false)}</div><div class="win" style="--r:${r}">
 <div class="bar"><img src="${pathToFileURL(path.join(ROOT, 'assets', 'icon', 'icon_blue.png')).href}">Influencor<span class="sp"></span><i></i><i class="sq"></i><i></i></div>
 <img class="shot" src="${src}"></div>${xr ? '<div class="orb"><i></i><b></b><i></i></div>' : ''}`,
    art: (W, n) => {
      let svg = `<svg class="art" width="${W}" height="1080" viewBox="0 0 ${W} 1080"><defs>
<linearGradient id="g1" x1="0" x2="1"><stop offset="0" stop-color="${BRIGHT}"/><stop offset=".5" stop-color="${BLUE}"/><stop offset="1" stop-color="${BRIGHT}"/></linearGradient>
<radialGradient id="blob"><stop offset="0" stop-color="${xr ? BRIGHT : '#9dbcf3'}" stop-opacity="${xr ? 0.35 : 0.65}"/><stop offset="1" stop-color="#9dbcf3" stop-opacity="0"/></radialGradient>
${SPARK(accent)}</defs>`;
      for (let k = 0; k <= n; k += 1) svg += `<circle cx="${k * 1920}" cy="${k % 2 ? 300 : 820}" r="560" fill="url(#blob)"/>`;
      let d = 'M-100 880';
      for (let k = 0; k < n; k += 1) {
        const x = k * 1920;
        d += ` C ${x + 500} ${k % 2 ? 1000 : 560}, ${x + 1300} ${k % 2 ? 560 : 1000}, ${x + 1960} ${k % 2 ? 760 : 880}`;
      }
      svg += `<path d="${d}" fill="none" stroke="url(#g1)" stroke-width="110" stroke-linecap="round" opacity="${xr ? 0.35 : 0.3}"/>`
        + `<path d="${d}" fill="none" stroke="#fff" stroke-width="6" opacity="${xr ? 0.3 : 0.9}" transform="translate(0,-22)"/>`;
      for (let k = 0; k < n; k += 1) {
        const x = k * 1920;
        svg += `<use href="#spark" x="${x + 150}" y="${k % 2 ? 720 : 420}" width="64" height="64"/><use href="#spark" x="${x + 1720}" y="${k % 2 ? 380 : 690}" width="48" height="48"/>`
          + `<use href="#spark" x="${x + 1880}" y="${k % 2 ? 950 : 180}" width="36" height="36"/>`;
      }
      return `${svg}</svg>`;
    },
  };
}
FRAMES.desk = landscape(false);
FRAMES.xr = landscape(true);

const b = await openBrowser(9343);

async function render(html, name, W, H, dpr) {
  const file = path.join(b.work, `${name}.html`);
  fs.writeFileSync(file, html);
  await b.viewport(W, H, dpr);
  await b.load(pathToFileURL(file).href, 2500);
  const ok = await b.evaluate('document.fonts.ready.then(() => [...document.images].every((i) => i.complete && i.naturalWidth > 0))');
  if (!ok) throw new Error(`${name} : une image ne s'est pas chargée`);
  await sleep(300);
}

async function compose(name, device) {
  const frame = FRAMES[device.frame];
  const rawDir = path.join(RAW, device.raw);
  const shots = SHOTS.filter(([file]) => (!device.only || device.only.includes(file))
    && fs.existsSync(path.join(rawDir, `${file}.png`)));
  if (!shots.length) throw new Error(`${name} : aucune capture brute dans ${rawDir} (lancer store_shots_test.dart)`);
  const [PW, PH] = device.panel;
  const W = PW * shots.length;
  const panels = shots.map(([file, t], i) => `<div class="panel" style="left:${i * PW}px">${
    frame.panel(pathToFileURL(path.join(rawDir, `${file}.png`)).href, t, frame.tilt[i % frame.tilt.length])}</div>`).join('');
  await render(`<!doctype html><html><head><meta charset="utf-8">${FONTS}<style>
html,body{margin:0;width:${W}px;height:${PH}px;overflow:hidden}
body{position:relative;font-family:'Plus Jakarta Sans',sans-serif}
svg.art{position:absolute;inset:0}
.panel{position:absolute;top:0;width:${PW}px;height:${PH}px}
.shot{display:block;width:100%}
${frame.css}</style></head><body>${frame.art(W, shots.length)}${panels}</body></html>`, name, W, PH, device.dpr);

  const dir = path.join(OUT, name);
  fs.mkdirSync(dir, { recursive: true });
  for (const f of fs.readdirSync(dir)) if (f.endsWith('.png')) fs.rmSync(path.join(dir, f));
  for (const [i] of shots.entries()) {
    const out = path.join(dir, `${name}-capture-${i + 1}.png`);
    await b.shoot(out, { clip: { x: i * PW, y: 0, width: PW, height: PH } });
    console.log(`  → ${path.relative(ROOT, out)}  (${shots[i][0]})`);
  }
}

async function brandAssets() {
  const icon = pathToFileURL(path.join(ROOT, 'assets', 'icon', 'icon_blue.png')).href;
  // Icon: the launcher icon (full-bleed square; Play rounds the corners itself).
  // Play wants a 32-bit PNG: a transparent page background gives the alpha channel.
  await b.send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
  await render(`<!doctype html><html><body style="margin:0;background:transparent"><img src="${icon}" style="display:block;width:512px;height:512px"></body></html>`, 'icon', 512, 512, 1);
  const iconOut = path.join(OUT, 'icone-512.png');
  await b.shoot(iconOut);
  await b.send('Emulation.setDefaultBackgroundColorOverride', {});
  // Chrome writes an opaque image as 24-bit RGB: re-save it as 32-bit ARGB.
  if (process.platform === 'win32') {
    const ps = `Add-Type -AssemblyName System.Drawing; $s=[System.Drawing.Image]::FromFile('${iconOut}');`
      + '$b=New-Object System.Drawing.Bitmap($s.Width,$s.Height,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb);'
      + '$g=[System.Drawing.Graphics]::FromImage($b);$g.DrawImage($s,0,0,$s.Width,$s.Height);$g.Dispose();$s.Dispose();'
      + `$b.Save('${iconOut}',[System.Drawing.Imaging.ImageFormat]::Png);$b.Dispose()`;
    const r = spawnSync('powershell', ['-NoProfile', '-Command', ps], { stdio: 'inherit' });
    if (r.status !== 0) throw new Error('Conversion de l\'icône en PNG 32 bits impossible');
  }
  console.log(`  → ${path.relative(ROOT, path.join(OUT, 'icone-512.png'))}`);

  // Feature graphic: blue banner, logo, name, slogan and the home screen.
  const home = path.join(RAW, 'mobile', '8-dossier.png');
  const degany = path.join(RAW, 'mobile', '3-degany.png');
  const phone = (src, cls) => `<div class="ph ${cls}"><div class="sc"><img src="${pathToFileURL(src).href}"></div></div>`;
  await render(`<!doctype html><html><head><meta charset="utf-8">${FONTS}<style>
html,body{margin:0;width:1024px;height:500px;overflow:hidden}
body{position:relative;background:radial-gradient(ellipse 700px 500px at 85% 30%,#3a6fd0 0%,rgba(58,111,208,0) 70%),linear-gradient(120deg,${DEEP} 0%,${BLUE} 55%,#2c5fbf 100%);font-family:'Plus Jakarta Sans',sans-serif;color:#fff}
.ring{position:absolute;border-radius:50%;border:2px solid rgba(255,255,255,.12)}
.logo{position:absolute;left:64px;top:62px;display:flex;align-items:center;gap:16px}
.logo img{width:60px;height:60px;border-radius:16px;box-shadow:0 10px 24px rgba(0,0,0,.25),0 0 0 2px rgba(255,255,255,.25)}
.logo b{font-weight:800;font-size:38px;letter-spacing:-.5px}
h1{position:absolute;left:64px;top:162px;width:520px;margin:0;font-weight:800;font-size:46px;line-height:1.12;letter-spacing:-1px}
h1 em{font-style:normal;color:#ffd2b5}
p{position:absolute;left:64px;top:300px;width:470px;margin:0;font-weight:500;font-size:19px;line-height:1.45;color:rgba(255,255,255,.82)}
.ph{position:absolute;width:230px;height:480px;border-radius:36px;background:#141a2a;box-shadow:0 30px 60px rgba(0,0,0,.4),inset 0 0 0 2px rgba(255,255,255,.18)}
.ph .sc{position:absolute;inset:8px;border-radius:29px;overflow:hidden;background:#fff}.ph img{width:100%;display:block;margin-top:14px}
.a{left:612px;top:70px;transform:rotate(-6deg)}.b{left:790px;top:40px;transform:rotate(5deg)}
.dot{position:absolute;width:12px;height:12px;border-radius:50%;background:${ORANGE};box-shadow:0 0 0 6px rgba(242,107,29,.2)}
</style></head><body>
<div class="ring" style="width:520px;height:520px;left:600px;top:-140px"></div><div class="ring" style="width:760px;height:760px;left:480px;top:-260px"></div>
<div class="logo"><img src="${icon}"><b>Influencor</b></div>
<h1>Tout votre contenu prêt à publier, <em>prêt à vendre.</em></h1>
<p>Notes, photos et vidéos rangées, avec Degany, l'assistant IA qui retrouve tout pour vous.</p>
${phone(home, 'a')}${fs.existsSync(degany) ? phone(degany, 'b') : ''}
<span class="dot" style="left:584px;top:420px"></span>
</body></html>`, 'banner', 1024, 500, 1);
  await b.shoot(path.join(OUT, 'presentation-1024x500.png'));
  console.log(`  → ${path.relative(ROOT, path.join(OUT, 'presentation-1024x500.png'))}`);
}

try {
  for (const name of devices) {
    console.log(name);
    await compose(name, DEVICES[name]);
  }
  if (brand) await brandAssets();
} finally {
  b.close();
}
