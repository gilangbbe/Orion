# Task 3 — Baseline LLM Leaderboard

- Benchmark: **starlette v1.6.0** @ `4f250d6b8145` · 55 questions
- Hardware: Apple M5 / 26GB / macOS 26.6.2
- Runtime: mlx-lm 0.31.3
- Judge(s): mlx:mlx-community/Qwen3-8B-4bit
- Runs aggregated: seed-llama-3.2-3b-4bit, seed-qwen3-8b-4bit

> ⚠️ Some rows graded with **no judge** or a **provisional local judge**. correctness / architectural_reasoning / teaching_quality on those rows are fallback or weak-judge estimates — re-grade with a strong judge before drawing model-selection conclusions.

## Overall

| model | quant | composite | correctness | completeness | architectural_reasoning | hallucination | evidence_accuracy | structured_output | teaching_q | struct_valid% | load_s | ttft_s | gen_tps | peak_GB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **qwen3-8b-4bit** | q4 | 0.845 | 1.64 | 1.62 | 1.62 | 1.42 | 1.89 | 1.96 | — | 98 | 47.1 | 10.58 | 22.0 | 8.03 |
| **llama-3.2-3b-4bit** | q4 | 0.632 | 1.05 | 1.07 | 1.07 | 0.98 | 1.62 | 1.78 | — | 89 | 1.0 | 4.68 | 43.0 | 4.53 |

_Axis scale 0–2 (higher better). hallucination: 2 = clean, 0 = fabricates. composite = mean of the 6 axes present, normalised to 0–1._

## Composite by category

| model | code understanding | cross file reasoning | architecture | dependency change impact | behavioral reasoning | contradiction detection | evidence | teaching | transfer |
|---|---|---|---|---|---|---|---|---|---|
| **llama-3.2-3b-4bit** | 0.81 | 0.60 | 0.71 | 0.51 | 0.52 | 0.67 | 0.60 | 0.71 | 0.50 |
| **qwen3-8b-4bit** | 0.98 | 0.99 | 0.75 | 0.81 | 0.84 | 0.62 | 0.94 | 0.73 | 0.77 |

## Reasoning-vs-plausibility signal

Heuristic only. A model that *reasons* should score similarly on hard cross-file / behavioural / change-impact items as on easy code-understanding items, keep hallucination high, and cite real evidence. A model that merely *sounds right* shows a large easy→hard drop and/or low evidence_accuracy with high verbal completeness.

| model | easy composite | hard composite | drop | mean hallucination | mean evidence_acc | concept_coverage |
|---|---|---|---|---|---|---|
| **llama-3.2-3b-4bit** | 0.677 | 0.572 | 0.105 | 0.98 | 1.62 | 0.15 |
| **qwen3-8b-4bit** | 0.906 | 0.725 | 0.182 | 1.42 | 1.89 | 0.23 |
