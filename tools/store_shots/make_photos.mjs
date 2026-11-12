/** Writes the demo photos to build/store_shots/photos/ (step 1 of the store shots). */
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { openBrowser } from './browser.mjs';
import { PHOTOS } from './photos.mjs';

const OUT = path.join(process.cwd(), 'build', 'store_shots', 'photos');
fs.mkdirSync(OUT, { recursive: true });
const b = await openBrowser();
try {
  await b.viewport(1080, 1080);
  for (const [name, svg] of Object.entries(PHOTOS)) {
    const html = path.join(b.work, `${name}.html`);
    fs.writeFileSync(html, `<!doctype html><html><body style="margin:0">${svg}</body></html>`);
    await b.load(pathToFileURL(html).href, 700);
    await b.shoot(path.join(OUT, name), { format: 'jpeg', quality: 90 });
    console.log(`  build/store_shots/photos/${name}`);
  }
} finally {
  b.close();
}
