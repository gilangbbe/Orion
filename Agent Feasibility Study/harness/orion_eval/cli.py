"""Command line: resolve-anchors | run | grade | leaderboard | all.

Layout assumed (relative to the 'Agent Feasibility Study' dir):
  benchmark/benchmark.json            input benchmark
  benchmark/benchmark.resolved.json   written by resolve-anchors
  vendor/starlette/                   pinned checkout (git checkout 1.6.0)
  results/<run>/                      answers.jsonl, grades.jsonl, run_meta.json, LEADERBOARD.md
  results/mlruns/                     MLflow tracking dir
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import platform
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

from . import EXPERIMENT_NAME, __version__

HERE = Path(__file__).resolve()
STUDY_DIR = HERE.parents[2]                      # .../Agent Feasibility Study
BENCH = STUDY_DIR / "benchmark" / "benchmark.json"
BENCH_RESOLVED = STUDY_DIR / "benchmark" / "benchmark.resolved.json"
VENDOR = STUDY_DIR / "vendor" / "starlette"
RESULTS = STUDY_DIR / "results"
MODELS_YAML = HERE.parents[1] / "config" / "models.yaml"


# ---------------------------------------------------------------- helpers

def _hardware() -> str:
    try:
        chip = subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
    except Exception:
        chip = platform.processor() or "unknown"
    try:
        mem = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True).strip())
        mem_gb = f"{round(mem / 1e9)}GB"
    except Exception:
        mem_gb = "?"
    return f"{chip} / {mem_gb} / macOS {platform.mac_ver()[0]}"


def _commit_sha() -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(VENDOR), "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return "UNRESOLVED"


def _load_bench() -> dict:
    path = BENCH_RESOLVED if BENCH_RESOLVED.is_file() else BENCH
    return json.loads(path.read_text())


def _load_models() -> dict:
    return yaml.safe_load(MODELS_YAML.read_text())


def _model_cfg(models: dict, model_id: str) -> dict:
    d = dict(models.get("defaults", {}))
    for m in models["models"]:
        if m["id"] == model_id:
            d.update(m)
            return d
    raise SystemExit(f"model id {model_id!r} not in {MODELS_YAML}")


# ---------------------------------------------------------------- resolve-anchors

def cmd_resolve_anchors(args: argparse.Namespace) -> None:
    bench = json.loads(BENCH.read_text())
    sha = _commit_sha()
    bench["metadata"]["commit_sha"] = sha
    resolved = missing = 0

    def find_line(rel: str, symbol: str | None) -> int | None:
        f = VENDOR / rel
        if not f.is_file():
            return None
        if not symbol:
            return None
        leaf = symbol.split("::")[-1].split(".")[-1]
        if not leaf or leaf.startswith("tests/") or " " in leaf:
            return None
        pat = re.compile(rf"^\s*(?:async\s+def|def|class)\s+{re.escape(leaf)}\b")
        for i, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
            if pat.search(line):
                return i
        return None

    for q in bench["questions"]:
        for e in q["evidence"]:
            ln = find_line(e["file"], e.get("symbol"))
            if ln is not None:
                e["line"] = ln
                resolved += 1
            else:
                e["line"] = None
                missing += 1
    bench["metadata"]["line_hints_verified"] = True
    bench["metadata"]["line_hint_resolution"] = {"resolved": resolved, "unresolved": missing}
    BENCH_RESOLVED.write_text(json.dumps(bench, indent=2, ensure_ascii=False) + "\n")
    print(f"commit {sha}")
    print(f"resolved {resolved} anchors, {missing} unresolved -> {BENCH_RESOLVED}")


# ---------------------------------------------------------------- run

def cmd_run(args: argparse.Namespace) -> None:
    from .context import build_context
    from .prompts import build_messages
    from .runner import ModelRunner, gen_result_dict
    from .schema import extract_json, validate_answer

    bench = _load_bench()
    meta = bench["metadata"]
    sha = meta.get("commit_sha") or _commit_sha()
    questions = bench["questions"]
    if args.limit:
        questions = questions[: args.limit]
    if args.categories:
        cats = set(args.categories.split(","))
        questions = [q for q in questions if q["category"] in cats]

    models = _load_models()
    ids = ([m["id"] for m in models["models"] if m.get("seed_run")] if args.model == "seed"
           else [m["id"] for m in models["models"]] if args.model == "all"
           else args.model.split(","))

    for model_id in ids:
        cfg = _model_cfg(models, model_id)
        run_dir = RESULTS / (args.out or f"seed-{model_id}")
        run_dir.mkdir(parents=True, exist_ok=True)
        print(f"\n=== {model_id}  ({cfg['hf_repo']}) -> {run_dir} ===", flush=True)

        runner = ModelRunner(cfg["hf_repo"], temperature=cfg.get("temperature", 0.0),
                             top_p=cfg.get("top_p", 1.0),
                             max_gen_tokens=cfg.get("max_gen_tokens", 900),
                             seed=cfg.get("seed", 0))
        if args.dry_run:
            print("  dry-run: skipping load/generate")
        else:
            runner.load()
            print(f"  loaded in {runner.load_seconds:.1f}s, weights ~{runner.weights_gb:.2f} GB",
                  flush=True)

        answers: list[dict] = []
        ans_path = run_dir / "answers.jsonl"
        with ans_path.open("w") as fh:
            for i, q in enumerate(questions, 1):
                ctx = build_context(q["relevant_files"], VENDOR)
                msgs = build_messages(q, ctx.text, sha)
                rec: dict[str, Any] = {
                    "id": q["id"], "category": q["category"], "difficulty": q["difficulty"],
                    "context_files": ctx.files_included, "context_missing": ctx.files_missing,
                    "context_chars": ctx.total_chars, "context_truncated": ctx.truncated,
                }
                if args.dry_run:
                    rec["raw_text"] = ""
                    answers.append(rec)
                    fh.write(json.dumps(rec) + "\n")
                    continue
                g = runner.generate(msgs, max_gen_tokens=cfg.get("max_gen_tokens", 900))
                obj, method = extract_json(g.text)
                schema_ok, errs = validate_answer(obj)
                rec.update(gen_result_dict(g))
                rec.update({
                    "raw_text": g.text, "answer_obj": obj, "json_method": method,
                    "schema_valid": schema_ok, "schema_errors": errs,
                })
                answers.append(rec)
                fh.write(json.dumps(rec) + "\n")
                fh.flush()
                print(f"  [{i:>2}/{len(questions)}] {q['id']:<6} "
                      f"json={method:<6} schema={'ok' if schema_ok else 'BAD':<3} "
                      f"ttft={g.ttft_seconds:.2f}s {g.gen_tps:.1f}tok/s "
                      f"peak={g.peak_memory_gb:.2f}GB", flush=True)

        run_meta = {
            "harness_version": __version__,
            "model_id": model_id, "hf_repo": cfg["hf_repo"], "quant": cfg.get("quant", ""),
            "tier": cfg.get("tier", ""), "role": cfg.get("role", ""),
            "repository": meta.get("repository"), "version": meta.get("version"),
            "commit_sha": sha, "n_questions": len(questions),
            "mlx_lm_version": _mlx_lm_version(), "hardware": _hardware(),
            "load_seconds": None if args.dry_run else round(runner.load_seconds, 2),
            "weights_gb": None if args.dry_run else round(runner.weights_gb, 3),
            "temperature": cfg.get("temperature", 0.0),
            "created": dt.datetime.now().isoformat(timespec="seconds"),
            "judge": None,
        }
        (run_dir / "run_meta.json").write_text(json.dumps(run_meta, indent=2) + "\n")
        if not args.dry_run:
            runner.unload()
        print(f"  wrote {len(answers)} answers -> {ans_path}")


def _mlx_lm_version() -> str:
    try:
        import mlx_lm
        return mlx_lm.__version__
    except Exception:
        return "?"


# ---------------------------------------------------------------- grade

def cmd_grade(args: argparse.Namespace) -> None:
    from .grade import grade_record, resolve_judge, COMPOSITE_AXES
    from .grade import _repo_paths  # noqa
    from .mlflow_log import log_model_run

    bench = _load_bench()
    qi = {q["id"]: q for q in bench["questions"]}
    repo_paths = _repo_paths(VENDOR)
    judge = resolve_judge(args.judge)

    run_dirs = [RESULTS / d for d in args.runs] if args.runs else sorted(
        p.parent for p in RESULTS.glob("*/answers.jsonl"))

    try:
        for run_dir in run_dirs:
            ans = [json.loads(l) for l in (run_dir / "answers.jsonl").read_text().splitlines()
                   if l.strip()]
            meta = json.loads((run_dir / "run_meta.json").read_text())
            meta["judge"] = args.judge
            grades = []
            gpath = run_dir / "grades.jsonl"
            with gpath.open("w") as fh:
                for rec in ans:
                    q = qi.get(rec["id"])
                    if not q:
                        continue
                    g = grade_record(rec, q, repo_paths, judge)
                    grades.append(g)
                    fh.write(json.dumps(g) + "\n")
                    print(f"  {rec['id']:<6} comp={g.get('composite')} "
                          f"corr={g.get('correctness')} hall={g.get('hallucination')} "
                          f"ev={g.get('evidence_accuracy')} so={g.get('structured_output')}",
                          flush=True)
            (run_dir / "run_meta.json").write_text(json.dumps(meta, indent=2) + "\n")
            print(f"  wrote {len(grades)} grades -> {gpath}")
            if not args.no_mlflow:
                # MLflow is a convenience view; the JSONL above is the source of truth.
                # Never let a tracking-backend problem abort the grading run.
                try:
                    from .mlflow_log import default_tracking_uri
                    cfg = {"id": meta["model_id"], "hf_repo": meta["hf_repo"],
                           "quant": meta.get("quant", ""), "tier": meta.get("tier", ""),
                           "role": meta.get("role", "")}
                    rid = log_model_run(
                        model_cfg=cfg, meta=dict(meta), answers=ans, grades=grades,
                        tracking_uri=default_tracking_uri(RESULTS),
                        artifact_dir=str(RESULTS / "mlartifacts"),
                    )
                    if rid:
                        print(f"  mlflow run {rid} in experiment {EXPERIMENT_NAME}")
                except Exception as exc:
                    print(f"  [warn] mlflow logging skipped: {exc!r}")
    finally:
        close = getattr(judge, "close", None)
        if callable(close):
            close()


# ---------------------------------------------------------------- investigate (Phase 2)

def _next_repeatability_dir(out_dir: Path) -> tuple[Path, int]:
    """Docs/11 M6: each `investigate --repeatability` invocation is exactly ONE investigation
    (never a loop over N) -- this just picks the next non-clobbering `runN` slot so repeated
    manual invocations accumulate instead of overwriting each other. `runN` is 1-indexed and
    based on what already exists on disk, not an in-memory counter, so it's safe across
    separate process invocations run hours apart."""
    base = out_dir / "repeatability"
    base.mkdir(parents=True, exist_ok=True)
    existing = sorted(
        int(p.name[3:]) for p in base.glob("run*")
        if p.is_dir() and p.name[3:].isdigit()
    )
    n = (existing[-1] + 1) if existing else 1
    run_dir = base / f"run{n}"
    run_dir.mkdir()
    return run_dir, n


def cmd_investigate(args: argparse.Namespace) -> None:
    """Docs/11_phase2_semantic_analysis.md M1: one headless Claude Code CLI investigation
    over a Code-Graph-exported repo, writing a candidate semantic_findings.json for
    `orion-index ingest-semantic` (Swift) to validate and persist.

    `--repeatability` (M6) redirects the three output files into an auto-numbered
    `<out>/repeatability/runN/` slot instead of writing directly under `<out>/`, so this same
    single-investigation command can be invoked several separate times -- by hand, one at a
    time -- without each run clobbering the last. It never loops or runs more than one
    investigation itself; `repeatability-report` is the separate command that reads back
    however many `runN/` slots exist once you're done."""
    from .semantic.investigate import READ_ONLY_TOOLS, ClaudeInvestigator

    repo_root = Path(args.repo) if args.repo else VENDOR
    out_dir = Path(args.out)
    export_dir = out_dir / "export"
    if not export_dir.is_dir():
        raise SystemExit(
            f"no {export_dir} -- run `swift run orion-index analyze {repo_root} "
            f"--out {out_dir}` first"
        )

    investigator = ClaudeInvestigator(
        repo_root=repo_root, export_dir=export_dir, model=args.model,
        max_budget_usd=args.max_budget_usd, timeout_seconds=args.timeout,
    )

    if args.dry_run:
        prompt = investigator.build_prompt()
        print(prompt)
        print(f"\ncommand: {investigator.build_command('<prompt above>')}")
        return

    write_dir = out_dir
    run_label = None
    if args.repeatability:
        if args.write or args.raw_write or args.meta_write:
            raise SystemExit("--repeatability picks its own filenames -- don't combine with --write/--raw-write/--meta-write")
        write_dir, n = _next_repeatability_dir(out_dir)
        run_label = f"run{n}"
        print(f"repeatability {run_label} -> {write_dir}", flush=True)

    print(
        f"investigating {repo_root} (model={args.model}, "
        f"budget=${args.max_budget_usd:.2f}, timeout={args.timeout}s) ...",
        flush=True,
    )
    result = investigator.run()

    raw_path = write_dir / (args.raw_write or "semantic_findings.raw.json")
    raw_path.write_text(json.dumps(result.wrapper, indent=2, ensure_ascii=False) + "\n")

    turns = result.num_turns if result.num_turns is not None else "?"
    cost = f"${result.total_cost_usd:.4f}" if result.total_cost_usd is not None else "?"
    duration = f"{result.duration_ms:.0f}ms" if result.duration_ms is not None else "?"
    print(
        f"outcome={result.outcome} ok={result.ok} extraction={result.extraction_method} "
        f"turns={turns} cost={cost} duration={duration} session={result.session_id}"
    )
    if result.candidate_errors:
        print("  candidate errors:")
        for e in result.candidate_errors:
            print(f"    - {e}")

    # A small, Swift-owned shape (Docs/11 M2 `InvestigationMeta`) -- not the CLI's own
    # `--output-format json` wrapper, which is internal and could change shape across
    # versions. Written regardless of whether a candidate was extracted, so a rejected/
    # incomplete attempt is still identifiable if `ingest-semantic --meta` is pointed at it.
    meta_path = write_dir / (args.meta_write or "investigation_meta.json")
    meta_path.write_text(json.dumps({
        "model_used": result.model_used,
        "session_id": result.session_id,
        "num_turns": result.num_turns,
        "total_cost_usd": result.total_cost_usd,
        "duration_ms": result.duration_ms,
        "tools_used": READ_ONLY_TOOLS.split(","),
    }, indent=2, ensure_ascii=False) + "\n")

    if result.candidate is not None:
        cand_path = write_dir / (args.write or "semantic_findings.json")
        cand_path.write_text(json.dumps(result.candidate, indent=2, ensure_ascii=False) + "\n")
        print(f"  wrote candidate  -> {cand_path}")
        if run_label is None:
            print(
                f"  next: swift run orion-index ingest-semantic {cand_path} "
                f"--meta {meta_path} --out {out_dir}"
            )
        else:
            print(f"  {run_label} done. Run again with --repeatability for the next one when ready,")
            print(f"  or once all runs are in: python -m orion_eval.cli repeatability-report --out {out_dir}")
    else:
        print("  no candidate JSON extracted -- nothing written besides the raw wrapper/meta")
    print(f"  wrote raw wrapper -> {raw_path}")
    print(f"  wrote meta        -> {meta_path}")

    if result.stderr_tail:
        print(f"  stderr (tail): {result.stderr_tail}")


def cmd_score_semantic(args: argparse.Namespace) -> None:
    """Docs/11_phase2_semantic_analysis.md M5: score an exported semantic model
    (components.jsonl + claims.jsonl) against a hand-authored gold component file."""
    from .semantic.score import score

    export_dir = Path(args.out) / "export"
    if not export_dir.is_dir():
        raise SystemExit(
            f"no {export_dir} -- run `ingest-semantic --export` or `orion-index export` first"
        )
    report = score(Path(args.gold), export_dir, threshold=args.threshold)

    print(
        f"component alignment ({len(report.matches)} matched, "
        f"{len(report.missed_gold)} missed, {len(report.spurious_predicted)} spurious):"
    )
    for m in sorted(report.matches, key=lambda m: -m.f1):
        print(
            f"  {m.gold_name!r:<32} <-> {m.predicted_name!r:<40} "
            f"jaccard={m.jaccard:.2f} P={m.precision:.2f} R={m.recall:.2f} F1={m.f1:.2f}"
        )
    if report.missed_gold:
        print(f"  missed (no predicted component matched):   {report.missed_gold}")
    if report.spurious_predicted:
        print(f"  spurious (no gold component matched):       {report.spurious_predicted}")
    print(
        f"macro precision={report.macro_precision:.3f} recall={report.macro_recall:.3f} "
        f"f1={report.macro_f1:.3f}"
    )

    if report.evidence_accuracy is not None:
        confirmed = report.evidenced_claim_count - report.contradicted_claim_count
        print(
            f"evidence accuracy: {report.evidence_accuracy:.3f} "
            f"({confirmed}/{report.evidenced_claim_count} evidenced claims confirmed, "
            f"{report.contradicted_claim_count} contradicted)"
        )

    if args.write:
        Path(args.write).write_text(json.dumps(report.to_dict(), indent=2) + "\n")
        print(f"wrote {args.write}")


def cmd_repeatability_report(args: argparse.Namespace) -> None:
    """Docs/11_phase2_semantic_analysis.md M6: read back whatever `investigate
    --repeatability` runs exist under `<out>/repeatability/runN/` and report component-set
    stability + cost/turn/duration variance across them. Runs no investigation itself."""
    from .semantic.repeatability import build_report, discover_failed_runs, discover_runs

    out_dir = Path(args.out)
    run_dirs = discover_runs(out_dir)
    failed = discover_failed_runs(out_dir)
    if not run_dirs and not failed:
        raise SystemExit(
            f"no runs under {out_dir / 'repeatability'} -- "
            f"run `investigate --repeatability --out {out_dir}` at least twice first"
        )

    if failed:
        print(f"{len(failed)} failed run(s) (no candidate -- excluded from stability below):")
        for run_dir, reason in failed:
            print(f"  {run_dir.name:<6} {reason}")
        print()

    if not run_dirs:
        print("no successful runs yet.")
        return

    report = build_report(out_dir, threshold=args.threshold)

    print(f"{len(report.runs)} successful run(s) found:")
    for r in report.runs:
        turns = r.num_turns if r.num_turns is not None else "?"
        cost = f"${r.total_cost_usd:.4f}" if r.total_cost_usd is not None else "?"
        print(
            f"  {r.label:<6} components={r.component_count:<3} "
            f"relationships={r.relationship_count:<3} claims={r.evidenced_claim_count:<3} "
            f"uncertainties={r.uncertainty_count:<3} turns={turns} cost={cost}"
        )

    if len(report.runs) < 2:
        print("\nneed at least 2 runs to compute pairwise stability -- run --repeatability again")
        return

    print("\npairwise component-set stability (1.0 = identical decomposition):")
    for p in report.pairs:
        print(
            f"  {p.run_a} <-> {p.run_b}   matched={p.matched} missed={p.missed} "
            f"spurious={p.spurious} macro_f1={p.macro_f1:.3f}"
        )
    print(
        f"\nmean_pairwise_f1={report.mean_pairwise_f1:.3f} "
        f"(min={report.min_pairwise_f1:.3f} max={report.max_pairwise_f1:.3f})"
    )
    print(f"cost_usd:     {report.cost_usd}")
    print(f"duration_ms:  {report.duration_ms}")
    print(f"num_turns:    {report.num_turns}")

    if args.write:
        Path(args.write).write_text(json.dumps(report.to_dict(), indent=2) + "\n")
        print(f"\nwrote {args.write}")


# ---------------------------------------------------------------- leaderboard

def cmd_report(args: argparse.Namespace) -> None:
    from .report import build_report
    path = build_report(STUDY_DIR, args.out)
    print(f"wrote {path}  (open in a browser; no server needed)")


def cmd_leaderboard(args: argparse.Namespace) -> None:
    from .leaderboard import build_leaderboard
    run_dirs = [RESULTS / d for d in args.runs] if args.runs else sorted(
        {p.parent for p in RESULTS.glob("*/grades.jsonl")})
    if not run_dirs:
        raise SystemExit("no results/*/grades.jsonl found — run `grade` first")
    out = args.out or (RESULTS / "LEADERBOARD.md")
    path = build_leaderboard(run_dirs, out)
    print(f"wrote {path} from {len(run_dirs)} run(s)")


# ---------------------------------------------------------------- all

def cmd_all(args: argparse.Namespace) -> None:
    cmd_run(args)
    gargs = argparse.Namespace(runs=None, judge=args.judge, no_mlflow=args.no_mlflow)
    cmd_grade(gargs)
    cmd_leaderboard(argparse.Namespace(runs=None, out=None))
    cmd_report(argparse.Namespace(out=None))


# ---------------------------------------------------------------- argparse

def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="orion-eval", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("resolve-anchors", help="fill evidence line numbers from the pinned checkout")
    sp.set_defaults(func=cmd_resolve_anchors)

    sp = sub.add_parser("run", help="generate answers for one/more models")
    sp.add_argument("--model", default="seed",
                    help="'seed' (seed_run models), 'all', or comma list of model ids")
    sp.add_argument("--out", default=None, help="results subdir name (default seed-<id>)")
    sp.add_argument("--limit", type=int, default=0, help="only the first N questions")
    sp.add_argument("--categories", default="", help="comma list to filter categories")
    sp.add_argument("--dry-run", action="store_true", help="build contexts/prompts, no model")
    sp.set_defaults(func=cmd_run)

    sp = sub.add_parser("grade", help="score answers (deterministic + optional judge) + MLflow")
    sp.add_argument("--runs", nargs="*", help="results subdir names (default: all with answers)")
    sp.add_argument("--judge", default="none",
                    help="none | mlx:<hf_repo> | anthropic[:model]")
    sp.add_argument("--no-mlflow", action="store_true")
    sp.set_defaults(func=cmd_grade)

    sp = sub.add_parser("leaderboard", help="aggregate runs into a Markdown leaderboard")
    sp.add_argument("--runs", nargs="*", help="results subdir names (default: all graded)")
    sp.add_argument("--out", default=None)
    sp.set_defaults(func=cmd_leaderboard)

    sp = sub.add_parser(
        "investigate",
        help="run one Claude Code CLI semantic investigation over a Code Graph export (Phase 2)",
    )
    sp.add_argument("--out", required=True, help=".orion dir with export/ (from orion-index analyze --out)")
    sp.add_argument("--repo", default=None, help="repo checkout to investigate (default: vendored Starlette)")
    sp.add_argument("--model", default="claude-sonnet-5")
    sp.add_argument("--max-budget-usd", type=float, default=2.00)
    sp.add_argument("--timeout", type=int, default=900, help="wall-clock seconds")
    sp.add_argument("--write", default=None, help="candidate filename under --out (default semantic_findings.json)")
    sp.add_argument("--raw-write", default=None, help="raw wrapper filename under --out (default semantic_findings.raw.json)")
    sp.add_argument("--meta-write", default=None, help="meta filename under --out (default investigation_meta.json)")
    sp.add_argument("--dry-run", action="store_true", help="print the prompt/command, don't invoke claude")
    sp.add_argument(
        "--repeatability", action="store_true",
        help="Docs/11 M6: write to an auto-numbered <out>/repeatability/runN/ instead of "
             "directly under <out>/, so this command can be run several separate times (one "
             "investigation each) without overwriting the previous run. Never runs more than "
             "one investigation itself -- run it again by hand for the next N.",
    )
    sp.set_defaults(func=cmd_investigate)

    sp = sub.add_parser(
        "score-semantic",
        help="score an exported semantic model against a gold component set (Phase 2 M5)",
    )
    sp.add_argument("--out", required=True, help=".orion dir with export/ (components.jsonl, claims.jsonl)")
    sp.add_argument("--gold", required=True, help="path to a *.gold.json component file")
    sp.add_argument("--threshold", type=float, default=0.3, help="Jaccard overlap needed to align a gold/predicted pair")
    sp.add_argument("--write", default=None, help="write the full report as JSON to this path")
    sp.set_defaults(func=cmd_score_semantic)

    sp = sub.add_parser(
        "repeatability-report",
        help="compare however many `investigate --repeatability` runs exist so far (Phase 2 M6)",
    )
    sp.add_argument("--out", required=True, help=".orion dir with a repeatability/ subdir")
    sp.add_argument("--threshold", type=float, default=0.3, help="Jaccard overlap needed to align a component pair")
    sp.add_argument("--write", default=None, help="write the full report as JSON to this path")
    sp.set_defaults(func=cmd_repeatability_report)

    sp = sub.add_parser("report", help="build the self-contained HTML answer-review page")
    sp.add_argument("--out", default=None, help="output path (default results/review.html)")
    sp.set_defaults(func=cmd_report)

    sp = sub.add_parser("all", help="run + grade + leaderboard")
    sp.add_argument("--model", default="seed")
    sp.add_argument("--out", default=None)
    sp.add_argument("--limit", type=int, default=0)
    sp.add_argument("--categories", default="")
    sp.add_argument("--dry-run", action="store_true")
    sp.add_argument("--judge", default="none")
    sp.add_argument("--no-mlflow", action="store_true")
    sp.set_defaults(func=cmd_all)

    args = p.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
