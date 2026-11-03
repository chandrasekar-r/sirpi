// Mesh repair + colour grouping for 3D printing. Pure JS (no three.js), usable in the browser and in Node.
//
// Part input:  { name, positions: Float32Array (local xyz), index: Uint32Array|null,
//                matrix: number[16] (column-major, local -> printer mm, Z-up), color: [r,g,b] 0..1 }
// Pipeline per part (local space): weld -> solidify flat sheets / thicken thin axes -> cap open boundary loops
// Then (printer space): Manifold per part -> union per colour group -> smaller groups carve bigger ones.

// ---------- small linear algebra ----------
const colLen = (m, c) => Math.hypot(m[c * 4], m[c * 4 + 1], m[c * 4 + 2]);
const det3 = (m) =>
  m[0] * (m[5] * m[10] - m[9] * m[6]) - m[4] * (m[1] * m[10] - m[9] * m[2]) + m[8] * (m[1] * m[6] - m[5] * m[2]);
function xform(m, p, out, o) {
  const x = p[0], y = p[1], z = p[2];
  out[o] = m[0] * x + m[4] * y + m[8] * z + m[12];
  out[o + 1] = m[1] * x + m[5] * y + m[9] * z + m[13];
  out[o + 2] = m[2] * x + m[6] * y + m[10] * z + m[14];
}

// ---------- welding ----------
export function weld(positions, index, eps = 1e-5) {
  const n = positions.length / 3;
  let minX = Infinity, minY = Infinity, minZ = Infinity, maxX = -Infinity, maxY = -Infinity, maxZ = -Infinity;
  for (let i = 0; i < n; i++) {
    const x = positions[i * 3], y = positions[i * 3 + 1], z = positions[i * 3 + 2];
    if (x < minX) minX = x; if (y < minY) minY = y; if (z < minZ) minZ = z;
    if (x > maxX) maxX = x; if (y > maxY) maxY = y; if (z > maxZ) maxZ = z;
  }
  const scale = Math.max(maxX - minX, maxY - minY, maxZ - minZ, 1e-9);
  const q = 1 / (scale * eps);
  const map = new Map(), remap = new Uint32Array(n), verts = [];
  for (let i = 0; i < n; i++) {
    const x = positions[i * 3], y = positions[i * 3 + 1], z = positions[i * 3 + 2];
    const key = `${Math.round(x * q)},${Math.round(y * q)},${Math.round(z * q)}`;
    let id = map.get(key);
    if (id === undefined) { id = verts.length / 3; map.set(key, id); verts.push(x, y, z); }
    remap[i] = id;
  }
  const triCount = index ? index.length / 3 : n / 3;
  const tris = [];
  for (let t = 0; t < triCount; t++) {
    const a = remap[index ? index[t * 3] : t * 3], b = remap[index ? index[t * 3 + 1] : t * 3 + 1], c = remap[index ? index[t * 3 + 2] : t * 3 + 2];
    if (a !== b && b !== c && a !== c) tris.push(a, b, c);
  }
  return { verts: new Float32Array(verts), tris: new Uint32Array(tris),
           bbox: [minX, minY, minZ, maxX, maxY, maxZ] };
}

// ---------- boundary analysis ----------
function boundaryEdges(tris) {
  const count = new Map();
  for (let t = 0; t < tris.length; t += 3) {
    for (let e = 0; e < 3; e++) {
      const a = tris[t + e], b = tris[t + (e + 1) % 3];
      const k = a < b ? `${a},${b}` : `${b},${a}`;
      count.set(k, (count.get(k) || 0) + 1);
    }
  }
  const out = []; // directed edges as they appear in their single triangle
  for (let t = 0; t < tris.length; t += 3) {
    for (let e = 0; e < 3; e++) {
      const a = tris[t + e], b = tris[t + (e + 1) % 3];
      if (count.get(a < b ? `${a},${b}` : `${b},${a}`) === 1) out.push([a, b, t / 3]);
    }
  }
  let nonManifoldEdges = 0;
  for (const v of count.values()) if (v > 2) nonManifoldEdges++;
  return { edges: out, nonManifoldEdges };
}

/** Close open boundary loops with centroid fans (open cylinders, tubes, lathes). */
export function capLoops(mesh) {
  const { edges } = boundaryEdges(mesh.tris);
  if (!edges.length) return { mesh, capped: 0 };
  const next = new Map();
  for (const [a, b] of edges) { if (next.has(a)) return { mesh, capped: -1 }; next.set(a, b); }
  const verts = Array.from(mesh.verts), tris = Array.from(mesh.tris), seen = new Set();
  let loops = 0;
  for (const [start] of edges) {
    if (seen.has(start)) continue;
    const loop = []; let v = start, guard = 0;
    while (!seen.has(v)) {
      seen.add(v); loop.push(v);
      v = next.get(v);
      if (v === undefined || ++guard > 1e6) return { mesh, capped: -1 };
    }
    if (v !== start || loop.length < 3) return { mesh, capped: -1 };
    let cx = 0, cy = 0, cz = 0;
    for (const i of loop) { cx += verts[i * 3]; cy += verts[i * 3 + 1]; cz += verts[i * 3 + 2]; }
    const c = verts.length / 3;
    verts.push(cx / loop.length, cy / loop.length, cz / loop.length);
    for (let i = 0; i < loop.length; i++) {
      const a = loop[i], b = loop[(i + 1) % loop.length];
      tris.push(b, a, c); // reverse of the boundary direction keeps orientation consistent
    }
    loops++;
  }
  return { mesh: { verts: new Float32Array(verts), tris: new Uint32Array(tris), bbox: mesh.bbox }, capped: loops };
}

/** Turn a zero-thickness sheet into a slab of thickness `t` along local `axis` (0,1,2). */
export function solidify(mesh, axis, t) {
  const nv = mesh.verts.length / 3, verts = new Float32Array(nv * 6);
  for (let i = 0; i < nv; i++) {
    for (let k = 0; k < 3; k++) {
      const v = mesh.verts[i * 3 + k] + (k === axis ? t / 2 : 0), w = mesh.verts[i * 3 + k] - (k === axis ? t / 2 : 0);
      verts[i * 3 + k] = v; verts[(i + nv) * 3 + k] = w;
    }
  }
  // orient every triangle so its normal points +axis on the top sheet
  const src = mesh.tris, oriented = new Uint32Array(src.length);
  const P = (i, k) => mesh.verts[i * 3 + k];
  const u = (axis + 1) % 3, w = (axis + 2) % 3;
  for (let t3 = 0; t3 < src.length; t3 += 3) {
    const a = src[t3], b = src[t3 + 1], c = src[t3 + 2];
    const n = (P(b, u) - P(a, u)) * (P(c, w) - P(a, w)) - (P(b, w) - P(a, w)) * (P(c, u) - P(a, u));
    if (n >= 0) { oriented[t3] = a; oriented[t3 + 1] = b; oriented[t3 + 2] = c; }
    else { oriented[t3] = a; oriented[t3 + 1] = c; oriented[t3 + 2] = b; }
  }
  const tris = [];
  for (let t3 = 0; t3 < oriented.length; t3 += 3) {
    const a = oriented[t3], b = oriented[t3 + 1], c = oriented[t3 + 2];
    tris.push(a, b, c, a + nv, c + nv, b + nv);
  }
  for (const [a, b] of boundaryEdges(oriented).edges) {
    tris.push(a, a + nv, b + nv, a, b + nv, b);
  }
  return { verts, tris: new Uint32Array(tris), bbox: mesh.bbox };
}

/** Scale along local axes thinner than `minT` mm (mm per local unit taken from the matrix). */
export function thicken(mesh, matrix, minT, maxFactor = 25) {
  const [x0, y0, z0, x1, y1, z1] = mesh.bbox;
  const ext = [x1 - x0, y1 - y0, z1 - z0], ctr = [(x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2];
  const f = [1, 1, 1];
  let changed = false;
  for (let a = 0; a < 3; a++) {
    const mm = ext[a] * colLen(matrix, a);
    if (mm > 1e-6 && mm < minT) { f[a] = Math.min(maxFactor, minT / mm); changed = true; }
  }
  if (!changed) return { mesh, factors: f, changed };
  const v = new Float32Array(mesh.verts.length);
  for (let i = 0; i < v.length; i += 3) for (let a = 0; a < 3; a++) v[i + a] = ctr[a] + (mesh.verts[i + a] - ctr[a]) * f[a];
  return { mesh: { verts: v, tris: mesh.tris, bbox: mesh.bbox }, factors: f, changed };
}

/** Full local-space preparation for one part. Returns a mesh plus what was done to it. */
export function preparePart(part, { repair = true, minThickness = 1.2 } = {}) {
  let mesh = weld(part.positions, part.index);
  const info = { flat: false, solidified: false, thickened: false, capped: 0, open: false };
  if (!repair) return { mesh, info };
  const [x0, y0, z0, x1, y1, z1] = mesh.bbox;
  const extMM = [0, 1, 2].map((a) => [x1 - x0, y1 - y0, z1 - z0][a] * colLen(part.matrix, a));
  const maxE = Math.max(...extMM);
  const flatAxis = extMM.findIndex((e) => e < maxE * 1e-3);
  if (flatAxis >= 0 && maxE > 0) {
    info.flat = true;
    const tLocal = minThickness / Math.max(colLen(part.matrix, flatAxis), 1e-9);
    mesh = solidify(mesh, flatAxis, tLocal);
    info.solidified = true;
  }
  const th = thicken(mesh, part.matrix, minThickness);
  mesh = th.mesh; info.thickened = th.changed && !info.solidified;
  const { edges } = boundaryEdges(mesh.tris);
  if (edges.length) {
    info.open = true;
    const c = capLoops(mesh);
    if (c.capped > 0) { mesh = c.mesh; info.capped = c.capped; }
  }
  return { mesh, info };
}

/** Local mesh -> printer-space triangle soup (Float32Array, 9 floats per triangle). */
export function toWorld(mesh, matrix) {
  const nv = mesh.verts.length / 3, out = new Float32Array(nv * 3);
  for (let i = 0; i < nv; i++) xform(matrix, [mesh.verts[i * 3], mesh.verts[i * 3 + 1], mesh.verts[i * 3 + 2]], out, i * 3);
  let tris = mesh.tris;
  if (det3(matrix) < 0) {
    tris = new Uint32Array(mesh.tris);
    for (let t = 0; t < tris.length; t += 3) { const b = tris[t + 1]; tris[t + 1] = tris[t + 2]; tris[t + 2] = b; }
  }
  return { verts: out, tris };
}

// ---------- colour ----------
function srgbToLin(c) { return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
export function rgbToLab([r, g, b]) {
  // input r,g,b in sRGB 0..1
  const R = srgbToLin(r), G = srgbToLin(g), B = srgbToLin(b);
  let x = (R * 0.4124 + G * 0.3576 + B * 0.1805) / 0.95047, y = R * 0.2126 + G * 0.7152 + B * 0.0722, z = (R * 0.0193 + G * 0.1192 + B * 0.9505) / 1.08883;
  const f = (t) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
  x = f(x); y = f(y); z = f(z);
  return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
}
export const deltaE = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
export const hexToRgb = (h) => { const v = parseInt(h.replace('#', '').slice(0, 6), 16); return [(v >> 16 & 255) / 255, (v >> 8 & 255) / 255, (v & 255) / 255]; };
export const rgbToHex = ([r, g, b]) => '#' + [r, g, b].map((c) => Math.round(Math.max(0, Math.min(1, c)) * 255).toString(16).padStart(2, '0')).join('').toUpperCase();

function labToRgb([L, a, bb]) {
  let y = (L + 16) / 116, x = a / 500 + y, z = y - bb / 200;
  const fi = (t) => (t ** 3 > 0.008856 ? t ** 3 : (t - 16 / 116) / 7.787);
  x = fi(x) * 0.95047; y = fi(y); z = fi(z) * 1.08883;
  const lin = [x * 3.2406 + y * -1.5372 + z * -0.4986, x * -0.9689 + y * 1.8758 + z * 0.0415, x * 0.0557 + y * -0.2040 + z * 1.0570];
  return lin.map((c) => (c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(Math.max(c, 0), 1 / 2.4) - 0.055));
}

/**
 * Cluster part colours (weighted by surface area) into at most `maxColors` groups.
 * Returns [{ id, hex, lab, weight, parts: [partIndex] }] sorted by weight desc.
 */
export function clusterColors(items, maxColors, mergeDE = 12) {
  let clusters = items.map((it, i) => ({ lab: rgbToLab(it.color), weight: Math.max(it.weight, 1e-6), parts: [i] }));
  const merge = (i, j) => {
    const a = clusters[i], b = clusters[j], w = a.weight + b.weight;
    a.lab = a.lab.map((v, k) => (v * a.weight + b.lab[k] * b.weight) / w);
    a.weight = w; a.parts.push(...b.parts); clusters.splice(j, 1);
  };
  const closest = () => {
    let best = [0, 1, Infinity];
    for (let i = 0; i < clusters.length; i++) for (let j = i + 1; j < clusters.length; j++) {
      const d = deltaE(clusters[i].lab, clusters[j].lab);
      if (d < best[2]) best = [i, j, d];
    }
    return best;
  };
  while (clusters.length > 1) {
    const [i, j, d] = closest();
    if (d < mergeDE || clusters.length > Math.max(1, maxColors)) merge(i, j); else break;
  }
  clusters.sort((a, b) => b.weight - a.weight);
  return clusters.map((c, id) => ({ id, lab: c.lab, hex: rgbToHex(labToRgb(c.lab)), weight: c.weight, parts: c.parts }));
}

/** Nearest slot (by ΔE) for each cluster. slots: [{key, hex}] */
export function suggestSlots(clusters, slots) {
  const labs = slots.map((s) => rgbToLab(hexToRgb(s.hex)));
  return clusters.map((c) => {
    let best = 0, bd = Infinity;
    labs.forEach((l, i) => { const d = deltaE(c.lab, l); if (d < bd) { bd = d; best = i; } });
    return slots.length ? slots[best].key : null;
  });
}

// ---------- surface area (for colour weights) ----------
export function surfaceArea(world) {
  const v = world.verts, t = world.tris; let area = 0;
  for (let i = 0; i < t.length; i += 3) {
    const a = t[i] * 3, b = t[i + 1] * 3, c = t[i + 2] * 3;
    const ux = v[b] - v[a], uy = v[b + 1] - v[a + 1], uz = v[b + 2] - v[a + 2];
    const wx = v[c] - v[a], wy = v[c + 1] - v[a + 1], wz = v[c + 2] - v[a + 2];
    area += Math.hypot(uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx) / 2;
  }
  return area;
}

// ---------- manifold booleans ----------
let wasmPromise = null;
export function loadManifold(importer) {
  if (!wasmPromise) wasmPromise = importer().then(async (mod) => { const w = await mod.default(); w.setup(); return w; });
  return wasmPromise;
}

/**
 * groups: [{ key, parts: [{ world: {verts, tris} }] }]
 * Returns [{ key, triangles: Float32Array (9/tri), manifold: bool, volume }] plus report.
 */
export async function buildSolids(wasm, groups, { carve = true } = {}) {
  const { Manifold, Mesh } = wasm;
  const report = { parts: 0, manifoldParts: 0, passthroughParts: 0, groups: groups.length, volume: 0 };
  const built = [];
  for (const g of groups) {
    const solids = [], loose = [];
    for (const p of g.parts) {
      report.parts++;
      try {
        const mesh = new Mesh({ numProp: 3, vertProperties: p.world.verts, triVerts: p.world.tris });
        mesh.merge();
        const m = new Manifold(mesh);
        if (m.status && m.status() !== 'NoError' && m.status() !== 0) throw new Error(String(m.status()));
        if (m.isEmpty()) { m.delete(); continue; }
        // inside-out parts (negative volume) get flipped by Manifold; volume() is always >= 0
        solids.push(m); report.manifoldParts++;
      } catch (_) {
        loose.push(p.world); report.passthroughParts++;
      }
    }
    const union = solids.length ? Manifold.union(solids) : null;
    solids.forEach((m) => m.delete());
    built.push({ key: g.key, union, loose, volume: union ? union.volume() : 0 });
  }
  // smaller groups win where colours overlap: carve each group by every smaller group
  if (carve && built.length > 1) {
    const order = [...built].sort((a, b) => a.volume - b.volume);
    for (let i = order.length - 1; i > 0; i--) {
      const big = order[i]; if (!big.union) continue;
      const smaller = order.slice(0, i).map((g) => g.union).filter(Boolean);
      if (!smaller.length) continue;
      const cutter = Manifold.union(smaller);
      const carved = Manifold.difference(big.union, cutter);
      cutter.delete(); big.union.delete(); big.union = carved;
    }
  }
  const out = built.map((g) => {
    const chunks = [];
    if (g.union && !g.union.isEmpty()) {
      const m = g.union.getMesh(), v = m.vertProperties, np = m.numProp, t = m.triVerts;
      const arr = new Float32Array(t.length * 3);
      for (let i = 0; i < t.length; i++) { arr[i * 3] = v[t[i] * np]; arr[i * 3 + 1] = v[t[i] * np + 1]; arr[i * 3 + 2] = v[t[i] * np + 2]; }
      chunks.push(arr);
      report.volume += g.union.volume();
    }
    for (const w of g.loose) {
      const arr = new Float32Array(w.tris.length * 3);
      for (let i = 0; i < w.tris.length; i++) { arr[i * 3] = w.verts[w.tris[i] * 3]; arr[i * 3 + 1] = w.verts[w.tris[i] * 3 + 1]; arr[i * 3 + 2] = w.verts[w.tris[i] * 3 + 2]; }
      chunks.push(arr);
    }
    if (g.union) g.union.delete();
    const total = chunks.reduce((s, c) => s + c.length, 0), triangles = new Float32Array(total);
    let o = 0; for (const c of chunks) { triangles.set(c, o); o += c.length; }
    return { key: g.key, triangles, loose: g.loose.length };
  });
  return { solids: out, report };
}

/** Binary STL from a triangle soup (9 floats per triangle). */
export function stlBytes(tri) {
  const n = tri.length / 9, buf = new ArrayBuffer(84 + n * 50), dv = new DataView(buf);
  dv.setUint32(80, n, true);
  let o = 84;
  for (let i = 0; i < n; i++) {
    const p = i * 9;
    const ux = tri[p + 3] - tri[p], uy = tri[p + 4] - tri[p + 1], uz = tri[p + 5] - tri[p + 2];
    const wx = tri[p + 6] - tri[p], wy = tri[p + 7] - tri[p + 1], wz = tri[p + 8] - tri[p + 2];
    let nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
    const l = Math.hypot(nx, ny, nz) || 1; nx /= l; ny /= l; nz /= l;
    dv.setFloat32(o, nx, true); dv.setFloat32(o + 4, ny, true); dv.setFloat32(o + 8, nz, true); o += 12;
    for (let k = 0; k < 9; k++) { dv.setFloat32(o, tri[p + k], true); o += 4; }
    dv.setUint16(o, 0, true); o += 2;
  }
  return new Uint8Array(buf);
}
