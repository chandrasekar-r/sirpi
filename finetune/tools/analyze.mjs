// GLB metrics for game assets and FDM printability. Pure geometry, no rendering.
import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';

export async function parseGLB(buf) {
  const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
  return new Promise((res, rej) => new GLTFLoader().parse(ab, '', res, rej));
}

/** World-space triangles per mesh: [{ tris: Float32Array (9 per tri), box }] */
function collect(scene) {
  scene.updateMatrixWorld(true);
  const out = [];
  scene.traverse((o) => {
    if (!o.isMesh || !o.geometry?.attributes?.position) return;
    const g = o.geometry, p = g.attributes.position, idx = g.index;
    const n = idx ? idx.count : p.count;
    const tris = new Float32Array(n * 3);
    const v = new THREE.Vector3();
    for (let i = 0; i < n; i++) {
      v.fromBufferAttribute(p, idx ? idx.getX(i) : i).applyMatrix4(o.matrixWorld);
      tris[i * 3] = v.x; tris[i * 3 + 1] = v.y; tris[i * 3 + 2] = v.z;
    }
    const box = new THREE.Box3();
    for (let i = 0; i < tris.length; i += 3) box.expandByPoint(v.set(tris[i], tris[i + 1], tris[i + 2]));
    const mats = [].concat(o.material).filter(Boolean);
    out.push({ tris, box, colors: mats.map((m) => m.color?.getHexString?.() ?? '') });
  });
  return out;
}

/** Share of edges with exactly two faces after welding positions (1 = closed surface). */
function closedFraction(tris, tol) {
  const key = (i) => `${Math.round(tris[i] / tol)},${Math.round(tris[i + 1] / tol)},${Math.round(tris[i + 2] / tol)}`;
  const ids = new Map();
  const id = (i) => { const k = key(i); let x = ids.get(k); if (x === undefined) { x = ids.size; ids.set(k, x); } return x; };
  const edges = new Map();
  for (let t = 0; t < tris.length; t += 9) {
    const a = id(t), b = id(t + 3), c = id(t + 6);
    if (a === b || b === c || a === c) continue;
    for (const [u, w] of [[a, b], [b, c], [c, a]]) {
      const k = u < w ? `${u}_${w}` : `${w}_${u}`;
      edges.set(k, (edges.get(k) || 0) + 1);
    }
  }
  if (!edges.size) return 0;
  let ok = 0;
  for (const c of edges.values()) if (c === 2) ok++;
  return ok / edges.size;
}

function triArea(t, i, n) {
  const ax = t[i + 3] - t[i], ay = t[i + 4] - t[i + 1], az = t[i + 5] - t[i + 2];
  const bx = t[i + 6] - t[i], by = t[i + 7] - t[i + 1], bz = t[i + 8] - t[i + 2];
  const cx = ay * bz - az * by, cy = az * bx - ax * bz, cz = ax * by - ay * bx;
  const l = Math.hypot(cx, cy, cz);
  if (n) { n[0] = cx / (l || 1); n[1] = cy / (l || 1); n[2] = cz / (l || 1); }
  return l / 2;
}

export function analyze(gltf, mode, prompt) {
  const meshes = collect(gltf.scene);
  const all = new THREE.Box3();
  for (const m of meshes) all.union(m.box);
  const size = all.isEmpty() ? new THREE.Vector3() : all.getSize(new THREE.Vector3());
  const triangles = meshes.reduce((s, m) => s + m.tris.length / 9, 0);
  const colors = new Set(meshes.flatMap((m) => m.colors));
  const r = {
    meshes: meshes.length, triangles, colors: colors.size,
    size: size.toArray().map((x) => +x.toFixed(2)),
    animations: gltf.animations?.length || 0,
  };
  if (mode !== 'print' || !meshes.length) return r;

  // Printability. The print prompt asks for 1 unit = 1 mm.
  const diag = size.length() || 1;
  const tol = Math.max(1e-4, diag * 1e-5);
  // Floating parts: meshes linked when their boxes touch (with a small margin).
  const parent = meshes.map((_, i) => i);
  const find = (i) => (parent[i] === i ? i : (parent[i] = find(parent[i])));
  const margin = Math.max(0.2, diag * 0.002);
  const grown = meshes.map((m) => m.box.clone().expandByScalar(margin));
  for (let i = 0; i < meshes.length; i++)
    for (let j = i + 1; j < meshes.length; j++) if (grown[i].intersectsBox(grown[j])) parent[find(i)] = find(j);
  const clusters = new Set(meshes.map((_, i) => find(i))).size;

  let total = 0, overhang = 0, contact = 0, closedW = 0, thin = 0;
  const nrm = [0, 0, 0];
  const baseY = all.min.y, baseBand = Math.max(0.5, size.y * 0.01);
  for (const m of meshes) {
    const t = m.tris;
    let a = 0;
    for (let i = 0; i < t.length; i += 9) {
      const A = triArea(t, i, nrm);
      a += A;
      const cy = (t[i + 1] + t[i + 4] + t[i + 7]) / 3;
      if (nrm[1] < -0.9 && cy - baseY < baseBand) contact += A;
      else if (nrm[1] < -0.7071 && cy - baseY > baseBand) overhang += A;
    }
    total += a;
    closedW += closedFraction(t, tol) * a;
    const s = m.box.getSize(new THREE.Vector3());
    if (Math.min(s.x, s.y, s.z) < 1.2 && Math.max(s.x, s.y, s.z) > 3) thin++;
  }
  const footprint = Math.max(1e-6, size.x * size.z);
  const want = /(\d+(?:\.\d+)?)\s*mm/.exec(prompt || '');
  const target = want ? +want[1] : null;
  const largest = Math.max(size.x, size.y, size.z);
  const sizeRatio = target ? largest / target : null;

  Object.assign(r, {
    clusters,
    grounded: Math.abs(baseY) < Math.max(1, size.y * 0.02),
    contactRatio: +(contact / footprint).toFixed(3),
    closed: +(closedW / Math.max(total, 1e-9)).toFixed(3),
    overhangFrac: +(overhang / Math.max(total, 1e-9)).toFixed(3),
    thinParts: thin,
    fitsPlate: size.x <= 256 && size.y <= 256 && size.z <= 256,
    sizeRatio: sizeRatio && +sizeRatio.toFixed(2),
  });
  const sizeOk = sizeRatio == null ? 1 : Math.max(0, 1 - Math.abs(Math.log(sizeRatio)) / Math.log(2));
  r.printScore = Math.round(
    25 * r.closed +
    20 * (clusters === 1 ? 1 : 1 / clusters) +
    15 * ((r.grounded ? 0.5 : 0) + Math.min(1, r.contactRatio / 0.15) * 0.5) +
    15 * sizeOk * (r.fitsPlate ? 1 : 0.3) +
    10 * (thin === 0 ? 1 : Math.max(0, 1 - thin / 4)) +
    15 * Math.max(0, 1 - r.overhangFrac * 4));
  return r;
}
