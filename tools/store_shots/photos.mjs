/**
 * Demo "photos" for the store screenshots, drawn as SVG scenes (no stock
 * images, nothing downloaded). Exported as JPEG by play_store_shots.mjs.
 */
const W = 1080;
const H = 1080;

const grain = `<filter id="grain"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" stitchTiles="stitch"/>
<feColorMatrix values="0 0 0 0 .5  0 0 0 0 .5  0 0 0 0 .5  0 0 0 .07 0"/><feComposite in2="SourceGraphic" operator="in"/></filter>
<filter id="soft"><feGaussianBlur stdDeviation="18"/></filter><filter id="blur6"><feGaussianBlur stdDeviation="6"/></filter>`;
const svg = (body, defs = '') => `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}"><defs>${grain}${defs}</defs>${body}<rect width="${W}" height="${H}" filter="url(#grain)" opacity=".9"/></svg>`;

const baobab = (x, y, s, fill) => `<g transform="translate(${x} ${y}) scale(${s})" fill="${fill}">
<path d="M-38 0 C-34 -120 -30 -260 -26 -330 L26 -330 C30 -260 34 -120 38 0 Z"/>
<path d="M-26 -330 C-60 -360 -95 -370 -120 -400 L-112 -408 C-80 -385 -50 -375 -18 -352 Z"/>
<path d="M26 -330 C60 -362 92 -372 118 -404 L126 -396 C100 -366 66 -350 18 -350 Z"/>
<path d="M-8 -330 C-14 -370 -30 -400 -40 -430 L-30 -434 C-16 -404 -2 -376 6 -340 Z"/>
<path d="M8 -334 C22 -372 40 -398 58 -424 L66 -418 C50 -390 34 -366 20 -334 Z"/>
<ellipse cx="-120" cy="-410" rx="48" ry="16"/><ellipse cx="122" cy="-406" rx="52" ry="16"/>
<ellipse cx="-38" cy="-438" rx="40" ry="14"/><ellipse cx="64" cy="-428" rx="44" ry="14"/><ellipse cx="4" cy="-360" rx="70" ry="22"/></g>`;

const palm = (x, y, s, flip = 1) => `<g transform="translate(${x} ${y}) scale(${s * flip} ${s})" fill="#1c1018">
<path d="M0 0 C10 -120 30 -250 70 -360 L82 -354 C46 -250 26 -120 16 0 Z"/>
<path d="M74 -360 C10 -380 -60 -360 -110 -300 C-50 -340 10 -350 70 -345 Z"/>
<path d="M74 -360 C140 -400 210 -390 250 -330 C190 -360 130 -365 78 -350 Z"/>
<path d="M74 -362 C40 -430 -20 -460 -80 -450 C-20 -430 30 -400 70 -352 Z"/>
<path d="M76 -362 C120 -440 180 -460 230 -440 C170 -430 120 -400 82 -350 Z"/>
<path d="M76 -360 C60 -300 20 -250 -30 -220 C20 -270 50 -310 70 -352 Z"/>
<path d="M78 -358 C120 -300 170 -270 220 -260 C170 -290 120 -320 84 -352 Z"/></g>`;

export const PHOTOS = {
  'sunset.jpg': svg(`<rect width="1080" height="1080" fill="url(#sky)"/>
<circle cx="560" cy="610" r="150" fill="#ffe7a8" opacity=".95"/><circle cx="560" cy="610" r="260" fill="#ffd27a" opacity=".25" filter="url(#soft)"/>
<rect y="640" width="1080" height="440" fill="url(#sea)"/>
${[0, 1, 2, 3, 4, 5, 6, 7].map((i) => `<rect x="${460 - i * 14}" y="${660 + i * 34}" width="${200 + i * 28}" height="6" rx="3" fill="#ffe1a0" opacity="${0.7 - i * 0.07}"/>`).join('')}
<path d="M0 930 C300 880 700 900 1080 860 L1080 1080 L0 1080 Z" fill="#2a1626"/>
${palm(130, 960, 1.2)}${palm(980, 930, 1, -1)}`,
  `<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3b2a6b"/><stop offset=".35" stop-color="#c2477a"/><stop offset=".62" stop-color="#ff9a5a"/><stop offset=".7" stop-color="#ffc27a"/></linearGradient>
<linearGradient id="sea" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#b8527a"/><stop offset="1" stop-color="#3a2050"/></linearGradient>`),

  'baobab.jpg': svg(`<rect width="1080" height="1080" fill="url(#sky)"/>
<circle cx="760" cy="700" r="90" fill="#ffe3a0"/><circle cx="760" cy="700" r="240" fill="#ffb86b" opacity=".35" filter="url(#soft)"/>
<path d="M0 800 L1080 780 L1080 1080 L0 1080 Z" fill="#3a1a12"/>
<path d="M440 1080 C500 950 560 860 600 790 L640 790 C640 860 700 950 820 1080 Z" fill="#6b3420" opacity=".7"/>
${baobab(180, 830, 1.15, '#24100c')}${baobab(400, 812, 0.9, '#2c140e')}${baobab(860, 820, 1.25, '#1e0d09')}${baobab(1030, 800, 0.7, '#2c140e')}`,
  `<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#26355e"/><stop offset=".45" stop-color="#a6507a"/><stop offset=".72" stop-color="#f08a4b"/><stop offset=".78" stop-color="#f7b265"/></linearGradient>`),

  'lagoon.jpg': svg(`<rect width="1080" height="1080" fill="url(#sea)"/>
<path d="M0 0 L1080 0 L1080 300 C800 360 400 260 0 330 Z" fill="url(#sky)"/>
<path d="M0 330 C300 300 600 340 1080 300 L1080 340 C700 380 300 340 0 370 Z" fill="#2d7f6a"/>
${[0, 1, 2, 3, 4, 5].map((i) => `<path d="M${-50 + i * 30} ${520 + i * 90} C ${300} ${490 + i * 90}, ${700} ${560 + i * 90}, 1130 ${510 + i * 90}" fill="none" stroke="#fff" stroke-opacity=".18" stroke-width="5"/>`).join('')}
<path d="M0 860 C300 800 700 840 1080 780 L1080 1080 L0 1080 Z" fill="url(#sand)"/>
<g transform="translate(620 560) rotate(-8)"><path d="M-150 0 L150 0 C130 40 90 60 0 60 C-90 60 -130 40 -150 0 Z" fill="#c8452f"/>
<rect x="-150" y="-8" width="300" height="12" rx="6" fill="#f4e0c0"/><path d="M-10 -8 L-10 -230 L120 -30 Z" fill="#fff8ec"/><rect x="-14" y="-240" width="6" height="236" fill="#5b3a26"/></g>
<ellipse cx="620" cy="640" rx="190" ry="20" fill="#0d5f73" opacity=".35" filter="url(#blur6)"/>`,
  `<linearGradient id="sea" x1="0" y1="0" x2="0" y2="1"><stop offset=".3" stop-color="#1aa3b8"/><stop offset=".7" stop-color="#3fd0c9"/><stop offset="1" stop-color="#9eeadb"/></linearGradient>
<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4fa7e8"/><stop offset="1" stop-color="#bfe6fb"/></linearGradient>
<linearGradient id="sand" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f6e3bf"/><stop offset="1" stop-color="#e8c891"/></linearGradient>`),

  'food.jpg': svg(`<rect width="1080" height="1080" fill="url(#wood)"/>
${[0, 1, 2, 3, 4, 5, 6].map((i) => `<rect y="${i * 160}" width="1080" height="4" fill="#5a3620" opacity=".35"/>`).join('')}
<ellipse cx="560" cy="580" rx="400" ry="400" fill="#000" opacity=".25" filter="url(#soft)"/>
<circle cx="540" cy="540" r="390" fill="#f6f1ea"/><circle cx="540" cy="540" r="300" fill="#ece4d8"/>
<circle cx="540" cy="540" r="285" fill="url(#broth)"/>
${[[420, 430, 70], [620, 460, 80], [520, 640, 75], [680, 620, 60], [400, 600, 55]].map(([x, y, r]) => `<ellipse cx="${x}" cy="${y}" rx="${r}" ry="${r * 0.7}" fill="#7a3d22" transform="rotate(20 ${x} ${y})"/><ellipse cx="${x - 10}" cy="${y - 12}" rx="${r * 0.6}" ry="${r * 0.3}" fill="#a35a33" opacity=".7" transform="rotate(20 ${x} ${y})"/>`).join('')}
${Array.from({ length: 22 }, (_, i) => { const a = i * 1.7; const x = 540 + Math.cos(a) * (90 + (i * 37) % 170); const y = 540 + Math.sin(a) * (90 + (i * 53) % 170); return `<path d="M${x} ${y} q 30 -40 70 -10 q -30 40 -70 10 Z" fill="${i % 2 ? '#3f8a2e' : '#5fae3a'}" transform="rotate(${i * 33} ${x} ${y})"/>`; }).join('')}
<g transform="translate(900 260) rotate(30)"><rect x="-14" y="-200" width="28" height="400" rx="14" fill="#c9a57a"/><ellipse cx="0" cy="-220" rx="50" ry="70" fill="#c9a57a"/></g>
<circle cx="150" cy="900" r="110" fill="#f6f1ea"/><circle cx="150" cy="900" r="85" fill="#fbfaf6"/>
${Array.from({ length: 40 }, (_, i) => `<ellipse cx="${100 + (i * 23) % 100}" cy="${860 + (i * 17) % 80}" rx="9" ry="4" fill="#fff" stroke="#e7dfd0" transform="rotate(${i * 40} 150 900)"/>`).join('')}`,
  `<linearGradient id="wood" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#8b5a36"/><stop offset="1" stop-color="#6b4127"/></linearGradient>
<radialGradient id="broth"><stop offset="0" stop-color="#c98a3a"/><stop offset="1" stop-color="#9c5e20"/></radialGradient>`),

  'pastry.jpg': svg(`<rect width="1080" height="1080" fill="url(#bg)"/>
<ellipse cx="560" cy="600" rx="420" ry="400" fill="#000" opacity=".2" filter="url(#soft)"/>
<circle cx="540" cy="560" r="400" fill="#3f6e8c"/><circle cx="540" cy="560" r="370" fill="#4e82a3"/>
${[[400, 420], [600, 400], [720, 560], [620, 720], [420, 720], [330, 570], [530, 570]].map(([x, y]) => `<circle cx="${x + 6}" cy="${y + 10}" r="96" fill="#000" opacity=".25" filter="url(#blur6)"/><circle cx="${x}" cy="${y}" r="92" fill="url(#cake)"/><circle cx="${x}" cy="${y}" r="58" fill="#f2c46c" opacity=".55"/><path d="M${x - 40} ${y - 50} q 40 -20 80 0" stroke="#fff3cf" stroke-width="10" fill="none" stroke-linecap="round" opacity=".6"/>`).join('')}
<g transform="translate(170 180)"><circle r="110" fill="#fbf7ee"/><circle r="84" fill="#5a2f1a"/><ellipse cx="-20" cy="-25" rx="30" ry="12" fill="#c08a5a" opacity=".6"/></g>`,
  `<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f3d9b5"/><stop offset="1" stop-color="#e5bf8c"/></linearGradient>
<radialGradient id="cake" cx=".4" cy=".35"><stop offset="0" stop-color="#f7cf7a"/><stop offset=".7" stop-color="#d98d34"/><stop offset="1" stop-color="#a65a1c"/></radialGradient>`),

  'product.jpg': svg(`<rect width="1080" height="1080" fill="url(#bg)"/>
<circle cx="760" cy="300" r="220" fill="#fff" opacity=".45" filter="url(#soft)"/>
<rect x="0" y="760" width="1080" height="320" fill="#e9c9b7"/>
<ellipse cx="540" cy="790" rx="260" ry="40" fill="#8a5a48" opacity=".35" filter="url(#blur6)"/>
<rect x="400" y="330" width="280" height="460" rx="60" fill="url(#bottle)"/>
<rect x="470" y="250" width="140" height="100" rx="20" fill="#3a2a24"/><rect x="455" y="330" width="170" height="24" rx="10" fill="#2c1f1a"/>
<rect x="430" y="470" width="220" height="190" rx="18" fill="#fbf3ea"/>
<text x="540" y="560" font-family="Georgia,serif" font-size="44" text-anchor="middle" fill="#7a4a35" font-style="italic">Vanille</text>
<text x="540" y="610" font-family="Arial" font-size="22" letter-spacing="6" text-anchor="middle" fill="#a77b62">SAVON · MADA</text>
<rect x="420" y="350" width="30" height="400" rx="15" fill="#fff" opacity=".35"/>
<g transform="translate(250 780) rotate(-20)"><path d="M0 0 C40 -80 120 -150 220 -170 C170 -110 100 -50 0 0 Z" fill="#5e8a4a"/></g>
<g transform="translate(780 790)"><rect x="-90" y="-80" width="200" height="90" rx="22" fill="#f4e3c9"/><rect x="-90" y="-80" width="200" height="30" rx="15" fill="#fff" opacity=".35"/></g>
<g transform="translate(860 700) rotate(70)"><rect x="-6" y="-120" width="12" height="240" rx="6" fill="#3c2416"/></g>`,
  `<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f7d9cf"/><stop offset="1" stop-color="#eab9aa"/></linearGradient>
<linearGradient id="bottle" x1="0" x2="1"><stop offset="0" stop-color="#c98d5f"/><stop offset=".5" stop-color="#e5b083"/><stop offset="1" stop-color="#b3764a"/></linearGradient>`),

  'coffee.jpg': svg(`<rect width="1080" height="1080" fill="url(#bg)"/>
<ellipse cx="560" cy="580" rx="300" ry="300" fill="#000" opacity=".25" filter="url(#soft)"/>
<circle cx="540" cy="540" r="300" fill="#f7f3ee"/><circle cx="540" cy="540" r="210" fill="#efe7dd"/>
<circle cx="540" cy="540" r="190" fill="#fbfaf7"/><circle cx="540" cy="540" r="160" fill="url(#cof)"/>
<path d="M540 470 C500 500 490 560 540 610 C590 560 580 500 540 470 Z" fill="#f1dcc0" opacity=".9"/>
<path d="M540 490 L540 600" stroke="#c49a6c" stroke-width="5"/>
<rect x="720" y="510" width="150" height="60" rx="30" fill="#f7f3ee"/>
<g transform="translate(210 830) rotate(-25)"><rect x="-120" y="-70" width="240" height="140" rx="20" fill="#e7c08b"/><rect x="-120" y="-70" width="240" height="140" rx="20" fill="none" stroke="#c5945a" stroke-width="6"/></g>
${[[850, 220], [900, 300], [820, 320], [930, 200]].map(([x, y]) => `<ellipse cx="${x}" cy="${y}" rx="18" ry="26" fill="#4a2b1a" transform="rotate(30 ${x} ${y})"/><path d="M${x} ${y - 20} q -6 20 0 40" stroke="#2a170d" stroke-width="3" fill="none" transform="rotate(30 ${x} ${y})"/>`).join('')}
<path d="M120 160 C180 120 240 150 260 200 C200 220 150 210 120 160 Z" fill="#6f9a52"/>`,
  `<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#d9c7b3"/><stop offset="1" stop-color="#c7b097"/></linearGradient>
<radialGradient id="cof" cx=".45" cy=".4"><stop offset="0" stop-color="#b9783e"/><stop offset="1" stop-color="#6b3a17"/></radialGradient>`),

  'fashion.jpg': svg(`<rect width="1080" height="1080" fill="#f2e6da"/>
${Array.from({ length: 18 }, (_, i) => `<rect x="${i * 64 - 20}" y="-50" width="${i % 3 ? 40 : 22}" height="1200" fill="${['#c8452f', '#e9a23b', '#2e6f8e', '#f2e6da', '#7a2f4a', '#e9a23b'][i % 6]}" transform="rotate(12 540 540)"/>`).join('')}
<rect width="1080" height="1080" fill="url(#light)"/>
<path d="M0 760 C200 700 400 820 620 760 C820 700 960 760 1080 720 L1080 1080 L0 1080 Z" fill="#f6efe6" opacity=".9"/>
<g transform="translate(720 820)"><circle r="120" fill="#e8c77d"/><circle r="70" fill="#d9b062"/><path d="M-120 0 C-120 -30 120 -30 120 0" fill="none" stroke="#7a2f4a" stroke-width="16"/></g>
<g transform="translate(330 860)"><circle cx="-70" r="56" fill="#2a2a2a"/><circle cx="70" r="56" fill="#2a2a2a"/><rect x="-16" y="-8" width="32" height="10" fill="#2a2a2a"/><circle cx="-80" cy="-14" r="16" fill="#fff" opacity=".3"/><circle cx="60" cy="-14" r="16" fill="#fff" opacity=".3"/></g>`,
  `<radialGradient id="light" cx=".3" cy=".25"><stop offset="0" stop-color="#fff" stop-opacity=".35"/><stop offset="1" stop-color="#000" stop-opacity=".15"/></radialGradient>`),

  'look.jpg': svg(`<rect width="1080" height="1080" fill="url(#bg)"/>
<ellipse cx="560" cy="470" rx="330" ry="330" fill="#000" opacity=".12" filter="url(#soft)"/>
<circle cx="540" cy="440" r="320" fill="#d9b47a"/><circle cx="540" cy="440" r="190" fill="#c79d5e"/>
${Array.from({ length: 24 }, (_, i) => `<circle cx="540" cy="440" r="${200 + i * 5}" fill="none" stroke="#b88c4f" stroke-width="1.5" opacity=".5"/>`).join('')}
<path d="M350 440 C350 400 730 400 730 440 C730 480 350 480 350 440 Z" fill="#2e6f8e"/>
<g transform="translate(760 860) rotate(-12)"><rect x="-150" y="-70" width="300" height="160" rx="22" fill="#fff6ea"/><rect x="-150" y="-70" width="300" height="40" rx="18" fill="#c8452f"/></g>
<g transform="translate(250 850) rotate(18)"><path d="M-80 -60 L80 -60 L60 80 L-60 80 Z" fill="#7a2f4a"/><rect x="-30" y="-100" width="60" height="50" rx="12" fill="none" stroke="#7a2f4a" stroke-width="12"/></g>
<g transform="translate(860 200)"><circle cx="-60" r="48" fill="#222"/><circle cx="60" r="48" fill="#222"/><rect x="-14" y="-6" width="28" height="9" fill="#222"/></g>`,
  `<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#bfe0e0"/><stop offset="1" stop-color="#93c7c9"/></linearGradient>`),
};
