# Fine-tuning toolkit

Self-improvement for the local 3D Coder: the model generates several attempts per prompt, an automatic scorer keeps only
verified-good ones, and a LoRA trained on them is merged back into the weights. Everything runs on an Apple silicon Mac
with [MLX](https://github.com/ml-explore/mlx).

## Pipeline

```
eval baseline -> generate training attempts -> score -> keep best per prompt -> LoRA -> fuse + quantize -> re-evaluate
```

`tools/pipeline.sh` runs all stages and resumes after an interruption (each stage skips itself when its output exists).

| Script | What it does |
|---|---|
| `gen.py` | Batched generation with mlx-lm using the same prompt format as the app. Game, print and scene system prompts. |
| `score.mjs` + `analyze.mjs` | Loads each page in headless Chrome with the app's bridge, records script errors, triggers Export GLB, and measures the mesh (parts, triangles, and for prints: closed surfaces, floating parts, base contact, overhangs, thin walls, size vs request). |
| `select_sft.py` | Rejection sampling: best verified sample per prompt, answer trimmed to the HTML. Print samples must match the requested size. |
| `train.py` | `mlx_lm.lora` with two patches needed for long examples on Qwen3.5 (below). |
| `compare.py` | Markdown table of base vs tuned scores. |
| `mlx_to_hf.py` | Converts a fused MLX checkpoint back to Hugging Face layout (for publishing and GGUF conversion). |

## Training Qwen3.5 on long sequences with mlx-lm

Qwen3.5 mixes full attention with Gated DeltaNet linear attention. In training mode mlx-lm runs that recurrence one token
at a time, which exhausts Metal's buffer limit on 10k+ token examples. `chunked_gdn.py` replaces it during training with
the chunkwise (WY) form: blocks of 128 tokens computed with matrix products, sequential only across blocks, and the
triangular inverse done by recursive block inversion (stable, unlike a power series). It matches mlx-lm's reference to
about 1e-6 in outputs, state and gradients.

`chunked_loss.py` computes cross-entropy over the 248k-token vocabulary in 1,024-token slices with checkpointing, so full
logits for a whole example never sit in memory.

On a 48 GB M4 Pro an 8k-token step takes about 69 s at about 21 GB peak.

## Usage

```sh
cd finetune
uv venv -p 3.12 .venv && uv pip install --python .venv/bin/python mlx-lm==0.32.2 safetensors
(cd tools && npm install)        # playwright + three for the scorer; uses your installed Google Chrome
MODELS_DIR=~/models/glb-3d-coder tools/pipeline.sh
```

`MODELS_DIR` must contain `mlx-4bit` (generation) and `mlx-bf16` (training base). Create them with
`../tools/model/setup_local_model.sh`, then `mlx_lm.convert --dtype bfloat16` for the bf16 copy.

Prompts: `eval/prompts.jsonl` (50 held-out test prompts) and `data/train_prompts.jsonl` (242 training prompts).
