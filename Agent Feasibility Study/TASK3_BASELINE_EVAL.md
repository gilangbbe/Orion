# TASK3_BASELINE_EVAL.md

**Deliverable for Task 3 — Baseline LLM Evaluation**
Project: *Codebase Mentor* / Local LLM & Agent Feasibility Study
Harness: [`harness/`](harness/) · Benchmark: [`benchmark/benchmark.json`](benchmark/benchmark.json) · Pinned repo: `vendor/starlette` @ `4f250d6b8145` (Starlette 1.6.0)
Date: 2026-09-02

---

## 1. What Task 3 answers

> Which models can actually **reason about a software system**, not merely generate
> plausible-sounding code explanations?

Baseline means: **no RAG, no agents, no tools.** Each model is handed a fixed, fair slice of
ground-truth source and asked the benchmark question. Retrieval quality and agentic depth are
deliberately held out — they are Tasks 4 and 6. This isolates *reasoning capability at a given
context* from *the ability to find the right context*.

---

## 2. Model set (finalized)

From `MODEL_CANDIDATES.md` §9 plus the reviewer's inline answers (skip dense-32B; include a
reasoning-distill; alt-family = Gemma; drop the 70B tier). Full config: [`harness/config/models.yaml`](harness/config/models.yaml).

| id | HF repo (mlx-community) | tier | role | in seed run |
|---|---|---|---|:--:|
| `llama-3.2-3b-4bit` | `Llama-3.2-3B-Instruct-4bit` | small | floor | ✅ |
| `llama-3.2-3b-bf16` | `Llama-3.2-3B-Instruct-bf16` | small | quant-loss control | |
| `qwen3-8b-4bit` | `Qwen3-8B-4bit` | small | small generalist | ✅ |
| `qwen3-8b-8bit` | `Qwen3-8B-8bit` | small | q8 comparator | |
| `qwen2.5-coder-7b-4bit` | `Qwen2.5-Coder-7B-Instruct-4bit` | small | small coder | |
| `qwen3-14b-4bit` | `Qwen3-14B-4bit` | medium | mid generalist | |
| `qwen2.5-coder-14b-4bit` | `Qwen2.5-Coder-14B-Instruct-4bit` | medium | mid coder | |
| `gemma-3-12b-it-4bit` | `gemma-3-12b-it-4bit` | medium | alt family | |
| `r1-distill-qwen-14b-4bit` | `DeepSeek-R1-Distill-Qwen-14B-4bit` | medium | reasoning distill | |
| `qwen3-30b-a3b-4bit` | `Qwen3-30B-A3B-Instruct-2507-4bit` | large-MoE | MoE ceiling | |

The **seed run** in this session covers the two ✅ models end-to-end to validate the harness and
produce real preliminary numbers. The remaining eight run later with one command (§6).

---

## 3. Controlled context (the "fair slice")

For each question, [`harness/orion_eval/context.py`](harness/orion_eval/context.py) concatenates
the **verbatim** `relevant_files` from the pinned checkout (source, tests, docs), each wrapped in
`# ===== FILE: <path> =====` markers, in benchmark order.

- **Model-independent.** Budgeting is by **character count** (`CHAR_BUDGET = 110_000` ≈ 27–28K
  tokens), not tokens, so every model sees the identical bytes. All seed/short-list models
  support ≥ 32K context.
- **Truncation is logged.** If the relevant files exceed budget, the largest are head/tail
  truncated with an explicit `[TRUNCATED n chars]` marker and `context_truncated=True` recorded.
  In the seed benchmark, context ranges ~1.2K–94K chars; **nothing truncated**.
- This is Task 4's **Condition A (Direct)**. Tasks 4–6 swap this module for RAG / structured-graph
  / tool variants against the same questions.

The model is prompted ([`harness/orion_eval/prompts.py`](harness/orion_eval/prompts.py)) to
answer **only from the provided material**, never invent files/symbols, say so when the material
is insufficient (→ `epistemic_status: UNKNOWN`, a *valued* outcome), and return a single JSON
object:

```json
{ "answer": "...", "key_points": ["..."],
  "evidence": [{"file": "...", "symbol": "...", "why": "..."}],
  "epistemic_status": "VERIFIED | INFERRED | UNKNOWN | CONTRADICTED",
  "uncertainties": ["..."] }
```

Decoding is **greedy (temp 0.0)** for reproducibility. Extended "thinking" is disabled where the
chat template supports it (Qwen3), so the comparison is about the answer, not the scratchpad.

---

## 4. Metrics

### Quality axes (0–2 integer; graded per answer)

| Axis | Source | Notes |
|---|---|---|
| `correctness` | LLM judge | vs the benchmark `expected_answer`; fallback heuristic if no judge |
| `completeness` | LLM judge | coverage of `required_concepts`; fallback = keyword-coverage proxy |
| `architectural_reasoning` | LLM judge | mechanism **and** interaction, not restated question |
| `hallucination` | LLM judge + deterministic | 2 = clean, 0 = invents things / asserts a listed misconception; deterministic path forces 0 on any fabricated file path |
| `evidence_accuracy` | deterministic | citation overlap vs `relevant_files`/`relevant_symbols`; fabricated path → 0 |
| `structured_output` | deterministic | 2 = schema-valid JSON, 1 = parseable but off-schema, 0 = unparseable |
| `teaching_quality` | LLM judge | `teaching` + `transfer` items only; precise correction + a check question |

Also recorded (not folded into the composite): `epistemic_alignment` vs the item's
`expected_epistemic_status`, `concept_coverage` fraction, `evidence_file_recall`.

**Composite** = mean of the six always-available axes, normalized to 0–1. Correctness and
hallucination are reported **separately and never netted** — a model that is confidently right
*and* confidently wrong must stay visible (Product Spec §3, §86).

### Performance (measured per generation, aggregated per model)

`load_seconds`, `weights_gb` (post-load MLX resident), `ttft_seconds` (time to first token),
`gen_tps` (decode tokens/sec), `total_seconds`, `peak_memory_gb` (process-wide MLX peak =
weights + KV + activations), `prompt_tokens`, `gen_tokens`.

### Tracking

MLflow experiment **`orion-task3-baseline`** in `results/mlruns/` (file store): one parent run
per model, one nested run per question. The plain JSONL in `results/<run>/` is the source of
truth; MLflow is a convenience view. Launch the UI with
`mlflow ui --backend-store-uri "file://$PWD/results/mlruns"`.

---

## 5. Grading & the judge

Deterministic axes need no model. Subjective axes use a **pluggable judge**:

- `--judge anthropic[:model]` — strongest; needs `ANTHROPIC_API_KEY` (not set in this
  environment, so unused for the seed).
- `--judge mlx:<hf_repo>` — a local MLX model as judge.
- `--judge none` — deterministic axes + fallbacks only.

> **Seed-run caveat.** The seed grades use `--judge mlx:mlx-community/Qwen3-8B-4bit` — a
> *provisional, weak, and partly self-referential* judge (it also grades its own answers).
> Treat seed `correctness` / `architectural_reasoning` / `teaching_quality` as smoke-test
> signal, **not** model-selection evidence. Re-grade the full matrix with
> `--judge anthropic:claude-sonnet-5` or `--judge mlx:mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit`
> before Task 3's conclusions are drawn. The rubric mandates ≥ 20% human spot-check regardless.

---

## 6. How to run the rest

### On a clean machine — one command

Copy the whole `Agent Feasibility Study/` directory (`harness/`, `benchmark/`, the `.md` files,
`run_study.sh`) to the target Mac (Apple Silicon, macOS, Python ≥ 3.9 with a venv — nothing
else) and run:

```bash
./run_study.sh                 # provision + seed models (llama-3.2-3b, qwen3-8b)
MODELS=all ./run_study.sh      # full 10-model matrix (~40 GB of downloads)
SKIP_EVAL=1 ./run_study.sh     # just provision (venv + deps + pinned repo), run eval later
```

`run_study.sh` does preflight → venv (reuses `$VIRTUAL_ENV`/`./.venv`/`../.venv` or creates
one) → `pip install harness/requirements.txt` (pinned) → clone Starlette at the tag → resolve
anchors → `run → grade → leaderboard → report`. Judge auto-selects: Anthropic if
`ANTHROPIC_API_KEY` is set, else the local `mlx:Qwen3-8B` judge. Knobs: `MODELS`, `JUDGE`,
`STARLETTE_TAG`, `VENV`, `REQ_RELAX`, `SKIP_INSTALL`, `SKIP_CLONE`, `SKIP_EVAL` (see the header
of the script).

### Manual / piecemeal

```bash
cd "Agent Feasibility Study"
export PYTHONPATH=harness
PY=../.venv/bin/python

# one-time: pin the repo + resolve evidence anchors
git -C vendor/starlette rev-parse HEAD          # 4f250d6b8145...
$PY -m orion_eval.cli resolve-anchors

# full matrix (downloads ~40 GB total; run overnight)
$PY -m orion_eval.cli run --model all
$PY -m orion_eval.cli grade --judge anthropic:claude-sonnet-5   # or mlx:<big model>
$PY -m orion_eval.cli leaderboard

# or one model at a time
$PY -m orion_eval.cli all --model qwen3-14b-4bit --judge mlx:mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit

# review answers by hand (regenerate after each grade pass)
$PY -m orion_eval.cli report          # -> results/review.html, open in any browser
```

### `results/review.html` — the manual review UI

A single self-contained HTML file (no server, works offline, regenerate with `report`).
Left: every question with per-model composite pips and filters — **disagreements only**
(composite delta ≥ 0.25), **hallucination < 2**, **schema invalid**, **not reviewed by me**,
category / difficulty / text search. Right: the question, the full ground truth (expected
answer, required concepts, misconceptions in red, evidence anchors, grading notes), then each
model's parsed answer + auto-grade badges + judge rationale + raw completion + the context
files it saw + perf. Each (question, model) has a **My review** block — 0/1/2 per axis + a
note — saved to `localStorage`; **Export my review** writes `orion_task3_human_review.json`
for the rubric's ≥ 20% human spot-check. Keys `j`/`k` move between questions.

`qwen3-30b-a3b-4bit` will likely need `sudo sysctl iogpu.wired_limit_mb=20000` first on the
24 GB machine.

---

## 7. Seed run results (2 models, provisional judge)

> Generated by `run_seed.sh`. Full tables: [`results/LEADERBOARD.md`](results/LEADERBOARD.md).
> Per-answer detail: `results/seed-<model>/answers.jsonl` + `grades.jsonl`.

<!-- SEED_RESULTS_START -->

Run: `run_seed.sh`, 2026-09-02. Benchmark: Starlette 1.6.0 @ `4f250d6b8145`, 55 questions.
Hardware: Apple **M5 / 24 GiB** (`hw.memsize` reports 25.8 GB → the harness rounds to "26GB").
Judge: **`mlx:Qwen3-8B-4bit` — provisional, weak, self-referential** (see §5). All 55 answers
generated for both models; nothing context-truncated.

### Overall

| model | quant | composite | correct. | complete. | arch.reason. | halluc.(2=clean) | evidence | struct.out | struct-valid % | load s | TTFT s | gen tok/s | peak GB |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| **qwen3-8b-4bit** | q4 | **0.845** | 1.64 | 1.62 | 1.62 | 1.42 | 1.89 | 1.96 | 98 | 47.1 | 10.6 | 22.0 | 8.03 |
| **llama-3.2-3b-4bit** | q4 | 0.632 | 1.05 | 1.07 | 1.07 | 1.62 | 1.78 | ~1.7 | 89 | 1.0 | 4.7 | 43.0 | 4.53 |

_(0–2 axes; composite = mean of the 6 axes, normalised 0–1. `correct./complete./arch.` on both
rows come from the weak judge — indicative only.)_

### Composite by category

| model | code-und | cross-file | arch | dep/change | behavioural | contradiction | evidence | teaching | transfer |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| qwen3-8b-4bit | 0.98 | 0.99 | 0.75 | 0.81 | 0.84 | **0.62** | 0.94 | 0.73 | 0.77 |
| llama-3.2-3b-4bit | 0.81 | 0.60 | 0.71 | 0.51 | 0.52 | 0.67 | 0.60 | 0.71 | 0.50 |

### What the seed already shows (2 models, weak judge — directional only)

1. **The harness discriminates.** Clear, category-consistent separation between a 3B and an 8B;
   the 8B leads everywhere except contradiction-detection.
2. **Both models fail the signature Starlette gotcha (`BR-01`).** Both confidently assert that
   an `HTTPException` raised in middleware yields a clean 4xx — the exact "plausible but wrong"
   failure the benchmark targets. The weak judge still caught it (correctness 0/1). This is the
   single most encouraging data point for the benchmark's design.
3. **Composite ≠ the whole story.** On `TE-01` and `CD-01` qwen3-8b scored *below* llama-3b:
   it rubber-stamped the developer's misconception ("The developer's explanation is correct")
   and declared docs/impl consistent. Contradiction-detection (0.62) is qwen's weakest category
   — worth watching across the full set.
4. **`epistemic_status` is mostly `VERIFIED`.** Neither small model reaches for `INFERRED` /
   `CONTRADICTED` when it should (e.g. every `CD-*` item). Over-claiming is the default failure
   mode — central to the product thesis, and something the Depth Router / teaching layer must
   compensate for if a small model ships.
5. **Structured output is basically solved by prompt alone at 8B** (98% schema-valid), shakier
   at 3B (89%). No constrained decoding was needed.
6. **Perf, real numbers on M5/24 GiB:** qwen3-8b-4bit — 47 s cold load, ~22 tok/s decode, ~10 s
   mean TTFT (dominated by prefill of up to ~24K-token contexts), **8.0 GB peak**. llama-3.2-3b
   -4bit — 1 s warm load, ~43 tok/s, 4.5 GB peak. Both leave ample headroom on 24 GiB; the
   14B / 30B-MoE rows are where memory gets interesting (Task 5).

MLflow: experiment `orion-task3-baseline` in `results/mlflow.db` (SQLite). View with
`mlflow ui --backend-store-uri "sqlite:///$PWD/results/mlflow.db"`.

<!-- SEED_RESULTS_END -->

---

## 8. Reading the leaderboard for the Task 3 question

The harness emits a **"reasoning-vs-plausibility signal"** table:

- **easy → hard composite drop.** A model that reasons holds up on hard cross-file /
  behavioural / change-impact items. A model that pattern-matches shows a big drop.
- **hallucination mean.** Must stay near 2. A high composite with low hallucination score is a
  disqualifier for this product.
- **evidence_accuracy vs concept_coverage.** High verbal coverage with low evidence accuracy =
  fluent but ungrounded.
- **`epistemic_alignment` on the `UNKNOWN`/`INFERRED`/`CONTRADICTED` items.** Does the model
  correctly refuse to over-claim? (Items: AR-03, AR-06, DC-01, DC-03, DC-05, CD-05, all `TR-*`,
  and the `CD-*` contradiction items.)

No single scalar decides the model. Task 3's output is the leaderboard **plus** a written
capability verdict per model.

---

## 9. Limitations

- One repo, one language (Python/ASGI). Generalizes only so far — a second benchmark repo is
  needed before a cross-language claim.
- 55 items ranks models; it does not give tight CIs on small per-category gaps.
- Seed judge is weak/self-referential (§5).
- `peak_memory_gb` is the MLX allocator peak, not RSS; it excludes framework/Python overhead
  (~0.5–1 GB). Good for *comparing* models, not for absolute "will it fit" claims — those come
  from Task 5.
- Greedy decoding only. Temperature sensitivity is not explored here.
