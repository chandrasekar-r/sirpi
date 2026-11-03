"""Markdown comparison of two scored eval runs: compare.py BASE_DIR TUNED_DIR"""
import json, sys

def load(d):
    return {json.loads(l)["id"]: json.loads(l) for l in open(f"{d}/scores.jsonl") if l.strip()}

def stats(rows, mode):
    rows = [r for r in rows.values() if r.get("mode") == mode]
    n = len(rows) or 1
    pct = lambda f: f"{100 * sum(1 for r in rows if f(r)) / n:.0f}%"
    avg = lambda k: sum(r.get(k, 0) or 0 for r in rows) / n
    out = {
        "Works end to end (loads, no errors, valid GLB)": pct(lambda r: r.get("ok")),
        "No script errors": pct(lambda r: r.get("loads") and not r.get("errors")),
        "GLB exported": pct(lambda r: r.get("exported")),
        "Avg output tokens": f"{avg('tokens'):,.0f}",
        "Avg parts (meshes)": f"{avg('meshes'):.1f}",
        "Avg triangles": f"{avg('triangles'):,.0f}",
    }
    if mode == "print":
        scored = [r for r in rows if r.get("printScore") is not None]
        out["Avg print score (0-100, failed = 0)"] = f"{sum(r.get('printScore', 0) for r in rows) / n:.1f}"
        out["Single connected piece"] = pct(lambda r: r.get("clusters") == 1)
        out["Closed surfaces (avg)"] = f"{sum(r.get('closed', 0) for r in scored) / max(1, len(scored)):.2f}"
        out["Size within 30% of request"] = pct(lambda r: r.get("sizeRatio") and 0.7 <= r["sizeRatio"] <= 1.3)
    return out

base, tuned = load(sys.argv[1]), load(sys.argv[2])
print(f"# Base vs tuned ({sys.argv[1]} vs {sys.argv[2]})\n")
for mode in ("game", "print"):
    b, t = stats(base, mode), stats(tuned, mode)
    print(f"## {mode.title()} prompts ({sum(1 for r in base.values() if r.get('mode') == mode)})\n")
    print("| Metric | Base | Tuned |\n|---|---|---|")
    for k in b:
        print(f"| {k} | {b[k]} | {t[k]} |")
    print()
fixed = [i for i in base if not base[i].get("ok") and tuned.get(i, {}).get("ok")]
broke = [i for i in base if base[i].get("ok") and not tuned.get(i, {}).get("ok")]
print(f"Fixed by tuning: {len(fixed)} {fixed}\n\nBroken by tuning: {len(broke)} {broke}")
