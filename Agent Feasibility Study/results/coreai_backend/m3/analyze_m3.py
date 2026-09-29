"""Summarize the Docs/18 M3 MLX-vs-Core AI runs into markdown tables.

Usage: python3 analyze_m3.py   (from this directory, after run_m3.sh)
"""
import glob
import json
import os
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))
BACKENDS = ["mlx", "coreai"]


def load(path):
    with open(path) as f:
        return json.load(f)


def model_bench():
    print("## model-bench (greedy, thinking off, 256-token cap, median of 3 cold trials)\n")
    reports = {}
    for path in glob.glob(os.path.join(HERE, "model_bench", "model_bench_*.json")):
        r = load(path)
        reports["coreai" if r["modelIdentifier"].startswith("coreai") else "mlx"] = r
    if len(reports) < 2:
        print("(missing model-bench output)\n")
        return
    print("| metric | MLX | Core AI |\n|---|---|---|")
    m, c = reports["mlx"], reports["coreai"]
    print(f"| load (warm on-disk cache) | {m['loadMs']/1000:.1f} s | {c['loadMs']/1000:.1f} s |")
    print(f"| peak phys_footprint | {m['peakFootprintBytes']/2**30:.2f} GB | {c['peakFootprintBytes']/2**30:.2f} GB |")
    cases_m = {x["name"]: x for x in m["cases"]}
    cases_c = {x["name"]: x for x in c["cases"]}
    for name in ["short", "production", "long"]:
        a, b = cases_m[name]["median"], cases_c[name]["median"]
        print(f"| {name} ({a['promptTokens']} tok) TTFT | {a['ttftMs']/1000:.2f} s | {b['ttftMs']/1000:.2f} s |")
        print(f"| {name} prefill | {a['prefillTokensPerSecond']:.0f} tok/s | {b['prefillTokensPerSecond']:.0f} tok/s |")
        print(f"| {name} decode | {a['decodeTokensPerSecond']:.1f} tok/s | {b['decodeTokensPerSecond']:.1f} tok/s |")
    a, b = cases_m["production-repeat"]["median"], cases_c["production-repeat"]["median"]
    print(f"| same context, new session: TTFT | {a['ttftMs']/1000:.2f} s | {b['ttftMs']/1000:.2f} s |")
    print(f"| follow-up turn, same session: TTFT | {m['multiTurnMedianFollowUpTTFTMs']/1000:.2f} s | "
          f"{c['multiTurnMedianFollowUpTTFTMs']/1000:.2f} s |")
    print()


def is_malformed(row):
    text = row["answerText"].strip()
    return text.startswith("{") and '"action"' in text


def bench(depth):
    print(f"## bench --force-depth {depth} (55 questions)\n")
    print("| metric | MLX | Core AI |\n|---|---|---|")
    stats = {}
    for b in BACKENDS:
        d = os.path.join(HERE, f"bench_d{depth}_{b}")
        rows_path = os.path.join(d, "routing_benchmark.jsonl")
        if not os.path.exists(rows_path):
            stats[b] = None
            continue
        rows = [json.loads(l) for l in open(rows_path) if l.strip()]
        summary = load(os.path.join(d, "routing_benchmark_summary.json"))
        lat = sorted(r["latencyMs"] for r in rows if r["outcome"] != "error")
        outcomes = {}
        for r in rows:
            outcomes[r["outcome"]] = outcomes.get(r["outcome"], 0) + 1
        stats[b] = {
            "n": len(rows),
            "load": summary.get("modelLoadMs"),
            "p50": statistics.median(lat) if lat else 0,
            "p95": lat[min(len(lat) - 1, int(len(lat) * 0.95))] if lat else 0,
            "total": sum(r["latencyMs"] for r in rows),
            "outcomes": outcomes,
            "toolcall_rows": sum(1 for r in rows if (r.get("numTurns") or 0) > 0),
            "malformed": [r["id"] for r in rows if is_malformed(r)],
            "errors": [r["id"] for r in rows if r["outcome"] == "error"],
            "claims": sum(r["claimCount"] for r in rows),
        }
    if not all(stats.values()):
        print("(missing bench output)\n")
        return stats
    m, c = stats["mlx"], stats["coreai"]
    fmt = lambda s: ", ".join(f"{k}={v}" for k, v in sorted(s["outcomes"].items()))
    print(f"| model load (once) | {m['load']/1000:.1f} s | {c['load']/1000:.1f} s |")
    print(f"| latency p50 / p95 | {m['p50']/1000:.1f} / {m['p95']/1000:.1f} s | {c['p50']/1000:.1f} / {c['p95']/1000:.1f} s |")
    print(f"| total wall-clock | {m['total']/60000:.1f} min | {c['total']/60000:.1f} min |")
    print(f"| outcomes | {fmt(m)} | {fmt(c)} |")
    if depth == 2:
        print(f"| questions with ≥1 real tool call | {m['toolcall_rows']}/{m['n']} | {c['toolcall_rows']}/{c['n']} |")
    print(f"| malformed action (raw JSON as answer) | {len(m['malformed'])} | {len(c['malformed'])} |")
    print(f"| claims recorded | {m['claims']} | {c['claims']} |")
    print(f"| errors | {len(m['errors'])} | {len(c['errors'])} |")
    print()
    return stats


def teach():
    print("## teach bench --pairwise (15 gold items, k = 3)\n")
    out = {}
    for b in BACKENDS:
        d = os.path.join(HERE, f"teach_{b}")
        try:
            out[b] = (load(os.path.join(d, "teaching_calibration_summary.json")),
                      load(os.path.join(d, "teaching_calibration_run.json")))
        except FileNotFoundError:
            out[b] = None
    if not all(out.values()):
        print("(missing teach output)\n")
        return
    (ms, mr), (cs, cr) = out["mlx"], out["coreai"]
    print("| metric | MLX | Core AI |\n|---|---|---|")
    for key, label in [("kappaOverall", "per-criterion κ"), ("kappaConfidentOnly", "κ (grader-confident)"),
                       ("verdictAccuracy", "verdict-tier accuracy"), ("scoreMAE", "score MAE"),
                       ("splitVoteFraction", "split-vote fraction")]:
        print(f"| {label} | {ms[key]:.3f} | {cs[key]:.3f} |")
    print(f"| disputed items (pairwise tripwire) | {ms['disputedItems']} | {cs['disputedItems']} |")
    print(f"| unparseable judge replies | {mr['unparseableJudgeOutputs']}/{mr['judgeCalls']} | "
          f"{cr['unparseableJudgeOutputs']}/{cr['judgeCalls']} |")
    print(f"| wall-clock | {mr['wallClockSeconds']/60:.1f} min | {cr['wallClockSeconds']/60:.1f} min |")
    print()


if __name__ == "__main__":
    model_bench()
    bench(2)
    bench(1)
    teach()
