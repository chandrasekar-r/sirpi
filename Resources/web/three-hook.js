// three.js as generated pages import it, plus hooks Sirpi uses to find what the page built:
// every Scene is recorded, and each render remembers the scene and camera it drew.
// Served in place of the CDN copy for part picking and the live preview.
export * from './vendor/three/build/three.module.js';
import * as T from './vendor/three/build/three.module.js';

const S = (window.__sirpi ||= { scenes: [], renderers: [], last: null });
S.THREE = T;

export class Scene extends T.Scene {
  constructor(...a) { super(...a); if (!S.quiet) S.scenes.push(this); }
}

export class WebGLRenderer extends T.WebGLRenderer {
  constructor(...a) {
    super(...a);
    if (S.quiet) return;
    S.renderers.push(this);
    // three.js assigns render() in its constructor, so wrap the instance's copy.
    const render = this.render;
    this.render = (scene, camera) => {
      S.last = { scene, camera, renderer: this };
      if (S.onRender) S.onRender(scene, camera, this);
      return render.call(this, scene, camera);
    };
  }
}
