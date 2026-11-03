// Injected at document start into generated asset pages.
// - forwards JS errors to the app (for "Fix errors")
// - intercepts blob/data downloads (Export GLB) and hands the bytes to the app
// - exposes window.__forgeExport() so the app can trigger the page's export button
(() => {
  if (window.__forgeBridge) return;
  window.__forgeBridge = true;
  const post = (m) => { try { window.webkit.messageHandlers.forge.postMessage(m); } catch (_) {} };

  window.addEventListener('error', (e) => {
    if (e.target && e.target !== window && (e.target.src || e.target.href)) {
      post({ type: 'error', message: 'Failed to load resource: ' + (e.target.src || e.target.href) });
      return;
    }
    post({ type: 'error', message: `${e.message}${e.lineno ? ` (line ${e.lineno})` : ''}` });
  }, true);
  window.addEventListener('unhandledrejection', (e) => {
    const r = e.reason;
    post({ type: 'error', message: 'Unhandled promise rejection: ' + (r && (r.stack || r.message) || String(r)) });
  });
  const origError = console.error;
  console.error = function (...args) {
    post({ type: 'error', message: args.map((a) => (a && a.stack) || String(a)).join(' ') });
    return origError.apply(console, args);
  };

  const toBase64 = (buf) => {
    const bytes = new Uint8Array(buf);
    let bin = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
      bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(bin);
  };
  const sendBlob = async (blob, name) => {
    const buf = await blob.arrayBuffer();
    post({ type: 'download', name: name || 'asset.glb', data: toBase64(buf) });
  };

  const blobs = new Map();
  const origCreate = URL.createObjectURL;
  URL.createObjectURL = function (obj) {
    const url = origCreate.call(URL, obj);
    if (obj instanceof Blob) blobs.set(url, obj);
    return url;
  };

  const handleAnchor = (a) => {
    const href = a.href || '';
    if (!a.hasAttribute('download')) return false;
    if (href.startsWith('blob:') && blobs.has(href)) { sendBlob(blobs.get(href), a.download); return true; }
    if (href.startsWith('data:')) { fetch(href).then((r) => r.blob()).then((b) => sendBlob(b, a.download)); return true; }
    return false;
  };

  const origClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (handleAnchor(this)) return;
    return origClick.call(this);
  };
  const origDispatch = EventTarget.prototype.dispatchEvent;
  EventTarget.prototype.dispatchEvent = function (ev) {
    if (this instanceof HTMLAnchorElement && ev && ev.type === 'click' && handleAnchor(this)) return false;
    return origDispatch.call(this, ev);
  };
  document.addEventListener('click', (e) => {
    const a = e.target && e.target.closest && e.target.closest('a[download]');
    if (a && handleAnchor(a)) { e.preventDefault(); e.stopPropagation(); }
  }, true);

  window.__forgeExport = () => {
    const els = [...document.querySelectorAll('button, a, input[type=button], [role=button], div, span')];
    const score = (el) => {
      const t = ((el.textContent || el.value || el.title || el.id || '') + '').trim();
      if (!t || t.length > 40) return 0;
      if (/export\s*glb/i.test(t)) return 3;
      if (/glb/i.test(t)) return 2;
      if (/export|download/i.test(t)) return 1;
      return 0;
    };
    let best = null, bestScore = 0;
    for (const el of els) {
      const s = score(el) + (el.tagName === 'BUTTON' ? 0.5 : 0);
      if (s > bestScore) { best = el; bestScore = s; }
    }
    if (!best || bestScore < 1) return false;
    best.click();
    return true;
  };
})();
