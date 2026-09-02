"""MLflow logging. One parent run per (model, quant); one nested run per question.

Kept optional: if mlflow import/So fails, the JSONL artifacts in results/<run>/ are the
source of truth and the leaderboard can be built from them alone.
"""
from __future__ import annotations

import statistics as stats
from typing import Any

from . import EXPERIMENT_NAME


def _mean(xs: list[float]) -> float | None:
    xs = [x for x in xs if isinstance(x, (int, float))]
    return round(stats.fmean(xs), 4) if xs else None


def default_tracking_uri(results_dir) -> str:
    """SQLite backend — the MLflow file store is deprecated in 3.x and raises."""
    from pathlib import Path
    return f"sqlite:///{Path(results_dir).resolve() / 'mlflow.db'}"


def log_model_run(*, model_cfg: dict, meta: dict, answers: list[dict], grades: list[dict],
                  tracking_uri: str, artifact_dir: str | None = None) -> str | None:
    import os

    try:
        import mlflow
    except Exception:
        return None

    # Belt-and-braces: if a caller still passes a file:// or bare path, allow it rather
    # than crash the grading run.
    if not tracking_uri.startswith(("sqlite:", "postgresql:", "mysql:", "http:", "https:")):
        os.environ.setdefault("MLFLOW_ALLOW_FILE_STORE", "true")

    mlflow.set_tracking_uri(tracking_uri)
    if mlflow.get_experiment_by_name(EXPERIMENT_NAME) is None:
        kw = {"artifact_location": f"file://{artifact_dir}"} if artifact_dir else {}
        try:
            mlflow.create_experiment(EXPERIMENT_NAME, **kw)
        except Exception:
            pass  # created concurrently / already exists
    mlflow.set_experiment(EXPERIMENT_NAME)
    gi = {g["id"]: g for g in grades}

    with mlflow.start_run(run_name=model_cfg["id"]) as parent:
        mlflow.log_params({
            "model_id": model_cfg["id"],
            "hf_repo": model_cfg["hf_repo"],
            "quant": model_cfg.get("quant", ""),
            "tier": model_cfg.get("tier", ""),
            "role": model_cfg.get("role", ""),
            "benchmark_repo": meta.get("repository", ""),
            "benchmark_commit": meta.get("commit_sha", ""),
            "benchmark_version": meta.get("version", ""),
            "mlx_lm_version": meta.get("mlx_lm_version", ""),
            "hardware": meta.get("hardware", ""),
            "judge": meta.get("judge", "none"),
            "n_questions": len(answers),
        })

        for axis in ("correctness", "completeness", "architectural_reasoning", "hallucination",
                     "evidence_accuracy", "structured_output", "teaching_quality",
                     "composite", "epistemic_alignment", "concept_coverage",
                     "evidence_file_recall"):
            m = _mean([g.get(axis) for g in grades])
            if m is not None:
                mlflow.log_metric(f"mean_{axis}", m)

        # perf
        if isinstance(meta.get("load_seconds"), (int, float)):
            mlflow.log_metric("load_seconds", round(meta["load_seconds"], 2))
        if isinstance(meta.get("weights_gb"), (int, float)):
            mlflow.log_metric("weights_gb", round(meta["weights_gb"], 3))
        for k in ("ttft_seconds", "gen_tps", "total_seconds", "peak_memory_gb",
                  "prompt_tokens", "gen_tokens"):
            m = _mean([a.get(k) for a in answers])
            if m is not None:
                mlflow.log_metric(f"mean_{k}", m)
        mlflow.log_metric(
            "structured_output_valid_rate",
            round(sum(1 for a in answers if a.get("schema_valid")) / max(len(answers), 1), 4),
        )

        # per-category composite
        cats: dict[str, list[float]] = {}
        for g in grades:
            if isinstance(g.get("composite"), (int, float)):
                cats.setdefault(g["category"], []).append(g["composite"])
        for c, xs in cats.items():
            mlflow.log_metric(f"cat_{c}_composite", _mean(xs) or 0.0)

        for a in answers:
            g = gi.get(a["id"], {})
            with mlflow.start_run(run_name=a["id"], nested=True):
                mlflow.log_params({"qid": a["id"], "category": a.get("category", ""),
                                   "difficulty": a.get("difficulty", ""),
                                   "context_truncated": a.get("context_truncated", False)})
                for k, v in list(g.items()):
                    if isinstance(v, (int, float)) and not isinstance(v, bool):
                        mlflow.log_metric(k, v)
                for k in ("ttft_seconds", "gen_tps", "total_seconds", "peak_memory_gb",
                          "prompt_tokens", "gen_tokens"):
                    if isinstance(a.get(k), (int, float)):
                        mlflow.log_metric(k, a[k])
        return parent.info.run_id
