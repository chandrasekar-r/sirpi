# Third-party notices

Sirpi is MIT licensed (see `LICENSE`). It bundles or uses the following, each under its own licence.

## Bundled in the app

| Component | Where | Licence |
|---|---|---|
| [three.js](https://github.com/mrdoob/three.js) r187 (core, OrbitControls, TransformControls, GLTFLoader, GLTFExporter, OBJExporter, BufferGeometryUtils, unwrapUVs, RoomEnvironment, potpack) | `Resources/web/vendor/three/` | MIT |
| [Manifold](https://github.com/elalish/manifold) (WebAssembly build) | `Resources/web/vendor/manifold/` | Apache-2.0 (see `Resources/web/vendor/manifold/LICENSE`) |

## Swift packages (resolved at build time)

| Package | Licence |
|---|---|
| [mlx-swift](https://github.com/ml-explore/mlx-swift), [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | MIT |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache-2.0 |
| Their dependencies (swift-collections, swift-crypto, swift-numerics, swift-jinja and others) | Apache-2.0 or MIT, see each package |

## Models and data (downloaded by the user, not included in this repository)

| Item | Licence | Notes |
|---|---|---|
| [ccore/Qwen3.5-4B-GLB-3D-Coder](https://huggingface.co/ccore/Qwen3.5-4B-GLB-3D-Coder) | Apache-2.0 | Fine-tune of [Qwen/Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) (Apache-2.0). `tools/model/` converts it to MLX. |
| [NVIDIA SimReady assets](https://huggingface.co/datasets/nvidia/simready-assets) | CC-BY-4.0 | Imported on demand. Credit NVIDIA when you use them. |

## Tools used at runtime if installed

Bambu Studio (slicing), Blender (export), Pixar OpenUSD `usd-core` (SimReady conversion), and coding-agent CLIs such as Claude Code, opencode, Grok CLI and Kimi Code. These are separate programs under their own licences and terms.
