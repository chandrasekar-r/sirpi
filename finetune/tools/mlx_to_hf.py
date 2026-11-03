"""Converts an MLX Qwen3.5 checkpoint (e.g. a fused fine-tune) back to Hugging Face Transformers layout.

usage: mlx_to_hf.py <mlx_dir> <hf_template_dir> <out_dir>
Undoes mlx-lm's sanitize: key prefix, conv1d axis order, and the +1 shift on RMSNorm weights (all norms except the
linear-attention gated norm). Writes bf16 safetensors shards plus the template's config and tokenizer files.
"""
import glob, json, os, shutil, sys
import mlx.core as mx

src, tmpl, out = sys.argv[1:4]
w = {}
for f in sorted(glob.glob(os.path.join(src, "*.safetensors"))):
    w.update(mx.load(f))
if any(k.endswith(".scales") for k in w):
    sys.exit("quantized checkpoint: convert the bf16 one")

SHIFTED = ("input_layernorm.weight", "post_attention_layernorm.weight", "q_norm.weight", "k_norm.weight")
hf = {}
for k, v in w.items():
    nk = k.replace("language_model.model.", "model.language_model.", 1)
    if k.startswith("language_model.lm_head"):
        nk = k.replace("language_model.lm_head", "lm_head", 1)
    if nk.endswith("conv1d.weight"):
        v = mx.moveaxis(v, -1, 1)
    if nk.endswith(SHIFTED) or nk == "model.language_model.norm.weight":
        v = (v.astype(mx.float32) - 1.0)
    hf[nk] = v.astype(mx.bfloat16)

os.makedirs(out, exist_ok=True)
keys = sorted(hf)
shard, size, shards, limit = {}, 0, [], 4_000_000_000
for k in keys:
    n = hf[k].nbytes
    if shard and size + n > limit:
        shards.append(shard); shard, size = {}, 0
    shard[k] = hf[k]; size += n
shards.append(shard)
index = {"metadata": {"total_size": sum(v.nbytes for v in hf.values())}, "weight_map": {}}
for i, s in enumerate(shards):
    name = f"model-{i + 1:05d}-of-{len(shards):05d}.safetensors"
    mx.save_safetensors(os.path.join(out, name), s, metadata={"format": "pt"})
    for k in s:
        index["weight_map"][k] = name
json.dump(index, open(os.path.join(out, "model.safetensors.index.json"), "w"), indent=2)
for f in os.listdir(tmpl):
    if f.endswith((".json", ".jinja", ".txt", ".model")) and f not in ("model.safetensors.index.json", "shapes.json"):
        shutil.copy(os.path.join(tmpl, f), os.path.join(out, f))
cfg = json.load(open(os.path.join(out, "config.json")))
cfg["torch_dtype"] = "bfloat16"
if "text_config" in cfg:
    cfg["text_config"]["torch_dtype"] = "bfloat16"
json.dump(cfg, open(os.path.join(out, "config.json"), "w"), indent=2)
print(f"wrote {len(hf)} tensors in {len(shards)} shards to {out}")
