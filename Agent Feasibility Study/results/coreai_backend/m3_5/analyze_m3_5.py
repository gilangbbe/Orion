"""Docs/18 M3.5 gate: Core AI native tool calling vs M3's Core AI JSON-action and MLX baselines.

Usage: python3 analyze_m3_5.py   (from anywhere, after run_m3_5.sh)
"""
import json
import os
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))
M3 = os.path.join(HERE, "..", "m3")
RUNS = [
    ("MLX json (M3)", os.path.join(M3, "bench_d2_mlx")),
    ("Core AI json (M3)", os.path.join(M3, "bench_d2_coreai")),
    ("Core AI native (M3.5)", os.path.join(HERE, "bench_d2_coreai_native")),
]


def no_answer(row):
    """The answer is protocol debris, not prose: a raw JSON action (M3's slip), leftover
    `<tool_call>` markup, or nothing at all (a dropped malformed native call)."""
    text = row["answerText"].strip()
    return (
        not text
        or (text.startswith("{") and '"action"' in text)
        or "<tool_call>" in text
    )


def stats(path):
    rows_path = os.path.join(path, "routing_benchmark.jsonl")
    if not os.path.exists(rows_path):
        return None
    rows = [json.loads(line) for line in open(rows_path) if line.strip()]
    lat = sorted(r["latencyMs"] for r in rows if r["outcome"] != "error")
    outcomes = {}
    for r in rows:
        outcomes[r["outcome"]] = outcomes.get(r["outcome"], 0) + 1
    calls = [r.get("numTurns") or 0 for r in rows]
    return {
        "n": len(rows),
        "p50": statistics.median(lat) if lat else 0,
        "p95": lat[min(len(lat) - 1, int(len(lat) * 0.95))] if lat else 0,
        "total": sum(r["latencyMs"] for r in rows),
        "outcomes": outcomes,
        "toolcall_rows": sum(1 for c in calls if c > 0),
        "mean_calls": statistics.mean(calls) if calls else 0,
        "no_answer": [r["id"] for r in rows if no_answer(r)],
        "partial": sum(1 for r in rows if r.get("partial")),
        "errors": [r["id"] for r in rows if r["outcome"] == "error"],
        "claims": sum(r["claimCount"] for r in rows),
    }


def main():
    runs = [(name, stats(path)) for name, path in RUNS]
    present = [(n, s) for n, s in runs if s]
    print("## bench --force-depth 2 (55 questions)\n")
    print("| metric | " + " | ".join(n for n, _ in present) + " |")
    print("|---|" + "---|" * len(present))
    row = lambda label, f: print(f"| {label} | " + " | ".join(f(s) for _, s in present) + " |")
    row("latency p50 / p95", lambda s: f"{s['p50']/1000:.1f} / {s['p95']/1000:.1f} s")
    row("total wall-clock", lambda s: f"{s['total']/60000:.1f} min")
    row("questions with ≥ 1 real tool call", lambda s: f"{s['toolcall_rows']}/{s['n']}")
    row("mean tool calls per question", lambda s: f"{s['mean_calls']:.2f}")
    row("no answer (raw JSON / `<tool_call>` / empty)", lambda s: str(len(s["no_answer"])))
    row("partial", lambda s: str(s["partial"]))
    row("outcomes", lambda s: ", ".join(f"{k} {v}" for k, v in sorted(s["outcomes"].items())))
    row("claims recorded", lambda s: str(s["claims"]))
    row("errors", lambda s: str(len(s["errors"])))
    print()

    native = dict(runs).get("Core AI native (M3.5)")
    if not native:
        print("(native run missing)")
        return
    for name, s in present:
        if s["no_answer"]:
            print(f"- {name} no-answer ids: {', '.join(s['no_answer'])}")
        if s["errors"]:
            print(f"- {name} error ids: {', '.join(s['errors'])}")
    mlx, cj = dict(runs)["MLX json (M3)"], dict(runs)["Core AI json (M3)"]
    print("\n## M3.5 gate (hand-graded score checked separately)\n")
    checks = [
        ("≥ 1 real tool call ≥ MLX", native["toolcall_rows"] >= mlx["toolcall_rows"],
         f"{native['toolcall_rows']} vs {mlx['toolcall_rows']}"),
        ("no-answer ≤ MLX", len(native["no_answer"]) <= len(mlx["no_answer"]),
         f"{len(native['no_answer'])} vs {len(mlx['no_answer'])}"),
        ("p50 ≤ Core AI json", native["p50"] <= cj["p50"],
         f"{native['p50']/1000:.1f} vs {cj['p50']/1000:.1f} s"),
    ]
    for label, ok, detail in checks:
        print(f"- {'PASS' if ok else 'FAIL'} {label}: {detail}")


if __name__ == "__main__":
    main()
