// GLB post-processing helpers for the headless tool page (enhance.html), on the bundled three.js r187.
import * as THREE from 'three';
import { unwrapUVs } from 'three/addons/utils/unwrapUVs.js';

/**
 * Adds a non-overlapping second UV set (uv1, exported as glTF TEXCOORD_1) for lightmap baking. Godot's LightmapGI
 * reads this as UV2. Existing uv (TEXCOORD_0) is left alone.
 */
export function addLightmapUVs(root, { resolution = 1024, padding = 4 } = {}) {
  const t0 = performance.now();
  const result = unwrapUVs(root, { attribute: 'uv1', mode: 'lightmap', resolution, padding });
  if (!result) throw new Error('The UV charts did not fit the atlas. Try a larger lightmap resolution.');
  return {
    resolution,
    charts: result.charts.length,
    excludedFaces: result.warnings.excludedFaces,
    singleTriangleCharts: result.warnings.singleTriangleCharts,
    ms: Math.round(performance.now() - t0),
  };
}

/**
 * OBJ has no materials without an MTL file, so copy each part's material colour into per-vertex colours
 * (multiplied with any existing vertex colours). Handles multi-material meshes through their groups.
 */
export function bakeMaterialColors(root) {
  let meshes = 0;
  root.traverse((m) => {
    if (!m.isMesh || !m.geometry?.attributes?.position) return;
    const g = m.geometry.index ? m.geometry.toNonIndexed() : m.geometry.clone();
    const n = g.attributes.position.count;
    const out = new Float32Array(n * 3);
    const existing = g.getAttribute('color');
    const mats = [].concat(m.material);
    const groups = g.groups.length ? g.groups : [{ start: 0, count: n, materialIndex: 0 }];
    const c = new THREE.Color(), v = new THREE.Color();
    for (const grp of groups) {
      const mat = mats[grp.materialIndex ?? 0] || mats[0];
      c.copy(mat?.color ?? new THREE.Color(1, 1, 1));
      for (let i = grp.start; i < Math.min(n, grp.start + grp.count); i++) {
        v.copy(c);
        if (existing) v.multiply(new THREE.Color().fromBufferAttribute(existing, i));
        out[i * 3] = v.r; out[i * 3 + 1] = v.g; out[i * 3 + 2] = v.b;
      }
    }
    g.setAttribute('color', new THREE.BufferAttribute(out, 3));
    m.geometry = g;
    meshes++;
  });
  return { meshes };
}
