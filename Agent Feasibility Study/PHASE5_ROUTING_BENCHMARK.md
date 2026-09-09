# PHASE5_ROUTING_BENCHMARK.md

Docs/15_phase5_adaptive_exploration.md §6/M7: the full 55-question routing-quality/latency/cost
benchmark Docs/12_phase3_mlx_agent.md M5 (13 hand-picked questions) and Docs/13_phase4_architecture_ui.md
both explicitly deferred to Phase 5 ("Phase 5 owns turning this into one, not a substitute for
one"). This is that benchmark, at the corpus's real, full scale, against real vendored Starlette
(`4f250d6b814587e20c5365f0a5f0c4d42bcb929f`) — not a re-run of Docs/12 M5's own sample, and not
limited to the 5 categories that sample covered (the corpus has grown to 9 categories since).

## 1. What this answers

First full-scale read on **H4/H5** (does selective escalation earn its cost, and can the router
recognize when it's needed) and the real, measured behavior of the guardrail (Docs/15 §3) at
scale for the first time — M1's own tests and Docs/12's prior runs never exercised it against a
real, varied question set this large. One run, one repository — not a statistical claim about
routing policy in general; §5 below is explicit about what this run does and doesn't establish.

## 2. Method

**The harness**: `orion-agent bench` (Docs/15 §11 M7) — every question run independently
(`sessionId: nil`, matching Docs/12 M5's own single-question shape; this benchmark does not
exercise Phase 5's session-continuity feature, which is a separate concern), through the real,
unmodified `AgentSession.ask(_:)` — real Depth Model routing (heuristic or
`AppleFoundationDepthClassifier`), real guardrail check, real `Qwen3-8B-4bit` for depth 1/2, real
`claude-sonnet-5` CLI delegation for depth 3. No `--force-depth` anywhere in the reported run.
Default `--max-budget-usd 1.00`/`--timeout 400` (`AgentSessionConfig`'s own defaults, unchanged).

**The corpus**: the full `benchmark/benchmark.resolved.json` (55 questions, 9 categories —
`code_understanding`, `cross_file_reasoning`, `architecture`, `dependency_change_impact`,
`behavioral_reasoning`, `contradiction_detection`, `evidence`, `teaching`, `transfer`; the last
four did not exist in Docs/12 M5's 13-question sample, which predates them). Run in two batches
for cost-conscious staging (an 8-question `code_understanding` smoke slice, then the remaining
47) — the results below are the two batches' outputs concatenated; nothing else differs between
them (same repo, same commit, same config, same day).

**Correctness**: graded by hand against each question's own `expected_answer` (already carried
in every output row, Docs/15 §6.3), the same posture Docs/12 M5 used — no automated LLM-judge
axis (Phase 2's own explicitly-deferred stretch goal, still not built). At n=55, exhaustively
grading every answer word-for-word was judged disproportionate for this pass; §4.3 below is a
transparent, representative **sample** (10 of 55, spanning 8 categories and both depths that
produced usable answers), not a claim of having graded all 55.

**Raw data**: `results/phase5_routing_benchmark/routing_benchmark.jsonl` (all 55 rows: id,
category, question, expected_answer, depth, routing method/confidence, outcome, claim counts,
cost, latency, the full answer text) and `routing_benchmark_summary.json` (the aggregates below).

## 3. How to run

```
cd OrionMacOs
xcodebuild -scheme orion-agent -destination 'platform=macOS' -derivedDataPath .build/xcodebuild \
  -skipPackagePluginValidation -skipMacroValidation build   # plain `swift build` won't load Qwen3's Metal shaders

.build/xcodebuild/Build/Products/Debug/orion-agent bench \
  "../Agent Feasibility Study/vendor/starlette" \
  --questions "../Agent Feasibility Study/benchmark/benchmark.resolved.json" \
  --report-dir "../Agent Feasibility Study/results/phase5_routing_benchmark"
# --limit N / --category <name> for a smaller, cost-conscious slice first
```

## 4. Results

### 4.1 Headline numbers

| | |
|---|---|
| questions | 55 (all 9 categories) |
| **total cost** | **$1.01** |
| depth 1 (local, no tools) | 9 (16%) — 9/9 `verified` |
| depth 2 (local + tools) | 43 (78%) — 20 `verified`, 18 `partially_verified`, 5 `unverified` |
| depth 3 (Claude) *attempted* | 3 (5%) — 2 `declined` (guardrail false positive, §4.2), 1 `rejected` (budget exhausted, §4.2) |
| depth 3 *actually completed* | **0** |
| claims asserted / kept | 43 / 38 (88% survived evidence validation) |

The single largest surprise against every prior data point in Docs 12/13: **almost nothing
reached Claude, and of the 3 that did, none produced a usable answer.** Docs/12 M5's own 13
questions landed 9/13 (69%) on depth 3; a later re-verification (Risk #7) landed 1/13 to 9/13
depending on the run. This 55-question run landed **3/55 (5%)**, and even those 3 didn't survive
intact. Latency by depth: depth 1 p50=71.9s/p95=146.6s; depth 2 p50=98.0s/p95=162.1s (both purely
local-model wall-clock, no network); depth 3's 3 samples aren't a meaningful distribution (2 were
near-instant declines, 1 ran 99s before hitting its budget ceiling).

### 4.2 Two real findings, not routing noise

**Finding 1 — the guardrail produced two false positives on legitimately in-scope questions.**
`AR-01` ("What are the major components of Starlette, and how are they layered when handling an
HTTP request?") and `AR-05` ("How does the WebSocket request path diverge from the HTTP path
while going through the same application stack?") were both declined, with the classifier's own
recorded rationale for both: *"This looks like a general knowledge question, not one about the
analyzed repository."* Both are unambiguously about the analyzed repository — AR-01 is close to
verbatim the same question Docs/12 M5's own AR-01 answered correctly at depth 3 with 20 claims.
This is exactly the residual risk Docs/15 §12.1 named in the abstract ("a high false-decline rate
on legitimate questions is a prompt-wording problem to fix... not a reason to add a second
classifier") — now a concrete, measured instance of it, not a hypothetical. Two consequences
worth being explicit about: (a) this run cannot speak to depth-3 answer quality on architecture
questions at all, since the two architecture questions that should have reached Claude never did;
(b) `AppleFoundationDepthClassifier`'s guardrail instructions (Docs/15 §3.2) need a revision pass
before this run's low depth-3 rate is read as "the router correctly decided most questions don't
need Claude" — some real fraction of it is "the router incorrectly decided the question wasn't
about the repository at all."

**Finding 2 — the one real depth-3 attempt hit the budget ceiling, reproducing Docs/12 M5's own
finding 3.** `XF-01` ("Trace, across files, how an unhandled ValueError raised inside an HTTP
endpoint becomes a 500 response") ran 24 turns, spent $1.01, and was rejected for exceeding the
default `--max-budget-usd 1.00` before producing a final answer. Docs/12 M5 hit the identical
wall on `CU-07` at the *original*, lower $0.50 default and raised it to $1.00 as the fix; this run
shows $1.00 itself is still sometimes insufficient for a genuinely multi-file trace. Worth
revisiting the default again (or making it question-complexity-aware) rather than raising it a
second time by feel.

Net effect of both findings together: **this run's 5% depth-3 rate is not solid evidence that
Docs/12 Risk #7's "medium confidence routes to depth 2" policy is working better than previously
measured** — a meaningful share of what should have been depth-3 traffic was lost to a guardrail
bug and a budget ceiling, not correctly kept at depth 2. The real depth-2-vs-depth-3 trade-off
this run was designed to measure is confounded by both.

### 4.3 Correctness — a representative sample, not exhaustive grading

| id | category | depth | outcome | correct? |
|---|---|---|---|---|
| CU-05 | code_understanding | 1 | verified | **No** — omits the `_stream_consumed` guard entirely; Docs/12 M5 found this exact question wrong before, reproduced again |
| CU-08 | code_understanding | 2 | verified | **No** — says 302; real default is 307 (chosen specifically to preserve method/body) — the exact wrong answer Docs/12 M5 already documented for this question |
| XF-04 | cross_file_reasoning | 2 | verified | Reasonable — captures "stack already finalized" but not the actual `self.middleware_stack is not None` guard or insertion position |
| AR-02 | architecture | 2 | verified | Reasonable — correct high-level `__call__` → routing → `receive`/`send` flow, omits `ExceptionMiddleware`'s role |
| DC-01 | dependency_change_impact | 2 | verified | **Confabulated** — cites `benchmarks/routing_benchmark.py::ASGIRunner`, a real-but-unrelated file the model has now fabricated a connection to *twice* across two independent evaluations (Docs/12 M5's XF-07 did the same thing) — see below |
| BR-02 | behavioral_reasoning | 2 | verified | Partial — correct 405 + mechanism, `Allow` header incomplete (`GET` only, omits the implicit `HEAD`) |
| CD-01 | contradiction_detection | 1 | verified | Reasonable — correctly flags the docs/code order doesn't exactly match, direction of the real discrepancy plausible from the truncated answer |
| EV-01 | evidence | 2 | verified | Reasonable — real files/classes cited, but not the exact anchor/line the expected answer names |
| TE-02 | teaching | 1 | verified | **Yes** — correctly identifies the misconception and the real reason (response already sent before background tasks run) |
| TR-03 | transfer | 2 | verified | Partial — plausible race-condition hypotheses offered, misses the expected top hypothesis (exception path bypassing `call_next`'s post-processing) |

**The `ASGIRunner` confabulation recurring is the most concrete finding in this sample.**
Docs/12 Risk #7's six-stage classification table recorded `XF-07` inventing a connection to
`benchmarks/routing_benchmark.py::ASGIRunner` in an entirely separate evaluation run; `DC-01`
here does the same thing, unprompted, on a different question. Two independent occurrences
across two different evaluation sessions is no longer "an occasional hallucination" — it looks
like a specific, reproducible failure mode this model has with this particular repository
(plausibly: `ASGIRunner` is a real, memorable-sounding symbol name the model's retrieval keeps
surfacing as tangentially relevant and then over-attaching to unrelated questions). Worth a
targeted look at what `benchmarks/routing_benchmark.py` actually contains and why it keeps
getting pulled in, before assuming this is generic model noise.

Reading the sample as a whole: depth-2 answers are consistently in the "reasonable direction,
imprecise on the exact mechanism" register rather than depth-1's flatly-wrong register (CU-05/
CU-08, both depth-1-shaped failures even though CU-08 itself routed through depth 2 this run) —
consistent with Docs/12 Risk #7's own prior read that depth 2 "measurably increases genuine tool
use and doesn't regress anything... but is not a substitute for depth 3 on questions that need
either real source-reading or genuinely multi-step investigation." Nothing in this sample
contradicts that; it also cannot confirm or refute Docs/12 M5's "depth 3 correct 7/7" finding,
since this run produced zero completed depth-3 answers to check.

### 4.4 Per-category depth distribution

| category | depth 1 | depth 2 | depth 3 (attempted) |
|---|---|---|---|
| architecture | 1 | 3 | 2 (both declined — Finding 1) |
| behavioral_reasoning | 3 | 6 | 0 |
| code_understanding | 1 | 8 | 0 |
| contradiction_detection | 1 | 4 | 0 |
| cross_file_reasoning | 1 | 6 | 1 (rejected — Finding 2) |
| dependency_change_impact | 0 | 6 | 0 |
| evidence | 0 | 4 | 0 |
| teaching | 2 | 2 | 0 |
| transfer | 0 | 4 | 0 |

Every depth-3 attempt this run came from `architecture` or `cross_file_reasoning` — the two
categories Docs/12 M5 also found hardest and most Claude-dependent. The newer categories
(`contradiction_detection`, `evidence`, `teaching`, `transfer`) never once escalated past depth 2
in this run; whether that's because they're genuinely more tractable locally or because the
classifier under-escalates them is not something this single run can distinguish — worth
watching across a repeated run before concluding either way (the classifier's confidence is
already documented as noisy run-to-run, Docs/12 Risk #7).

## 5. What this is, and isn't, evidence for

**Real evidence for**: the full harness (`orion-agent bench`) works end to end against the real
55-question corpus at real scale, for $1.01 total — confirms Docs/15 M7's own tool is fit for
purpose. It also surfaced two concrete, fixable problems (the guardrail false-positive and the
budget ceiling) that a smaller sample could plausibly have missed by chance, which is itself the
point of running the full corpus rather than stopping at Docs/12 M5's 13 questions.

**Not evidence for**: a reliable read on the *current* depth-3-vs-depth-2 trade-off (confounded
by Finding 1/2, §4.2), a statistically meaningful correctness rate at any depth (n per depth is
small, and depth 3 has n=0 usable), or that the newer categories are inherently depth-2-tractable
(§4.4). A second run, after the guardrail fix, would meaningfully improve on this one rather than
just adding another data point — the guardrail bug is a real confound worth removing before the
next measurement, not something to average away with more samples.
