# Core AI vs MLX backend evaluation (Docs/18 M3) — interim

_Status: **the M3 gate is closed — Core AI passes by decision (2026-09-29)**, taken before the
remaining M3 runs (§5). **MLX was removed in Docs/18 M6**, so the MLX columns here are now
historical and can't be re-measured from this tree. Earlier the same day: **M3 on hold**
(latency is the priority). **M3.5 is done:** native tool calling fixed Core AI's depth-2 format adherence and is now
Core AI's default (§4b). **M4 short run done:** answering moves to 4B without thinking (p50 45 s
vs 99 s, same hand-graded quality); judging keeps 8B with thinking (§4c). **M5 short run done:**
guided-generation grading is 2.5× faster but reaches only κ 0.53 vs 0.78, so the text judge stays
the default. Grading is hardened against single failed calls (§4d)._

_Earlier status: **paused**, and the gate is **not yet decided**. The runtime comparison and the depth-2
comparison are complete. The depth-1 comparison has the MLX half only. The teaching-grader
comparison hasn't run. Resume with
`Agent Feasibility Study/results/coreai_backend/m3/run_m3.sh`; it skips finished steps._

**Setup.**
- Machine and model: Apple M5, 24 GB, macOS 27.0, Qwen3-8B.
- MLX side: `mlx-community/Qwen3-8B-4bit`, loaded by `mlx-swift-lm` 3.31.4.
- Core AI side: `coreai-models` @ `e7b24da`, `qwen3-8b-4bit`, INT4 block-32, exported in Docs/18 M1
  and loaded by `CoreAILanguageModel`.
- Binary: both backends run in the same **Release** `orion-agent` binary.
- Isolation: one backend per process, runs strictly sequential, and each database-writing run on
  a fresh copy of the vendored Starlette `.orion`.
- Everything is local, at $0.

Raw data is in `results/coreai_backend/m3/`, and the tables are built by `analyze_m3.py`.

## 1. Raw runtime — `orion-agent model-bench`

**Method.**
- Greedy decoding, thinking off, streamed, a 256-token cap, and the median of 3 trials after one
  discarded warm-up.
- Every timed run starts with a unique first line. Core AI's engine keeps a token-prefix KV cache
  *across sessions* (`TokenHistory`), so an identical re-send would time a cache hit, not prefill.
  That cross-session reuse is measured on purpose as its own row.
- Memory is peak `phys_footprint` (`proc_pid_rusage`), which is what macOS charges the process.

| metric | MLX | Core AI |
|---|---|---|
| load (warm on-disk caches) | 1.1 s | 2.8 s |
| **peak `phys_footprint`** | 17.43 GB | **10.93 GB** (−37%) |
| short (725 tok): time to first token / prefill / decode | 0.89 s / 813 / 26.8 tok/s | 0.89 s / 814 / 27.2 tok/s |
| production (4,927 tok, real `ContextBuilder` output) | 6.19 s / 796 / 24.1 tok/s | **5.88 s / 838** / 24.3 tok/s |
| long (18,026 tok): time to first token / prefill | 31.9 s / 565 tok/s | **27.0 s / 668 tok/s** |
| long (18,026 tok): decode | **16.6 tok/s** | 9.9 tok/s (−40%) |
| same context again, **new session**: time to first token | 6.17 s | **0.15 s** |
| **follow-up turn, same session**: time to first token | **0.16 s** | 6.19 s |

**Reading.**
- **Prefill and short-context decode:** at parity, with Core AI's prefill up to 18% faster on
  long prompts.
- **Long-context decode:** Core AI is markedly slower.
- **Memory:** Core AI peaks 37% lower.
- **KV reuse runs in opposite directions.**
  - MLX's `ChatSession` keeps its own KV cache, so a follow-up turn is nearly free.
  - Core AI re-tokenizes the whole transcript each turn. The re-rendered transcript diverges early,
    so a follow-up re-processes everything. This is Docs/18 Risk #2, now confirmed.
  - Conversely, Core AI's engine-wide prefix cache makes an identical context in a *new* session
    nearly free. That matters for Orion: every depth-1/2 question starts with the same primed
    context.
- **Phase 0's MLX "8.03 GB" was not a whole-process number.** It came from `mx.get_peak_memory`,
  which counts only MLX's own allocations. Measured the same way as Core AI, MLX's process peaks
  at 17.4 GB.

## 2. End to end — `orion-agent bench --force-depth 2` (all 55 benchmark questions)

| metric | MLX | Core AI |
|---|---|---|
| total wall-clock | 80.1 min | 81.2 min |
| latency p50 / p95 | 81.5 / 157.0 s | 80.3 / 233.3 s |
| **questions with ≥ 1 real tool call** | **49 / 55** | 30 / 55 |
| **malformed action returned as the answer** | 7 | **26** |
| outcomes | verified 26, partially 20, unverified 9 | verified 20, partially 9, **unverified 26** |
| claims recorded | 46 | 29 |

- **The failure is systematic.**
  - 24 of Core AI's 26 malformed replies are the *first* action written as
    `{"action": "<tool name>", "tool": "<tool name>", "arguments": {...}}`. The model knows
    exactly which tool and arguments it wants; it puts the tool name where the literal
    `"call_tool"` belongs.
  - `ActionLoop` treats an unknown action as a malformed final answer, so no tool runs and the
    raw JSON becomes the "answer".
  - MLX's 7 are mostly a different, milder slip: a valid `{"action": "answer", ...}` that didn't
    parse cleanly.
- **Ruled out.**
  - The first-turn prompt is byte-identical on both backends.
  - Sampling parity was checked in source (Docs/18 M2): temperature 0.6, no top-k, top-p or min-P
    on either side.
  - The plausible causes are therefore model-side: Core AI's INT4 block-32 quantization versus
    MLX's 4-bit group-64, or numerics over the ~5K-token system context.

**Hand-graded correctness.** The grades cover the same 10 questions Phase 5 graded, scored
Yes = 2, Reasonable = 1.5, Partial = 1, No = 0, Confabulated = 0. Details are in
`m3/hand_grades_d2.json`.

| | Yes | Reasonable | Partial | No | Confabulated | score |
|---|---|---|---|---|---|---|
| MLX | 0 | 1 | 3 | 4 | 2 | 4.5 / 20 |
| Core AI | 1 | 0 | 4 | 5 | 0 | 6.0 / 20 |

- **When Core AI answers, it's as good or better.** It had no full `ASGIRunner` confabulation,
  and it is the only backend that gave the real reason on TE-02.
- **4 of its 5 "No" grades are the malformed-action no-answer.** Correctness isn't the problem;
  format adherence is.

## 3. `bench --force-depth 1` — MLX baseline only

| metric | MLX | Core AI |
|---|---|---|
| model load (once) | 1.0 s | _not run_ |
| latency p50 / p95 | 75.5 / 169.5 s | — |
| total wall-clock | 74.4 min | — |
| outcomes | verified 55 (nothing asserted: depth 1 has no tools, see Docs/12 Risk #5) | — |
| malformed action / errors | 0 / 0 | — |

**Depth 1 is barely faster than depth 2 on MLX** (p50 75 s versus 82 s). Qwen3's unbounded
thinking dominates latency at both depths, not tool calls.

This matters twice:
- It matters for Core AI's depth-1 comparison, still to run.
- With the OS 27 router sending 54/55 questions to depth 2 anyway (Docs/18 M0), depth 1's only
  role left is questions forced there. Its latency advantage is marginal.

## 4. Teaching grader — `teach bench --pairwise`

_Not run for either backend._

## 4b. Native tool calling on Core AI (Docs/18 M3.5) — **adopted as Core AI's default**

**What changed.** `NativeToolLoop` hands the same four `QueryEngineTools` to a FoundationModels
`LanguageModelSession` as native `Tool`s. The model calls them in Qwen3's own trained
`<tool_call>` format, and `CoreAILanguageModel` parses those calls. The prompt carries no JSON
action contract.

**The run.**
- The same 55 questions, forced to depth 2, on a fresh database copy.
- The plain SwiftPM release binary.
- `--local-backend coreai --tool-protocol native`.
- Raw data is in `results/coreai_backend/m3_5/`, built by `analyze_m3_5.py`.

| metric | MLX json (M3) | Core AI json (M3) | **Core AI native (M3.5)** |
|---|---|---|---|
| questions with ≥ 1 real tool call | 49/55 | 30/55 | **55/55** |
| mean tool calls per question | 1.38 | 0.91 | **1.71** |
| no usable answer (raw JSON / `<tool_call>` / empty) | 7 | 26 | **0** |
| partial | 8 | 27 | **0** |
| outcomes | verified 26, partially 20, unverified 9 | verified 20, partially 9, unverified 26 | **verified 32, partially 21, unverified 2** |
| claims recorded | 46 | 29 | **53** |
| hand-graded (Phase 5 10-question sample) | 4.5 / 20 | 6.0 / 20 | **8.0 / 20** |
| latency p50 / p95, all 55 questions | 81.5 / 157.0 s | 80.3 / 233.3 s | 100.2 / 175.9 s |
| total wall-clock | 80.1 min | 81.2 min | 96.9 min |

**Format adherence is solved.**
- Every question made a real tool call. None ended in protocol debris, and none needed the
  forced-answer path.
- `CoreAILanguageModel` would silently drop a malformed `<tool_call>` block. That never happened.
- M3's systematic slip was `"action": "<tool name>"`: the model reaching for the native
  `{"name", "arguments"}` shape. It disappears once that shape is the protocol.

**Latency, read correctly.**
- The pre-registered criterion was "p50 ≤ Core AI json's 80 s", and it **fails as written**:
  100 s vs 80 s.
- That baseline is flattered by failure. Core AI json's 26 malformed questions ended after
  one turn (p50 37.5 s), with no tool round and no answer.
- Like for like:
  - **On the 29 questions Core AI json actually answered: json 108.4 s, native 101.9 s.**
    Native is ~6% faster.
  - On the 48 questions MLX answered: MLX 84.7 s, native 99.5 s.
- **MLX is still ~15 s faster per question at depth 2.** That fits M3's KV-reuse finding: MLX's
  `ChatSession` keeps its cache across the loop's turns, while Core AI re-prefills each tool round.
- Within one question the time is dominated by Qwen3's thinking, not the tool protocol. A live
  trace of CU-01 spent 58 s reasoning before the first call, out of ~100 s total.

**Hand grades** are in `results/coreai_backend/m3_5/hand_grades_d2_native.json`.
- Two grades improved on Core AI json. The four questions json lost to malformed actions
  (CU-05, CU-08, AR-02, TR-03) are now answered: two Partial, one No, one Confabulated.
- The `ASGIRunner` benchmark confabulation is back on AR-02 and DC-01. It is an answer-quality
  issue shared with MLX, not a protocol one.

**Decision.**
- Native becomes the Core AI default (`LocalModelBackend.defaultToolProtocol`).
- `--tool-protocol json` / `ORION_TOOL_PROTOCOL=json` restores the old path.
- MLX keeps `ActionLoop` (Docs/12 Risk #3). `ActionLoop` goes away with MLX in M6.

## 4c. Per-role model selection (Docs/18 M4, short run)

**Scope.** Kept short on purpose: 1 model-bench trial, 10 depth-2 questions (the Phase 5
hand-graded sample) and a 6-item teaching gold subset. It is enough to choose, not to publish.
- Tables are in `results/coreai_backend/m4/M4_RESULTS.md`, built by `analyze_m4.py`. Hand grades
  are in `m4/hand_grades.json`.
- Configs were set through `ORION_LOCAL_ROLES="*=<variant>:<on|off>"`, the same mechanism
  production uses.

**Raw runtime (greedy, thinking off, 256-token cap).**

| variant | load | peak footprint | prefill 4.9K | decode 725 / 4.9K / 18K tok | TTFT 18K |
|---|---|---|---|---|---|
| 8B | 2.0 s | 9.54 GB | 807 tok/s | 28.6 / 24.8 / 10.5 tok/s | 30.6 s |
| 8B INT8-KV | 21.9 s (first compile) | 17.97 GB | 782 tok/s | 28.2 / 20.2 / 8.0 tok/s | 27.6 s |
| **4B** | 1.4 s | 8.71 GB | **1435 tok/s** | **51.1 / 40.7 / 12.6 tok/s** | **17.1 s** |

**Answering: depth 2, native tools, 10 questions.**

| config | p50 / max | tool call | mean calls | hand grade |
|---|---|---|---|---|
| 8B think on (M3.5) | 99 / 153 s | 10/10 | 1.7 | 8.0 / 20 |
| 8B think off | 50 / 87 s | 10/10 | 4.1 | 7.0 / 20 |
| 8B INT8-KV think on | 134 / 281 s | 10/10 | 1.8 | 8.0 / 20 |
| 8B INT8-KV think off | 55 / 70 s | 10/10 | 4.1 | 7.0 / 20 |
| 4B think on | 63 / 108 s | 10/10 | 1.2 | 7.5 / 20 |
| **4B think off** | **45 / 55 s** | 10/10 | 5.5 | **7.5 / 20** |

**Judging and comparing: `teach bench --pairwise`, k=3, 6 items.**

| config | κ | verdict accuracy | score MAE | unparseable | strong-answer tripwire FPs | wall-clock |
|---|---|---|---|---|---|---|
| **8B think on** | 0.780 | **0.83** | 0.111 | 0/117 | 0 of 2 | 30.6 min |
| 8B think off | 0.040 | 0.00 | 0.550 | 0/117 | 0 of 2 | 5.5 min |
| 4B think on | 0.802 | 0.60 (5 graded) | 0.100 | 0/113 | 0 of 2 | 14.1 min |
| 4B think off | 0.081 | 0.00 | 0.583 | 0/117 | 0 of 2 | 2.8 min |

**Findings.**
- **Answer quality is flat across the matrix.** Grades span 7.0–8.0/20; one point on 10
  questions is within noise. The failures are the same everywhere: 302 for CU-08, the lazy-build
  slip, and missing `RequestBodyLimitMiddleware`.
- **Latency is driven by thinking first, then model size.**
  - Turning thinking off halves 8B's p50 (99 → 50 s), even though those runs make more tool
    calls (4.1 vs 1.7).
  - 4B without thinking is fastest, at a p50 of 45 s and a max of 55 s.
- **Judging needs thinking.** Without it, both sizes answer "met" to about 95% of criteria,
  including misconception (anti) criteria: 8B 38/39, 4B 37/39. Every verdict collapses to
  `partial`, and κ falls to 0.04–0.08.
- **4B with thinking judges almost as well per criterion** (κ 0.80), but:
  - its verdict accuracy is lower;
  - one judge call ended without a response (most likely thinking ran into the 8192-token cap),
    which failed that item's whole grade.
- **The comparer had no strong-answer false positives** on the two Phase 7 items where it
  false-fired under MLX. The short run can't isolate the comparer from the judge, though.
- **INT8-KV loses everywhere:** slower decode, a ~2× memory peak, and a slower thinking-on
  depth 2 (134 s). Rejected.
- **4B barely lowers peak memory** (8.7 vs 9.5 GB). The 40K-context KV cache dominates, not the
  weights.

**Choice: `LocalModelRoles.recommended`.**

| role | model | why |
|---|---|---|
| answering | `qwen3-4b-4bit`, thinking off | p50 45 s (vs 99 s), same quality |
| judging | 8B, thinking on | the only setup with high verdict accuracy and no failures |
| comparing | 8B, thinking on | unchanged; not isolated in the short run |
| drafting | 8B, thinking on | unchanged; deferred (verifier confounded by the 44% `CONTRADICTED` DB) |

- The table applies to plain `--local-backend coreai`.
- An explicit `coreai:<variant>` runs every role on that variant, and `ORION_LOCAL_ROLES`
  overrides both.

**For the full run later.**
- The complete 55-question and 15-item sets.
- The comparer measured on its own.
- 4B with thinking as a judge once a single failed call no longer sinks a grade.
- Drafting after Phase 7 M8's clean re-investigation.
- Memory with two variants loaded in one process (the app runs answering and judging).

## 4d. Guided-generation grading (Docs/18 M5, short run)

**Question.** Can a guided-generation judge, whose reply is a `@Generable` schema instance by
construction, match the thinking text judge at no-thinking speed?
- Same 6-item gold subset as §4c, k=3, pairwise.
- Tables are in `results/coreai_backend/m5/M5_RESULTS.md`.

**Two constraints discovered on the way.**
1. **Constrained decoding can't think.** `CoreAILanguageModel` applies the grammar from the first
   token, so guided turns run with `enable_thinking: false`. Any reasoning must be generated as
   schema text, before the verdict.
2. **Field order is not declaration order on Core AI.**
   - FoundationModels encodes `properties` as an unordered dictionary, plus an `x-order` list.
   - xgrammar (via `coreai-models` @ `e7b24da`) builds the grammar in dictionary order and ignores
     `x-order`.
   - A live stream showed `met` and `confidence` generated while `reasoning` was still partial.
   - Workaround: two guided turns in one session. Turn 1 is `{evidenceQuote, reasoning}`; turn 2
     is `{decision, confidence}`, with turn 1 in context.
   - An upstream issue is drafted in `m5/COREAI_MODELS_ISSUE_DRAFT.md` (not filed).

**Results.**

| judge | κ | verdict accuracy | score MAE | "met" on anti (expert 5/12) | wall-clock |
|---|---|---|---|---|---|
| **8B text, thinking (M4, default)** | **0.780** | **0.83** | 0.111 | 7/12 | 30.6 min |
| 8B text, no thinking (M4) | 0.040 | 0.00 | 0.550 | 12/12 | 5.5 min |
| 8B guided v1 | 0.164 | 0.00 | 0.528 | 12/12 | 10.9 min |
| 4B guided v1 | 0.509 | 0.17 | 0.333 | 8/12 | 7.3 min |
| 8B guided v2 | 0.526 | 0.33 | 0.250 | 8/12 | 12.3 min |
| 4B guided v2 | 0.469 | 0.33 | 0.333 | 7/12 | 7.4 min |

- Parse failures are **0 on every run**, text or guided. On Core AI the text judge had already
  reached M5's original goal in M4.
- There were **0 failed judge calls** with guided output. Guided turns are capped at 512 tokens:
  an uncapped first smoke ran over 9 minutes on one item, most likely a string field never closing.
- **Version 1** (`met` + an anti-criterion note) inverted polarity. A correct analysis ("the answer
  contradicts it") was followed by `met: true`, and some analyses claimed the answer "explicitly
  states" things it didn't.
- **Version 2** added two changes:
  - a kind-neutral decision, `answerStatesThisIdea`, with a prompt that never mentions `met` or
    ANTI;
  - a deterministic grounding check: a "stated" verdict whose quote isn't in the answer becomes an
    unconfident vote.

  That roughly tripled 8B's κ (0.16 → 0.53), but not to the thinking judge's level.

**Decision.**
- **Text with thinking stays the judge and comparer default** (`JudgeOutput.text`).
- Guided output is kept as an opt-in (`--judge-output guided`, `ORION_JUDGE_OUTPUT=guided`) at
  2.5× the speed and clearly lower agreement.
- **Hardening shipped:** a judge call that throws becomes one unconfident "not met" vote instead of
  failing the whole grade, and a failed comparer leaves the tripwire unrun. This fixes the failure
  mode §4c saw on 4B.
- `@Generable AgentAction` is not needed: M3.5's native tool calling already fixed depth-2 format
  adherence.

## 5. Gate status (Docs/18 M3) — **closed: Core AI passes by decision (2026-09-29)**

The project owner took the keep-or-replace decision before the remaining M3 runs, choosing Core AI
as the long-term path because it is Apple's new system inference framework. The table below is
the evidence as it stood, updated with M3.5–M5. It is not a claim that every criterion passed.

| criterion | status at the decision |
|---|---|
| teach κ ≥ MLX − 0.03 and verdict accuracy no worse | **not measured head-to-head.** Core AI 8B with thinking scored κ 0.78 / verdict 0.83 on the 6-item M4 subset. The Phase 7 MLX run scored κ 0.89 / 0.73 on all 15 items, which is not comparable |
| depth-1/2 hand-graded correctness no worse | depth 2: **passes** (8.0/20 native vs MLX 4.5/20); depth 1: **not measured** |
| peak memory ≤ MLX | **passes** (10.9 vs 17.4 GB) |
| decode tok/s ≥ MLX | **mixed:** parity at 725 and 4.9K tokens, **fails** at 18K (9.9 vs 16.6) |
| time to first token at 24K ≤ 1.2 × MLX | **passes** (27.0 vs 31.9 s at 18K) |
| (added) depth-2 format adherence | **passes** with native tool calling (M3.5): 55/55 tool calls, 0 malformed |
| (added) depth-2 latency | same model: **slower** (p50 ~100 s vs MLX 85 s). With M4's per-role default (4B, no thinking): **p50 45 s** |

_Superseded reading from before M3.5–M5, kept for the record:_

| criterion | status so far |
|---|---|
| teach κ ≥ MLX − 0.03 and verdict accuracy no worse | **not measured** |
| depth-1/2 hand-graded correctness no worse | depth 2: **passes on the 10-question sample** (6.0 vs 4.5), but see format adherence; depth 1: pending |
| peak memory ≤ MLX | **passes** (10.9 vs 17.4 GB) |
| decode tok/s ≥ MLX | **mixed**: parity at 725 and 4.9K tokens, **fails** at 18K (9.9 vs 16.6) |
| time to first token at 24K ≤ 1.2 × MLX | **passes** (27.0 vs 31.9 s at 18K) |
| (added) depth-2 format adherence | json protocol **fails** (tool call on 30/55 vs 49/55; malformed 26 vs 7); **native protocol (M3.5) passes: 55/55, 0 malformed** |

**Provisional reading.** Core AI can't replace MLX as the text-JSON `ActionLoop` backend today.
The failure mode is exactly what Docs/18 M5's grammar-constrained `@Generable AgentAction`
removes by construction, because xgrammar can't emit an action outside the schema.

Given that, and Core AI's memory and prefix-cache advantages, the sensible order is:
1. finish the remaining M3 runs;
2. run M5's guided-generation variant on Core AI;
3. only then take the final keep-or-replace decision.

MLX stays the default in the meantime.

**Update after M3.5.**
- Depth-2 format adherence no longer blocks Core AI. Native tool calling solved it without
  waiting for M5's `@Generable AgentAction`, which is now only a fallback.
- What still separates the backends at depth 2 is per-question latency: MLX is ~15 s faster.
  The teaching-grader and depth-1 runs are still open (M3 on hold).
