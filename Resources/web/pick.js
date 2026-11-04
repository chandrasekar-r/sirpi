// Part picking for generated asset pages (loaded with three-hook.js in place of three.js).
// A click (not an orbit drag) selects the mesh under the pointer, outlines it and tells Sirpi what it is.
(() => {
  const S = (window.__sirpi ||= { scenes: [], renderers: [], last: null });
  const post = (m) => { try { window.webkit.messageHandlers.forge.postMessage(m); } catch (_) {} };
  let down = null, picked = null, outline = null;

  const style = document.createElement('style');
  style.textContent = 'canvas { cursor: crosshair !important; }';
  document.documentElement.appendChild(style);

  const round = (n) => Math.round(n * 100) / 100;
  const materials = (o) => (Array.isArray(o.material) ? o.material : [o.material]).filter(Boolean);

  function describe(o) {
    const T = S.THREE;
    const box = new T.Box3().setFromObject(o);
    const size = box.getSize(new T.Vector3()), centre = box.getCenter(new T.Vector3());
    const all = new T.Box3().setFromObject(S.last.scene);
    const path = [];
    for (let p = o; p && !p.isScene; p = p.parent) if (p.name) path.unshift(p.name);
    const g = o.geometry || {};
    const params = {};
    for (const [k, v] of Object.entries(g.parameters || {})) if (typeof v === 'number') params[k] = round(v);
    let same = 0;
    S.last.scene.traverse((x) => { if (x.isMesh && x !== o && x.geometry === o.geometry) same++; });
    return {
      type: 'part',
      name: o.name || '', path, geometry: g.type || '', params,
      colors: materials(o).map((m) => (m.color ? '#' + m.color.getHexString() : '')),
      materialNames: materials(o).map((m) => m.name || ''),
      materialTypes: materials(o).map((m) => m.type || ''),
      centre: [centre.x, centre.y, centre.z].map(round), size: [size.x, size.y, size.z].map(round),
      modelMin: [all.min.x, all.min.y, all.min.z].map(round), modelMax: [all.max.x, all.max.y, all.max.z].map(round),
      sharedGeometry: same,
    };
  }

  function mark(o) {
    const T = S.THREE;
    if (outline) { outline.removeFromParent(); outline.geometry.dispose(); outline = null; }
    picked = o;
    if (o && S.last) {
      outline = new T.BoxHelper(o, 0xc8f25a);
      outline.userData.__sirpi = true;
      outline.material.depthTest = false; outline.renderOrder = 999;
      S.last.scene.add(outline);
    }
  }
  S.onRender = () => { if (outline && picked) outline.update(); };

  function hit(e) {
    const L = S.last, T = S.THREE;
    if (!L || !T) return null;
    const r = L.renderer.domElement.getBoundingClientRect();
    const ndc = new T.Vector2(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    const rc = new T.Raycaster();
    rc.setFromCamera(ndc, L.camera);
    const hits = rc.intersectObject(L.scene, true).filter((h) => h.object.isMesh && h.object.visible && !h.object.userData.__sirpi);
    return hits.length ? hits[0].object : null;
  }

  addEventListener('pointerdown', (e) => { down = [e.clientX, e.clientY]; }, true);
  addEventListener('pointerup', (e) => {
    if (!down || Math.hypot(e.clientX - down[0], e.clientY - down[1]) > 4) { down = null; return; }
    down = null;
    if (e.target && e.target.tagName !== 'CANVAS') return;
    const o = hit(e);
    mark(o);
    post(o ? describe(o) : { type: 'part', cleared: true });
  }, true);
  addEventListener('keydown', (e) => { if (e.key === 'Escape' && picked) { mark(null); post({ type: 'part', cleared: true }); } });

  window.__sirpiPick = { clear() { mark(null); } };
})();
