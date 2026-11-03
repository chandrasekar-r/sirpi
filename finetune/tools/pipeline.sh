#!/bin/zsh
# Full self-improvement run: baseline -> self-generated data -> verify -> LoRA -> fuse/quantize -> re-evaluate.
# Every stage skips itself when its output exists, so re-running resumes after an interruption.
set -e
cd "$(dirname "$0")/.."
# Model folders (mlx-4bit, mlx-bf16, outputs) live in MODELS_DIR, by default the parent of this finetune folder.
MODELS_DIR="${MODELS_DIR:-..}"
PY=.venv/bin/python
log() { print "[$(date '+%m-%d %H:%M')] $*"; }

log "1/7 baseline generation"
$PY tools/gen.py --model $MODELS_DIR/mlx-4bit --prompts eval/prompts.jsonl --out runs/base-4bit --batch 16 --max-tokens 16000 2>&1 | grep -v -i warning
[[ -f runs/base-4bit/summary.json ]] || (cd tools && node score.mjs ../runs/base-4bit --concurrency 4 > ../runs/base-4bit/score.log 2>&1)
log "baseline: $(tr -d '\n ' < runs/base-4bit/summary.json | head -c 400)"

# Split the training prompts by purpose (print prompts get more attempts below).
[[ -f data/train_game.jsonl ]] || grep '"mode": "game"' data/train_prompts.jsonl > data/train_game.jsonl
[[ -f data/train_print.jsonl ]] || grep '"mode": "print"' data/train_prompts.jsonl > data/train_print.jsonl

log "2/7 training data generation (146 game prompts x 3, 96 print prompts x 6)"
# Print prompts get more attempts: few baseline prints came out at the requested mm size, and only those are kept.
$PY tools/gen.py --model $MODELS_DIR/mlx-4bit --prompts data/train_game.jsonl --out runs/train-a --samples 3 --batch 16 --max-tokens 16000 2>&1 | grep -v -i warning
$PY tools/gen.py --model $MODELS_DIR/mlx-4bit --prompts data/train_print.jsonl --out runs/train-a --samples 6 --batch 16 --max-tokens 16000 2>&1 | grep -v -i warning
[[ -f runs/train-a/summary.json ]] || (cd tools && node score.mjs ../runs/train-a --concurrency 4 > ../runs/train-a/score.log 2>&1)
log "training pool: $(tr -d '\n ' < runs/train-a/summary.json | head -c 400)"

log "3/7 select best verified sample per prompt"
$PY tools/select_sft.py --runs runs/train-a --out data/sft --min-print 70
N=$(wc -l < data/sft/train.jsonl | tr -d ' ')
ITERS=$(( N * 2 ))
log "train examples: $N -> $ITERS iterations"

log "4/7 LoRA training"
if [[ ! -f runs/lora/adapters.safetensors ]]; then
  sed -i '' "s/arguments: \[5.0e-5, [0-9]*, 5.0e-6\]/arguments: [5.0e-5, $ITERS, 5.0e-6]/" tools/lora.yaml
  GDN_CHUNK=128 $PY tools/train.py -c tools/lora.yaml --model $MODELS_DIR/mlx-bf16 --train --data data/sft \
    --iters $ITERS --adapter-path runs/lora 2>&1 | grep -v -i warning | tee runs/lora-train.log
fi

log "5/7 fuse and quantize"
[[ -d $MODELS_DIR/mlx-tuned-bf16 ]] || .venv/bin/mlx_lm.fuse --model $MODELS_DIR/mlx-bf16 --adapter-path runs/lora --save-path $MODELS_DIR/mlx-tuned-bf16 2>&1 | grep -v -i warning
[[ -d $MODELS_DIR/mlx-tuned-4bit ]] || .venv/bin/mlx_lm.convert --hf-path $MODELS_DIR/mlx-tuned-bf16 --mlx-path $MODELS_DIR/mlx-tuned-4bit -q --q-bits 4 --q-group-size 64 2>&1 | grep -v -i warning
[[ -d $MODELS_DIR/mlx-tuned-6bit ]] || .venv/bin/mlx_lm.convert --hf-path $MODELS_DIR/mlx-tuned-bf16 --mlx-path $MODELS_DIR/mlx-tuned-6bit -q --q-bits 6 --q-group-size 64 2>&1 | grep -v -i warning

log "6/7 evaluate tuned 4-bit"
$PY tools/gen.py --model $MODELS_DIR/mlx-tuned-4bit --prompts eval/prompts.jsonl --out runs/tuned-4bit --batch 16 --max-tokens 16000 2>&1 | grep -v -i warning
[[ -f runs/tuned-4bit/summary.json ]] || (cd tools && node score.mjs ../runs/tuned-4bit --concurrency 4 > ../runs/tuned-4bit/score.log 2>&1)

log "7/7 compare"
$PY tools/compare.py runs/base-4bit runs/tuned-4bit | tee runs/compare.md
log "done"
