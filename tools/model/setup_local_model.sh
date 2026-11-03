#!/bin/zsh
# Sets up the local 3D Coder for Sirpi: downloads ccore/Qwen3.5-4B-GLB-3D-Coder (GGUF, Apache-2.0), rebuilds
# Hugging Face weights from it, and converts them to MLX 4-bit (and optionally 6-bit) in ~/models/glb-3d-coder.
# Needs: uv (https://docs.astral.sh/uv/), about 20 GB free disk during conversion. Usage: setup_local_model.sh [--6bit]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${MODELS_DIR:-$HOME/models/glb-3d-coder}"
WORK="$DEST/.convert"
mkdir -p "$DEST" "$WORK"
cd "$WORK"

print "1/5 Python environment"
[[ -x .venv/bin/python ]] || uv venv -q -p 3.12 .venv
uv pip install -q --python .venv/bin/python "mlx-lm==0.32.2" gguf safetensors numpy huggingface_hub

print "2/5 Downloading the GGUF (4.2 GB) and tokenizer"
.venv/bin/hf download ccore/Qwen3.5-4B-GLB-3D-Coder Qwen3.5-4B-GLB-3D-Coder-Q8_0.gguf --local-dir "$DEST"
cp -R "$HERE/template/." template/
.venv/bin/hf download ccore/Qwen3.5-4B-3D-Coder tokenizer.json --local-dir template

print "3/5 Rebuilding Hugging Face weights from the GGUF"
.venv/bin/python "$HERE/gguf_to_hf.py" "$DEST/Qwen3.5-4B-GLB-3D-Coder-Q8_0.gguf" template hf

print "4/5 Converting to MLX 4-bit"
rm -rf "$DEST/mlx-4bit"
.venv/bin/mlx_lm.convert --hf-path hf --mlx-path "$DEST/mlx-4bit" -q --q-bits 4 --q-group-size 64
if [[ "${1:-}" == "--6bit" ]]; then
  rm -rf "$DEST/mlx-6bit"
  .venv/bin/mlx_lm.convert --hf-path hf --mlx-path "$DEST/mlx-6bit" -q --q-bits 6 --q-group-size 64
fi

print "5/5 Cleaning up"
rm -rf hf
print "Done. In Sirpi open Settings > Local Model and pick \"MLX 4-bit\"."
