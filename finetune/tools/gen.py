"""Batched generation with mlx-lm, using the same ChatML prompt AssetForge builds.

usage: gen.py --model DIR --prompts FILE.jsonl --out DIR [--samples N] [--batch B] [--thinking 0|1]
              [--max-tokens N] [--temp T] [--only ID,ID] [--adapter DIR]

Writes <out>/<id>_s<k>.txt (raw output), <id>_s<k>.html (extracted page) and gen.jsonl (one row per sample).
Samples that already exist are skipped, so an interrupted run resumes where it stopped.
"""
import argparse, json, os, re, sys, time

import mlx.core as mx
from mlx_lm import load, batch_generate
from mlx_lm.sample_utils import make_sampler

GAME_SYSTEM = (
    "Create game assets for the Godot editor, which uses GLB files. Create whatever the user requests as a good-quality "
    "low-poly asset using only Three.js in one complete standalone HTML file. The HTML must show the asset and include an "
    "Export GLB button that downloads a working GLB. If the requested asset needs animation, add it and include the "
    "animation in the exported GLB; otherwise make it static."
)

PRINT_SYSTEM = (
    "Create objects for FDM 3D printing (Bambu Lab printer, 256 mm build plate) using only Three.js in one complete "
    "standalone HTML file. Model the requested object at its real size in millimetres (1 unit = 1 mm) as one solid, "
    "watertight piece: parts must overlap so they fuse, nothing may float, it must stand on a flat base resting on y = 0, "
    "walls must be at least 2 mm thick, and overhangs should stay under 45 degrees where possible. The HTML must show the "
    "object, state its size in mm, and include an Export GLB button that downloads a working GLB of the object only."
)

SYSTEMS = {"game": GAME_SYSTEM, "print": PRINT_SYSTEM}


def chatml(system, user, thinking):
    s = f"<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n"
    return s + ("<think>\n" if thinking else "<think>\n\n</think>\n\n")


def extract_html(text):
    m = re.search(r"```html", text, re.I) or re.search(r"```", text)
    if m:
        body = text[m.end():]
        end = body.find("\n```")
        if end >= 0:
            body = body[:end]
        body = body.strip()
        if "<html" in body.lower() or "<script" in body.lower():
            return body
    m = re.search(r"<!doctype|<html", text, re.I)
    if m:
        body = text[m.start():]
        end = body.lower().rfind("</html>")
        return body[: end + 7] if end >= 0 else body
    return None


def run_chunk(model, tok, chunk, a, sampler):
    """Generates one chunk; on a Metal error, frees memory and retries the chunk in halves (never kills the run)."""
    prompts = [tok.encode(chatml(SYSTEMS[r["mode"]], r["prompt"], a.thinking)) for _, r in chunk]
    try:
        res = batch_generate(model, tok, prompts, max_tokens=a.max_tokens, sampler=sampler,
                             completion_batch_size=len(prompts), prefill_batch_size=len(prompts))
        return res.texts
    except RuntimeError as e:
        mx.clear_cache()
        if len(chunk) == 1:
            print(f"giving up on {chunk[0][0]}: {e}", flush=True)
            return [""]
        print(f"GPU error on a chunk of {len(chunk)} ({e}); retrying in halves", flush=True)
        h = len(chunk) // 2
        return run_chunk(model, tok, chunk[:h], a, sampler) + run_chunk(model, tok, chunk[h:], a, sampler)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--adapter", default=None)
    ap.add_argument("--prompts", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--samples", type=int, default=1)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--thinking", type=int, default=0)
    ap.add_argument("--max-tokens", type=int, default=16000)
    ap.add_argument("--temp", type=float, default=0.8)
    ap.add_argument("--only", default="")
    ap.add_argument("--chunk", type=int, default=0,
                    help="prompts handed to the batcher at once (default 4x batch). Finished sequences free their slot "
                         "for the next prompt, so a larger chunk wastes less time waiting on the longest answer.")
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    rows = [json.loads(l) for l in open(a.prompts) if l.strip()]
    if a.only:
        keep = set(a.only.split(","))
        rows = [r for r in rows if r["id"] in keep]
    jobs = []
    for r in rows:
        for k in range(a.samples):
            name = f"{r['id']}_s{k}"
            if not os.path.exists(os.path.join(a.out, name + ".txt")):
                jobs.append((name, r))
    print(f"{len(jobs)} samples to generate", flush=True)
    if not jobs:
        return

    model, tok = load(a.model, adapter_path=a.adapter)
    sampler = make_sampler(temp=a.temp, top_p=0.95, top_k=40)
    log = open(os.path.join(a.out, "gen.jsonl"), "a")
    total_tokens, t_all = 0, time.time()
    # One chunk per batch: refilling slots across bigger chunks exhausted Metal's buffer limit after ~2 h.
    step = a.chunk or a.batch
    for i in range(0, len(jobs), step):
        chunk = jobs[i : i + step]
        t0 = time.time()
        texts = run_chunk(model, tok, chunk, a, sampler)
        dt = time.time() - t0
        for (name, r), text in zip(chunk, texts):
            ntok = len(tok.encode(text))
            total_tokens += ntok
            open(os.path.join(a.out, name + ".txt"), "w").write(text)
            html = extract_html(text.split("</think>")[-1])
            if html:
                open(os.path.join(a.out, name + ".html"), "w").write(html)
            log.write(json.dumps({"name": name, "id": r["id"], "mode": r["mode"], "prompt": r["prompt"],
                                  "tokens": ntok, "batch_seconds": round(dt, 1), "has_html": bool(html),
                                  "thinking": a.thinking}) + "\n")
            log.flush()
        el = time.time() - t_all
        print(f"[{i + len(chunk)}/{len(jobs)}] batch {dt:.0f}s · {total_tokens / el:.0f} tok/s overall · "
              f"peak {mx.get_peak_memory() / 1e9:.1f} GB", flush=True)
        mx.clear_cache()


if __name__ == "__main__":
    main()
