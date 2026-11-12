/** Minimal headless Chrome/Edge driver over the DevTools protocol (no deps). */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function openBrowser(port = 9341) {
  const exe = [
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    '/usr/bin/google-chrome', '/usr/bin/chromium',
  ].find((p) => fs.existsSync(p));
  if (!exe) throw new Error('Edge/Chrome introuvable.');
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'influencor-store-'));
  const proc = spawn(exe, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${path.join(work, 'profile')}`,
    '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--allow-file-access-from-files', 'about:blank'], { stdio: 'ignore' });

  let ws;
  for (let i = 0; i < 40 && !ws; i += 1) {
    try {
      const page = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === 'page');
      if (page) {
        ws = new WebSocket(page.webSocketDebuggerUrl);
        await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
      }
    } catch { ws = undefined; }
    if (!ws) await sleep(500);
  }
  if (!ws) throw new Error('DevTools injoignable');

  let seq = 0;
  const pending = new Map();
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
  };
  const send = (method, params = {}) => new Promise((res, rej) => {
    const id = ++seq;
    pending.set(id, (d) => (d.error ? rej(new Error(`${method}: ${d.error.message}`)) : res(d.result)));
    ws.send(JSON.stringify({ id, method, params }));
  });
  await send('Page.enable');

  return {
    work,
    send,
    async evaluate(expression) {
      const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
      if (r.exceptionDetails) throw new Error(`eval: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
      return r.result.value;
    },
    async viewport(width, height, dpr = 1) {
      await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: dpr, mobile: false });
    },
    async load(url, wait = 1500) {
      await send('Page.navigate', { url });
      await sleep(wait);
    },
    async shoot(file, { clip, format = 'png', quality } = {}) {
      const r = await send('Page.captureScreenshot', {
        format, ...(quality ? { quality } : {}), ...(clip ? { clip: { ...clip, scale: 1 } } : {}),
      });
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, Buffer.from(r.data, 'base64'));
    },
    close() { ws.close(); proc.kill(); },
  };
}
