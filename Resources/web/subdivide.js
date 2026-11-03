// Crease-aware Loop subdivision for generated low-poly assets.
//
// Each level splits every triangle into four and moves vertices with Loop's smoothing rules, so round
// parts (cylinders, spheres, lathe profiles) become genuinely round. Edges whose faces meet at more than
// `creaseAngle` degrees, open borders and texture seams are treated as creases and use the sharp-edge
// rules instead, so blades, box corners and cap rims stay crisp rather than melting into blobs.
import * as THREE from 'three';
import { mergeVertices, toCreasedNormals } from 'three/addons/utils/BufferGeometryUtils.js';

/** Weld vertices that share a position (and UV / colour when kept), and drop degenerate triangles. */
function prepare(geo, keepUV) {
  let g = geo.clone();
  for (const name of Object.keys(g.attributes)) {
    if (name === 'position' || name === 'color' || (keepUV && name === 'uv')) continue;
    g.deleteAttribute(name);
  }
  g.morphAttributes = {};
  g = mergeVertices(g, 1e-5);
  if (!g.index) g = mergeVertices(g, 1e-5);
  const idx = g.index.array, keep = [], groups = [];
  const src = g.groups.length ? g.groups : [{ start: 0, count: idx.length, materialIndex: 0 }];
  for (const grp of src) {
    const start = keep.length;
    for (let i = grp.start; i < grp.start + grp.count; i += 3) {
      const a = idx[i], b = idx[i + 1], c = idx[i + 2];
      if (a !== b && b !== c && a !== c) keep.push(a, b, c);
    }
    groups.push({ start, count: keep.length - start, materialIndex: grp.materialIndex ?? 0 });
  }
  g.setIndex(keep);
  g.clearGroups();
  if (geo.groups.length) for (const grp of groups) g.addGroup(grp.start, grp.count, grp.materialIndex);
  return g;
}

/** One level of crease-aware Loop subdivision on an indexed, welded geometry. */
function loopOnce(g, cosCrease) {
  const P = g.attributes.position.array;
  const extras = Object.keys(g.attributes).filter((n) => n !== 'position').map((n) => [n, g.attributes[n]]);
  const I = g.index.array;
  const nv = P.length / 3, nf = I.length / 3;

  // Face normals.
  const fn = new Float32Array(nf * 3);
  const va = new THREE.Vector3(), vb = new THREE.Vector3(), vc = new THREE.Vector3();
  for (let f = 0; f < nf; f++) {
    va.fromArray(P, I[f * 3] * 3); vb.fromArray(P, I[f * 3 + 1] * 3); vc.fromArray(P, I[f * 3 + 2] * 3);
    vc.sub(vb); va.sub(vb); vc.cross(va);
    const l = vc.length();
    if (l > 0) vc.multiplyScalar(1 / l);
    fn[f * 3] = vc.x; fn[f * 3 + 1] = vc.y; fn[f * 3 + 2] = vc.z;
  }

  // Edges: key -> { a, b, faces: [f...], opp: [vertex...], mid }
  const edges = new Map();
  const key = (a, b) => (a < b ? a * nv + b : b * nv + a);
  for (let f = 0; f < nf; f++) {
    for (let k = 0; k < 3; k++) {
      const a = I[f * 3 + k], b = I[f * 3 + (k + 1) % 3], c = I[f * 3 + (k + 2) % 3];
      const id = key(a, b);
      let e = edges.get(id);
      if (!e) { e = { a: Math.min(a, b), b: Math.max(a, b), faces: [], opp: [], sharp: false, mid: -1 }; edges.set(id, e); }
      e.faces.push(f); e.opp.push(c);
    }
  }

  // Sharpness and per-vertex neighbourhoods.
  const neighbours = Array.from({ length: nv }, () => new Set());
  const sharpNbr = Array.from({ length: nv }, () => []);
  for (const e of edges.values()) {
    if (e.faces.length !== 2) e.sharp = true;
    else {
      const [f0, f1] = e.faces;
      const d = fn[f0 * 3] * fn[f1 * 3] + fn[f0 * 3 + 1] * fn[f1 * 3 + 1] + fn[f0 * 3 + 2] * fn[f1 * 3 + 2];
      e.sharp = d < cosCrease;
    }
    neighbours[e.a].add(e.b); neighbours[e.b].add(e.a);
    if (e.sharp) { sharpNbr[e.a].push(e.b); sharpNbr[e.b].push(e.a); }
  }

  const ne = edges.size;
  const outP = new Float32Array((nv + ne) * 3);
  const outX = extras.map(([name, attr]) => [name, attr.itemSize, attr.array, new Float32Array((nv + ne) * attr.itemSize)]);

  // Vertex points.
  for (let v = 0; v < nv; v++) {
    const s = sharpNbr[v];
    const x = P[v * 3], y = P[v * 3 + 1], z = P[v * 3 + 2];
    let ox = x, oy = y, oz = z;
    if (s.length === 2) {
      const a = s[0] * 3, b = s[1] * 3;
      ox = 0.75 * x + 0.125 * (P[a] + P[b]);
      oy = 0.75 * y + 0.125 * (P[a + 1] + P[b + 1]);
      oz = 0.75 * z + 0.125 * (P[a + 2] + P[b + 2]);
    } else if (s.length < 2) {
      const n = neighbours[v].size;
      if (n >= 3) {
        const beta = n === 3 ? 3 / 16 : 3 / (8 * n);
        let sx = 0, sy = 0, sz = 0;
        for (const u of neighbours[v]) { sx += P[u * 3]; sy += P[u * 3 + 1]; sz += P[u * 3 + 2]; }
        ox = (1 - n * beta) * x + beta * sx;
        oy = (1 - n * beta) * y + beta * sy;
        oz = (1 - n * beta) * z + beta * sz;
      }
    } // 3 or more crease edges: a corner, which stays put.
    outP[v * 3] = ox; outP[v * 3 + 1] = oy; outP[v * 3 + 2] = oz;
    for (const [, size, src, dst] of outX) for (let k = 0; k < size; k++) dst[v * size + k] = src[v * size + k];
  }

  // Edge points.
  let next = nv;
  for (const e of edges.values()) {
    const a = e.a * 3, b = e.b * 3, m = next * 3;
    if (e.sharp) {
      outP[m] = 0.5 * (P[a] + P[b]); outP[m + 1] = 0.5 * (P[a + 1] + P[b + 1]); outP[m + 2] = 0.5 * (P[a + 2] + P[b + 2]);
    } else {
      const c = e.opp[0] * 3, d = e.opp[1] * 3;
      outP[m] = 0.375 * (P[a] + P[b]) + 0.125 * (P[c] + P[d]);
      outP[m + 1] = 0.375 * (P[a + 1] + P[b + 1]) + 0.125 * (P[c + 1] + P[d + 1]);
      outP[m + 2] = 0.375 * (P[a + 2] + P[b + 2]) + 0.125 * (P[c + 2] + P[d + 2]);
    }
    for (const [, size, src, dst] of outX) {
      for (let k = 0; k < size; k++) dst[next * size + k] = 0.5 * (src[e.a * size + k] + src[e.b * size + k]);
    }
    e.mid = next++;
  }

  // Four children per face, kept contiguous so material groups scale by 4.
  const outI = new Uint32Array(nf * 12);
  for (let f = 0; f < nf; f++) {
    const a = I[f * 3], b = I[f * 3 + 1], c = I[f * 3 + 2];
    const ab = edges.get(key(a, b)).mid, bc = edges.get(key(b, c)).mid, ca = edges.get(key(c, a)).mid;
    outI.set([a, ab, ca, ab, b, bc, ca, bc, c, ab, bc, ca], f * 12);
  }

  const out = new THREE.BufferGeometry();
  out.setAttribute('position', new THREE.BufferAttribute(outP, 3));
  for (const [name, size, , dst] of outX) out.setAttribute(name, new THREE.BufferAttribute(dst, size));
  out.setIndex(new THREE.BufferAttribute(outI, 1));
  for (const grp of g.groups) out.addGroup(grp.start * 4, grp.count * 4, grp.materialIndex);
  return out;
}

/**
 * Loop smoothing pulls round parts inside their original silhouette (an 8-sided cylinder ends ~9 % thinner),
 * which opens gaps where parts meet. Scale each part back out to its original bounding box, per axis,
 * never shrinking and never by more than 30 %.
 */
function restoreExtent(g, before) {
  g.computeBoundingBox();
  const after = g.boundingBox;
  const s0 = before.getSize(new THREE.Vector3()), s1 = after.getSize(new THREE.Vector3());
  const c0 = before.getCenter(new THREE.Vector3()), c1 = after.getCenter(new THREE.Vector3());
  const k = new THREE.Vector3(
    s1.x > 1e-9 ? Math.min(1.3, Math.max(1, s0.x / s1.x)) : 1,
    s1.y > 1e-9 ? Math.min(1.3, Math.max(1, s0.y / s1.y)) : 1,
    s1.z > 1e-9 ? Math.min(1.3, Math.max(1, s0.z / s1.z)) : 1);
  const p = g.attributes.position.array;
  for (let i = 0; i < p.length; i += 3) {
    p[i] = c0.x + (p[i] - c1.x) * k.x;
    p[i + 1] = c0.y + (p[i + 1] - c1.y) * k.y;
    p[i + 2] = c0.z + (p[i + 2] - c1.z) * k.z;
  }
  g.attributes.position.needsUpdate = true;
}

const hasTexture = (mat) => [].concat(mat).some((m) => m && (m.map || m.normalMap || m.roughnessMap || m.metalnessMap || m.emissiveMap || m.aoMap));

/**
 * Subdivides every eligible mesh under `root` in place.
 * opts: { levels: 1|2|3, creaseAngle: degrees, maxTriangles: total budget }
 */
export function enhanceScene(root, opts = {}) {
  const levels = Math.max(1, Math.min(3, opts.levels ?? 2));
  const crease = opts.creaseAngle ?? 50;
  const cosCrease = Math.cos(THREE.MathUtils.degToRad(crease));
  const budget = opts.maxTriangles ?? 1_500_000;
  const stats = { meshes: 0, skipped: 0, before: 0, after: 0 };
  const done = new Map(); // shared geometries are subdivided once

  const meshes = [];
  root.traverse((o) => { if (o.isMesh) meshes.push(o); });
  const tri = (g) => (g.index ? g.index.count : g.attributes.position.count) / 3;
  let projected = 0;
  for (const m of meshes) projected += tri(m.geometry) * 4 ** levels;
  const lv = projected > budget ? Math.max(1, levels - Math.ceil(Math.log(projected / budget) / Math.log(4))) : levels;

  for (const m of meshes) {
    const g0 = m.geometry;
    stats.before += tri(g0);
    if (m.isSkinnedMesh || (g0.morphAttributes && Object.keys(g0.morphAttributes).length) || !g0.attributes.position) {
      stats.skipped++; stats.after += tri(g0); continue;
    }
    let g = done.get(g0.uuid);
    if (!g) {
      g = prepare(g0, hasTexture(m.material));
      g.computeBoundingBox();
      const before = g.boundingBox.clone();
      for (let i = 0; i < lv; i++) g = loopOnce(g, cosCrease);
      restoreExtent(g, before);
      g = toCreasedNormals(g, THREE.MathUtils.degToRad(crease));
      g = mergeVertices(g, 1e-6);
      g.computeBoundingBox(); g.computeBoundingSphere();
      done.set(g0.uuid, g);
    }
    m.geometry = g;
    for (const mat of [].concat(m.material)) if (mat) { mat.flatShading = false; mat.needsUpdate = true; }
    stats.meshes++; stats.after += tri(g);
  }
  stats.levels = lv;
  return stats;
}
