# PHASE7_TEACHING_EVAL.md

Docs/17_phase7_teaching_mode.md M7: calibration of Teaching Mode's answer grader, plus a first
end-to-end read on H8 ("interactive teaching produces better developer understanding than passive
reading"). Companion to `PHASE2_EVAL.md` (can Claude reconstruct architecture) and
`PHASE5_ROUTING_BENCHMARK.md` (does selective escalation earn its cost) — this one asks: **when
the grader turns a developer's free-text answer into a per-criterion verdict, does it agree with a
human reading the same answer against the same rubric?**

The whole of Phase 7's design (Docs/17 §2) rests on one bet: an LLM is more reliable emitting
*atomic, checkable booleans* ("does this answer state that routes are tried in registration
order? yes/no") than emitting a holistic score, and *code* — `RubricScoring.aggregate` — can
turn a set of those booleans into a score, a verdict tier, and a mastery update deterministically.
M7 measures the one link in that chain that is still an LLM: the per-criterion boolean.

## 1. What this answers

- **Grader calibration (the ship gate, Docs/17 Decision 10).** Per-criterion Cohen's κ between
  the local Qwen3-8B grader and hand-authored expert labels, over a gold set of
  (question, developer answer) pairs. Plus: how far the *derived* score lands from an
  expert-derived score, which verdict tiers get confused, how often the k=3 self-consistency
  vote splits, and how often the §7.4 pairwise tripwire fires.
- **H8, n = 1, honestly.** Whether the pipeline runs end-to-end on real output — concept →
  question → answer → per-criterion grade → correction → mastery move → transfer problem —
  against real vendored Starlette. Framed exactly as Phase 2 M4 framed its own first data point:
  "the pipeline works end to end on real output," not "this reliably teaches."

One run, one grader model, one repository, one author. Not a statistical claim about grading
policy in general; §6 and §8 are explicit about what this does and does not establish.

## 2. Method

### 2.1 The grader-calibration gold set

`benchmark/starlette_teaching_grader.gold.json` — **15 items**, each a triple of

- a full `phase7.v1` question (prompt, reference answer, rubric of `required` / `bonus` /
  `anti` criteria, every criterion grounded in `<path>::<Dotted.Name>` anchors that resolve
  against the vendored Starlette run),
- a **developer answer** written to span the quality spectrum (strong / partial / carries a
  named misconception / off-track), and
- an **expert label per criterion** — `met` / `not_met` / `ambiguous` — assigned by reading the
  Starlette source at `4f250d6b814587e20c5365f0a5f0c4d42bcb929f` **before** running the grader.

Coverage: 6 items band 1, 6 band 2, 3 band 3; concepts from 6 areas (Routing, Responses &
Background Tasks, Exception Handling, the Match-enum claim, the Routing→Exception-Handling
relationship, a band-3 `build_middleware_stack` change-impact claim), across the
`component` / `claim` / `relationship` concept kinds. 98 criterion instances; 94 after dropping
4 `ambiguous` expert labels.

**Disclosure — this is a smoke test of the grader machinery, not a validated calibration.**
Single author; the developer answers were written by the same person who wrote the rubrics and
the expert labels; `n` is well below Docs/17 §12.2's target of 10–15 answers *per band*. A real
calibration needs answers from a real developer and labels from a second, independent expert.
The κ below is a first data point and a regression fixture for future prompt changes — the same
"authored with prior knowledge, not blind" limitation Phase 2 M5 carried, one notch weaker
because the answers are synthetic too.

### 2.2 The generation-quality gold set

`benchmark/starlette_teaching.gold.json` — **22 entries**, one per (concept, band): the
acceptable question shape, the reference-answer key points (fact-checked against source), the
required criteria a sound rubric should contain, the anchors that count as valid grounding, and
what a generated question **must not** say. Bands 7 / 11 / 4; kinds 13 component / 5 claim /
4 relationship. Two entries are deliberately built on source concepts that are **factually wrong
for this commit** (`RedirectResponse` default is 307, not the concept's "302"; `Request.body()`
returns the *cached* body on a second call, not "an empty string") — kept as factual-correctness
test cases for the generator. Scored **by hand** against a real generation run (no automated
scorer, same posture as Phase 2 M5). See §5 for status.

### 2.3 The harness

`orion-agent teach bench <repo> --gold <gold.json> --report-dir <dir> --pairwise` (Docs/17 §10).
For each gold item it seeds the question (anchor-resolution enforced; the §6.3 CONTRADICTED-claim
consistency check skipped for trusted hand-authored gold — see §2.4), runs the real
`RubricGrader` with the real `LocalCriterionJudge` (Qwen3-8B-4bit, k = 3 self-consistency,
`persistMastery: false`), pairs each graded criterion to its expert label by verbatim text, and
computes — all in `CalibrationStats`, pure and unit-tested (12 tests):

- **Cohen's κ** over `(expert met/not-met, grader met/not-met)` pairs — overall, restricted to
  grader-confident criteria, and split by `required` vs `anti`.
- **Score MAE / RMSE**: grader-derived score vs. a score `RubricScoring.aggregate` produces from
  the *expert's* labels (an `ambiguous` expert label is treated as not-confident, exactly as a
  split grader k-vote is — so it drops out of the denominator on both sides).
- **Verdict-tier confusion matrix** (`solid` / `partial` / `shaky` / `off-track`).
- **Self-consistency**: fraction of criteria with a split k = 3 vote; of those, how often the
  majority still matched the expert.
- **Disputed rate**: §7.4 pairwise same-idea tripwire firings.

Raw output: `results/phase7_teaching_calibration/teaching_calibration.jsonl` (one row per item,
every per-criterion pair) + `teaching_calibration_summary.json`.

### 2.4 A finding that shaped the harness: the vendored DB's semantic layer

The vendored Starlette `.orion/orion.db` — built up over six phases of development, including
Phase 6 model-revision experiments — has **48 of 108 semantic claims classified `CONTRADICTED`**
(structural Code Graph vs. semantic claim), many over the exact core files (`routing.py`,
`responses.py`, `applications.py`) the teaching concepts and gold questions cite. Several of
those `CONTRADICTED` claims have *accurate* statements; the classification is noisy on this
database (the succeeded run has `resolver: none`, so many `depends_on` edges are unresolved and
claims that need them fall through to `CONTRADICTED`).

Consequence: `TeachingQuestionVerifier`'s §6.3 consistency check (reject a candidate whose
reference anchors best-match a `CONTRADICTED` claim at Jaccard ≥ 0.3) **rejects almost every
hand-authored gold question** on the first pass — the routing question's `{Router, Route,
Match}` anchor set matched a `CONTRADICTED` claim at Jaccard 1.00. This is Docs/17 Risk #2
("verification is structural, not semantic") meeting a database whose structural layer is itself
incomplete. `teach bench` therefore defaults to **trusting the gold question** (schema + anchor
resolution still enforced; `--verify-gold` re-enables the full gate). The finding is recorded,
not papered over: a clean re-investigation of Starlette with a real SCIP resolver is a
prerequisite for the §12.1 generation-gold run to mean anything, and is tracked for M8.

## 3. How to run

```
cd OrionMacOs
xcodebuild -scheme orion-agent -destination 'platform=macOS' -derivedDataPath .build/xcodebuild \
  -skipPackagePluginValidation -skipMacroValidation build

# grading writes rows — run against a COPY of the db
mkdir -p /tmp/st && cp "../Agent Feasibility Study/vendor/starlette/.orion/orion.db" /tmp/st/orion.db
.build/xcodebuild/Build/Products/Debug/orion-agent teach bench \
  "../Agent Feasibility Study/vendor/starlette" \
  --gold "../Agent Feasibility Study/benchmark/starlette_teaching_grader.gold.json" \
  --out /tmp/st \
  --report-dir "../Agent Feasibility Study/results/phase7_teaching_calibration" \
  --pairwise
# --limit N for a cheap smoke slice first
```

Runtime: **~75 min** for 15 items (~294 per-criterion Qwen3 generations at k = 3, plus 30
pairwise same-idea calls) on an M-series laptop. No network, no API cost — grading is fully
local.

## 4. Results — grader calibration

_(run 2026-09-10, vendored Starlette `4f250d6b`, Qwen3-8B-4bit, k = 3, `teach bench --pairwise`, trusted-gold mode)_

### 4.1 Headline

| | |
|---|---|
| gold items graded | 15 / 15 (0 skipped) |
| criterion pairs (matched, non-`ambiguous`) | 94 |
| **Cohen's κ (all criteria)** | **0.894** — "almost perfect" (Landis & Koch) |
| Cohen's κ (grader-confident only) | 0.950 |
| Cohen's κ (`required` only) | 0.875 |
| Cohen's κ (`anti` only — misconception detection) | 0.862 |
| raw agreement | 0.947 (89 / 94) |
| score MAE / RMSE (grader vs. expert-derived) | 0.117 / 0.233 |
| verdict-tier accuracy | 0.733 (11 / 15) |
| split k = 3 votes | 13 (12.1% of criteria) |
| — of those, majority matched expert | 0.769 (10 / 13) |
| disputed (pairwise tripwire) | 5 / 15 |

**Per-criterion agreement is strong and holds across criterion kinds** — the LLM-emits-booleans
bet (Docs/17 §2.1) is supported by this data. On the 81 criteria the grader was confident about,
it disagreed with the expert **4 times** (κ 0.950).

### 4.2 Verdict-tier confusion (expert-derived → grader-derived)

| expert ↓ / grader → | solid | partial | shaky | off-track |
|---|---|---|---|---|
| **solid** | 6 | 0 | 0 | 0 |
| **partial** | 0 | 1 | 0 | 0 |
| **shaky** | 0 | 2 | 0 | 0 |
| **off-track** | 0 | 1 | 1 | 4 |

**Every verdict error is the grader being more lenient** — never stricter. `solid` is called
perfectly (6/6); the drift is entirely on weak answers, where the grader credits ~1 extra
criterion and the score aggregation pushes a borderline answer up a tier.

### 4.3 Where grader and expert disagreed, by hand

Of 94 criterion pairs, **5 disagreements**:

| item | criterion | grader | expert | confident? | reading |
|---|---|---|---|---|---|
| `gc-responses-b1-strong` | anti: "tasks run concurrently / in parallel" | met | not_met | **no (split k-vote)** | strong answer says "sequential not parallel" verbatim; grader split, so it's excluded from the score and surfaced as "needs review" — mechanism working |
| `gc-match-b2-strong` | anti: "PARTIAL short-circuits like FULL" | met | not_met | **no (split)** | same — caught by the split-vote guard, no score impact |
| `gc-match-b2-argmax` | required: "PARTIAL is only used as a fallback…" | met | not_met | yes | **genuine miss** — the argmax-misconception answer never states the fallback rule; grader credited it anyway → verdict `shaky` instead of `off-track` |
| `gc-mw-b3-overbroad` | required: "user-middleware HTTPException renders as its mapped response" | met | not_met | yes | **genuine miss** — the answer says endpoints "keep working like before" and says nothing about user-middleware exceptions; grader credited it → verdict `partial` instead of `off-track` |
| `gc-mw-b3-overbroad` | required: "today ExceptionMiddleware doesn't see user-middleware exceptions" | met | not_met | no (split) | split; contributes to the same lenient verdict |

Two more verdict misses (`gc-match-b2-hedged`, `gc-rel-b2-partial`: `partial` vs `shaky`) have
**no per-criterion disagreement** — they come from `ambiguous` expert labels being excluded from
the expert's denominator but counted by the (confident) grader. A boundary effect of the
ambiguous-handling rule, not a grader error.

**Net:** 2 genuine confident misses in 94 criteria (both crediting a weak answer), plus 2
split-vote catches that the design already neutralises, plus 2 ambiguous-label boundary effects.

### 4.4 The pairwise tripwire (§7.4) over-fires

5 of 15 items flagged `disputed`. **3 of those 5 are on strong answers** (`gc-routing-b1-strong`,
`gc-exceptions-b1-strong`, `gc-mw-b3-strong`) that both grader and expert scored **1.00 / solid**
— the same-idea check returned "not the same idea" for answers that plainly are. Per §7.4 a
`disputed` flag only marks the attempt for review; it does not change the grade. But a 20%
false-positive rate on *perfect* answers means the tripwire as currently prompted is too noisy to
surface to a developer. Tuning it (or gating it to borderline scores only) is an M8 item.

### 4.5 The κ gate (Decision 10)

Bar: **κ ≥ 0.60** per-criterion pooled (Landis & Koch "substantial"; Docs/17 §2.2 cites κ ≈
0.72 / 0.61 across judge models as the expected neighbourhood). **Result: κ = 0.894 — the
mechanical gate PASSES.**

**Decision 10 outcome: the gate is held. `TeachingSession.isCalibrated` stays `false`;
`persistMastery` stays off; the "self-check only" banner stays.** Reasoning:

1. **The gold set is not the one §12.2 specified.** Single author, synthetic answers, self-
   assigned expert labels, n = 15 total (§12.2 asked for 10–15 real developer answers *per*
   band, independently labelled). A κ from a set where one person wrote the answer, the rubric,
   and the "expert" label measures internal consistency more than grader validity.
2. **The measured lenient drift bites exactly what would be turned on.** `isCalibrated = true`
   starts persisting `p_mastered`; an inflated verdict → inflated mastery → the BKT state reads
   "solid" when the developer is "shaky". Verdict-tier accuracy 0.73 with a one-directional
   generous bias is the failure mode Decision 10 exists to prevent.

What M7 delivers instead: the harness (`teach bench` + `CalibrationStats`), both gold sets, and
this result as the regression apparatus. Flipping the gate waits for a real developer-answer /
independent-label set — an M8-or-later task, and one that needs a second person.

## 5. Results — generation quality (§12.1)

**Deferred.** A meaningful generation-gold run needs a clean Starlette re-investigation first
(§2.4): generating teaching questions against a semantic layer that is 44% `CONTRADICTED` over
the core files would measure the state of that database, not the generator. The §12.1 gold set
(`starlette_teaching.gold.json`, 22 entries) is authored and ready; it will be scored by hand
against a generation run once Starlette is re-analysed with a real resolver. The two
deliberately-wrong source concepts (redirect / reqbody) are in place as factual-correctness
traps for that run.

## 6. Reading these numbers

- **n = 15, one author, synthetic answers.** The κ is a smoke test that the grader machinery
  produces sane agreement on clear-cut criteria and a regression fixture for prompt changes —
  not evidence the grader is calibrated for real use.
- **The grader ran fully local.** No Claude in the loop — Qwen3-8B doing per-criterion boolean
  judgement, the cheap path Phase 7 is built around. A κ that holds up here is a stronger
  result than one that needed API spend.
- **`persistMastery: false` throughout the bench.** It measured criterion verdicts and the
  derived score/verdict only; no mastery estimate moved.
- **The corpus DB is not clean (§2.4)** — blocks the §12.1 generation run and means the concepts
  the grader questions are built on come from a noisy semantic layer.
- **The lenient verdict drift and the noisy pairwise tripwire are the two concrete things to
  fix** before this grader drives a persisted mastery estimate.

## 7. H8 — first end-to-end data point

_(vendored Starlette `4f250d6b`, `orion-agent teach` CLI, **local Qwen3 generation and grading**;
the answer is authored by the same person who built the grader — a stand-in, disclosed — so this
shows the *pipeline runs on real output*, not that it teaches. `persistMastery` left on here, its
CLI default, to exercise the mastery write.)_

**`teach next` (band 1, Routing & Endpoint Dispatch, `--source local`).** Qwen3 generated, in one
attempt, a verified question — "How does Starlette's routing system map incoming URLs to
HTTP/WebSocket endpoints using converters?" — with a reference answer and a 5-criterion rubric
(3 `required`, 1 `bonus`, 1 `anti`), every anchor resolving. Question quality was *mediocre*: the
`anti` criterion it wrote — "Endpoints are handled without requiring converter registration" — is
not actually a misconception (most routes have no custom converters), a concrete example of
Docs/17 Risk #1 (a criterion badly worded by the generator, which §6.3 verification can't catch).

**`teach answer` with a deliberately partial answer** (covered Route pattern-matching and type
conversion; **said nothing about `register_url_convertor`**):

```
✓ [required] Route objects match URL patterns to HTTP/WebSocket endpoints
✗ [required] Convertors parse URL parameters into values          (needs review — grader output was not valid JSON)
✗ [required] register_url_convertor registers custom converters   (needs review — grader output was not valid JSON)
✗ [bonus]    compile_path uses Convertor classes                  (needs review — grader output was not valid JSON)
· [anti]     Endpoints are handled without requiring converter…    (needs review — grader output was not valid JSON)
score 1.00  →  solid   (1/1 required, 0 bonus, 0 anti)
mastery: p 0.15 → 0.53   band new → new   (attempt 1)
```

**`teach state`:** `Routing & Endpoint Dispatch — new (p=0.53, n=1, last solid)`.

**This run surfaced a real failure mode, and it argues for the Decision 10 hold.** Qwen3-8B
produced **unparseable JSON on 4 of the 5 criteria** for this particular question. The k = 3
self-consistency guard did its job — all four dropped to `low` confidence and were excluded from
the denominator — but `RubricScoring.aggregate` then computed the score over the **one** required
criterion that did parse (1 / 1 met → 1.00 → `solid`), and mastery moved `p 0.15 → 0.53`. A
partial answer that omitted a whole required concept was scored *perfect* and persisted as such.
The `requiredTotal == 0 → shaky` guard didn't fire because one criterion survived. The correction
text was honest about it ("2 point(s) couldn't be graded confidently and need a manual look"),
and with `persistMastery: false` (the app's setting) no mastery would have moved — but the
verdict a developer sees would still have read `solid`.

Two things to fix in M8, both visible in this one run: (1) the local grader's JSON reliability on
an ad-hoc generated question was far worse here than in the §4 gold run (13 split votes in 94
criteria there; 4 in 5 here) — needs a tolerant re-parse / retry, or the `FoundationModels`
`@Generable` path; (2) a verdict should not be shown as `solid`/`partial`/etc. when fewer than
some floor of the `required` criteria were confidently graded — surface "couldn't grade this
answer" instead.

**H8 proper (§12.3) is not answered here.** The pipeline runs concept → question → decomposed
grade → correction → transfer problem → persisted state on real Starlette output. Whether it
*teaches* — did the transfer problem surface a real gap, did a misconception fire on something
true, did the bands track the learner's own sense of understanding — needs a real learner on a
repo they don't already know. n = 1 and this tester knows Starlette cold (Docs/17 Risk #4); that
half of §12.3 is left for the user.

## 8. Limitations

1. **Single author, synthetic developer answers, n = 15.** Below the §12.2 target; not blind.
2. **One grader model.** Qwen3-8B-4bit only. No comparison against a stronger judge or against
   the `FoundationModels` `@Generable` path (Docs/17 Risk #8).
3. **The corpus DB is 44% `CONTRADICTED`** (§2.4) — blocks the §12.1 generation run and taints
   the concept pool the grader questions are built on.
4. **n = 1 for H8, and the tester knows Starlette cold** (Docs/17 Risk #4). No unfamiliar-repo
   run here.
5. **Verdict-tier accuracy 0.73 with a lenient bias**, and **pairwise tripwire false-positive
   rate ~20% on strong answers** — both measured, both un-tuned, both M8.
6. **Local grader JSON reliability** (§7): on the one ad-hoc generated question, Qwen3 emitted
   unparseable JSON for 4 of 5 criteria — far worse than the §4 gold run — and the
   "exclude low-confidence from the denominator" rule then scored a partial answer as `solid`.
   The gold run may understate this because its questions were hand-authored, not generated.
7. **No verdict floor.** A tier is shown even when only 1 of N `required` criteria was
   confidently graded (§7). M8.
