// Scores generated pages: loads each in headless Chromium with AssetForge's bridge, records script errors,
// clicks Export GLB, captures the GLB, screenshots the page and measures the mesh.
//
// usage: node score.mjs <run dir> [--concurrency 4]
// writes <run dir>/scores.jsonl, <name>.glb, <name>.png and prints a summary.
import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import { parseGLB, analyze } from './analyze.mjs';

const dir = process.argv[2];
const conc = +(process.argv[process.argv.indexOf('--concurrency') + 1] || 4) || 4;
// The app's bridge script (error capture + GLB download interception); override with SIRPI_BRIDGE.
const bridge = fs.readFileSync(process.env.SIRPI_BRIDGE || new URL('../../Resources/web/bridge.js', import.meta.url), 'utf8');
const gen = Object.fromEntries(
  fs.readFileSync(path.join(dir, 'gen.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l)).map((r) => [r.name, r]));
const names = Object.keys(gen).sort();

const browser = await chromium.launch({
  channel: 'chrome', headless: true,
  args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--use-angle=swiftshader', '--enable-webgl'],
});

async function scoreOne(name) {
  const g = gen[name];
  const base = { name, id: g.id, mode: g.mode, prompt: g.prompt, tokens: g.tokens };
  const htmlPath = path.join(dir, name + '.html');
  if (!fs.existsSync(htmlPath)) return { ...base, html: false, loads: false, exported: false, errors: ['no html in output'] };
  const ctx = await browser.newContext({ viewport: { width: 640, height: 480 }, acceptDownloads: false });
  const page = await ctx.newPage();
  const errors = [];
  let glb = null;
  await page.exposeFunction('__forgePost', (m) => {
    if (m.type === 'error' && errors.length < 10 && !errors.includes(m.message)) errors.push(m.message);
    if (m.type === 'download' && !glb) glb = Buffer.from(m.data, 'base64');
  });
  await page.addInitScript(`window.webkit = { messageHandlers: { forge: { postMessage: (m) => window.__forgePost(m) } } };\n${bridge}`);
  page.on('pageerror', (e) => { if (errors.length < 10) errors.push(String(e.message || e)); });
  let loads = true;
  try {
    await page.goto('file://' + path.resolve(htmlPath), { waitUntil: 'load', timeout: 30000 });
    await page.waitForTimeout(2500);
  } catch (e) { loads = false; errors.push('load: ' + e.message.split('\n')[0]); }
  let clicked = false;
  if (loads) {
    clicked = await page.evaluate(() => (window.__forgeExport ? window.__forgeExport() : false)).catch(() => false);
    for (let i = 0; i < 40 && clicked && !glb; i++) await page.waitForTimeout(200);
    await page.screenshot({ path: path.join(dir, name + '.png') }).catch(() => {});
  }
  await ctx.close();
  const r = { ...base, html: true, loads, errors, exportButton: clicked, exported: !!glb };
  if (glb) {
    fs.writeFileSync(path.join(dir, name + '.glb'), glb);
    try {
      const gltf = await parseGLB(glb);
      Object.assign(r, analyze(gltf, g.mode, g.prompt));
      r.glbValid = r.triangles > 0;
    } catch (e) { r.glbValid = false; r.errors.push('glb parse: ' + e.message); }
  }
  r.ok = r.loads && r.errors.length === 0 && r.exported && !!r.glbValid;
  return r;
}

const results = [];
let next = 0;
await Promise.all(Array.from({ length: conc }, async () => {
  while (next < names.length) {
    const n = names[next++];
    const r = await scoreOne(n).catch((e) => ({ name: n, ok: false, errors: ['scorer: ' + e.message] }));
    results.push(r);
    process.stdout.write(`${r.ok ? '✓' : '✗'} ${n} ${r.mode ?? ''} ${r.triangles ?? ''}${r.printScore != null ? ' print=' + r.printScore : ''}${r.errors?.length ? ' · ' + r.errors[0].slice(0, 90) : ''}\n`);
  }
}));
await browser.close();
results.sort((a, b) => a.name.localeCompare(b.name));
fs.writeFileSync(path.join(dir, 'scores.jsonl'), results.map((r) => JSON.stringify(r)).join('\n') + '\n');

const summary = (rows) => {
  const n = rows.length || 1, f = (k) => rows.filter((r) => r[k]).length;
  const avg = (k) => { const v = rows.map((r) => r[k]).filter((x) => typeof x === 'number'); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null; };
  return {
    n: rows.length, ok: `${f('ok')}/${rows.length}`, noErrors: `${rows.filter((r) => r.loads && !r.errors?.length).length}/${rows.length}`,
    exported: `${f('exported')}/${rows.length}`, avgTriangles: Math.round(avg('triangles') ?? 0), avgMeshes: +(avg('meshes') ?? 0).toFixed(1),
    avgTokens: Math.round(avg('tokens') ?? 0), printScore: avg('printScore') != null ? +avg('printScore').toFixed(1) : undefined,
  };
};
const out = { all: summary(results), game: summary(results.filter((r) => r.mode === 'game')), print: summary(results.filter((r) => r.mode === 'print')) };
fs.writeFileSync(path.join(dir, 'summary.json'), JSON.stringify(out, null, 2));
console.log(JSON.stringify(out, null, 2));
