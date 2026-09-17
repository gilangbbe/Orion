# 17 — Phase 7: Teaching Mode (Development Plan)

> Status: **M0–M7 done.**
> **M0**: `v6_phase7_schema` migration (seven tables + indexes, additive — no Phase 1–6 table
> altered), typed `OrionRecord`s (`Model/TeachingRecords.swift`), the `phase7.v1` candidate DTOs
> (`Teaching/TeachingQuestionCandidate.swift`), six teaching-value enums in `Enums.swift`, bare
> `Store` CRUD for every table — including `knowledge_states`, reserved since Phase 2 and finally
> built. 14 tests (`TeachingSchemaTests`).
> **M1**: `ConceptExtractor` (`Teaching/ConceptExtractor.swift`) — pure deterministic derivation
> of `teaching_concepts` from the latest run's persisted `components` / `component_relationships`
> / non-`UNKNOWN` `claims` + a Phase-1-graph centrality score (`Store.symbolDegrees`, normalised
> to max = 1), same-kind `AnchorAlignment` Jaccard dedup (≥ 0.6), a top-N-by-centrality cap
> (Decision 9, default 60), and natural-key reconciliation on re-run (missing sources →
> `stale`, not deleted; reappearing → revived). `orion-index teach-concepts [--extract]` debug
> command. **M1 covers `component` / `claim` / `relationship` concepts only** — `role` /
> `dataflow` are deferred (each would dedup into its base component; they need a distinct
> identity, resolved alongside M2's band-3 generation). 11 tests (`ConceptExtractorTests`) +
> verified live against the real vendored-Starlette research DB (4 investigations, 142 raw
> candidates → 44 concepts after 23 same-kind dedups, 0 over the 60 cap; re-run inserts 0;
> `--cap 20` correctly caps out 24).
> **M2**: the safety-critical `TeachingQuestionVerifier` (`OrionCodeIntel/Teaching/`) — schema →
> evidence-anchor resolution → `CONTRADICTED`-claim consistency check → persist; a `required`/
> reference anchor that doesn't resolve is fatal, a `bonus`/`anti` one is dropped, and a
> reference answer whose anchors best-match a `CONTRADICTED` claim (Jaccard ≥ 0.3) is rejected.
> `TeachingQuestionGenerator` + `TeachingPromptBuilder` + `LocalTeachingDrafter` /
> `ClaudeTeachingDrafter` (`OrionAgent/Teaching/`, band 1–2 local / band 3 Claude, retry-once on
> rejection), `TeachingSchema.cliJSONSchema()`/`.promptHint`, `orion-agent teach-generate` debug
> command, and a Python offline prompt-iteration helper. 24 new tests (13 verifier + 4 prompt +
> 7 generator) + `TeachingGenerationLiveTests` (env-gated, CI-skipped).
> **Verified live** on real Starlette: Claude band-3 generation produced a genuinely strong
> `add_middleware`-vs-`add_route`-on-a-running-app change-impact question (6 atomic `required`
> + 2 `bonus` + 3 `anti`, all anchors resolved first try); the local Qwen3-8B run produced
> schema-conformant JSON but **hallucinated an anchor twice → correctly rejected** by the
> verifier — the H7 safety gate working as designed, and a real signal that band-1/2 local
> generation will need prompt tightening (or a lower verified-yield expectation) in M7.
> **M3**: `RubricGrader` (`OrionCodeIntel/Teaching/`) — `k = 3` per-criterion judging via an
> injected `CriterionJudging` protocol, majority vote, split k-run → `low` confidence (excluded
> from the score denominator, surfaced as "needs review"); `RubricScoring` (pure) does the §7.3
> threshold math (`required_met / confident_required_total`, bonus capped at +0.15, verdict
> bands, `off-track` forced by a tripped anti + 2 missed required) and the §7.5 templated
> correction; anti-criterion misconception lifecycle (detect → `teaching_misconceptions` +
> `Store.ensureKnowledgeState`; clear on a later confident not-met of the same statement; never
> double-recorded); the §7.4 pairwise `AnswerComparing` tripwire (both orderings, `disputed`
> flag + `teaching_grade` diagnostic, does **not** move the score). `LocalCriterionJudge` /
> `LocalAnswerComparer` (`OrionAgent/Teaching/`, closure-wrapped, tolerant JSON parse → `low`
> not-met on garbage). `orion-agent teach-answer` debug command. Recorded deviation: standalone,
> not `AgentSession.gradeAnswer` (no Depth routing), same as M2. 23 new tests (10 `RubricScoring`
> + 8 `RubricGrader` + 5 `CriterionJudges`) + `TeachingGradingLiveTests` (env-gated, CI-skipped).
> **Verified live** with real Qwen3-8B: a good conceptual answer scored **1.0 / `solid`**, the
> answer carrying the exact "routes match by specificity" misconception scored **0.0 /
> `off-track` with the anti-criterion tripped** — the decomposed-rubric grader distinguishing
> conceptual understanding from a wrong mental model, end to end.
> **M4**: `KnowledgeUpdate` (`OrionCodeIntel/Teaching/`) — the §8.2 BKT-style mastery update, fed
> **criterion-level** (one observation per confident `required` outcome + one strong-negative per
> tripped anti, then a flat `learn` transit), §8.2 defaults; `band(pMastered:attemptsCount:)`
> stays `new` until the 2nd attempt. Wired into `RubricGrader.grade` — **now runs on every
> graded attempt** (M3 only touched `knowledge_states` for misconceptions), updating
> `p_mastered` / `attempts_count` / `confidence_band` / `last_verdict` and returning a
> `KnowledgeDelta` on the result. `TeachingPlanner` (`OrionCodeIntel/Teaching/`) — §8.3
> next-concept ranking `(1 − p) × centrality × recencyPenalty + misconceptionBoost`, ties by
> attempts → band → id, `stale` excluded. `orion-index teach-concepts --plan` and a mastery
> line on `orion-agent teach-answer`. **Decision 8 ("one look at real data")**: applying the
> §8.2 rule to M3's own live good/bad grades gives `p_mastered ≈ 0.81` for the good attempt and
> `≈ 0.15` for the fully-wrong one — recorded finding: the flat `learn` term makes a wholly-wrong
> attempt land back at the *prior*, not near 0, so `p_mastered` alone can't tell "never tried"
> from "tried and failed" (which is why the band gates on `attempts_count` and the planner
> weights an open misconception). Priors kept at §8.2 values. 17 new tests (10 `KnowledgeUpdate`
> + 7 `TeachingPlanner`); full suite **432 → 448, 0 failures**. One build gotcha hit and cleared: the
> `RubricGrader.Result` layout change needed `swift package clean` (the Docs/13 M2
> stale-incremental-object gotcha — SIGSEGV in a value copy until a clean rebuild).
> **M6**: Teaching Mode is a real `OrionApp/` destination — an `HSplitView` concept rail (each
> concept a native `Gauge`-based `MasteryMeter`, ordered by `TeachingPlanner` rank) beside a
> staged work pane (`.picking → .questioning → .grading → .graded`) whose Evaluation `GroupBox`
> shows the **per-criterion checklist** (✓/✗, "needs your review" for a split k-run, the
> developer's quote echoed, tappable evidence anchors, a ⚠ row per tripped anti-criterion) — the
> decomposed grade, not a bare number (H7). `Model/TeachingLoader` (pure projections) +
> `Model/TeachingSession` (`@Observable`) + `Ingestion/TeachingRunner` (mirrors `AskRunner`).
> **Decision 10**: `TeachingSession.isCalibrated = false` until M7 — a persistent "self-check
> only" note, and `RubricGrader(persistMastery: false)` (new flag) grades and records the
> attempt but touches no `knowledge_states` / `teaching_misconceptions`. Sidebar gains a
> misconception badge + a mastery strip. `RubricGrader.PerCriterion` gained
> `criterionId`/`evidenceAnchors`. 11 new tests (`OrionAppTests` 137 → **148, 0 failures**);
> `OrionCodeIntel` suite still green. App builds + launches clean; a populated-screen
> click-through wasn't captured (this app's documented `System Events` limitation, Docs/13 M2–M4).
> **M7**: `orion-agent teach bench` + `CalibrationStats` (pure κ / MAE / confusion, 12 tests) +
> two hand-authored gold sets against vendored Starlette (`benchmark/starlette_teaching_grader.gold.json`
> 15 items, `starlette_teaching.gold.json` 22 entries). Live run (15 items, ~75 min, fully local
> Qwen3, no API cost) → **per-criterion Cohen's κ = 0.894** ("almost perfect"; 0.95
> grader-confident) — the LLM-emits-booleans bet holds. **But** verdict-tier accuracy is 0.73
> with a one-directional *lenient* drift (weak answers bumped up a tier, never down) and the §7.4
> pairwise tripwire false-fires on 3/6 strong answers. **Decision 10 outcome: gate HELD despite
> the κ pass** — `TeachingSession.isCalibrated` stays `false` — because the gold set is
> single-author / synthetic / n = 15 (not §12.2's real-developer-answers spec) and the lenient
> drift is exactly the failure mode mastery persistence would suffer. Finding: the vendored DB's
> semantic layer is 44% `CONTRADICTED`, so §6.3 verification rejects nearly every hand-authored
> gold question — `teach bench` trusts hand-authored gold by default (`--verify-gold` for the
> full gate); a clean Starlette re-investigation is an M8 prerequisite for the §12.1 generation
> run. Write-up: `Agent Feasibility Study/PHASE7_TEACHING_EVAL.md`.
> This document is the
> design pass Docs/14 §4.8 and §7 Decision 3 explicitly deferred ("design an LLM-graded teaching
> loop... should get its own planning doc before implementation"). Remaining milestone entries
> below gain `[done]` markers and real findings as each is built, the same way Docs 10–16 did.
> Depends on Phase 1
> ([10_phase1_deterministic_code_intelligence.md](10_phase1_deterministic_code_intelligence.md)),
> Phase 2 ([11_phase2_semantic_analysis.md](11_phase2_semantic_analysis.md)), Phase 3
> ([12_phase3_mlx_agent.md](12_phase3_mlx_agent.md)), Phase 4
> ([13_phase4_architecture_ui.md](13_phase4_architecture_ui.md)), Phase 4.5
> ([14_phase4_5_ui_ux_redesign.md](14_phase4_5_ui_ux_redesign.md)), and Phase 6
> ([16_phase6_continuous_model_updates.md](16_phase6_continuous_model_updates.md)) — all complete.
> Corpus stays vendored Starlette (pinned `4f250d6b814587e20c5365f0a5f0c4d42bcb929f`) for
> continuity with every prior phase.

## 1. Context

Phases 1–6 built, in order: a deterministic Code Graph (Phase 1); semantic components / claims /
evidence reconstructed via a delegated Claude Code investigation and verified against that graph
(Phase 2); an MLX agent that routes an arbitrary question through local / tool-augmented /
delegated reasoning (Phase 3); an Architecture UI (Phase 4), redesigned for real navigation and
epistemic clarity (Phase 4.5); guardrails, persisted conversational sessions and a routing
benchmark (Phase 5); and continuous, evidence-linked model revisions (Phase 6).

None of them touch the last stage of [05_user_flow_and_ux.md](05_user_flow_and_ux.md) or the last
item of [08_development_phases.md](08_development_phases.md):

```
Phase 7 — Teaching mode

Implement:
- explanation;
- questioning;
- developer answer evaluation;
- misconception detection;
- transfer problems.
```

and Docs/05 Stage 7's loop:

```
Explain -> Question -> Developer answer -> Evaluation -> Correction -> Transfer problem
```

with Docs/05's own one hard constraint on it:

> The system evaluates conceptual understanding, not wording similarity.

Phase 7 is the primary test of **H8** ("interactive teaching produces better developer
understanding and transfer than explanation-only interaction" —
[09_research_hypotheses.md](09_research_hypotheses.md)), and it exercises **H2** (the persistent
Codebase Model is what the teaching layer draws its material from) and **H7** (epistemic
transparency: a developer is shown *why* an answer scored the way it did, not handed an opaque
grade).

### What already exists to build on

- **`knowledge_states`** — reserved and unbuilt since Phase 2 (`Migrations.swift:214`:
  "`knowledge_states` stays reserved and unbuilt (Phase 7 — Teaching)"). Docs/07 §9 already
  sketches its shape: `user_id`, `component_id`, `concepts_seen`, `concepts_mastered`,
  `misconceptions`, `confidence`, `last_assessed`. Phase 7 finally builds it (§9).
- **The persisted Codebase Model** — `components`, `component_members`, `component_relationships`,
  `claims`, `evidence`, `investigations`, `model_revisions` / `model_revision_entries`. Every one
  of these rows is already evidence-linked and epistemically typed
  ([04_codebase_mental_model.md](04_codebase_mental_model.md)); Phase 7 turns them into teaching
  *concepts* (§5) rather than inventing new material.
- **`SemanticImporter`'s validation pipeline** (Phase 2 M2, extended in Phase 3 M3 / Phase 6 M4)
  — schema validation -> evidence-anchor resolution -> structural consistency check -> persistence.
  Phase 7 reuses this exact pipeline to *verify a generated question before it is ever shown*
  (§6.3), the same way Claude's whole-repo findings and single-question answers are verified.
- **`DepthModel` + `AgentSession`** (Phase 3) — the local-Qwen3-8B / Claude-Code split, with
  `--max-budget-usd` / `--timeout` ceilings. Phase 7 routes *question generation* through the same
  split (a 1-hop recall question is local; a 3-hop change-impact question is delegated) rather
  than a new routing mechanism.
- **`AppleFoundationDepthClassifier`** (`@Generable` / `@Guide` constrained generation on Apple's
  on-device model) — Phase 7's per-criterion answer grading (§7) is exactly the "fast, structured,
  near-binary classification" profile this backend was chosen for.
- **`AnchorAlignment`** (Phase 6 M1, ported from `score.py`) — normalized-anchor Jaccard overlap.
  Reused to match a developer's answer spans to rubric criteria and to dedupe concepts.
- **`TeachingView` / `TeachingSample`** (Docs/14 §8 M7) — the Explain / Question / Your Answer /
  Evaluation / Correction / Transfer *screen shape* is already built and shipping, backed by one
  fixed `TokenManager` vs. `SessionManager` sample. Phase 7 swaps the sample for a real
  `TeachingLoader` / `TeachingRunner` and adds the per-criterion checklist (§11); it does not
  re-litigate the screen's layout.

---

## 2. Research foundations

The user's framing for this phase: *if we put an LLM in the loop for generating questions and
grading answers, the LLM can be wrong — so how do we make it reliably better at both?* And a
specific intuition to test: *LLMs are much stronger at anything with numbers or measurable
criteria than at holistic judgement.*

That intuition is well-supported, and it points at one concrete technique that shapes this entire
phase.

### 2.1 The core thesis — decompose every judgement into small measurable checks

The single most consistent finding across the LLM-as-a-judge literature is that **a holistic
score is noisy and a decomposed one is not**. Asking a model to "grade this answer 1–10" or "how
well does the student understand X" forces it to calibrate against an abstract scale it has no
stable anchor for; the same pair of answers re-scored minutes apart lands 0.1–1.0 points apart,
inside the judge's own variance
([Rubric-Conditioned LLM Grading](https://arxiv.org/pdf/2601.08843),
[A survey on LLM-as-a-judge](https://www.sciencedirect.com/science/article/pii/S2666675825004564)).

What *is* reliable: many small, atomic, near-binary decisions against explicit criteria, each
answered `true`/`false` with a supporting quote, then **aggregated into a number by code, not by
the model**. Google's own practitioner guidance is blunt about it — "evaluating multiple
requirements in a single question forces the LLM judge to guess which clause is more important;
divide requirements into discrete, atomic TRUE/FALSE questions" and "treat rubrics like formal
specifications, constrain the judge to strict objective boolean truths"
([How to Write Reliable Rubrics for LLM-as-a-Judge Evaluations](https://dev.to/googleai/how-to-write-reliable-rubrics-for-llm-as-a-judge-evaluations-ndp)).
Rubrics that describe *what makes an answer succeed* ("constitutive") reproduce far better than
rubrics that presuppose a quality scale — Cohen's κ ≈ 0.72 vs. 0.61 across judge models
([Can LLM-as-a-Judge Reliably Verify Rubrics in Agentic Scenarios?](https://arxiv.org/pdf/2606.29920)).
Prometheus, the strongest open evaluator line, only reaches GPT-4-level agreement with humans
(Pearson ≈ 0.90) *when a per-task score rubric and a reference answer are both supplied*
([Prometheus](https://arxiv.org/abs/2310.08491)); without them it collapses. G-Eval's
chain-of-thought-then-form-fill protocol makes the same move — turn the judgement into a filled
form, not a free number ([G-Eval](https://arxiv.org/abs/2303.16634)).

This is **exactly the discipline Orion already runs on**: Phase 2 M2 derives a component's
`confidence_tier` from "did every cited member resolve" rather than asking Claude for a
confidence; Phase 6 Decision 2 generates the "Reason" sentence from a deterministic template over
structured diff facts, not a model call. Phase 7 applies the same rule to teaching: **the LLM
produces atomic criterion verdicts; the score, the verdict tier and the mastery update are
computed deterministically from those verdicts.**

### 2.2 Question generation — grounded and difficulty-controlled, not free-form

Free-form "write me a question about this code" is the weakest possible use of a generator: the
question can be ambiguous, the implied answer can be wrong, and there is nothing to grade against.
The knowledge-graph QG literature converges on two fixes Orion is well-placed to adopt:

- **Generate from a grounded sub-structure, and carry a reference answer + rubric with the
  question.** KG-driven MCQ pipelines build the question, the key, and the difficulty estimate
  together from a selected subgraph, then run automatic quality filtering before use
  ([KNIGHT](https://arxiv.org/html/2602.20135),
  [Generating MCQs with Interpretable Difficulty Estimation](https://doi.org/10.3390/make8050137),
  [An LLM-Guided Method for Controllable Question Generation](https://aclanthology.org/2024.findings-acl.280.pdf)).
  Orion's `claims` / `evidence` / `component_relationships` rows *are* that grounded
  sub-structure, and they already carry the anchors a reference answer must cite.
- **Control difficulty structurally (graph hop-distance), not by asking the model for "hard".**
  DCQG work shows a difficulty *label* in the prompt does not reliably produce a
  difficulty-appropriate question — there is no enforced causality between the label and the
  output ([Difficulty-controllable QG over KGs](https://www.sciencedirect.com/science/article/abs/pii/S0306457324000815)).
  What does work: a difficulty *parameter that controls graph depth* — 1-hop for recall, 2-hop
  for comprehension / contrast, 3+-hop for multi-step transfer
  ([KNIGHT](https://arxiv.org/html/2602.20135),
  [KAQG](https://arxiv.org/pdf/2505.07618)). This maps one-to-one onto Docs/09's own teaching
  evaluation dimensions (recall / conceptual understanding / change-impact reasoning /
  novel-scenario transfer) and onto Orion's existing Depth Model levels.

### 2.3 Answer evaluation — rubric decomposition, calibration, "conceptual not wording"

Docs/05 §7's "conceptual understanding, not wording similarity" *is* the rubric-decomposition
result stated as a requirement. Embedding-similarity-to-a-reference-answer is precisely the
wording-similarity trap; a set of semantic criteria each checked with a supporting quote from the
developer's own answer is how the literature actually gets to conceptual grading. Recent work
grading real student free-response explanations this way reports LLM–human discrepancy of 0–3%
per criterion ([Using an LLM to Investigate Students' Explanations on Conceptual Physics
Questions](https://arxiv.org/html/2508.14823),
[LLM-as-a-Grader](https://arxiv.org/html/2511.10819v2)).

Adopted concretely (§7):

- **One constrained call per criterion** (or one batched structured array), returning
  `{ met: bool, confidence: high|medium|low, evidence_quote, note }`. Atomic, evidence-bearing.
- **Self-consistency**: judge each criterion k = 3 times on the cheap local model, majority vote;
  a split vote becomes `confidence: low` and is surfaced as "needs review", never silently
  scored. Repeated-assessment inconsistency is a named failure mode
  ([Can LLM-as-a-Judge Reliably Verify Rubrics…](https://arxiv.org/pdf/2606.29920)); k-sampling is
  the standard cheap mitigation.
- **Deterministic aggregation**: `score = met_required / total_required`, bonus criteria add a
  capped margin; verdict tiers (`solid` / `partial` / `shaky` / `off-track`) are fixed threshold
  bands. The model never sees a running total, so it cannot anchor.
- **Misconception detection as explicit anti-criteria**: a separate list of "statements that would
  indicate a wrong mental model", generated with the rubric, each atomic and evidence-linked. An
  answer that trips one records a `misconception`. Generate-retrieve-rerank over a misconception
  bank is the stronger approach in the literature
  ([Misconception Diagnosis From Student-Tutor Dialogue](https://arxiv.org/html/2602.02414),
  [Evaluating GPT for detecting erroneous mental models in programming education](https://link.springer.com/article/10.1007/s10209-026-01320-z));
  Phase 7 ships the anti-criteria form first and leaves a retrieval bank as a follow-up (§15).
- **A calibration gate before shipping** (§12): a hand-graded gold set of real developer answers,
  expert-scored per criterion; measure the grader's per-criterion Cohen's κ and its score MAE vs.
  expert. Ship the confident-grade UI only if κ clears a bar; otherwise the verdict renders as
  "self-check only" — the exact lesson from Docs/12 Risk #5 (a depth-1 "verified" that was really
  "not checked"), carried into teaching.

### 2.4 LLM-judge failure modes, and what we do about each

| Failure mode | Evidence | Mitigation in Phase 7 |
|---|---|---|
| Holistic-score variance / poor scale calibration | [Rubric-Conditioned LLM Grading](https://arxiv.org/pdf/2601.08843) | Never ask for a score; derive it from atomic verdicts (§2.1, §7.3). |
| Verbosity bias (longer answer scored higher) | [survey](https://www.sciencedirect.com/science/article/pii/S2666675825004564) | Rubric is *coverage* of required criteria; reference answer is deliberately terse; length is never an input. |
| Position / selection bias | [CalibraEval](https://arxiv.org/pdf/2410.15393) | Not applicable to single-answer grading. For the optional "answer vs. reference" sanity pass, run both orderings and average ([Pair2Score](https://arxiv.org/pdf/2605.02069)). |
| Self-preference / self-consistency drift | [Can LLM-as-a-Judge Reliably Verify Rubrics…](https://arxiv.org/pdf/2606.29920) | k = 3 majority vote per criterion; disagreement -> `confidence: low`, flagged for review. |
| Reasoning-free judging is worse | [Explicit Reasoning Makes Better Judges](https://arxiv.org/pdf/2509.13332) | Each criterion verdict requires the supporting `evidence_quote` and a one-line `note` before the boolean — a mini chain-of-thought, form-filled (G-Eval shape). |
| Rubric granularity drives agreement | [Generating and Refining Dynamic Evaluation Rubrics](https://arxiv.org/html/2605.30568v1) | Criteria are single-fact, constitutive ("mentions the dependency direction"), never compound. |
| Human corrections should feed back | [How to Calibrate LLM-as-Judge with Human Corrections](https://www.langchain.com/resources/llm-as-a-judge) | The calibration gold set (§12) is expert-corrected per criterion and is the regression set for any prompt change. |

### 2.5 Mastery modelling under few observations

A teaching session produces very few graded items per concept, and educational-measurement work
is explicit that "high measurement precision is unattainable using only accuracies" at that
sample size — richer per-item signal (partial credit, response time) is what buys back
reliability ([Learning meets Assessment: IRT and BKT](https://arxiv.org/abs/1803.05926),
[StanBKT](https://arxiv.org/pdf/2605.23048)). Two consequences for Phase 7:

- **Track `p(mastered)` explicitly as a probability with a Bayesian-Knowledge-Tracing-style
  update** (`slip` / `guess` / `learn` parameters), not a running average of right/wrong. Show it
  as a coarse band (`new` / `shaky` / `developing` / `solid`), never a false-precise percentage.
- **Feed the update criterion-level, not question-level.** One question yields 4–8 atomic
  observations (each criterion met / not), which is the "get more signal per administered item"
  move the literature recommends — far better than one binary correct/incorrect per question.

### 2.6 Design principles carried into the rest of this document

- **P1 — The model proposes atomic facts; code decides scores.** Generation emits a question +
  rubric + reference answer + anti-criteria; grading emits per-criterion booleans. Every number a
  developer sees (score, verdict tier, mastery band) is computed by `RubricGrader` /
  `KnowledgeState`, never by an LLM.
- **P2 — Nothing unverified is ever shown.** A generated question runs through
  `SemanticImporter`'s existing anchor-resolution + consistency check before it can be asked; one
  that cites an unresolvable anchor or a `CONTRADICTED` reference claim is dropped, exactly as a
  bad Claude finding is (§6.3).
- **P3 — Difficulty is structural.** Hop-distance in the Codebase Model sets the difficulty band;
  the prompt never just says "make it hard".
- **P4 — Reuse the routing and verification stack.** Generation goes through `DepthModel` /
  `AgentSession`; verification goes through `SemanticImporter`; a generation run *is* an
  `investigations` row.
- **P5 — Epistemic transparency (H7).** The developer sees the checklist: which criteria were met,
  the quote that satisfied each, the grader's confidence. The grade is never opaque.
- **P6 — Honest about n = 1.** This is a single-user local tool; H8 gets a first data point from
  the user's own use, framed as such — not a controlled study.

---

## 3. Decisions

Items marked **(open)** are genuine judgement calls to confirm with the user before or during the
milestone noted; everything else follows directly from §2 and prior-phase precedent.

1. **One document, one phase** — matching Docs/15 Decision 1. The research lives in §2 of this
   plan, not a separate literature doc; empirical results land in
   `Agent Feasibility Study/PHASE7_TEACHING_EVAL.md` during M7, the same place Phase 2/5 put
   theirs.
2. **Teaching material is derived, never authored.** Every concept, question, rubric and reference
   answer traces to persisted `components` / `claims` / `component_relationships` rows and their
   evidence anchors. No hand-written question bank.
3. **The LLM never emits a score.** Generation and grading emit structured facts only (P1). This
   is the direct, concrete answer to "the LLM could be wrong" — it is wrong at the level of one
   checkable boolean with a quote attached, which is auditable and cheap to gold-test, not at the
   level of a hidden grade.
4. **Difficulty band = hop-distance** (P3): band 1 = one component/claim (recall); band 2 = one
   relationship, or a two-component contrast (comprehension); band 3 = a 3+-hop chain or an
   explicit change-impact framing ("if X were removed…") (transfer).
5. **Generation routing = the Phase 3 Depth Model.** Band 1–2 generation runs local (Qwen3-8B,
   bounded structured output); band 3 delegates to Claude Code (it already does change-impact
   reasoning in Phase 3/5). Same `--max-budget-usd` / `--timeout` ceilings.
6. **Grading runs local by default.** Per-criterion boolean judging is Qwen3-8B (or Apple
   `FoundationModels` `@Generable` where constrained decoding is cleaner); a batch of
   `confidence: low` criteria may be re-checked once via Claude Code, gated by a small budget.
7. **Single developer identity for v1** — a fixed `developer_id = 'local'`. The column exists for a
   future multi-user story (mirrors Docs/07's `user_id`), but no auth, no profiles.
8. **Mastery is a BKT-style probability shown as a band** (§2.5), not a percentage. **(open, M4)**
   — the exact `slip`/`guess`/`learn` priors and the band cutoffs want one look at real Starlette
   data before they are fixed.
9. **Concept cap.** On a large repo, `ConceptExtractor` keeps the top-N concepts by architectural
   centrality (default N = 60), the same "cap by centrality" posture `ArchitectureModelLoader`
   already takes for the diagram. **(open, M1)** — N.
10. **The calibration gate is a real gate.** If M7's gold-set per-criterion κ is below the bar
    (**open** — proposed ≥ 0.6), the app ships Teaching Mode with the verdict labelled "self-check
    only — not independently calibrated" and no mastery persistence, rather than showing a grade
    the evidence doesn't support.

---

## 4. What Phase 7 is not

- **Not a change to `DepthModel`, `ActionLoop`, guardrails, sessions, or `RevisionDiffer`.** Phase
  7 adds a new consumer of the Codebase Model and a new `AgentSession` entry point; it does not
  touch routing, Phase 5's session machinery, or Phase 6's diffing.
- **Not a new epistemic vocabulary.** [04_codebase_mental_model.md](04_codebase_mental_model.md)
  §3's `FACT|INTERPRETATION|INFERENCE|UNKNOWN|CONTRADICTED` set is closed. A rubric criterion's
  `kind` (`required`/`bonus`/`anti`) and a verdict tier are teaching-layer concepts, not new claim
  types.
- **Not a UI redesign.** Docs/14 §4.8 already designed and built `TeachingView`'s shape; Phase 7
  wires real data into it and adds the checklist + mastery strip, nothing more.
- **Not a spaced-repetition scheduler / long-term curriculum engine.** v1 selects the *next*
  concept by mastery × centrality with a short no-immediate-repeat window (§8.3). A real
  review-scheduling policy is a follow-up if usage warrants it.
- **Not a controlled learning study.** H8 gets a first, n = 1, self-reported data point (P6), the
  same honesty every prior phase applied to its own hypotheses.
- **Not a misconception *retrieval bank*.** v1 detects misconceptions via generated anti-criteria
  only; a curated, embedding-retrieved bank (§2.3) is explicitly deferred (§15).

---

## 5. Concepts — the teaching unit

A **concept** is one evidence-linked unit of understanding derived from the persisted Codebase
Model. `ConceptExtractor` (`Sources/OrionCodeIntel/Teaching/ConceptExtractor.swift`, pure logic
over `Store`, no model) produces them from the latest architecture investigation plus every
Ask/depth-3 investigation's surviving claims:

| Concept `kind` | Derived from | Example (Starlette) | Difficulty band seed |
|---|---|---|---|
| `component` | a `components` row + its `description` / `architectural_role` | "Routing & URL Convertors — matches requests to endpoint handlers" | 1 |
| `claim` | a non-`UNKNOWN` `claims` row + its evidence | "`Router.app` dispatches to the first matching `Route` in declaration order" | 1–2 |
| `relationship` | a `component_relationships` row | "Middleware Stack depends on Routing" | 2 |
| `role` | a component's `architectural_role` in context of its neighbours | "why Error & Exception Handling is a cross-cutting layer, not a leaf" | 2–3 |
| `dataflow` | a 3+-hop chain of `component_relationships` | "how a request travels app -> middleware -> routing -> endpoint" | 3 |

Each concept carries: `subject_label`, `source_component_id` / `source_claim_id`, an
`evidence_anchors[]` set (unioned from the source rows), a `centrality` score (from the Phase 1
relationship graph — in/out degree of the concept's member symbols, normalised), and a
`difficulty_band` seed (a generated question may land one band higher or lower and updates the row
if so). Concepts are de-duplicated by `AnchorAlignment` overlap (≥ 0.6 on normalised anchors ->
same concept, keep the higher-centrality label).

`ConceptExtractor` re-runs whenever a new investigation is ingested (cheap, deterministic); a
concept whose every source row was removed by a later investigation is marked `stale`, not
deleted, so a `KnowledgeState` pointing at it still resolves (same "pointer outlives target"
discipline as Docs/15 §4.2 sessions).

---

## 6. Question + rubric generation pipeline

`TeachingQuestionGenerator` (`Sources/OrionAgent/Teaching/`), driven by `AgentSession`.

### 6.1 Structured output contract (`TEACHING_QUESTION_SCHEMA`, version `phase7.v1`)

```json
{
  "schema_version": "phase7.v1",
  "concept_id": "…",
  "difficulty_band": 2,
  "explain": "Two–three sentence primer that sets up the question without answering it.",
  "question": "Explain the difference between TokenManager and SessionManager, and how they interact.",
  "reference_answer": "Concise model answer, ≤ 120 words, every factual clause citing an anchor.",
  "reference_anchors": ["starlette/middleware/sessions.py::SessionMiddleware", "…"],
  "rubric": [
    { "kind": "required", "text": "Identifies TokenManager as the narrow token refresh/validation helper.",
      "evidence": ["…::TokenManager"] },
    { "kind": "required", "text": "Identifies SessionManager as owning the session lifecycle.",
      "evidence": ["…::SessionManager"] },
    { "kind": "required", "text": "States the direction of the interaction (SessionManager delegates persistence, not the reverse).",
      "evidence": ["…::SessionManager.save"] },
    { "kind": "bonus", "text": "Mentions the hand-off to SessionStore / Keychain.",
      "evidence": ["…::SessionStore"] }
  ],
  "anti_criteria": [
    { "text": "Claims the two are interchangeable / the same layer.", "evidence": ["…::SessionManager"] },
    { "text": "Reverses the dependency (claims TokenManager owns sessions).", "evidence": ["…::TokenManager"] }
  ],
  "transfer_problem": "If SessionStore were removed tomorrow, which component changes first, and why?"
}
```

- `rubric[]` criteria are **single-fact and constitutive** (§2.4). 3–6 `required`, 0–3 `bonus`.
- `anti_criteria[]` are the misconception detectors (§2.3) — 1–3, each the negation of a required
  criterion or a known reversal.
- Every `evidence` / `reference_anchors` entry is a verbatim `<path>::<Dotted.Name>` anchor from
  `symbols.jsonl`, same contract as Phase 2/3.
- `transfer_problem` is a band = `difficulty_band + 1` framing, not graded in the same attempt —
  it seeds the *next* question if the developer chooses "Try the transfer problem".

### 6.2 Difficulty control (P3)

`AgentSession.generateQuestion(conceptId:band:)` selects the concept's neighbourhood by hop-count:

- **Band 1** — the concept's own rows only. Prompt asks for a recall/definition question. Local.
- **Band 2** — the concept + its direct `component_relationships` neighbours, or a sibling
  concept to contrast against. Local.
- **Band 3** — a 3+-hop chain, or the concept plus an explicit "what breaks if this changes"
  framing. Delegated to Claude Code (`--max-budget-usd` default `0.50`, band-3 generation is
  cheaper than a full Ask investigation).

The Depth Model is *not* re-run here — the band already determines local-vs-delegated, directly.

### 6.3 Verification before use (P2)

A generated question is a candidate, not a question, until it passes — reusing
`SemanticImporter`'s existing steps, not a new checker:

```
TEACHING_QUESTION_SCHEMA candidate
  ↓
1. Schema validation        -- Decodable, schema_version, required-field / band-range / count bounds.
  ↓
2. Evidence validation      -- every rubric.evidence / anti_criteria.evidence / reference_anchor
  |                            resolves to a real symbols.anchor in the current run
  |                            (Store.symbol(runId:anchor:), parent-symbol-aware per Phase 2 M2).
  |                            Any unresolved anchor on a `required` criterion or the reference
  |                            answer -> candidate REJECTED (diagnostic TEACHING_ANCHOR_UNRESOLVED).
  |                            An unresolved anchor on a `bonus`/`anti` criterion -> that criterion
  |                            dropped, candidate kept.
  ↓
3. Consistency check        -- the reference answer's factual clauses are matched (AnchorAlignment,
  |                            ≥ 0.3) against persisted `claims`; if the best match is
  |                            `CONTRADICTED`, the candidate is REJECTED
  |                            (TEACHING_REFERENCE_CONTRADICTED) -- we never teach against a claim
  |                            the Code Graph already disagrees with.
  ↓
4. Persist                  -- teaching_questions (verified = 1) + teaching_rubric_criteria rows,
  |                            plus one investigations row (question = "phase7_question_generation",
  |                            complexity = band-mapped, model_used, cost/turns/duration) so a
  |                            generation run is auditable exactly like any other investigation,
  |                            and Phase 6's RevisionDiffer sees it (it will find nothing to diff
  |                            -- generation asserts no new claims -- which is correct).
```

A rejected candidate is retried once at the same band with the diagnostics fed back into the
prompt; a second rejection drops that concept from this session with a logged reason (not shown
to the developer as a failure — the next concept is simply chosen).

---

## 7. Answer evaluation pipeline — the quantified core (P1)

`RubricGrader` (`Sources/OrionAgent/Teaching/RubricGrader.swift`).

### 7.1 Per-criterion judging

For each `teaching_rubric_criteria` row (including `anti`), one structured judgement:

```json
{ "criterion_id": "…",
  "evidence_quote": "verbatim span from the developer's answer, or \"\" if none",
  "note": "one line: why this is / isn't met",
  "met": true,
  "confidence": "high" }
```

- Constrained generation (`@Generable` on `FoundationModels`, or Qwen3-8B with the same
  extract-the-JSON tolerance Phase 3's `ActionLoop` uses).
- The `evidence_quote` and `note` are required **before** `met` in the schema — a form-filled
  mini-rationale, per [Explicit Reasoning Makes Better Judges](https://arxiv.org/pdf/2509.13332).
- The grader sees: the criterion, the developer's full answer, the concept's evidence snippets. It
  does **not** see the reference answer for the boolean pass (that would invite wording-similarity
  grading); the reference answer is only used in the optional §7.4 sanity pass.
- **Self-consistency**: k = 3 samples per criterion on the local model (cheap). Majority `met`;
  a 2–1 or 1–1–1 split sets `confidence: low`.

### 7.2 Misconception detection

`anti` criteria are judged the same way. `met = true` on an anti-criterion means the
misconception is present -> a `teaching_misconceptions` row (linked to the tripped criterion and
this attempt) and a flag on the `KnowledgeState`. A misconception clears (`cleared_at` set) when a
later attempt on any question for the same concept judges the same anti-criterion `met = false`
with `confidence: high`.

### 7.3 Deterministic scoring (never the model)

```
required_met   = count(required criteria with majority met, confidence != low-and-split)
required_total = count(required criteria)
bonus_met      = count(bonus criteria with majority met)
raw            = required_met / required_total                       (0.0 – 1.0)
score          = min(1.0, raw + 0.05 * bonus_met)                    (bonus caps at +0.15)

verdict tier:
  score >= 0.85  and 0 anti tripped         -> solid
  score >= 0.6                              -> partial
  score >= 0.3                              -> shaky
  else, or any anti tripped with 2+ required missed -> off-track
```

`low`-confidence criteria are **excluded from `required_total`** and listed separately as "needs
your review" — the developer, or a later Claude re-check, resolves them; they never silently
count as pass or fail.

### 7.4 Optional reference sanity pass

Once per attempt (not per criterion), a single pairwise judgement — "does the developer's answer
convey the same core idea as the reference answer?" — run **both orderings and averaged**
([Pair2Score](https://arxiv.org/pdf/2605.02069), [CalibraEval](https://arxiv.org/pdf/2410.15393)).
This does **not** affect `score`; a large disagreement between the pairwise verdict and the rubric
score (e.g. rubric says `solid`, pairwise says "misses the point") is surfaced as a
`TEACHING_SCORE_DISPUTED` diagnostic and flags the attempt for the calibration set (§12). It is a
tripwire on the rubric, not a second grade.

### 7.5 Correction text

Deterministically templated (Phase 6 Decision 2 precedent), from the *unmet* required criteria and
any tripped anti-criteria: *"You covered X and Y. You didn't establish {unmet criterion text}. You
also implied {anti-criterion text}, which isn't right: {reference clause}."* No model call. A
local-model paraphrase pass to smooth it is an explicit follow-up (§15), not v1.

---

## 8. KnowledgeState + concept selection

### 8.1 Schema-backed mastery (§9)

One `knowledge_states` row per `(developer_id, concept_id)`. Realises Docs/07 §9:

| Docs/07 field | Phase 7 column |
|---|---|
| `concepts_seen` | a row existing at all; `attempts_count` |
| `concepts_mastered` | `p_mastered >= 0.85` (band `solid`) |
| `misconceptions` | `teaching_misconceptions` rows with `cleared_at IS NULL` |
| `confidence` | `confidence_band` (`new`/`shaky`/`developing`/`solid`), derived from `p_mastered` + `attempts_count` |
| `last_assessed` | `last_assessed_at` |

### 8.2 Update rule (BKT-style, §2.5) **(open, M4 — priors/cutoffs)**

Per attempt, fold in **each criterion result** as a separate observation (not one per question):

```
p          = prior p_mastered (default 0.15 on first sight)
for each required criterion result (in order):
    obs    = met ? 1 : 0
    p_obs  = obs==1 ? (p*(1-slip) + (1-p)*guess)
                    : (p*slip     + (1-p)*(1-guess))
    p      = obs==1 ? p*(1-slip) / p_obs
                    : p*slip     / p_obs
p          = p + (1-p)*learn        -- learning from having engaged with the concept
p_mastered = p
```

Defaults to tune on real data: `slip = 0.1`, `guess = 0.2`, `learn = 0.15`. A tripped
anti-criterion applies one extra `obs = 0` with `slip = 0.05` (a misconception is strong negative
evidence). `confidence_band` stays `new` until `attempts_count >= 2` regardless of `p_mastered` —
one lucky question is not mastery (§2.5: small-N caution).

### 8.3 Next-concept selection

`TeachingPlanner.next(developerId:)`:

```
score(concept) = (1 - p_mastered) * centrality * recency_penalty
recency_penalty = 0.1 if assessed in the last 3 selections, else 1.0
```

Pick the max; ties broken by lowest `attempts_count` then lowest `difficulty_band`. A concept with
an uncleared misconception gets a +0.3 additive boost — shaky *load-bearing* understanding is the
priority. `stale` concepts (§5) are excluded.

---

## 9. Schema (`v6_phase7_schema`, GRDB `DatabaseMigrator`)

Additive only — no Phase 1–6 table altered. Follows the bare-CRUD-in-`Store` precedent of
`routing_decisions` (Phase 3 M1), `ask_sessions` (Phase 5 M0), `model_revision_entries` (Phase 6
M0).

```sql
CREATE TABLE teaching_concepts (
    id                TEXT PRIMARY KEY,
    repository_id     TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
    kind              TEXT NOT NULL,          -- 'component'|'claim'|'relationship'|'role'|'dataflow'
    subject_label     TEXT NOT NULL,
    source_component_id TEXT REFERENCES components(id) ON DELETE SET NULL,
    source_claim_id   TEXT REFERENCES claims(id) ON DELETE SET NULL,
    evidence_anchors  TEXT NOT NULL,          -- JSON array
    centrality        REAL NOT NULL DEFAULT 0,
    difficulty_band   INTEGER NOT NULL DEFAULT 1,
    stale             INTEGER NOT NULL DEFAULT 0,
    created_at        TEXT NOT NULL,
    UNIQUE (repository_id, kind, subject_label)
);

CREATE TABLE teaching_questions (
    id               TEXT PRIMARY KEY,
    concept_id       TEXT NOT NULL REFERENCES teaching_concepts(id) ON DELETE CASCADE,
    investigation_id TEXT REFERENCES investigations(id) ON DELETE SET NULL,
    difficulty_band  INTEGER NOT NULL,
    explain          TEXT NOT NULL,
    prompt           TEXT NOT NULL,
    reference_answer TEXT NOT NULL,
    reference_anchors TEXT NOT NULL,          -- JSON array
    transfer_problem TEXT,
    generated_by     TEXT NOT NULL,           -- 'local' | 'claude_code'
    verified         INTEGER NOT NULL DEFAULT 0,
    created_at       TEXT NOT NULL
);

CREATE TABLE teaching_rubric_criteria (
    id          TEXT PRIMARY KEY,
    question_id TEXT NOT NULL REFERENCES teaching_questions(id) ON DELETE CASCADE,
    ordinal     INTEGER NOT NULL,
    kind        TEXT NOT NULL,                -- 'required' | 'bonus' | 'anti'
    text        TEXT NOT NULL,
    evidence_anchors TEXT NOT NULL,           -- JSON array
    UNIQUE (question_id, ordinal)
);

CREATE TABLE teaching_attempts (
    id           TEXT PRIMARY KEY,
    question_id  TEXT NOT NULL REFERENCES teaching_questions(id) ON DELETE CASCADE,
    developer_id TEXT NOT NULL DEFAULT 'local',
    answer_text  TEXT NOT NULL,
    score        REAL NOT NULL,               -- derived (§7.3), never model-authored
    verdict_tier TEXT NOT NULL,               -- 'solid'|'partial'|'shaky'|'off-track'
    model_used   TEXT,
    disputed     INTEGER NOT NULL DEFAULT 0,  -- §7.4 tripwire
    created_at   TEXT NOT NULL
);

CREATE TABLE teaching_criterion_results (
    id            TEXT PRIMARY KEY,
    attempt_id    TEXT NOT NULL REFERENCES teaching_attempts(id) ON DELETE CASCADE,
    criterion_id  TEXT NOT NULL REFERENCES teaching_rubric_criteria(id) ON DELETE CASCADE,
    met           INTEGER NOT NULL,
    confidence    TEXT NOT NULL,              -- 'high'|'medium'|'low'
    evidence_quote TEXT NOT NULL,
    note          TEXT NOT NULL,
    vote_detail   TEXT,                       -- JSON: the k=3 sample outcomes
    UNIQUE (attempt_id, criterion_id)
);

CREATE TABLE knowledge_states (
    id               TEXT PRIMARY KEY,
    developer_id     TEXT NOT NULL DEFAULT 'local',
    concept_id       TEXT NOT NULL REFERENCES teaching_concepts(id) ON DELETE CASCADE,
    p_mastered       REAL NOT NULL DEFAULT 0.15,
    attempts_count   INTEGER NOT NULL DEFAULT 0,
    last_verdict     TEXT,
    confidence_band  TEXT NOT NULL DEFAULT 'new',
    first_seen_at    TEXT NOT NULL,
    last_assessed_at TEXT NOT NULL,
    UNIQUE (developer_id, concept_id)
);

CREATE TABLE teaching_misconceptions (
    id                TEXT PRIMARY KEY,
    knowledge_state_id TEXT NOT NULL REFERENCES knowledge_states(id) ON DELETE CASCADE,
    criterion_id      TEXT NOT NULL REFERENCES teaching_rubric_criteria(id) ON DELETE CASCADE,
    attempt_id        TEXT NOT NULL REFERENCES teaching_attempts(id) ON DELETE CASCADE,
    statement         TEXT NOT NULL,
    detected_at       TEXT NOT NULL,
    cleared_at        TEXT
);

CREATE INDEX idx_teaching_concepts_repo    ON teaching_concepts(repository_id, stale, centrality);
CREATE INDEX idx_teaching_questions_concept ON teaching_questions(concept_id, verified);
CREATE INDEX idx_teaching_attempts_question ON teaching_attempts(question_id, created_at);
CREATE INDEX idx_knowledge_states_dev      ON knowledge_states(developer_id, concept_id);
CREATE INDEX idx_teaching_misconceptions_ks ON teaching_misconceptions(knowledge_state_id, cleared_at);
```

`diagnostics` (existing table) gains `stage = "teaching_generate"` /
`stage = "teaching_grade"` codes: `TEACHING_SCHEMA_INVALID`, `TEACHING_ANCHOR_UNRESOLVED`,
`TEACHING_REFERENCE_CONTRADICTED`, `TEACHING_CRITERION_SPLIT_VOTE`, `TEACHING_SCORE_DISPUTED`.

### 9.1 Export additions (`<out>/export/`)

Additive to [EXPORT.md](../OrionMacOs/EXPORT.md), matching Phase 2 M3 / Phase 6 M4:
`teaching_concepts.jsonl`, `teaching_questions.jsonl` (with nested `rubric[]`),
`teaching_attempts.jsonl` (with nested `criterion_results[]`), `knowledge_state.json` (the
current per-concept mastery snapshot). `orion-index export` gains a fourth exporter call, no-op
when the repo has no teaching data yet.

---

## 10. CLI (`orion-agent teach`)

A new nested `AsyncParsableCommand` group, mirroring Phase 5's `session` group. Verified live
against the real analyzed fixture repo per this codebase's own CLI-testing precedent (no XCTest
against ArgumentParser structs).

- **`teach concepts <path>`** — lists derived concepts: label, kind, difficulty band, centrality,
  and current mastery band. `--json`.
- **`teach next <path>`** — `TeachingPlanner.next` picks a concept, generates (or reuses an
  existing verified) question, prints `Explain` + `Question`. `--concept <name-or-anchor>` forces
  a concept; `--band 1|2|3` forces difficulty; `--max-budget-usd` / `--timeout` for band-3
  delegation.
- **`teach answer <path> <question-id> "<answer>"`** — runs `RubricGrader`, prints the per-criterion
  checklist (✓/✗/? with the quote and note for each), the derived score + verdict tier, the
  templated correction, the `KnowledgeState` delta (`p_mastered` before -> after, band change,
  any misconception detected/cleared), and the transfer problem. `--json`. `--explain` adds the
  k = 3 vote detail and the §7.4 pairwise sanity result.
- **`teach state <path>`** — dumps `knowledge_states` + open misconceptions. `--json`.
- **`teach bench <path> --gold <gold.json> --report-dir <dir>`** — the calibration harness (§12):
  per-criterion Cohen's κ vs. expert labels, score MAE, verdict-tier confusion matrix,
  disputed-attempt rate. Writes `teaching_calibration.jsonl` + a summary, exactly the
  `orion-agent bench` shape from Phase 5 M7.

Exit codes follow `orion-agent ask`: `0` handled, `1` generation rejected / grader failed, `2`
usage, `3` no analyzed run / no semantic investigation.

---

## 11. App UI wiring (`OrionApp/`)

Minimal, additive — Docs/14 §4.8 already built the screen shape.

- **`Model/TeachingLoader.swift`** — reads `teaching_concepts` / `knowledge_states` via
  `CodebaseModelStore` (stays read-only, Docs/13 M3), maps them onto the existing
  `TeachingSample` shape *plus* a new `criteria: [CriterionResultView]` list.
- **`Ingestion/TeachingRunner.swift`** — mirrors `AskRunner`: resolves the Claude binary via
  `ClaudeBinaryLocator` (the GUI-`PATH` gap Docs/13 Risk 13 already fixed twice), calls
  `AgentSession.generateQuestion` / `AgentSession.gradeAnswer` on a background `Task`, writes
  through a fresh writable `Store`.
- **`TeachingView` changes** — swap `let sample: TeachingSample` for `@State` loaded data; the
  Evaluation section gains the **criterion checklist** (each row: ✓/✗/? icon via `EpistemicBadge`
  colours, the criterion text, the developer's quote that satisfied it, a `ConfidenceBadge` for
  the grader's confidence). Evidence anchors in the checklist open the existing `EvidenceView`
  sheet. The derived score + verdict tier render as a `ConfidenceBadge`-style band, not a number
  alone. "Try the transfer problem" advances to a band + 1 question on the same concept; "Next
  concept" calls `TeachingPlanner`.
- **Sidebar** — the `.teaching` destination (already present, Docs/14 §8 M1) gets a real
  unread-style badge = count of concepts with an uncleared misconception, reusing
  `sidebarBadgeCount(for:)` (the generic infra Phase 6 M6 built). A small mastery summary strip
  ("18 concepts · 6 solid · 2 shaky · 1 misconception") sits under the repo identity block.
- **Calibration honesty** — if Phase 7 ships before M7's gold set clears the κ bar (§3 Decision
  10), `TeachingView` shows a persistent "Self-check only — grading is not yet calibrated against
  expert review" note and `TeachingRunner` skips `knowledge_states` writes.

No change to `RepositorySession`, `AnalysisRunner`, `AskRunner`, `AgentSession`'s existing
entry points, or the navigation shell.

---

## 12. Calibration & evaluation (H8)

Produced during **M7**, written up in `Agent Feasibility Study/PHASE7_TEACHING_EVAL.md` (the Phase
2 / Phase 5 precedent).

### 12.1 Generation quality gold set

`Agent Feasibility Study/benchmark/starlette_teaching.gold.json` — 20–30 hand-authored
(concept -> acceptable question shape + reference-answer key points + required-criteria list),
covering all three difficulty bands and every concept `kind`. Score a real generation run:
question relevance, reference-answer factual correctness (hand-checked against source), rubric
criterion validity (is each criterion actually single-fact and checkable), anchor resolution rate.
Disclosed limitation, same as Phase 2 M5: authored with knowledge of Starlette's structure, not
blind.

### 12.2 Grader calibration gold set

10–15 real developer answers per band (solicited from the user across a spread of concepts),
**expert-labelled per criterion** (met / not met / ambiguous). Metrics:

- **Per-criterion Cohen's κ** (grader vs. expert) — the ship gate (§3 Decision 10).
- **Score MAE** and **verdict-tier confusion matrix** (grader-derived vs. expert-derived from the
  same expert criterion labels).
- **Self-consistency**: fraction of criteria with a split k = 3 vote; agreement of majority vote
  with expert on those.
- **Disputed rate**: §7.4 tripwire firings, hand-adjudicated.

### 12.3 H8 first data point

The user works through a Teaching Mode session on vendored Starlette (a codebase they now know
well from six phases of building against it — so a weak learning signal, acknowledged), plus one
genuinely unfamiliar small Python repo. Report, honestly n = 1: did the transfer problems surface
real gaps; did misconception detection fire on anything true; did the mastery bands track the
user's own sense of what they did and didn't understand. This is a first data point for H8, framed
exactly as Phase 2 M4 framed its own ("the pipeline works end to end on real output", not "this
reliably teaches").

---

## 13. Testing & verification

**Unit (`OrionCodeIntelTests` / `OrionAgentTests`, no model load, no network)**

- `ConceptExtractor` against a real small analyzed fixture repo: components/claims/relationships
  become the expected concept rows; centrality matches a hand-computed degree count; a concept
  whose source rows are removed by a second investigation goes `stale`, not deleted;
  `AnchorAlignment` dedup collapses two overlapping concepts to one.
- `TeachingQuestionGenerator` verification pipeline (fixture candidates, no live model): a valid
  `phase7.v1` candidate round-trips and persists; an unresolvable `required`-criterion anchor
  rejects with `TEACHING_ANCHOR_UNRESOLVED`; an unresolvable `bonus` anchor drops that criterion
  and keeps the question; a reference answer matched to a `CONTRADICTED` claim rejects with
  `TEACHING_REFERENCE_CONTRADICTED`; a schema-version mismatch rejects; the generation
  `investigations` row is written on both accept and reject.
- `RubricGrader` scoring math (pure function, synthetic criterion-result arrays): `required_met /
  required_total` with bonus cap; `low`-confidence criteria excluded from the denominator and
  listed separately; verdict-tier thresholds at their exact boundaries; an anti-criterion `met`
  forcing `off-track` when 2+ required missed.
- `KnowledgeState` update (pure function): the BKT fold over a known criterion-result sequence
  reaches a hand-computed `p_mastered`; `confidence_band` stays `new` until `attempts_count >= 2`;
  a tripped anti-criterion applies the extra negative observation; a later high-confidence
  `met = false` on the same anti-criterion sets `cleared_at`.
- `TeachingPlanner.next`: selection score ordering, recency penalty, the misconception boost, ties
  broken deterministically, `stale` concepts excluded.
- `v6_phase7_schema` migration: applies cleanly on top of `v5_phase6_schema`; all new tables +
  indexes present; Phase 1–6 tests still green; cascade directions confirmed
  (`teaching_concepts` delete cascades questions/criteria/attempts/results/knowledge_states;
  `knowledge_states` delete cascades misconceptions).

**Model-dependent (`XCTSkip` without an opt-in env var, same posture as Phase 2/3's live tests)**

- `ORION_TEACHING_LIVE_LOCAL=1` — real Qwen3-8B generates a band-1 question for a real Starlette
  concept that passes verification; real `RubricGrader` judges a hand-written good and a
  hand-written bad answer to expected verdict tiers.
- `ORION_TEACHING_LIVE_CLAUDE=1` — real `claude` CLI generates a band-3 change-impact question,
  verified and persisted.

**CLI** — verified live against a real tiny analyzed fixture repo (no XCTest against ArgumentParser
structs, per Phase 5 M5 precedent): `teach concepts`, `teach next` (auto and `--concept` /
`--band`), `teach answer` (checklist + score + state delta rendering), `teach state`, and
`teach answer` against a bogus question id failing fast with exit 3 before any model load.

**CI** — stays Swift-only and network-free; all live `teaching` test classes added to the CI
`--skip` list, same defense-in-depth as Phase 3/5. `OrionApp.xcodeproj` keeps its build-only CI
job.

---

## 14. Implementation order

Each milestone lands real code + tests against `OrionMacOs/` (and, from M6, `OrionApp/`), with a
`[done]` marker and real findings added here before the next starts — the Docs 10–16 rhythm.

- **M0 — Schema skeleton. [done]** `v6_phase7_schema` migration
  (`Migrations.swift` — `registerV6` + `v6SQL`, seven tables: `teaching_concepts`,
  `teaching_questions`, `teaching_rubric_criteria`, `teaching_attempts`,
  `teaching_criterion_results`, `knowledge_states`, `teaching_misconceptions`, plus five indexes;
  additive, no Phase 1–6 table touched). Typed records (`Model/TeachingRecords.swift`, all seven
  with explicit `public init`s per the `AskSessionRecord` M0 precedent — M2/M3's generator and
  grader live in `OrionAgent` and need to construct them cross-module). Six teaching-value enums
  in `Enums.swift` (`TeachingConceptKind`, `RubricCriterionKind`, `TeachingQuestionSource`,
  `TeachingVerdictTier`, `GraderConfidence`, `KnowledgeConfidenceBand`). The `phase7.v1` candidate
  DTOs + `TeachingSchema.currentVersion` (`Teaching/TeachingQuestionCandidate.swift`), mirroring
  `SemanticFindings`/`AgentAnswerFindings`. Bare `Store` CRUD (insert/read primitives + the two
  genuinely-bare single-column writes `setTeachingConceptStale` / `setTeachingMisconceptionCleared`
  and a whole-row `updateKnowledgeState` — no composed lifecycle logic, that's M1–M4). **Decision:
  teaching rows are keyed by `repository_id` only**, not `(repository_id, commit_hash, run_id)` —
  a developer's learning artifacts persist across a re-analysis of the same commit, so
  `source_component_id`/`source_claim_id` are `ON DELETE SET NULL` and `ConceptExtractor` (M1)
  re-marks a source-less concept `stale` rather than the DB deleting it (same "pointer outlives
  target" discipline as Docs/15 §4.2). 14 new tests (`TeachingSchemaTests`): migration applies on
  top of `v1`…`v5`; every record round-trips incl. JSON-array anchor columns; `stale` filter +
  centrality ordering; `UNIQUE(developer_id, concept_id)` and `UNIQUE(question_id, ordinal)`;
  concept-delete cascades the whole subtree; a deleted source component `SET NULL`s the FK but
  leaves the concept; repository-delete cascades concepts. Full `OrionCodeIntel` suite **374
  tests, 0 failures** under the exact CI invocation (`swift test` + the seven live-class
  `--skip`s). `OrionApp.xcodeproj` untouched — no app-side teaching code until M6.
- **M1 — `ConceptExtractor`. [done]** `Sources/OrionCodeIntel/Teaching/ConceptExtractor.swift`
  (`enum`, pure logic over `Store`, no model). `extract(store:commitHash:cap:now:)` reads the
  latest run and derives:
  - **`component` concepts** — one per `ComponentRecord` in the run's *latest architecture
    investigation* (`question == InvestigationRecord.architectureQuestionMarker`, `.last`); label
    = name; anchors = member symbol anchors; band 1.
  - **`relationship` concepts** — one per `ComponentRelationshipRecord` in that investigation;
    label = `"Source → Target"`; anchors = the two endpoints' member-anchor union, sorted and
    capped at 40; band 2.
  - **`claim` concepts** — one per non-`UNKNOWN` `ClaimRecord` across *every* investigation for
    the run (identical statements collapsed); label = statement; anchors = resolvable evidence
    anchors; band 1 if one anchor else 2. A claim with no resolvable evidence is skipped.
  - **Centrality** — `Store.symbolDegrees(runId:)` (new: in+out degree per symbol over the Phase 1
    `relationships` graph, one `UNION ALL … GROUP BY`); a concept's raw score is the sum over its
    member symbols, normalised so the top concept = 1.0.
  - **Dedup** — `AnchorAlignment` normalised-Jaccard ≥ 0.6, **same-kind only**. Real finding: the
    first cut deduped cross-kind and a small two-component relationship collapsed into its
    endpoint on the fixture; "how X and Y interact" is distinct band-2 material from "what X is",
    so same-kind is the fix (documented in the code).
  - **Cap** — top-N by centrality (**Decision 9**, `defaultCap = 60`); overflow counted as
    `cappedOut`, not inserted.
  - **Reconciliation** — `DeterministicID.teachingConcept(repositoryId:kind:subjectLabel:)` is the
    natural key; on re-run an unchanged concept is a no-op, a concept whose sources vanished is
    `setTeachingConceptStale(true)` (never deleted), a stale concept whose sources return is
    revived. M1 does **not** rewrite an existing concept's centrality/band/anchors (documented
    simplification — content refresh is a later milestone if cross-re-analysis drift matters).

  `role` / `dataflow` concepts are **not** built in M1 — each would produce a concept whose
  anchor set is a subset of some `component` concept's, so even same-kind dedup can't save them;
  they need a distinct identity, a question better answered alongside M2's band-3 generation
  (which is what consumes band 2–3 material).

  `orion-index teach-concepts [--db|--out] [--commit] [--cap] [--extract] [--include-stale]
  [--json]` (`TeachConceptsCommand.swift`, registered in `OrionIndex.swift`) — mirrors
  `revisions`' `--db`/`--out` convention; `--extract` runs the derivation then prints an
  `inserted/revived/re-staled/deduped/over-cap` summary.

  **11 tests** (`ConceptExtractorTests`, fixture-driven): the three kinds + labels/source ids/
  bands; anchors are sorted members; unresolvable-evidence and `UNKNOWN` claims yield nothing;
  centrality normalises to max 1.0; same-kind dedup collapses a 0.6-Jaccard pair keeping the
  higher-centrality label; `--cap 2` keeps the top two; re-run is idempotent; a vanished source
  is re-staled then revived; a claim-only run still produces `claim` concepts; no run → empty
  `Result`. **Verified live** against the real vendored-Starlette research DB (on a copy —
  defensive against DEBUG `eraseDatabaseOnSchemaChange`, harmless for an additive migration but
  the DB holds 4 paid investigations): 43 components / 62 relationships / 37 non-`UNKNOWN`
  claims → 142 raw candidates → **44 concepts** after 23 same-kind dedups, **0 over the 60 cap**
  (so the default holds comfortably for a repo this size — the cap is a large-repo safety valve,
  not a routine constraint); re-run inserted 0; `--cap 20` capped out 24; output ranks
  relationships/components sensibly by centrality (`Routing → Connection & Message Objects` top
  at 1.000). Full `OrionCodeIntel` suite green under the exact CI invocation.
- **M2 — Question + rubric generation. [done]**
  - **`TeachingSchema` (`OrionCodeIntel/Teaching/TeachingQuestionCandidate.swift`)** gained
    `cliJSONSchema()` (structural, `$schema`-less, for `claude --json-schema`) + `promptHint`,
    mirroring `AgentAnswerSchema`. Length floors `minReferenceAnswerChars = 20` /
    `minCriterionChars = 8` (the Phase 3 M5 `"test"`-answer lesson).
  - **`TeachingQuestionVerifier` (`OrionCodeIntel/Teaching/`)** — pure over `Store`, the
    load-bearing safety gate. `verifyAndPersist(candidate:concept:store:run:generatedBy:now:)`:
    (1) schema/shape — `schema_version`, `concept_id` matches the requested concept,
    `difficulty_band ∈ 1…3`, non-empty explain/question, reference answer ≥ 20 chars, ≥ 1
    `required` criterion, every `rubric[].kind ∈ {required,bonus}`, every criterion text ≥ 8
    chars; (2) evidence — each `reference_anchor` and each `required` criterion anchor resolves
    via `Store.symbol(runId:anchor:)`, **any miss is fatal**; a `bonus`/`anti` criterion with an
    unresolvable anchor is **dropped** (`TEACHING_CRITERION_DROPPED` warning), kept if ≥ 1 anchor
    survives; (3) consistency — normalise `reference_anchors`, find the best-Jaccard persisted
    claim across the run's investigations, reject if that claim (≥ 0.3) is `CONTRADICTED`;
    (4) persist a `verified` `TeachingQuestionRecord` + ordered `TeachingRubricCriterionRecord`s
    (required → bonus → anti). Writes `diagnostics` rows (`stage = "teaching_generate"`,
    **random ids** — a generation is non-deterministic/repeatable, unlike Phase 1's
    content-addressed diagnostics, so a content hash would collide across retries).
    **Recorded deviation from §6.3**: M2 does **not** write an `investigations` row for a
    generation run — a `"phase7_question_generation"` row would become the newest one and silently
    break `SemanticExporter`'s `Store.latestInvestigation(runId:)` scoping;
    `teaching_questions.investigation_id` stays null, `generated_by` is the provenance record.
    **Recorded deviation from §14**: not a method on `AgentSession` — generation doesn't route
    through the Depth Model (§6.2), so it's the standalone `TeachingQuestionGenerator` the CLI/app
    construct directly.
  - **`TeachingPromptBuilder` / `TeachingQuestionGenerator` / drafters (`OrionAgent/Teaching/`)** —
    `TeachingPromptInputs` (pure); `TeachingPromptBuilder.build` assembles the task/band-guidance/
    grounding/schema-hint prompt (related concepts only at band ≥ 2, prior-rejection reasons
    appended on retry). `TeachingQuestionDrafting` protocol (+ `source`); `LocalTeachingDrafter`
    (closure over a `Qwen3Agent.respond`, `source = .local`); `ClaudeTeachingDrafter`
    (`ProcessRunner` + the exact `ClaudeCodeInvestigator` flag set, `source = .claudeCode`, and —
    live finding — surfaces the wrapper's own `errors`/`subtype` on a no-candidate result, the
    same gap Phase 5 M5 fixed for `ClaudeCodeInvestigator`). `TeachingQuestionGenerator.generate`
    gathers grounding from the `Store`, drafts, tolerantly extracts the JSON object, decodes,
    verifies, and **retries once** with the rejection reasons fed back; returns
    `.generated` / `.rejected` / `.draftUnusable`.
  - **`orion-agent teach-generate <path> --concept <id-or-label> [--band] [--source
    local|claude|auto] [--out] [--commit] [--max-budget-usd] [--timeout] [--json]`** — debug
    command, mirrors `classify`; registered in `OrionAgentCLI.swift`.
  - **`harness/orion_eval/teaching/generate.py`** — offline prompt-iteration helper (build the
    prompt from a concept JSON, optionally shell an authenticated `claude`); not wired to
    anything, mirrors `TeachingSchema` by hand.
  - **24 new tests** (full suite 385 → **409, 0 failures**): `TeachingQuestionVerifierTests` (13 — valid persist with sorted anchors +
    ordered criteria; every schema failure; fatal vs. dropped anchor handling; the
    `CONTRADICTED`-match reject and the non-contradicted pass; diagnostics land with the right
    stage/severity), `TeachingPromptBuilderTests` (4), `TeachingQuestionGeneratorTests` (7 —
    first-attempt persist, retry-then-succeed, retry-then-reject, unparsable-both-attempts,
    no-resolvable-anchor short-circuit before drafting, `generated_by` reflects the drafter,
    tolerant JSON extraction), `TeachingGenerationLiveTests`
    (`ORION_TEACHING_LIVE_LOCAL`, CI-`--skip`ped).
  - **Verified live** against the real Starlette DB (concepts extracted via `teach-concepts
    --extract`): **Claude band-3** on `Application Core → Routing` produced a strong change-impact
    question ("a live app calls `add_middleware` and gets `RuntimeError`, another calls
    `add_route` and it works — trace the path and explain why") with 6 atomic `required` + 2
    `bonus` + 3 `anti` criteria, every anchor resolved, `attempts: 1`, `dropped: 0`, ~130s /
    ≈$0.3. **Local Qwen3-8B band-1** on `Routing` produced schema-conformant JSON both attempts
    but **hallucinated an anchor** (`star-<hex>::Convertor`) → correctly `.rejected` — the
    verifier gate holding, and a concrete data point that local verified-yield needs attention
    (prompt tightening, or accepting a lower band-1/2 pass rate) before M7's calibration run.
- **M3 — `RubricGrader`. [done]**
  - **`RubricScoring` (`OrionCodeIntel/Teaching/RubricGrader.swift`)** — the pure §7.3 math:
    `score = required_met / confident_required_total` (a split k-run excludes that `required`
    criterion from the denominator and lists it under `needsReview` — never counted either way),
    `+ min(0.15, 0.05 × bonus_met)`; verdict bands `solid ≥ 0.85 & 0 anti` / `partial ≥ 0.6` /
    `shaky ≥ 0.3` / else `off-track`, with `off-track` also forced by `≥ 1` anti tripped **and**
    `≥ 2` required missed, and `shaky` when nothing is confidently assessable
    (`confident_required_total == 0`). `correctionText(...)` is the §7.5 deterministic template
    over unmet-required + tripped-anti + `needsReview` + reference answer — no model call.
  - **`CriterionJudging` / `AnswerComparing` protocols** (in `OrionCodeIntel` so `RubricGrader`
    references them; real impls in `OrionAgent`). `CriterionVerdict = {met, confidence,
    evidenceQuote, note}`.
  - **`RubricGrader.grade(questionId:answer:developerId:)`** — loads the question + criteria +
    concept, judges each criterion `k = 3` times, takes the majority `met`, marks a non-unanimous
    run (or a `.low` representative vote) as `.low` confidence, aggregates via `RubricScoring`,
    runs the §7.4 pairwise tripwire when a comparer is injected (both orderings; a
    `(score ≥ 0.6) != sameIdea` disagreement sets `attempt.disputed` + a `teaching_grade` /
    `TEACHING_SCORE_DISPUTED` diagnostic, and does **not** move the score), then persists:
    `teaching_attempts` (derived score/verdict, `model_used` = judge source, `disputed`),
    `teaching_criterion_results` (one per criterion, `vote_detail` = the k JSON samples), and the
    misconception lifecycle — a confidently-`met` anti-criterion ⇒ `Store.ensureKnowledgeState`
    (new — insert-if-absent, left at M0 defaults for M4 to move) + a `teaching_misconceptions`
    row (not double-recorded if one with the same `statement` is already open); a later
    confidently-not-met (`.high`) judgement of the same statement clears it. Random diagnostic /
    row ids (a grade is repeatable). Recorded deviation: standalone, **not**
    `AgentSession.gradeAnswer` — grading has no Depth-Model routing, same reasoning as M2's
    generator.
  - **`LocalCriterionJudge` / `LocalAnswerComparer` (`OrionAgent/Teaching/CriterionJudges.swift`)**
    — closure-wrapped single-shot generation, per-criterion prompt (anti-criteria get an explicit
    "`met: true` means the answer CONTAINS this WRONG idea" note), tolerant JSON parse; garbage or
    an unrecognised confidence string → `low` / not-met (conservative). A `FoundationModels`
    `@Generable` variant (stricter decoding) is a noted later refinement.
  - **`orion-agent teach-answer <path> <question-id> "<answer>" [--k] [--pairwise] [--explain]
    [--json]`** (`TeachAnswerCommand.swift`, registered) — prints the per-criterion checklist
    (✓/✗/⚠), derived score + verdict, `needsReview`/`disputed`/misconception deltas, and the
    correction.
  - **23 new tests**: `RubricScoringTests` (10 — every threshold boundary, low-confidence
    exclusion, bonus cap, forced `off-track`, correction templating), `RubricGraderTests` (8 —
    persist attempt + `vote_detail` results, k-majority, split → low + excluded, misconception
    detect/clear/no-double-record, pairwise dispute → flag + diagnostic, unknown-question throw),
    `CriterionJudgesTests` (5 — parse a good verdict, garbage → low/not-met, unknown confidence →
    low, anti prompt wording, comparer parse). `TeachingGradingLiveTests`
    (`ORION_TEACHING_LIVE_GRADE`, CI-`--skip`ped).
  - **Verified live** with real Qwen3-8B (222s / 18 judge calls): the good conceptual answer
    scored **1.0 / `solid`**; the answer carrying the "routes match by specificity / longest-
    prefix" misconception scored **0.0 / `off-track`, anti-criterion tripped** — the decomposed
    rubric distinguishing conceptual understanding from a wrong mental model end to end, exactly
    what Docs/05 §7 ("conceptual understanding, not wording similarity") asks for.
- **M4 — `KnowledgeState` + planner. [done]**
  - **`KnowledgeUpdate` (`OrionCodeIntel/Teaching/KnowledgeUpdate.swift`)** — pure. `fold(p:met:
    slip:guess:)` is one BKT observation; `apply(prior:requiredMet:antiTripped:params:)` folds
    one graded attempt (one obs per **confident** `required` outcome — low-confidence excluded,
    matching `RubricScoring` — plus one `antiSlip` obs per tripped anti), then the flat `learn`
    transit, clamped to `[0,1]`. `Params` = the §8.2 defaults (`slip 0.1`, `guess 0.2`,
    `learn 0.15`, `antiSlip 0.05`). `band(pMastered:attemptsCount:)` → `.new` until
    `attemptsCount >= 2`, then `solid ≥ 0.85` / `developing ≥ 0.55` / `shaky`.
  - **Wired into `RubricGrader.grade`** — M3 only ensured a `knowledge_states` row for
    misconceptions; **M4 runs the update on every graded attempt**: `p_mastered`,
    `attempts_count += 1`, `confidence_band` (from `KnowledgeUpdate.band`), `last_verdict`,
    `last_assessed_at` written via `Store.updateKnowledgeState`; `RubricGrader.Result` gains
    `knowledgeState: KnowledgeDelta?` (before/after `p_mastered` + band + attempt count).
  - **`TeachingPlanner` (`OrionCodeIntel/Teaching/TeachingPlanner.swift`)** — `rank` /
    `next(repositoryId:developerId:recentConceptIds:)`. `score = (1 − p_mastered) × centrality ×
    recencyFactor + (open misconception ? 0.3 : 0)`, `recencyFactor = 0.1` for a concept in the
    caller-supplied recent list; `stale` excluded; ties broken by `attempts_count` → band → id.
    A never-assessed concept uses the `0.15` prior.
  - **CLI**: `orion-index teach-concepts --plan [--developer]` prints the planner ranking with
    `p_mastered` / attempts / misconception flag; `orion-agent teach-answer` prints a
    `mastery: p X → Y  band A → B` line.
  - **Decision 8 — the "one look at real M2/M3 output"**: applying the §8.2 rule to M3's own
    live grades gives **`p_mastered ≈ 0.81`** for the 2-required-met "good" attempt and
    **`≈ 0.15`** for the 2-missed + 1-anti "fully wrong" one. Recorded finding (in the code doc
    comment + a test): the flat `learn` term fills 15% of the gap regardless of correctness, so
    a wholly-wrong attempt lands back at the **prior**, not near 0 — `p_mastered` alone can't
    distinguish "never attempted" from "attempted and failed", which is exactly why `band(...)`
    gates on `attempts_count` and `TeachingPlanner` also weights an open misconception. Priors
    kept at the §8.2 values; band cutoffs set at `0.85` / `0.55`.
  - **New tests** (full suite 432 → **448, 0 failures**): `KnowledgeUpdateTests` (10 —
    hand-checked fold/apply numbers incl. the two §8.2 "one look" cases, band gating + cutoffs,
    convergence, clamping), `TeachingPlannerTests` (7 — centrality order, mastered-below-shaky,
    misconception boost, recency demotion, stale exclusion, tie-break order, `next`); the M3
    `testAntiTrippedRecordsMisconceptionAndKnowledgeState` reworked for the every-attempt KS
    update. **Verified live**: `orion-index teach-concepts --plan` on the real
    Starlette DB ranks `Routing → Connection & Message Objects` (centrality 1.0) first at
    `score = 0.85`, all `p = 0.15` / `n = 0` as expected for an unattempted developer.
  - **Build gotcha**: adding a field to `RubricGrader.Result` needed `swift package clean` — a
    stale `OrionCodeIntelTests` object file compiled against the old layout SIGSEGV'd in a value
    copy (the exact Docs/13 M2 incremental-build gotcha).
- **M5 — CLI. [done]** `orion-agent teach` (`Sources/orion-agent/Commands/TeachCommand.swift`,
  nested `AsyncParsableCommand` group, registered in `OrionAgentCLI.swift`) — the product surface,
  replacing the M2/M3 standalone `teach-generate` / `teach-answer` debug commands (deleted):
  - **`teach concepts <path> [--developer] [--extract] [--json]`** — lists concepts with the
    developer's mastery (`p_mastered`, `confidence_band`, attempts, open-misconception count).
  - **`teach next <path> [--concept] [--band] [--recent id,id] [--source local|claude|auto]
    [--fresh] [--max-budget-usd] [--timeout] [--json]`** — `TeachingPlanner.next` picks the
    concept (or `--concept` forces one), **reuses the newest verified question** for it (matching
    `--band` when explicit) or generates a fresh one via `TeachingQuestionGenerator` (local band
    1–2 / Claude band 3); prints Explain + Question only (the rubric/reference answer stay the
    grader's). Exit 1 on `.rejected`/`.draftUnusable`.
  - **`teach answer <path> <question-id> "<answer>" [--developer] [--k] [--pairwise] [--explain]
    [--json]`** — `RubricGrader`, prints the per-criterion checklist (✓/✗/·, "needs review" for
    low-confidence), derived score + verdict, misconception deltas, the mastery move, the
    templated correction, and the **transfer problem**. Exit 1 if the grader throws.
  - **`teach state <path> [--developer] [--json]`** — `knowledge_states` for the developer:
    per-concept `p_mastered` / band / attempts / last verdict + open misconceptions, with a
    `N engaged · M solid · K misconceptions` header.
  - **`teach concepts` / `teach next` bootstrap an empty concept table** by running
    `ConceptExtractor` once (extraction proper stays `orion-index teach-concepts --extract`);
    a repository with no semantic investigation exits 3 with a clear message.
  - No XCTest against the `ArgumentParser` structs (the Phase 5 M5 precedent). **Verified live**
    end to end against the real Starlette DB: `teach concepts` and `teach state` (pure reads);
    `teach next --concept "Application Core → Routing" --band 3 --source claude` generated a
    strong change-impact question in 1 attempt (~100s); `teach answer` on a hand-written answer
    graded it **0.67 / `partial` (2/3 required, 2 "needs review")**, moved mastery **p 0.15 →
    0.41, band new→new (attempt 1)**, and printed the correction + transfer problem; `teach
    state` then showed `Application Core → Routing — new (p=0.41, n=1, last partial)`.
    **Finding**: grading a band-3 question (11 criteria × k=3 = 33 local generations) took ~10.5
    min on Qwen3-8B — k=3 over a many-criteria question is expensive on an 8B model; worth an
    M7/M8 look (adaptive k, a faster judge, or batching criteria into one structured call).
- **M6 — App UI. [done]** Teaching Mode is a real destination in `OrionApp/`, replacing the
  Docs/14 §8 M7 sample screen (`TeachingSample.swift` deleted).
  - **Shape** — `HSplitView { conceptRail; workPane }`, the same master-detail idiom as `AskView`
    (and the same reasons: `NavigationSplitView` would let the rail collapse away with no toggle
    to recover it; `.inspector`'s resize handle only shrinks on this SDK — both documented in
    `AskView`/`ContentView`). Left: a `ScrollView`+`LazyVStack` of concepts (again, not
    `List`+`Section` — AskView's documented macOS sidebar-`List` bridging bug), each row a
    `MasteryMeter` (new shared view: a native `Gauge(.accessoryLinearCapacity)` tinted by band +
    the band *word* — `p_mastered` fills the bar but is never printed as a false-precise number,
    Docs/17 §2.5) plus a ⚠ for an open misconception; ordered by `TeachingPlanner` rank. A
    `.glassProminent` "Start suggested concept" pinned in the rail's bottom `safeAreaInset`.
  - **Work pane** — a staged flow (`.idle` → `.picking` → `.questioning` → `.grading` →
    `.graded`): `ContentUnavailableView` when nothing's selected; a `GroupBox` concept card with a
    Recall/Comprehension/Transfer `Picker(.segmented)` and a "Get a question" CTA; then Explain
    (`MarkdownText`) → Question → a `TextEditor` answer → **Evaluation** as a `GroupBox` whose
    core is the **per-criterion checklist** — ✓/✗ for `required`/`bonus`, "needs your review" for
    a `low`-confidence (split k-run) criterion, the developer's own `evidence_quote` echoed under
    a met criterion, tappable evidence anchors opening `EvidenceView`, and a `⚠` row per tripped
    anti-criterion ("Your answer suggests: …"). Then the templated Correction, an optional
    mastery-moved row, and the accent-tinted Transfer panel ("Try this — one level up" /
    "Another question here" / "Next concept"). Native controls throughout so Tahoe's Liquid Glass
    comes for free (WWDC25 323); `.glass`/`.glassProminent` only on the one primary action per
    state; `DesignTokens.Radius`/`.Spacing` for concentric geometry.
  - **Calibration honesty (Docs/17 Decision 10 / §11)** — `TeachingSession.isCalibrated = false`
    until M7. A persistent top `safeAreaInset` note ("Self-check only… your mastery isn't being
    scored"), and `TeachingRunner.grade` passes `RubricGrader(persistMastery: false)` — the new
    flag: the attempt + criterion results are still written (the auditable record), but **no
    `knowledge_states` row is touched and no `teaching_misconceptions` row is written**; the
    in-memory `Result` still carries `misconceptionsDetected` so the checklist can show a tripped
    anti-criterion. `RubricGrader.PerCriterion` also gained `criterionId` + `evidenceAnchors` so
    the checklist rows can resolve and open their cited source. Flip `isCalibrated` in M7.
  - **Sidebar** (`ContentView`) — the `.teaching` destination badge = concepts with an open
    misconception (reusing `sidebarBadgeCount(for:)`); a one-line mastery strip under the repo
    identity ("N concepts · M solid · K shaky · ⚠ 1"), refreshed read-only on every destination
    switch alongside the Model Changes count.
  - **Data layer** — `Model/TeachingLoader.swift` (pure: concept rows + `TeachingPlanner` order,
    the overview counts, the graded-attempt → `TeachingGradeCard` projection incl. anchor
    resolution — the `ModelChangeLoader`/`ArchitectureModelLoader` discipline);
    `Model/TeachingSession.swift` (`@Observable`, owned by `ContentView`, recreated per repo
    open like `AskHistory`); `Ingestion/TeachingRunner.swift` (`generate` / `grade` on
    `Task.detached`, band 1–2 local Qwen3 / band 3 Claude via `ClaudeBinaryLocator`, `drafter` /
    `judge` injectable — the `AskRunner` seam). `teach concepts`/`teach next` first-use
    `ConceptExtractor` bootstrap carries into the app (`TeachingLoader.concepts(bootstrap:)`).
  - **11 new tests** (`OrionAppTests` 137 → **148, 0 failures**): `TeachingLoaderTests` (5 —
    concept rows carry mastery and are planner-ordered; open misconception surfaces; overview band
    counts; `latestVerifiedQuestion` band matching; `gradeCard` maps criteria + resolves evidence
    + suppresses the mastery move under the calibration gate), `TeachingSessionTests` (6 — the
    full `select → getQuestion → submit → graded` machine via scripted drafter/judge against a
    real analyzed fixture repo, empty-answer no-op, `startNext` picks the top concept, a
    verifier rejection surfaces an error and stays in `.picking`). `RubricGraderTests` +1 for
    `persistMastery: false`. Full `OrionCodeIntel` suite still green.
  - **GUI verification** — `xcodebuild build` + `build-for-testing` succeed; the app launches and
    renders the Welcome screen with no crash. A populated-Teaching-Mode click-through screenshot
    was **not** captured: this app's custom SwiftUI controls don't respond to `System Events`
    synthetic clicks and coordinate clicks fail with `-25200` (documented since Docs/13 M2–M4).
    Correctness rests on the 11 tests above (real load / generate / verify / grade / plan paths)
    plus M5's live end-to-end CLI run of the identical backend on real Starlette.
- **M7 — Calibration + H8 run. [done]** `orion-agent teach bench` (Docs/17 §10) — seeds each
  gold question, grades the paired answer with the real `RubricGrader` + local Qwen3 judge
  (k = 3, `persistMastery: false`), and measures the grader against expert per-criterion labels
  with **`CalibrationStats`** (pure Cohen's κ / MAE / RMSE / confusion matrix; 12 unit tests).
  Two hand-authored gold sets against vendored Starlette `4f250d6b`: `starlette_teaching_grader.gold.json`
  (§12.2 — 15 items, bands 6/6/3, 98 criterion instances, expert labels assigned from source
  *before* running the grader) and `starlette_teaching.gold.json` (§12.1 — 22 entries, all
  bands × concept kinds, two deliberately-wrong source concepts as factual-correctness traps).
  - **Result** (15-item live run, ~75 min, fully local, no API cost —
    `results/phase7_teaching_calibration/`): **per-criterion Cohen's κ = 0.894** ("almost
    perfect"; 0.950 on grader-confident criteria; 0.875 `required`, 0.862 `anti`), raw agreement
    0.947 (89/94). Score MAE 0.117. **Verdict-tier accuracy 0.733**, and every error is the
    grader being *more lenient* — `solid` called 6/6, but `expert off-track → grader partial/shaky`
    ×2 and `expert shaky → grader partial` ×2, never stricter. The §7.4 pairwise tripwire fired
    on 5/15 items, **3 of them strong answers both sides scored 1.00/solid** (≈20% false-positive
    on perfect answers).
  - **Decision 10 outcome — the gate is HELD even though κ mechanically passes** (0.894 ≥ 0.60).
    `TeachingSession.isCalibrated` stays `false`; `persistMastery` stays off; the "self-check
    only" banner stays. Reasons: (a) the gold set is single-author / synthetic answers / self-
    assigned labels / n = 15 — not §12.2's "real developer answers, independently labelled,
    10–15 per band"; (b) the measured lenient verdict drift is exactly what inflates a persisted
    `p_mastered`. What M7 ships is the *apparatus* (`teach bench` + `CalibrationStats` + both
    gold sets + this result as a regression fixture); flipping the gate waits for a real
    calibration set collected with a second person.
  - **Finding — the vendored DB blocks §12.1.** Starlette's `.orion/orion.db` (six phases of
    development, incl. Phase 6 revision experiments) has **48/108 semantic claims `CONTRADICTED`**
    (the succeeded run is `resolver: none`, so `depends_on`-dependent claims fall through), many
    over the core files. `TeachingQuestionVerifier` §6.3 therefore rejects nearly every
    hand-authored gold question (Jaccard 1.00 against a contradicted claim). `teach bench`
    defaults to **trusting hand-authored gold** (schema + anchor resolution still enforced;
    `--verify-gold` re-enables the full gate). The §12.1 generation-gold run is **deferred**
    pending a clean Starlette re-investigation with a real resolver — an M8 prerequisite.
  - **H8 first data point** — `teach next` → `teach answer` → `teach state` runs end-to-end on
    real Starlette with local generation + grading (write-up §7): the pipeline produces a real
    question, a decomposed grade, a templated correction, and a persisted mastery move. n = 1
    and the tester built the grader (disclosed) — this shows "the pipeline works on real output",
    not "it teaches". The unfamiliar-repo half of §12.3 (a real learner) is left for the user.
    **This run surfaced a failure mode**: Qwen3 emitted unparseable JSON on 4 of 5 criteria for
    the generated question; the k = 3 guard dropped all four to `low`, and `RubricScoring.aggregate`
    then scored over the *one* surviving `required` criterion (1/1 → 1.00 → `solid`), moving
    mastery `p 0.15 → 0.53` on a partial answer. Also: the locally-generated `anti` criterion
    ("Endpoints are handled without requiring converter registration") isn't a real misconception
    — Risk #1 (a criterion badly worded by the generator, which §6.3 can't catch), live.
  - Write-up: `Agent Feasibility Study/PHASE7_TEACHING_EVAL.md`. No CI change (`teach bench` is a
    live CLI, verified by the run; `CalibrationStatsTests` is pure, no `--skip`).
- **M8 — Hardening.** Whatever the live milestones actually surface (the Docs 12–16 pattern —
  M8 is never planned in advance). Named by M7's data: **(1)** the lenient verdict-tier drift —
  raise thresholds or make a low-confidence `anti` count harder toward "needs review"; **(2)**
  the §7.4 pairwise tripwire's ~20% false-positive rate on strong answers — re-prompt or gate it
  to borderline scores; **(3)** the local grader's JSON reliability (H8 run: 4/5 criteria
  unparseable on one generated question) — tolerant re-parse / retry, or the `FoundationModels`
  `@Generable` path; **(4)** a floor on confidently-graded `required` criteria before a verdict
  tier is shown at all (H8: 1 of 4 required graded → `solid`); **(5)** a clean Starlette
  re-investigation (real resolver) so the §12.1 generation-gold run measures the generator, not
  the DB; **(6)** a real developer-answer / independent-expert-label calibration set — the one
  that can actually clear Decision 10. Also still open: correction-text paraphrase smoothing
  (§7.5); the M5 finding that band-3 grading is ~33 Qwen3 gens ≈ 10 min (adaptive k / faster
  judge / batch criteria into one structured call).

---

## 15. Risks / open questions

1. **The grader is an LLM and can be wrong at the criterion level.** This is the whole reason for
   §2's design. Mitigations, in order of load-bearing-ness: atomic constitutive criteria (not
   holistic scores); form-filled rationale before the boolean; k = 3 self-consistency with split
   votes excluded and surfaced; the §12.2 κ gate that keeps the confident-grade UI off until the
   evidence supports it; the §7.4 pairwise tripwire. What none of this fixes: a criterion that is
   *itself* badly worded by the generator — see #2.
2. **Verification is structural, not semantic** (the standing Orion limitation, Docs/11 Risk #6,
   Docs/16 Risk #7). §6.3 confirms every anchor resolves and the reference answer isn't
   `CONTRADICTED` — it cannot confirm the question is *unambiguous* or the rubric is *complete*.
   A generated question with a subtly wrong reference answer that happens to cite resolvable,
   non-contradicted anchors will pass. The gold set (§12.1) measures how often this happens;
   below-bar generation quality means band-3 (Claude-generated) only, or human review of
   generated questions before they enter the pool.
3. **Small-N mastery is noisy** (§2.5). Mitigated by criterion-level (not question-level)
   observations, explicit probabilistic tracking, coarse bands, and the `attempts_count >= 2`
   floor on anything above `new`. Still: `p_mastered` after two questions is a weak estimate and
   the UI must not imply otherwise.
4. **n = 1, and the test subject knows the corpus.** H8 gets a genuine but weak first data point.
   The unfamiliar-repo half of §12.3 is the better signal; a real multi-user study is out of
   scope and named as such (P6).
5. **Concept explosion / selection quality on large repos.** Capped at top-N by centrality
   (Decision 9); if the cap hides concepts a developer actually wants, `teach next --concept`
   and the app's "pick a concept" affordance are the escape hatch.
6. **Misconception detection via anti-criteria only.** A misconception the generator didn't think
   to write an anti-criterion for goes undetected. A generate-retrieve-rerank misconception bank
   ([2602.02414](https://arxiv.org/html/2602.02414)) is the known stronger approach and is the
   natural follow-up once there's real data on what anti-criteria miss.
7. **Cost.** Band-3 generation and any Claude re-check of low-confidence criteria spend real API
   budget. Bounded by `--max-budget-usd` (default `0.50` for generation, lower for re-checks) and
   by grading running local-first. A full `teach bench` run's cost is stated up front in M7 the
   way Phase 5 M7 did, and run only on explicit user approval.
8. **`FoundationModels` availability.** The `@Generable` grading path needs macOS 26 +
   Apple-Intelligence-enabled; when unavailable, grading falls back to Qwen3-8B with tolerant JSON
   extraction (same fallback shape as `AppleFoundationDepthClassifier`'s in Phase 3), which is
   slightly less reliable at strict structure — noted, not blocking.

---

## Sources (§2)

- [Prometheus: Inducing Fine-grained Evaluation Capability in Language Models](https://arxiv.org/abs/2310.08491)
- [G-Eval: NLG Evaluation using GPT-4 with Better Human Alignment](https://arxiv.org/abs/2303.16634)
- [How to Write Reliable Rubrics for LLM-as-a-Judge Evaluations (Google AI)](https://dev.to/googleai/how-to-write-reliable-rubrics-for-llm-as-a-judge-evaluations-ndp)
- [Can LLM-as-a-Judge Reliably Verify Rubrics in Agentic Scenarios?](https://arxiv.org/pdf/2606.29920)
- [Rubric-Conditioned LLM Grading: Alignment, Uncertainty, and Robustness](https://arxiv.org/pdf/2601.08843)
- [Generating and Refining Dynamic Evaluation Rubrics for LLM-as-a-Judge](https://arxiv.org/html/2605.30568v1)
- [A survey on LLM-as-a-judge](https://www.sciencedirect.com/science/article/pii/S2666675825004564)
- [Explicit Reasoning Makes Better Judges](https://arxiv.org/pdf/2509.13332)
- [CalibraEval: Calibrating Prediction Distribution to Mitigate Selection Bias in LLMs-as-Judges](https://arxiv.org/pdf/2410.15393)
- [Pair2Score: Pairwise-to-Absolute Transfer for LLM-Based Essay Scoring](https://arxiv.org/pdf/2605.02069)
- [How to Calibrate LLM-as-Judge with Human Corrections (LangChain)](https://www.langchain.com/resources/llm-as-a-judge)
- [KNIGHT: Knowledge Graph-Driven MCQ Generation with Adaptive Hardness Calibration](https://arxiv.org/html/2602.20135)
- [KAQG: A Knowledge-Graph-Enhanced RAG for Difficulty-Controlled Question Generation](https://arxiv.org/pdf/2505.07618)
- [Generating Multiple-Choice Knowledge Questions with Interpretable Difficulty Estimation Using KGs and LLMs](https://doi.org/10.3390/make8050137)
- [An LLM-Guided Method for Controllable Question Generation](https://aclanthology.org/2024.findings-acl.280.pdf)
- [Difficulty-controllable question generation over knowledge graphs: a counterfactual reasoning approach](https://www.sciencedirect.com/science/article/abs/pii/S0306457324000815)
- [Using an LLM to Investigate Students' Explanations on Conceptual Physics Questions](https://arxiv.org/html/2508.14823)
- [LLM-as-a-Grader: Practical Insights for Short-Answer and Report Evaluation](https://arxiv.org/html/2511.10819v2)
- [Evaluating GPT as automated analyzer for detecting students' erroneous mental models in programming education](https://link.springer.com/article/10.1007/s10209-026-01320-z)
- [Misconception Diagnosis From Student-Tutor Dialogue: Generate, Retrieve, Rerank](https://arxiv.org/html/2602.02414)
- [Learning meets Assessment: On the relation between Item Response Theory and Bayesian Knowledge Tracing](https://arxiv.org/abs/1803.05926)
- [StanBKT: Rethinking Parameter Estimation in Bayesian Knowledge Tracing](https://arxiv.org/pdf/2605.23048)
