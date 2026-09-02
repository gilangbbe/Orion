# MODEL_CANDIDATES.md

**Deliverable for Task 1 — Model Discovery & Benchmarking**
Project: *Codebase Mentor* / Local LLM & Agent Feasibility Study
Status: **candidate inventory only — no winner chosen** (per study rules #5, #7)
Date compiled: 2026-09-02

---

## 1. Purpose

Identify a representative range of **MLX Community** models that could plausibly serve as the
reasoning layer for Codebase Mentor, and record the facts needed to design Task 3
(baseline evaluation). This document does **not** rank models or recommend one. It defines
the shortlist that Task 3 will benchmark and the constraints that shape that shortlist.

---

## 2. Target hardware (fixed constraint for this study)

| Property | Value | Consequence |
|---|---|---|
| Chip | Apple **M5** (10-core: 4 P + 6 E), 10-core GPU with per-core Neural Accelerators | Strong prompt **prefill**; decode is bandwidth-bound |
| Unified memory | **24 GB** | Practical model+KV budget ≈ **15–17 GB** after OS + app (default `iogpu.wired_limit`); can push to ~19 GB by raising the wired limit, with stability risk |
| Memory bandwidth | ~**142 GB/s** (M5 base) | Rough decode ceiling ≈ `bandwidth ÷ active-bytes-per-token`; ~20–28 tok/s for a 4-bit 8B model |
| OS | macOS 26.6.2 (build 25G83) | |
| Runtime | `mlx-lm` (record exact version at run time — was **v0.31.3**, 2026-04-22 at time of writing) | |

**Immediate implication:** the study's "Large: ~70B+" tier is **not locally runnable on this
machine**. A dense 70B at 4-bit is ≈ 38–42 GB of weights alone. See §6.

---

## 3. Selection criteria

A model is a candidate if it is:

1. Published (or trivially convertible) under the **`mlx-community`** Hugging Face org, or
   directly loadable by `mlx-lm` from the vendor repo.
2. Instruction-tuned (chat) — base models excluded.
3. In one of the three size bands the study requires (small 3–8B / medium 12–32B / large 70B+).
4. Either (a) small enough to run on the 24 GB M5 at some usable quant, **or** (b) explicitly
   kept as an *upper-reference* point to be measured on borrowed hardware (large tier).
5. Has a **documented context length ≥ 32K** (Codebase Mentor needs room for graph +
   evidence + source; see study Task 5).

Coding-specialist and generalist models are both included on purpose — the study must find
out whether code-tuned models actually reason better *about systems* or just *about syntax*
(study rule #6).

---

## 4. Candidate inventory

### Notation

- **Mem (4-bit)** = approximate resident size of weights only, MLX 4-bit (`q4`, group size 64).
  Add KV cache: roughly **0.10–0.20 GB per 1K tokens** for 7–14B, **0.20–0.40 GB per 1K** for 24–32B
  (dense), less for MoE. A 32K working context is a meaningful add.
- **tok/s (est.)** = order-of-magnitude decode estimate for the **M5 base / 24 GB**, derived from
  bandwidth ÷ bytes-per-token and cross-checked against public M5-family numbers. **Treat as a
  hypothesis to be measured in Task 3, not a result.**
- **Tools** = native tool-calling support in the model's chat template (H = strong/native,
  M = usable, L = weak/none). Constrained JSON is separately achievable for *any* model via
  Outlines / logit-processor grammars (see §7).
- **Ctx** = vendor-documented max context. Long contexts often need RoPE scaling flags and cost
  memory; "usable" context on 24 GB is much smaller (Task 5 measures this).

---

### 4.1 Small tier (~3–8B)

| Model (HF repo, `mlx-community/…` unless noted) | Params | Quant options | Ctx | MLX compat | Mem (4-bit) | tok/s (est., M5/24GB) | Tools | License |
|---|---|---|---|---|---|---|---|---|
| `Llama-3.2-3B-Instruct` | 3.2B | 4 / 8 / bf16 | 128K | Native (`llama`), reference model for `mlx-lm` | ~1.9 GB | 40–55 | M (Llama tool fmt) | Llama 3.2 Community |
| `Qwen3-4B-Instruct-2507` | 4.0B | 4 / 6 / 8 / bf16 | 256K (YaRN; 32K native) | Native (`qwen3`) | ~2.4 GB | 35–50 | H (Qwen/Hermes tool fmt) | Apache-2.0 |
| `Qwen3-8B` | 8.2B | 4 / 6 / 8 / bf16 | 128K | Native (`qwen3`), hybrid thinking | ~4.6 GB | 20–30 | H | Apache-2.0 |
| `Qwen2.5-Coder-7B-Instruct` | 7.6B | 4 / 8 / bf16 | 128K (RoPE) | Native (`qwen2`) | ~4.3 GB | 22–30 | H | Apache-2.0 |
| `Meta-Llama-3.1-8B-Instruct` | 8.0B | 4 / 8 / bf16 | 128K | Native (`llama`) | ~4.5 GB | 22–30 | M | Llama 3.1 Community |
| `gemma-3-4b-it` | 4.3B | 4 / 8 / bf16 | 128K | Native (`gemma3`); multimodal (text path used here) | ~2.6 GB | 30–45 | M (Gemma 3 fn-calling prompt) | Gemma Terms of Use |
| `Phi-4-mini-instruct` | 3.8B | 4 / 8 / bf16 | 128K | Native (`phi3`) | ~2.3 GB | 35–50 | M | MIT |
| `Ministral-8B-Instruct-2410` | 8.0B | 4 / 8 / bf16 | 128K | Native (`mistral`) | ~4.5 GB | 22–30 | M | **MRL — research/non-commercial only** ⚠ |

**Notes**
- `Llama-3.2-3B-Instruct-4bit` is the `mlx-lm` default download and a sensible **floor**: if a
  task is unsolvable here it sets a lower bound, not an upper one.
- **Ministral-8B** license (Mistral Research License) forbids commercial use — keep it as a
  scientific reference point only, exclude from any shipping decision.
- Small tier comfortably fits full 128K context on 24 GB; these are the models where Task 5's
  "just give it more code" hypothesis can be tested without memory as the limiter.

---

### 4.2 Medium tier (~12–32B)

| Model | Params (active) | Quant options | Ctx | MLX compat | Mem (4-bit) | tok/s (est., M5/24GB) | Tools | License |
|---|---|---|---|---|---|---|---|---|
| `Qwen3-14B` | 14.8B | 4 / 6 / 8 | 128K | Native (`qwen3`) | ~8.4 GB | 12–18 | H | Apache-2.0 |
| `Qwen3-32B` | 32.8B | 4 / (6) | 128K | Native (`qwen3`) | ~18 GB | 5–9 | H | Apache-2.0 — **marginal on 24 GB**, little KV headroom |
| `Qwen3-30B-A3B-Instruct-2507` | 30.5B (**3.3B active**) MoE | 4 / 6 / 8 | 256K (YaRN; 128K native) | Native (`qwen3_moe`) | ~16–17 GB | 18–30 (MoE) | H | Apache-2.0 — needs wired-limit tuning; **practical "large" ceiling on 24 GB** |
| `Qwen3-Coder-30B-A3B-Instruct` | 30.5B (**3.3B active**, 128 experts / 8 active) MoE | 4 / 6 / 8 | **256K** native (1M YaRN) | Native (`qwen3_moe`) | ~16–17 GB | 18–30 (MoE) | **H — tuned for agentic tool use** | Apache-2.0 |
| `Qwen2.5-Coder-14B-Instruct` | 14.7B | 4 / 8 | 128K (RoPE) | Native (`qwen2`) | ~8.5 GB | 12–18 | H | Apache-2.0 |
| `Qwen2.5-Coder-32B-Instruct` | 32.5B | 4 / 8 | 128K (RoPE) | Native (`qwen2`) | ~18–19 GB | 5–9 | H | Apache-2.0 — **marginal on 24 GB** (min ~19 GB system RAM reported) |
| `gemma-3-12b-it` | 12.2B | 4 / 8 | 128K | Native (`gemma3`) | ~7.5 GB | 12–18 | M | Gemma Terms of Use |
| `gemma-3-27b-it` | 27.4B | 4 / 8 | 128K | Native (`gemma3`) | ~15.5 GB | 6–10 | M | Gemma Terms of Use — **marginal on 24 GB** |
| `Mistral-Small-3.2-24B-Instruct-2506` | 23.6B | 4 / 8 | 128K | Native (`mistral`) | ~13.5 GB | 8–12 | M–H (native fn-calling) | Apache-2.0 |
| `Devstral-Small-2507` (24B) | 23.6B | 4 / 8 | 256K (128K on older builds) | Native (`mistral`) | ~13.5 GB | 8–12 | **H — built for agentic/SWE tool loops** | Apache-2.0 |
| `phi-4` | 14.7B | 4 / 8 | **16K only** ⚠ | Native (`phi3`) | ~8.5 GB | 12–18 | M | MIT — short context is disqualifying for large-context strategies |
| `DeepSeek-R1-Distill-Qwen-14B` | 14.8B | 4 / 8 | 128K | Native (`qwen2`) | ~8.4 GB | 10–16 (verbose CoT) | L–M | MIT — reasoning distill; long thinking traces inflate latency |
| `DeepSeek-R1-Distill-Qwen-32B` | 32.8B | 4 | 128K | Native (`qwen2`) | ~18 GB | 4–8 (verbose CoT) | L–M | MIT — **marginal on 24 GB** |

**Notes**
- **MoE is the key finding of this tier for 24 GB hardware.** `Qwen3-30B-A3B` and
  `Qwen3-Coder-30B-A3B` carry ~30B of knowledge but read only ~3.3B params per token, so they
  can be *faster* than a dense 14B while being far more capable — *if* the full weight set fits
  in memory. On 24 GB this is right at the edge: expect to raise
  `sudo sysctl iogpu.wired_limit_mb` and to keep the working context modest.
- Dense 32B-class models (`Qwen3-32B`, `Qwen2.5-Coder-32B`, `gemma-3-27b`, `R1-Distill-32B`) are
  all **marginal-to-infeasible** on 24 GB once KV cache and activations are added. Include at
  most one as a "does it even load" data point; do not build the study around them.
- `phi-4`'s 16K context rules it out of Task 5's ≥32K conditions; keep only as a small-context
  reasoning reference.

---

### 4.3 Large tier (~70B+) — upper-reference only

| Model | Params (active) | Quant | Ctx | Mem (4-bit, weights only) | Runnable on 24 GB M5? | License |
|---|---|---|---|---|---|---|
| `Llama-3.3-70B-Instruct` | 70B | 4 / 8 | 128K | ~38–42 GB | **No** — needs ≥ 48 GB (tight) / 64 GB (comfortable) | Llama 3.3 Community |
| `Qwen2.5-72B-Instruct` | 72B | 4 | 128K | ~40–44 GB | **No** | Qwen (Tongyi Qianwen) License |
| `DeepSeek-R1-Distill-Llama-70B` | 70B | 4 | 128K | ~38–42 GB | **No** | MIT |
| `Qwen3-235B-A22B` | 235B (22B active) MoE | 4 | 128K | ~120–130 GB | **No** — needs ≥ 128 GB | Apache-2.0 |
| `Llama-4-Scout-17B-16E` | 109B (17B active) MoE | 4 | very long | ~55–60 GB | **No** — needs ≥ 64–96 GB | Llama 4 Community |

**Decision required from the team (not made here):** the large tier can be handled three ways —
(a) rent/borrow an M-series with ≥ 64 GB for a **bounded upper-reference run** on the same
benchmark, (b) allow a *non-local* API model as a ceiling comparator only, clearly flagged as
out-of-scope for the shipping product, or (c) drop the tier and cap the study at the MoE-30B
class. Recommendation deferred to the Task 3 kickoff.

---

## 5. MLX compatibility details

- **All models above have a native architecture class in current `mlx-lm`** (`llama`,
  `qwen2`, `qwen3`, `qwen3_moe`, `gemma3`, `mistral`, `phi3`). No custom modelling code needed.
- Prebuilt MLX weights exist under `mlx-community/` for the mainstream entries; where a specific
  quant is missing, `mlx_lm.convert --hf-path <repo> -q --q-bits N` reproduces it. **Record the
  conversion command and the resulting weight hash** for every model actually benchmarked
  (study rule #7 / reproducibility; Product Spec §47).
- Quant recipes to include in Task 3: **4-bit (q4, gs64)** as the default, **8-bit (q8)** for the
  ≤ 8B models where it fits, and **bf16** for the ≤ 4B models as a quality ceiling. 6-bit is
  optional and only interesting if 4-bit shows quality cliffs.
- Gemma 3 and Qwen3-MoE are the newest architectures here — verify the installed `mlx-lm`
  version loads them cleanly before committing benchmark time.

---

## 6. Memory budget reality check (24 GB M5)

| Config | Weights (4-bit) | KV @ 8K | KV @ 32K | Fits with 8K ctx? | Fits with 32K ctx? |
|---|---|---|---|---|---|
| 3–4B | ~2–2.6 GB | ~0.4 GB | ~1.6 GB | ✅ huge headroom | ✅ (128K also fine) |
| 7–8B | ~4.3–4.6 GB | ~0.8 GB | ~3.2 GB | ✅ | ✅ |
| 14B | ~8.4 GB | ~1.4 GB | ~5.5 GB | ✅ | ✅ (tight-ish) |
| 24B dense | ~13.5 GB | ~2.5 GB | ~10 GB | ✅ (tight) | ⚠ risky |
| 30B MoE | ~16–17 GB | ~1.5 GB | ~6 GB | ⚠ needs wired-limit bump | ⚠ needs tuning |
| 32B dense | ~18–19 GB | ~2.5 GB | ~10 GB | ⚠ marginal | ❌ |
| 70B dense | ~40 GB | — | — | ❌ | ❌ |

KV figures assume fp16 cache and typical GQA head counts; they are estimates to be replaced by
Task 3 peak-memory measurements. **Practical guidance for the study:** treat **≤ 14B dense** and
**30B-class MoE (with tuning)** as the feasible envelope on this machine; everything larger is
either a marginal single data point or an off-machine reference.

---

## 7. Tool use & structured output — capability notes

The Product Spec (§39–41, §40) requires **narrowly-scoped, read-only tools** and **typed
structured outputs**. Two independent mechanisms matter:

1. **Native tool-calling** (model emits a structured call in its own trained format):
   - **Strong:** Qwen2.5-Coder, Qwen3, Qwen3-Coder (agentic-tuned), Devstral (SWE-agent tuned),
     Mistral-Small-3.x.
   - **Usable:** Llama 3.x (Llama tool format / `<|python_tag|>`), Gemma 3 (function-calling
     prompt convention), Phi-4 / Phi-4-mini.
   - **Weak:** R1-Distill models (reasoning-tuned, not tool-tuned).
2. **Constrained decoding** (grammar / JSON-schema enforced at sampling time), model-agnostic:
   - `mlx-lm` exposes `logits_processors` in `generate_step`; **Outlines** has an `mlx-lm`
     backend for JSON-schema / regex-constrained generation.
   - Caveat to test in Task 3: constraining output can **suppress reasoning quality and
     tool-selection accuracy** ("constraint tax" — arXiv 2606.25605). Measure structured-output
     reliability *and* its effect on correctness, not just schema-validity.
   - The eventual shipping app on Apple Foundation Models would use `@Generable` guided
     generation; the MLX study should emulate that contract with Outlines so results transfer.

**What Task 3 must record per model:** JSON-schema conformance rate, tool-name accuracy,
argument-fill accuracy, and correctness delta between free-form and constrained modes.

---

## 8. Licensing summary (for the shipping decision, not this doc)

| License | Models | Commercial use | Notes |
|---|---|---|---|
| Apache-2.0 | Qwen3 (all), Qwen2.5-Coder (all), Mistral-Small-3.2, Devstral-Small | ✅ unrestricted | Cleanest path |
| MIT | Phi-4, Phi-4-mini, DeepSeek-R1 distills | ✅ unrestricted | |
| Llama 3.x Community | Llama-3.2-3B, Llama-3.1-8B, Llama-3.3-70B | ✅ if < 700M MAU | Attribution + acceptable-use policy |
| Gemma Terms of Use | Gemma 3 (4B/12B/27B) | ✅ with use restrictions | Google prohibited-use policy applies |
| Qwen License | Qwen2.5-72B | ✅ with conditions | Not Apache (unlike Qwen3) |
| MRL (research only) | Ministral-8B | ❌ | Reference/benchmark use only |

---

## 9. Proposed Task 3 shortlist (for review — still not a winner)

To keep Task 3 tractable, benchmark **~6 models** spanning the feasible envelope, plus 1 upper
reference:

| Band | Models | Rationale |
|---|---|---|
| Floor | `Llama-3.2-3B-Instruct` (4-bit, bf16) | Lower bound; is the task even in reach for a 3B? |
| Small generalist | `Qwen3-8B` (4-bit, 8-bit) | Apache, 128K, native tools, strong small reasoner |
| Small coder | `Qwen2.5-Coder-7B-Instruct` (4-bit) | Tests "code-tuned = better system reasoning?" at small size |
| Mid generalist | `Qwen3-14B` (4-bit) | Best-supported dense mid model that fits with room to spare |
| Mid coder | `Qwen2.5-Coder-14B-Instruct` (4-bit) | Code-tuned mid comparator |
| MoE | `Qwen3-30B-A3B-Instruct` (4-bit) | Capability of a 30B at ~14B speed, if it fits |


Open questions to resolve before Task 3:
1. One dense-32B "does it load / how slow" data point — worth the memory pain, or skip?
Answer: Skip. lets focus on the model that not in marginal of 24GB
2. Include a reasoning-distill (R1-Distill-Qwen-14B) to see if explicit CoT helps
   architecture questions enough to justify its latency?
answer: worth to try
3. Which alt-family model — Mistral (Apache, 24B) or Gemma (smaller, Google terms)?
Answer: Gemma
4. Large tier: rent hardware, use an API ceiling, or drop (see §4.3)?
Answer: Drop

---

## 10. Sources

- [mlx-lm on GitHub](https://github.com/ml-explore/mlx-lm) · [mlx-lm on PyPI](https://pypi.org/project/mlx-lm/)
- [Using MLX at Hugging Face](https://huggingface.co/docs/hub/en/mlx)
- [mlx-community org on Hugging Face](https://huggingface.co/mlx-community)
- [Exploring LLMs with MLX and the Neural Accelerators in the M5 GPU — Apple ML Research](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)
- [Explore large language models on Apple silicon with MLX — WWDC25](https://developer.apple.com/videos/play/wwdc2025/298/)
- [Qwen3 blog — Qwen team](https://qwenlm.github.io/blog/qwen3/) · [Qwen3 GitHub](https://github.com/QwenLM/Qwen3)
- [Qwen3-Coder-30B-A3B-Instruct — Hugging Face](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct)
- [Qwen2.5-Coder-32B with 128K context in MLX — ml-explore discussion #1808](https://github.com/ml-explore/mlx/discussions/1808)
- [Gemma explained: what's new in Gemma 3 — Google Developers Blog](https://developers.googleblog.com/gemma-explained-whats-new-in-gemma-3/) · [Gemma 3 technical report](https://arxiv.org/pdf/2503.19786)
- [Mistral Small 3.1 — Mistral AI](https://mistral.ai/news/mistral-small-3-1/) · [Devstral Small — Hugging Face](https://huggingface.co/mistralai/Devstral-Small-2507)
- [Outlines structured generation (mlx-lm backend)](https://github.com/dottxt-ai/outlines)
- [Constraint Tax in Open-Weight LLMs (tool calling under structured output) — arXiv 2606.25605](https://arxiv.org/pdf/2606.25605)
- [apple-silicon-llm-bench — reproducible local LLM benchmark](https://github.com/john-rocky/apple-silicon-llm-bench)
- [Memory bandwidth is the local inference bottleneck: M5 Pro vs Max vs Ultra](https://contracollective.com/blog/apple-silicon-memory-bandwidth-local-llm-tokens-per-second-m5-2026)

> Landscape caveat: the local-model ecosystem moves fast and several data points above
> (mlx-lm version, newest Gemma / Mistral / Qwen point releases, M5 throughput figures) must be
> re-verified at Task 3 kickoff. Every number labelled "est." is a hypothesis for the benchmark
> to confirm or refute — not a result.
