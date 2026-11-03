<p align="center">
  <img src="docs/images/icon.png" width="160" alt="Sirpi icon: the Tamil letter சி built from glass blocks">
</p>

<h1 align="center">Sirpi (சிற்பி)</h1>

<p align="center"><b>Describe it, and Sirpi sculpts it in 3D.</b><br>
A native macOS app that turns a sentence or a picture into a game asset, a 3D print or a whole editable scene.<br>
Runs a fine-tuned model on your Mac's GPU, or the coding agents and AI services you already use.</p>

<p align="center">
  <a href="https://github.com/chandrasekar-r/sirpi/releases/latest">Download</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="finetune/README.md">Fine-tuning toolkit</a>
</p>

*Sirpi* means "sculptor" in Tamil.

![Generated asset in Sirpi](docs/images/asset-preview.png)

## What it does

- **Three purposes.** *Game asset* (a GLB for Godot or any engine), *3D print* (one solid, watertight object at real size in millimetres, sized to fit your printer), or *3D scene* (a whole place such as a street or a room, in metres, with every object separately named).
- **Text or picture in.** Describe what you want, or attach a reference picture. Before generating, Sirpi asks a few follow-up questions (style, size, colours, purpose) so the result matches what you had in mind.
- **Local first.** The bundled 3D Coder ([Qwen3.5-4B GLB 3D Coder](https://huggingface.co/ccore/Qwen3.5-4B-GLB-3D-Coder)) runs inside the app on the GPU with [MLX](https://github.com/ml-explore/mlx-swift): about 80 tokens per second on an M4 Pro, no server, nothing leaves your Mac.
- **Or bring your own model.** Coding-agent CLIs you are already signed in to (Claude Code, opencode, Grok CLI, Kimi Code, Cursor Agent, Codex, Gemini CLI, pi) are detected automatically and use their own logins. Cloud APIs (Claude, OpenAI, Gemini, xAI, Cloudflare Workers AI, OpenRouter, Groq, DeepSeek, Mistral) and local servers (Ollama, LM Studio) work with a key or URL.
- **Customise.** Select objects in a scene, move, rotate and scale them with a gizmo, recolour materials, duplicate, delete, and insert assets from your library. Every change is a new version.
- **Real-world assets.** Browse and import the 2,677 [NVIDIA SimReady](https://huggingface.co/datasets/nvidia/simready-assets) assets (OpenUSD with PBR materials), converted to GLB on demand.
- **Matches your picture.** After an asset made from a picture, Sirpi renders it from four sides next to the picture, asks a vision model what differs, and refines it once automatically.
- **Fast fixes.** Fixes and refinements come back as small edits to the existing code instead of a whole new file, so fixing a script error takes seconds. A generation that was stopped or cut off can be continued from where it ended.
- **Detail on demand.** *Smooth & add detail* subdivides meshes so curves become smooth while sharp edges stay crisp.
- **Print on a Bambu Lab printer.** Prepare repairs meshes into watertight solids, matches colours to your AMS, slices with Bambu Studio and sends the job over the local network (LAN mode).
- **Turntable videos.** Render a seamless 360° video of any asset: 720p to 4K, square or vertical, studio, soft or dramatic lighting, and a transparent background (HEVC with alpha) for trailers and editors.
- **Export anywhere.** GLB (optionally with lightmap UVs for Godot's LightmapGI), OBJ with colours, a copy straight into a Godot project, Blender (open, or save a `.blend`), STL and sliced 3MF.

| Follow-up questions | Customising a scene |
|---|---|
| ![Follow-up questions](docs/images/follow-up-questions.png) | ![Scene customiser](docs/images/customise.png) |

## Install

1. Download `Sirpi-<version>-macOS-arm64.zip` from [Releases](https://github.com/chandrasekar-r/sirpi/releases/latest), unzip, and move `Sirpi.app` to Applications.
2. The app is not notarised. The first time, right-click it and choose **Open**, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Sirpi.app
   ```

Requirements: an Apple silicon Mac and macOS 27 or later. 16 GB of memory is enough for the local model; more is better.

### Get a model

Pick one or more:

- **Local 3D Coder (free, private).** Needs [uv](https://docs.astral.sh/uv/), about 4 GB to download and 20 GB free while converting:
  ```sh
  tools/model/setup_local_model.sh          # MLX 4-bit, the fastest
  tools/model/setup_local_model.sh --6bit   # also MLX 6-bit, closest to the original
  ```
  Then choose it in **Settings › Local Model**.
- **A coding agent you already use.** Install and sign in to it once in Terminal; Sirpi finds it in **Settings › Coding Agents**.
- **A cloud API.** Add a key in **Settings › Cloud APIs**. Keys are stored in a file only your user account can read.

### Optional

- [Bambu Studio](https://bambulab.com/en/download/studio) for slicing, and a Bambu Lab printer in LAN mode for printing.
- [Blender](https://www.blender.org/download/) for Blender export.
- [uv](https://docs.astral.sh/uv/) for importing NVIDIA SimReady assets (Sirpi sets up Pixar's USD converter on first use).

## Build from source

Needs Xcode 27 (for MLX's Metal shaders) and its Metal toolchain:

```sh
xcodebuild -downloadComponent MetalToolchain   # once
./scripts/build.sh                             # builds build/Sirpi.app
./scripts/build.sh --install                   # and copies it to /Applications
```

## How it works

| Part | Implementation |
|---|---|
| App | SwiftUI on macOS 27 with Liquid Glass. Pages are rendered with WebKit (`WebPage`) through a `forge://` URL scheme. |
| Local model | `NativeEngine` runs MLX in-process (`mlx-swift-lm`), streaming tokens off the main thread. GGUF files can also run through `llama-server`. |
| Providers | `Providers.swift` (OpenAI-compatible, Claude Messages API, and CLI agents run headless in an empty folder). `CLIDiscovery.swift` finds agents and checks sign-in with each CLI's own status command. |
| Generation | The model writes one standalone Three.js page with an *Export GLB* button. `Resources/web/bridge.js` captures script errors and the exported GLB. |
| Mesh tools | `Resources/web/` (three.js r187): crease-aware Loop subdivision, lightmap UVs, OBJ export, the scene editor, and print preparation with [Manifold](https://github.com/elalish/manifold). |
| Printing | Bambu Studio CLI for slicing; MQTT over TLS and FTPS to the printer in LAN mode. |
| SimReady | `Resources/tools/simready_to_glb.py` uses Pixar's `usd-core` to flatten instanced USD meshes and map NVIDIA's OmniPBR materials to glTF PBR. |
| Fine-tuning | [`finetune/`](finetune/README.md): rejection-sampling LoRA on Apple silicon, including a chunked Gated DeltaNet kernel that makes long-sequence training of Qwen3.5 possible in mlx-lm. |

## Privacy

With the local model, generation never leaves your Mac. Coding agents and cloud APIs receive your prompt (and reference picture, if attached) under their own terms. API keys are stored in `~/Library/Application Support/Sirpi/` with permissions for your user only. Sirpi never reads or copies coding-agent credentials.

## Credits

- 3D Coder model by [ccore](https://huggingface.co/ccore/Qwen3.5-4B-GLB-3D-Coder), based on [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) (Apache-2.0).
- [three.js](https://threejs.org), [Manifold](https://github.com/elalish/manifold), [MLX](https://github.com/ml-explore), [swift-transformers](https://github.com/huggingface/swift-transformers).
- [NVIDIA SimReady](https://huggingface.co/datasets/nvidia/simready-assets) assets (CC-BY-4.0).

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Licence

[MIT](LICENSE) © 2026 Chandrasekar R
