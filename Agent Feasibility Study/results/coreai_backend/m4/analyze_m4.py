"""Docs/18 M4 short run: per-role Core AI model selection tables.

Usage: python3 analyze_m4.py   (after run_m4.sh)
"""
import glob
import json
import os
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))
M3_5 = os.path.join(HERE, "..", "m3_5", "bench_d2_coreai_native")
V8, V8KV, V4 = "qwen3-8b-4bit", "qwen3-8b-4bit_weights_8bit_kv_cache", "qwen3-4b-4bit"
SHORT = {V8: "8B", V8KV: "8B INT8-KV", V4: "4B"}
IDS = ["CU-05", "CU-08", "XF-04", "AR-02", "DC-01", "BR-02", "CD-01", "EV-01", "TE-02", "TR-03"]


def rows(path):
    p = os.path.join(path, "routing_benchmark.jsonl")
    if not os.path.exists(p):
        return None
    return [json.loads(line) for line in open(p) if line.strip()]


def model():
    print("## Raw runtime (model-bench, greedy, thinking off, 256-token cap, 1 trial)\n")
    print("| variant | load | peak footprint | prefill 4.9K tok | decode 725 / 4.9K / 18K tok | TTFT 18K |")
    print("|---|---|---|---|---|---|")
    for v in (V8, V8KV, V4):
        files = glob.glob(os.path.join(HERE, "model", f"model_bench_coreai_{v}.json"))
        if not files:
            print(f"| {SHORT[v]} | (missing) |||||")
            continue
        r = json.load(open(files[0]))
        c = {x["name"]: x["median"] for x in r["cases"]}
        print(f"| {SHORT[v]} | {r['loadMs']/1000:.1f} s | {r['peakFootprintBytes']/2**30:.2f} GB | "
              f"{c['production']['prefillTokensPerSecond']:.0f} tok/s | "
              f"{c['short']['decodeTokensPerSecond']:.1f} / {c['production']['decodeTokensPerSecond']:.1f} / "
              f"{c['long']['decodeTokensPerSecond']:.1f} tok/s | {c['long']['ttftMs']/1000:.1f} s |")
    print()


def no_answer(r):
    t = r["answerText"].strip()
    return not t or (t.startswith("{") and '"action"' in t) or "<tool_call>" in t


def answering(grades):
    print("## Answering: depth 2, native tools, 10 hand-graded questions\n")
    print("| config | p50 / max latency | total | tool call | mean calls | no answer | verified / partial / unverified | hand grade |")
    print("|---|---|---|---|---|---|---|---|")
    for v in (V8, V8KV, V4):
        for mode in ("on", "off"):
            name = f"{v}:{mode}"
            if name == f"{V8}:on":
                rs = [r for r in (rows(M3_5) or []) if r["id"] in IDS]
                src = " (M3.5)"
            else:
                rs = rows(os.path.join(HERE, f"answer_{v}_{mode}"))
                src = ""
            if not rs:
                print(f"| {SHORT[v]} think {mode} | (missing) |||||||")
                continue
            lat = sorted(r["latencyMs"] for r in rs)
            oc = {k: sum(1 for r in rs if r["outcome"] == k) for k in ("verified", "partially_verified", "unverified")}
            g = grades.get(name, {}).get("_score")
            print(f"| {SHORT[v]} think {mode}{src} | {statistics.median(lat)/1000:.0f} / {lat[-1]/1000:.0f} s | "
                  f"{sum(lat)/60000:.1f} min | {sum(1 for r in rs if (r.get('numTurns') or 0) > 0)}/{len(rs)} | "
                  f"{statistics.mean(r.get('numTurns') or 0 for r in rs):.1f} | {sum(no_answer(r) for r in rs)} | "
                  f"{oc['verified']} / {oc['partially_verified']} / {oc['unverified']} | "
                  f"{'%.1f / 20' % g if g is not None else '—'} |")
    print()


def teach():
    print("## Judging + comparing: teach bench --pairwise, k=3, 6-item gold subset\n")
    print("| config | κ (all) | raw agreement | verdict accuracy | score MAE | unparseable | disputed (strong-answer FPs) | wall-clock |")
    print("|---|---|---|---|---|---|---|---|")
    for v in (V8, V4):
        for mode in ("on", "off"):
            d = os.path.join(HERE, f"teach_{v}_{mode}")
            sp = os.path.join(d, "teaching_calibration_summary.json")
            if not os.path.exists(sp):
                print(f"| {SHORT[v]} think {mode} | (missing) |||||||")
                continue
            s = json.load(open(sp))
            run = json.load(open(os.path.join(d, "teaching_calibration_run.json")))
            calib = [json.loads(line) for line in open(os.path.join(d, "teaching_calibration.jsonl")) if line.strip()]
            strong_fp = sum(1 for r in calib if r.get("disputed") and r["id"].endswith("-strong"))
            print(f"| {SHORT[v]} think {mode} | {s['kappaOverall']:.3f} | {s['rawAgreementOverall']:.3f} | "
                  f"{s['verdictAccuracy']:.2f} | {s['scoreMAE']:.3f} | "
                  f"{run['unparseableJudgeOutputs']}/{run['judgeCalls']} | "
                  f"{s['disputedItems']} ({strong_fp} of 2) | {run['wallClockSeconds']/60:.1f} min |")
    print()
    print("Verdicts per item (grader vs expert):\n")
    names = []
    table = {}
    for v in (V8, V4):
        for mode in ("on", "off"):
            p = os.path.join(HERE, f"teach_{v}_{mode}", "teaching_calibration.jsonl")
            if not os.path.exists(p):
                continue
            names.append(f"{SHORT[v]} {mode}")
            for line in open(p):
                r = json.loads(line)
                table.setdefault(r["id"], {"expert": r.get("expertVerdict")})[names[-1]] = (
                    f"{r.get('graderVerdict')}{' ⚑' if r.get('disputed') else ''}")
    print("| item | expert | " + " | ".join(names) + " |")
    print("|---|---|" + "---|" * len(names))
    for item, cols in table.items():
        print(f"| {item} | {cols['expert']} | " + " | ".join(cols.get(n, "—") for n in names) + " |")
    print("\n⚑ = pairwise tripwire fired (disputed)\n")


if __name__ == "__main__":
    gp = os.path.join(HERE, "hand_grades.json")
    grades = json.load(open(gp)) if os.path.exists(gp) else {}
    if not grades.get(f"{V8}:on"):
        m35 = os.path.join(HERE, "..", "m3_5", "hand_grades_d2_native.json")
        if os.path.exists(m35):
            grades[f"{V8}:on"] = json.load(open(m35))["coreai_native"]
    model()
    answering(grades)
    teach()
