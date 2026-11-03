"""Rebuild HF safetensors for the Qwen3.5 GLB coder from its GGUF, inverting llama.cpp's
convert_hf_to_gguf transforms for qwen35 (see conversion/qwen.py):
  A_log -> -exp(A_log); dt_bias -> dt_proj.bias; conv1d squeezed; non-linear-attn norms +1;
  V heads reordered grouped->tiled in in_proj_qkv(v rows), in_proj_z, in_proj_a/b, A_log, dt_bias,
  conv1d(v channels), out_proj(columns).
usage: gguf_to_hf.py <model.gguf> <hf_template_dir> <out_dir>
"""
import json, shutil, sys, re
from pathlib import Path
import numpy as np
import gguf
from gguf.quants import dequantize
from safetensors.numpy import save_file

src, tdir, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
cfg = json.load(open(tdir / "config.json")); tc = cfg["text_config"]
shapes = json.load(open(tdir / "shapes.json"))
NK, NV = tc["linear_num_key_heads"], tc["linear_num_value_heads"]
HK, HV = tc["linear_key_head_dim"], tc["linear_value_head_dim"]
R = NV // NK
nlayers = tc["num_hidden_layers"]

tmap = gguf.get_tensor_name_map(gguf.MODEL_ARCH.QWEN35, nlayers)

def hf_short(hf):  # name as the converter sees it before mapping
    s = hf.replace("model.language_model.", "model.")
    if s.endswith(".dt_bias"): s = s[:-len(".dt_bias")] + ".dt_proj.bias"
    return s

hf_names = [k for k in shapes if "visual" not in k and "mtp" not in k]
g2h = {}
for hf in hf_names:
    s = hf_short(hf)
    base, suffix = (s.rsplit(".", 1) if s.endswith((".weight", ".bias")) else (s, ""))
    g = tmap.get_name(base, try_suffixes=()) if not suffix else tmap.get_name(base)
    if g is None:
        g = tmap.get_name(s, try_suffixes=(".weight", ".bias"))
        if g is None: raise SystemExit(f"no gguf name for {hf}")
    else:
        g = g + ("." + suffix if suffix else "")
    g2h[g] = hf

def untile(x, axis, hd):
    """inverse of llama.cpp _reorder_v_heads (grouped->tiled): tiled [R, NK, hd] -> grouped [NK, R, hd]"""
    x = np.moveaxis(x, axis, 0)
    sh = x.shape
    x = x.reshape(R, NK, hd, *sh[1:]).swapaxes(0, 1).reshape(sh)
    return np.ascontiguousarray(np.moveaxis(x, 0, axis))

r = gguf.GGUFReader(str(src))
tensors = {}
for t in r.tensors:
    hf = g2h.get(t.name)
    if hf is None: raise SystemExit(f"unmapped gguf tensor {t.name}")
    a = dequantize(t.data, t.tensor_type).astype(np.float32)
    want = shapes[hf]["shape"]
    a = a.reshape([int(x) for x in reversed(t.shape)]) if a.size == np.prod(want) else a
    n = hf
    if "linear_attn." in n:
        if n.endswith("in_proj_qkv.weight"):
            qk = 2 * NK * HK
            a = np.concatenate([a[:qk], untile(a[qk:], 0, HV)], 0)
        elif n.endswith("in_proj_z.weight"): a = untile(a, 0, HV)
        elif n.endswith(("in_proj_a.weight", "in_proj_b.weight")): a = untile(a, 0, 1)
        elif n.endswith((".A_log", ".dt_bias")): a = untile(a.reshape(-1), 0, 1)
        elif n.endswith("conv1d.weight"):
            a = a.reshape(a.shape[0], -1) if a.ndim == 2 else a
            qk = 2 * NK * HK
            a = np.concatenate([a[:qk], untile(a[qk:], 0, HV)], 0)
        elif n.endswith("out_proj.weight"): a = untile(a, 1, HV)
    if n.endswith(".A_log"): a = np.log(-a)
    if n.endswith("norm.weight") and not n.endswith("linear_attn.norm.weight"): a = a - 1.0
    a = a.reshape(want)
    tensors[n] = a.astype(np.float32 if a.ndim == 1 else np.float16) if False else a.astype(np.float32)
    print(f"{t.name:40s} {t.tensor_type.name:6s} -> {n} {list(a.shape)}")

missing = set(hf_names) - set(tensors)
print("missing:", missing)
# bf16 via float32 -> upper 16 bits isn't available in numpy; store fp32 shards (mlx_lm.convert casts).
items = sorted(tensors.items()); shard, size, idx, shards = {}, 0, {}, []
def flush():
    global shard, size
    if not shard: return
    name = f"model-{len(shards)+1:05d}.safetensors"; save_file(shard, str(out / name), metadata={"format": "pt"})
    for k in shard: idx[k] = name
    shards.append(name); shard, size = {}, 0
for k, v in items:
    shard[k] = v; size += v.nbytes
    if size > 4_000_000_000: flush()
flush()
json.dump({"metadata": {}, "weight_map": idx}, open(out / "model.safetensors.index.json", "w"), indent=1)
for f in ["config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "preprocessor_config.json", "video_preprocessor_config.json"]:
    if (tdir / f).exists(): shutil.copy(tdir / f, out / f)
print("wrote", out)
