"""Docs/18 M5 short run: guided-generation grading vs M4's text judges, same 6-item gold subset.

Usage: python3 analyze_m5.py   (after run_m5.sh)
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
M4 = os.path.join(HERE, "..", "m4")
RUNS = [
    ("8B text, thinking (M4)", os.path.join(M4, "teach_qwen3-8b-4bit_on")),
    ("8B text, no thinking (M4)", os.path.join(M4, "teach_qwen3-8b-4bit_off")),
    ("4B text, thinking (M4)", os.path.join(M4, "teach_qwen3-4b-4bit_on")),
    ("8B guided v1 (M5)", os.path.join(HERE, "v1_teach_guided_qwen3-8b-4bit")),
    ("4B guided v1 (M5)", os.path.join(HERE, "v1_teach_guided_qwen3-4b-4bit")),
    ("8B guided v2 (M5)", os.path.join(HERE, "teach_guided_qwen3-8b-4bit")),
    ("4B guided v2 (M5)", os.path.join(HERE, "teach_guided_qwen3-4b-4bit")),
]


def load(d):
    sp = os.path.join(d, "teaching_calibration_summary.json")
    if not os.path.exists(sp):
        return None
    rows = [json.loads(line) for line in open(os.path.join(d, "teaching_calibration.jsonl")) if line.strip()]
    return json.load(open(sp)), json.load(open(os.path.join(d, "teaching_calibration_run.json"))), rows


def met_rate(rows, kind):
    crit = [c for r in rows for c in r["criteria"] if c["kind"] == kind]
    return f"{sum(c['graderMet'] for c in crit)}/{len(crit)}"


def main():
    loaded = [(n, load(d)) for n, d in RUNS]
    print("## Grading: teach bench --pairwise, k=3, 6-item gold subset\n")
    print("| judge | κ | verdict accuracy | score MAE | 'met' on anti-criteria | graded | failed calls | disputed (strong FPs) | wall-clock |")
    print("|---|---|---|---|---|---|---|---|---|")
    for name, data in loaded:
        if not data:
            print(f"| {name} | (missing) ||||||||")
            continue
        s, run, rows = data
        strong_fp = sum(1 for r in rows if r.get("disputed") and r["id"].endswith("-strong"))
        print(f"| {name} | {s['kappaOverall']:.3f} | {s['verdictAccuracy']:.2f} | {s['scoreMAE']:.3f} | "
              f"{met_rate(rows, 'anti')} | {s['gradedItems']}/{s['goldItems']} | "
              f"{run.get('failedJudgeCalls', '—')} | {s['disputedItems']} ({strong_fp} of 2) | "
              f"{run['wallClockSeconds']/60:.1f} min |")
    ref = next((d for _, d in loaded if d), None)
    if ref:
        anti = [c for r in ref[2] for c in r["criteria"] if c["kind"] == "anti"]
        print(f"\nExpert: {sum(c['expertLabel'] == 'met' for c in anti)}/{len(anti)} anti-criteria met "
              "(the answers that actually hold the misconception).")
    print("\nVerdicts per item (⚑ = tripwire fired):\n")
    names = [n for n, d in loaded if d]
    table = {}
    for name, data in loaded:
        if not data:
            continue
        for r in data[2]:
            table.setdefault(r["id"], {"expert": r.get("expertVerdict")})[name] = (
                f"{r.get('graderVerdict')}{' ⚑' if r.get('disputed') else ''}")
    print("| item | expert | " + " | ".join(names) + " |")
    print("|---|---|" + "---|" * len(names))
    for item, cols in table.items():
        print(f"| {item} | {cols['expert']} | " + " | ".join(cols.get(n, "—") for n in names) + " |")


if __name__ == "__main__":
    main()
