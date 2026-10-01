# iOS companion — evaluation (Docs/19)

Measurements of the iOS companion's on-device AI. Every number below was taken on a **real
iPhone 17** (`iPhone18,3`, iOS 27). Its system model is **AFM 3 Core** with a **4,096-token**
window. The Mac's system model is a different, larger variant (AFM 3 Core Advanced, 8,192 tokens),
and there is no API to pick a variant, so Mac runs don't stand in for the phone (Docs/19 M0).

Raw results: `results/ios_companion/` (`m0/` probe, `m6/` Ask, `m7/` Learn, `m8/` redesign, large repository, drafting with code).

## M8 — Hardening

**Device drafting with code excerpts** (iPhone 17; the same 10 top-ranked concepts as M7;
`m8/iphone17-drafting-with-code-excerpts.json`). Each draft now sees the cited lines (up to 14) of
its top 3 symbols, from the snapshot's `evidence_snippets`, on top of their signatures.

| | M7 run B (signatures only) | M8 (with code) |
|---|---|---|
| kept (verified) | 9/10 | **10/10** |
| latency p50 | 13.9 s | 11.2 s |
| drafts with at least one wrong point (single reader) | ~3/9 | ~3/10 |
| usable as written (single reader) | ~1/9 | ~2–3/10 |

- **What improved:** the points are more code-specific, and correct ones appear that signatures
  couldn't support. Examples: `BackgroundTask` awaiting `self.func(...)` when async;
  `BackgroundTasks` awaiting each task; 405 with an `Allow` header; the 307 default.
- **What didn't:**
  - The questions are still tautological or confused. One compares a class with itself; one
    names a class that doesn't exist.
  - A wrong point can sit next to its correct twin ("405" and "302 for unsupported methods" in one
    rubric).
- **Conclusion unchanged from M7:** Mac-shipped questions should be the main supply.

**A large repository** (`transformers`, 2,638 files, 132,018 symbols; a structural analysis
only):

| Measure | Result |
|---|---|
| Analysis on the Mac | 235 s |
| Snapshot | 5.2 s; 21.9 MB (146 MB database), one CloudKit asset |
| Import, iOS simulator | 0.54 s |
| Explore's model | 6.25 s, then **0.77 s** once filtered in SQL |
| Search across 2,637 modules | 2 ms |
| Ask context | ≤ 24 ms |

## M7 — On-device Learn

**Setup:**
- **Grader calibration:** the hand-labelled gold set (`benchmark/starlette_teaching_grader.gold.json`,
  15 answers, 6/6/3 across bands, 94 matched non-ambiguous criterion pairs). It runs through the
  real `RubricGrader` with the phone's judge, by the app's on-device bench
  (`OrionMobile/OrionMobile/Learn/LearnBench.swift`), on a copy of the phone's Starlette snapshot
  (`4f250d6b`). It's the same harness as `orion-agent teach bench`, now shared as
  `GraderCalibration`.
- **Judge:** `SingleCallCriterionJudge`, one guided call per vote: quote → reasoning → verdict →
  confidence.
- **Drafting:** `GuidedTeachingDrafter` for the 10 top-ranked concepts (bands capped at 2), through
  `TeachingQuestionVerifier`.

### Grader calibration (iPhone 17, AFM 3 Core)

| run | sampling | `confidence` guide | k | κ (bar 0.60) | κ required / anti | verdict accuracy | unconfident points | per answer (p50) |
|---|---|---|---|---|---|---|---|---|
| 1 | default | none | **1** | **0.69** | 0.88 / 0.42 | 0.60 | 34% | 18.7 s |
| 1 | default | none | 3 | 0.60 | 0.76 / 0.44 | 0.53 | 41% | 62.0 s |
| 2 | default | described | 1 | 0.58 | 0.68 / 0.42 | 0.67 | 5% | 22.2 s |
| A | greedy | described | 1 | 0.51 | 0.57 / 0.42 | 0.67 | 9% | 22.3 s |
| **B (shipped)** | **greedy** | **none** | **1** | **0.62** | 0.76 / 0.51 | 0.53 | 35% | 22.8 s |

- **Judge calls:** 686 across the runs, p50 2.8–3.5 s and p90 3.4–4.3 s per run. The slowest was
  10.5 s. 1 call failed (run A), and `RubricGrader` counted it as an unconfident vote.
- **For comparison:** the Mac's Qwen3-8B text judge with thinking scored κ 0.89 on this gold set
  (Docs/17 M7), and κ 0.78 on Docs/18's 6-item subset.

**Choices:**
1. **k = 1.** k = 3 took 3.3× as long (15.3 vs 4.7 min for the set, about a minute per answer) and
   agreed with the expert *less*.
2. **Greedy decoding.** The same answer should get the same grade. Greedy measured κ 0.62 against
   one sampled run's 0.69, and with sampling the run-to-run spread is unknown.
3. **`confidence` stays undescribed.** Describing it ("how sure you are of your true or false
   verdict") cut the unconfident points from about 35% to 5–9%, but the model then called correct
   points "not stated". That cost about 0.11 κ under both sampling modes, and only 2 of 6 strong
   answers were rated solid.

**Gate: held.** κ 0.62 clears the 0.60 bar, but:
- verdict tiers are right only 53% of the time, and expert off-track answers come out "shaky"
  (3 of 6);
- misconceptions (anti-points) are caught poorly (κ 0.51, 5 of 11 when greedy);
- a third of the points are left "for your review";
- the gold set has the limits that held the Mac's gate at κ 0.89: single author, synthetic answers,
  n = 15 (Docs/17 Decision 10).

`LearnModel.isCalibrated` stays `false`: grades are a self-check, and no mastery estimate is
written.

### On-device drafting

| run | kept (verified) | rejected | latency p50 / max | notes |
|---|---|---|---|---|
| 1 | 9/10, all on the first try | 1 (contradicted claim) | 12.4 / 22.3 s | questions echoed the prompt's "relate to or differ from…, or…" |
| 2 | 9/10 | 1 (contradicted claim) | 11.7 / 36.8 s | task chosen in code; relationship questions said "the first side" |
| B | 9/10 (1 on its retry) | 1 (contradicted claim) | 13.9 / 29.0 s | sides named; final |

- **The verifier works as designed.** Every rejection is the contradicted-claim check, on Starlette's
  known-bad semantic layer (48 of 108 claims are `CONTRADICTED`, Docs/17 M7). One of those
  "contradicted" claims is the gold set's own correct reference answer about `Router.app`.
- **No draft failed on an anchor.** The schema's anchor enums make an invented anchor impossible.
  Anchor failures were the Mac drafters' most common rejection.
- **Quality is the problem.** I read all 27 kept drafts (single reader). Most have at least one of:
  - a rubric that doesn't match its question (relationship questions given rubrics about
    `HTTPEndpoint.method_not_allowed`);
  - tautological points ("Response inherits from Response", "X depends on Y");
  - **a point that's wrong about the code.** At least 6 drafts contain one: `BackgroundTask`
    inheriting from `BackgroundTasks` (backwards; the next run had it right),
    "`WebSocket` inherits from `WebSocketClose`", one rubric asserting both a 302 and a 307
    default.

  About 3 of 27 are usable as written. The best is run B's "What parameter in
  `RedirectResponse.__init__` controls the default status code?", with a correct 307 rubric.
- **Why:** the drafter sees signatures, not code. The verifier checks that citations resolve and
  don't rest on contradicted claims, not that a statement is true.

### Mac check

`teach bench --local-backend system --judge-output single`, 3 items on the Mac's AFM 3 Core Advanced:
κ 0.77, about 2.1 s per call. `teach next --local-backend system` drafted a verified question in
8–25 s. These are plumbing checks; the Mac's model is not the phone's.

## M6 — On-device Ask

**Setup:**
- **Question set:** the 55-question Starlette benchmark (`benchmark/benchmark.json`), run by the
  app's on-device bench (`OrionMobile/OrionMobile/Ask/AskBench.swift`).
- **Knowledge:** a *copy* of the phone's Starlette knowledge, the M2 snapshot at commit `4f250d6b`
  (33 components, 60 concepts).
- **Ask path:** the one the app uses (`SystemModelAsk`):
  - compact token-budgeted context;
  - four snapshot tools (`lookup_symbol`, `symbol_details`, `callers`, `search_claims`) with
    results capped at 900 characters;
  - at most 3 tool calls;
  - a 512-token reply cap.
- **Two runs:**
  - **A, the 10 hand-graded questions forced to depth 2.** These match `coreai_backend/m3–m4`, which
    allows a direct comparison.
  - **B, all 55 with the phone's real routing:** heuristics, then the system-model classifier.

### A — 10 questions, depth 2 (comparable to Docs/18 M4)

| config | p50 / max latency | total | tool call | verified / partial | hand grade |
|---|---|---|---|---|---|
| **iPhone 17 · system model (AFM 3 Core)** | **13.0 / 17.2 s** | **2.2 min** | 10/10 | 7 / 3 | **10.0 / 20** |
| Mac · Core AI Qwen3-8B, thinking on (M3.5) | 99 / 153 s | 16.2 min | 10/10 | 4 / 6 | 8.0 / 20 |
| Mac · Core AI Qwen3-8B, thinking off (M4) | 50 / 87 s | 8.9 min | 10/10 | 8 / 2 | 7.0 / 20 |
| Mac · Core AI Qwen3-4B, thinking off (M4, recommended) | 45 / 55 s | 7.3 min | 10/10 | 8 / 2 | 7.5 / 20 |

- **Grading:** the same rubric and questions as M3–M4 (Yes 2 / Reasonable 1.5 / Partial 1 / No 0 /
  Confabulated 0). Per-question grades are in `m6/hand_grades_d2.json`.
  - **Graded by Claude against `benchmark.json`'s ground truth, single grader, n = 10.**
    Indicative, not decisive.
- **Reading the comparison:**
  - The phone is **3.5× faster** than the fastest Core AI configuration.
  - It scores slightly higher. The likely reason is the *context*, not the model: the compact
    builder primes exactly the claims and signatures matching the question, and `symbol_details`
    hands over real code from the snapshot.
  - The Mac runs used `ContextBuilder`'s 20K-character export dump instead.
- **Typical misses:** required specifics (CU-05's `RuntimeError` guard, CU-08's method
  preservation), wrong code paths (BR-02), and one answer citing invented evidence (DC-01).
  They're the same kinds of misses as Qwen3's.

### B — all 55, the phone's real routing

| | before the fix | after (`canDelegate = false`) |
|---|---|---|
| routed to depth 3 | **19 / 55 (35%)** → "ask this on your Mac" | 0 (answered at depth 2) |
| answered at depth 2, with tool calls | 35 | **53 / 55** |
| verified / partially verified | 24 / 11 (+19 incomplete) | **35 / 18** |
| errors | 1 (guardrail) | 2 (guardrail: CU-05, BR-03) |
| latency p50 / p90 / max | 15.7 / 21.4 / 25.1 s (depth-3 rows return fast) | **19.3 / 23.3 / 38.6 s** |
| first answer text p50 | 13.7 s | 14.2 s |
| mean tool calls per question | 1.9 | 2.8 (`symbol_details` 56, `lookup_symbol` 48, `search_claims` 44, `callers` 8) |

**Findings:**

1. **The phone's classifier sends a third of questions to depth 3.**
   - On the Mac, the classifier on AFM 3 Core Advanced sent 54/55 to depth 2 (Docs/18 M0). On the
     iPhone, AFM 3 Core sent 19/55 to depth 3, so the classifier is far more cautious on the
     smaller model.
   - The phone can't delegate, so those questions got no answer.
   - **Fix:** `AgentSessionConfig.canDelegate` is `false` on the phone, and depth 3 runs at depth 2
     as best effort. The routing rationale records the classification and why depth 2 ran, and the
     usual outcome labels stay honest.
2. **The safety guardrail trips on benign code questions about 2–4% of the time.**
   - CU-05 ("What does `Request.stream()` do…") tripped it in both routed runs, but not in the forced
     run. BR-03 tripped it once.
   - Shown to the user as "The on-device model's safety guardrails declined this question."
   - Not worked around: it's the system's safety layer.
3. **Latency is dominated by the tool rounds.**
   - Text starts streaming at about 14 s and the answer completes at about 19 s.
   - Same-session KV reuse is unreliable on the phone (M0), so each tool round re-prefills.
4. **The answers are ungraded beyond outcomes in run B.** Run A carries the grade.

## M0 — Foundation Models probe

See Docs/19 M0. In short:
- iPhone: AFM 3 Core, 4,096 tokens, no reasoning (any `reasoningLevel` throws).
- Guided generation keeps declaration order; tool calling works.
- A 1.9K-token prompt: ~3 s to the first token, ~64 tok/s decode.
