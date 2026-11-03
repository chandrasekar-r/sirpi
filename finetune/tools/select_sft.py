"""Builds the fine-tuning set from scored generations (rejection sampling: keep the best verified attempt per prompt).

usage: select_sft.py --runs RUN_DIR [RUN_DIR...] --out data/sft [--min-print 70] [--valid 0.1]

Game samples qualify when the page loads with no script errors, Export GLB produces a valid GLB, the output was not cut
off, and the asset has some structure (6+ meshes). Print samples additionally need printScore >= --min-print.
The assistant turn is just the fenced HTML, so the model also learns to skip prose before the code.
"""
import argparse, json, math, os, random, re, sys

sys.path.insert(0, os.path.dirname(__file__))
from gen import SYSTEMS, extract_html  # noqa: E402


def quality(r):
    if r["mode"] == "print":
        return r.get("printScore", 0) + 0.5 * math.log1p(r.get("meshes", 0))
    return math.log1p(r.get("meshes", 0)) + 0.5 * math.log1p(r.get("triangles", 0)) + 0.1 * min(r.get("colors", 0), 12)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", nargs="+", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--min-print", type=float, default=70)
    ap.add_argument("--valid", type=float, default=0.1)
    ap.add_argument("--max-tokens", type=int, default=15500)
    ap.add_argument("--size-tol", type=float, default=1.6,
                    help="print samples must be within this factor of the size the prompt asks for (baseline mostly built "
                         "at game scale, ~1%% of the requested mm, and training on those would teach the wrong scale)")
    ap.add_argument("--print-repeat", type=int, default=2, help="copies of each print example (rarer than game ones)")
    a = ap.parse_args()

    best, seen = {}, {}
    for run in a.runs:
        for line in open(os.path.join(run, "scores.jsonl")):
            r = json.loads(line)
            r["run"] = run
            seen.setdefault(r["id"], []).append(r)
            if not r.get("ok") or r.get("tokens", 0) > a.max_tokens or r.get("meshes", 0) < 6:
                continue
            if r["mode"] == "print":
                if r.get("printScore", 0) < a.min_print:
                    continue
                ratio = r.get("sizeRatio")
                if ratio is not None and not (1 / a.size_tol <= ratio <= a.size_tol):
                    continue
            if r["id"] not in best or quality(r) > quality(best[r["id"]]):
                best[r["id"]] = r

    rows = []
    for pid, r in sorted(best.items()):
        html = open(os.path.join(r["run"], r["name"] + ".html")).read().strip()
        rows.append({"id": pid, "mode": r["mode"], "messages": [
            {"role": "system", "content": SYSTEMS[r["mode"]]},
            {"role": "user", "content": r["prompt"]},
            {"role": "assistant", "content": "```html\n" + html + "\n```"},
        ]})
    random.Random(0).shuffle(rows)
    nv = max(2, int(len(rows) * a.valid))
    # Repeat print examples in the training split only, so validation stays one copy per prompt.
    train = rows[nv:] + [r for r in rows[nv:] if r["mode"] == "print"] * (a.print_repeat - 1)
    random.Random(1).shuffle(train)
    os.makedirs(a.out, exist_ok=True)
    for name, part in (("valid", rows[:nv]), ("train", train)):
        with open(os.path.join(a.out, f"{name}.jsonl"), "w") as f:
            for row in part:
                f.write(json.dumps({"messages": row["messages"]}) + "\n")
    by = lambda m: sum(1 for r in rows if r["mode"] == m)
    tot = lambda m: sum(1 for k, v in seen.items() if v[0]["mode"] == m)
    stats = {"prompts_game": tot("game"), "kept_game": by("game"), "prompts_print": tot("print"), "kept_print": by("print"),
             "train": len(train), "valid": nv}
    json.dump(stats, open(os.path.join(a.out, "stats.json"), "w"), indent=2)
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
