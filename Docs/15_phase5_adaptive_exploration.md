# 15 — Phase 5: Adaptive Exploration — Guardrails, Conversational Sessions & Routing Benchmark

> Status: **M0-M8 done — this plan's full implementation order is complete.**
>
> **M0 (schema)**: `v4_phase5_schema` migration (`ask_sessions`/`ask_session_turns`, additive
> only — Phase 1-3 tables untouched), typed `AskSessionRecord`/`AskSessionTurnRecord`
> (`Model/AskSessionRecords.swift`), a new `AskSessionScope` enum, `InvestigationOutcome.declined`
> (no exhaustive Swift `switch` over the enum exists anywhere in the codebase — checked directly —
> so this needed no other call-site changes), and bare CRUD `Store` primitives
> (`insertAskSession`/`askSession`/`askSessions`/`updateAskSessionActivity`/
> `insertAskSessionTurn`/`askSessionTurns` — plumbing only, session lifecycle logic stays M3). 11
> new tests, both cascading-delete directions confirmed, plus that deleting a session's
> `components` row cascades the session itself away rather than `SET NULL`-ing it — a real
> behavior gotten right on purpose (§4.2), not left implicit.
>
> **M1 (guardrails)**: `DepthClassificationOutput` gained `isRepositoryRelated`/
> `offTopicRationale` in the same `@Generable` call (`AppleFoundationDepthClassifier`'s
> instructions extended with the scope rule + worked examples); `DepthDecision.isInScope: Bool =
> true` (defaulted, every pre-Phase-5 call site unchanged); `DepthModel.classify`'s new
> short-circuit runs after the fallback classifies but before confidence-based escalation, and
> never for a `DepthHeuristics` match; `AgentSession.declineOutOfScope` never touches
> `Qwen3Agent`/`ClaudeCodeInvestigator`, persists one `investigations` row
> (`outcome = .declined`) plus the routing decision, and returns `partial: false` (a decline is a
> correct, complete result). **One real design gap found and fixed, not anticipated by the
> plan**: `AgentSession.resolveDepth`'s non-forced path hard-coded
> `DepthModel(fallback: AppleFoundationDepthClassifier())` inline with no injection seam, so
> nothing above `DepthModel` could be tested without a live FoundationModels call or
> `--force-depth` (which always stays in scope and so can never reach `declineOutOfScope`). Fixed
> by adding an injectable `depthFallback: DepthFallbackClassifying` parameter to
> `AgentSession.init`, mirroring the exact reason `sessionFactory` is already injectable. 14 new
> tests.
>
> **M2 (`ComponentDetailLoader` relocation)**: the query logic — not a verbatim move — split into
> `OrionCodeIntel.ComponentDetailQuery` (`semanticDetail`/`structuralDetail`, operating directly
> on `Store`, no `ArchitectureNode`/`ArchitectureLayer` dependency since this module can't depend
> on app-target UI types) and a thin `OrionApp`-side adapter that still owns the
> `ArchitectureNode`-shaped empty-placeholder fallback (only the UI layer has a `node` to fall
> back to). **One real coupling found and fixed along the way**: the claim-confidence mapping
> called `ConfidenceBadge.tierLabel(forScore:)` — a `View`-conforming SwiftUI type — which would
> have dragged a SwiftUI dependency down into `OrionCodeIntel` had it moved unchanged. Fixed by
> moving the actual mapping to `ConfidenceTier.label(forScore:)` in `OrionCodeIntel`'s
> `Enums.swift`, with `ConfidenceBadge` reduced to a thin, signature-unchanged forwarder — no
> other call site (`AskRunner`) needed touching. `OrionApp`'s own `ComponentDetailView` needed
> zero changes.
>
> **M3 (session persistence + context threading)**: `Store.createAskSession`/`recordSessionTurn`/
> `priorTurns` are the one real lifecycle layer composed on top of M0's bare CRUD (scope/
> `componentId` invariant enforced at creation; turn-insert + session-activity-columns in one
> atomic write; prior turns bounded to 5, oldest-first); `ContextBuilder.build` gained
> `priorTurns`/`componentContext` (defaulted, byte-identical output confirmed for the empty case);
> `AgentSession.ask(_:sessionId:)` — session-less calls behave exactly as before, a passed
> `sessionId` primes depth 1/2 with prior turns + component context and records this turn
> afterward, a guardrail decline never advances the session. **A real prerequisite gap found and
> fixed, not anticipated by the plan**: nothing persisted a turn's actual answer text anywhere —
> `SemanticIngestOutcome.answer`/`AgentSessionResult.answerText` were both transient, so
> reconstructing a prior turn's answer for context-priming was impossible until this milestone
> added `investigations.answer_text` (an `ALTER TABLE` inside the still-unshipped `v4` migration,
> not a new `v5` — safe specifically because `v4` hasn't released yet) and threaded it through
> every `InvestigationRecord`-constructing call site (`SemanticImporter.persistInvestigation`'s
> three callers, `AgentSession`'s decline/timeout/error paths). Depth-3 delegation is
> deliberately **not yet context-aware in a session** — `ClaudeCodeInvestigator` doesn't take a
> `--resume` parameter until M4; a session's depth-3 turns in M3 still run fresh, though the
> Claude session id they return is already captured into `ask_sessions.claude_session_id` ahead
> of M4 actually using it. 12 new `AskSessionStoreTests`, 6 new `ContextBuilderTests`, 8 new
> `AgentSessionTests` (session-not-found, turn recorded, decline doesn't advance, second-turn
> priming confirmed via a captured `sessionFactory` instructions string, component-context
> priming against a real ingested component, depth-3's Claude session id captured for future
> resume).
>
> **M4 (Claude `--resume`)**: the real reason M3 deliberately punted this — a bare
> `resumeSessionId: String?` can't distinguish "session-less call" (needs
> `--no-session-persistence`) from "session's first depth-3 turn" (needs neither flag, so the
> CLI persists it for later) from "later turn" (`--resume <id>`), since the first two both have
> no id. Resolved with a small `ClaudeCodeInvestigator.ClaudeSessionContinuity` enum
> (`.none`/`.newSession`/`.resume(id)`) rather than two parameters that would have to agree —
> `.none` is byte-for-byte the pre-Phase-5 behavior, confirmed by a regression test hitting real,
> if harmless, non-determinism along the way (`AgentAnswerSchema.cliJSONSchema()`'s
> `[String: Any]` → `JSONSerialization` round trip has no guaranteed key order, so a naive
> full-argument-array equality check between two separate `buildArguments` calls flaked even
> with nothing semantically different — fixed by asserting the specific flags that matter
> instead of raw array equality). `buildPrompt` also branches on continuity: a resumed turn gets
> a short "you already have this repository's context" reminder instead of the full
> repository-orientation intro (still followed by the same evidence-anchor/claim-type/schema
> rules every investigation carries) — a real token/cost saving `--resume` exists to enable, not
> just a flag flip. `AgentSession.runDelegated` computes the right case from
> `session?.claudeSessionId` (`nil` session → `.none`; session with no Claude id yet →
> `.newSession`; session with one → `.resume`). Verified end to end through `AgentSession`
> itself, not just at `ClaudeCodeInvestigator`'s own unit level: a real two-turn session (via
> stand-in `claude` scripts) shows the second turn's captured argv actually carrying
> `--resume claude-s1` and omitting the repository-orientation intro from its prompt — the actual
> point of this milestone, not merely that the flags compile. 8 new tests (5
> `ClaudeCodeInvestigatorTests`, 3 `AgentSessionTests`).
>
> **M5 (CLI)**: `orion-agent session create/list/show` (new nested `AsyncParsableCommand` group —
> the first in this codebase; `Ask`/`Classify` were both flat top-level commands until now) plus
> `ask --session <id>`. `session create --component <name-or-anchor>` resolves against the
> latest investigation's components by exact case-insensitive name first, then by a member
> symbol's anchor (`Store.symbol(runId:anchor:)` + a linear scan of each candidate's members —
> fine at CLI-invocation scale); a repo with no semantic investigation yet gets a clear,
> actionable error rather than an empty/confusing session. `session show` gained
> `Store.investigation(id:)` (a small, obviously-missing single-row lookup — every other
> investigation read was scoped to a run or a whole session, none to one id) to resolve each
> turn's question/answer/outcome, and reads each turn's depth off `routing_decisions` the same
> way `--explain` already does. `ask`'s formatted output gained a `[declined -- outside this
> repository's scope]` marker so a decline is never visually confused with a plain,
> nothing-asserted `verified` depth-1 answer (Docs/15 §7). **A real compile-time gotcha hit and
> fixed, not anticipated**: `@Option(help:)` takes `ArgumentHelp`, which is
> `ExpressibleByStringLiteral` — a single string *literal* (including a multi-line triple-quoted
> one) satisfies that, but a runtime `String` built via `+` concatenation does not, and fails
> with a misleading cascading "does not conform to Decodable" error on the whole command struct
> rather than a clear message at the actual broken line; fixed by using triple-quoted literals
> with `\` line continuations (this codebase's own existing convention for long prompt strings)
> instead of concatenation.
>
> **The §5 "Ask about X twice" resume-vs-fresh-start decision is finalized, not merely
> discussed**: resume the most recently active session for that component by default, with an
> always-available "+ New session" affordance for the deliberate fresh-start case — there is no
> CLI-level analog of this (the CLI's `session create` is always an explicit, separate action),
> so the decision itself is recorded here as this milestone's own checkpoint and its actual
> implementation lands in M6's app UI.
>
> No CLI-level automated tests — this codebase has never unit-tested its `ArgumentParser` command
> structs directly (`OrionCodeIntelTests`/`OrionAgentTests` depend on the libraries, not the
> `orion-index`/`orion-agent` executables), so this milestone follows that same precedent:
> verified live instead, against a real tiny analyzed fixture repo — `session create` (both
> repository- and component-scoped, plus the no-semantic-investigation error path),
> `session list` (text and `--json`), `session show` (empty and clear-hint states), and
> `ask --session <bogus-id>` failing fast with exit 3 *before* attempting any model load
> (confirmed by real elapsed time, not just reading the code path).
>
> **M6 (App UI)**: `AskHistory` rewritten from a pure, synchronous, UI-local model (Docs/14 §8 M4)
> into a real, DB-backed session model — `refresh`/`select`/`createSession`/`ask` all read/write
> through `CodebaseModelStore`/a fresh writable `Store`, exactly the layering
> `SemanticInvestigationRunner`/`AnalysisRunner` already established for the app's other writes
> (`CodebaseModelStore` itself stays read-only, per Docs/13 M3's own design). Ask's list promotes
> from one row per question (Docs/14 §4.6) to one row per session, grouped by component exactly
> as before; the detail pane now stacks a session's turns oldest-first (the one place in this app
> a scrolling column is the right shape, since turns within one session genuinely are one
> conversation, unlike across sessions). Past turns are reconstructed from persisted data alone
> via a new `AskRunner.loadPersistedTurn` — reusing `AskResultSummary`'s existing "test-support"
> memberwise init for real reconstruction, not just tests, with two small, explicitly documented
> fidelity gaps (`droppedClaimCount` and the loop-level `partial` flag were never persisted, so
> they're approximated on reload, never fabricated as a false precise count). The §5
> resume-or-create decision finalized in M5 is now real: `askAbout`/`resumeOrStartSession`/
> `startSession` implement "resume the most recent session for that scope, else mark the next
> action as creating one" (resume) vs. "always create, even if one exists" (the "+" affordance) as
> two deliberately distinct paths, not one conflated one. A guardrail decline gets its own neutral
> "Outside this repository's scope" treatment, checked before the ungrounded/partial branches so
> it's never confused with either. **One simplification made and recorded, not silently
> substituted for the plan's own wording**: §5 sketched "a lightweight 'Start a session' prompt"
> for submitting with nothing selected; implemented instead as the same resume-or-create
> resolution `askAbout` already uses (reuse a "General" session if one exists, else create one) —
> satisfies the plan's actual concern ("never a same-question-forever throwaway session per
> keystroke," not "never auto-create anything") without a second UI surface for it.
>
> `AskHistoryTests` (Docs/14 §8 M4's own file) rewritten entirely against the new async, DB-backed
> API, using the same real-`AnalysisPipeline`-against-a-temp-repo fixture pattern
> `SemanticInvestigationRunnerTests` already established, plus a `TurnGenerating` stub mirroring
> `AgentSessionTests`' own `ScriptedSession` for model-free depth-1 answers. **One real fixture bug
> caught by the suite itself, not a product bug**: the first version's scripted answer ("foo is a
> no-op.", 15 chars) tripped Docs/12 M5's own `minLength: 20` schema floor — fixed by lengthening
> the fixture, the same resolution Docs/13 M7 already recorded for the identical class of failure.
>
> **M7 (routing benchmark)**: `orion-agent bench` built (a new `AsyncParsableCommand` reading a
> benchmark JSON file, looping `AgentSession.ask(_:)` in-process with no session, writing
> `routing_benchmark.jsonl` + a computed summary) and verified live at zero cost before spending
> anything real — a 2-question local smoke test, plus a decode check against the real
> `benchmark.resolved.json`. One naming correction versus the plan's own §6.3 sketch, caught
> immediately on writing it: the plan reused `--out` for the report directory, colliding with
> every other command's `--out` (the *analyzed repository's* directory) — fixed with a distinct
> `--report-dir`, `--out` left consistent everywhere.
>
> **Then run for real**, with the user's explicit approval before any paid step (an 8-question
> free smoke slice first, confirming the harness against a real repo and reproducing a known bug
> live, then the remaining 47 on request) — the full, real 55-question benchmark against vendored
> Starlette, **$1.01 total cost**, written up in
> `Agent Feasibility Study/PHASE5_ROUTING_BENCHMARK.md` (raw data alongside it in
> `results/phase5_routing_benchmark/`). Headline: depth 3 was reached only 3/55 times (5%, vs.
> Docs/12 M5's 9/13), and **two real, load-bearing bugs surfaced**, not just routing noise: (1)
> the guardrail declined two unambiguously in-scope architecture questions as "general knowledge"
> — Docs/15 §12.1's own named risk, now a measured false-positive, not a hypothetical; (2) the one
> real depth-3 attempt hit the `$1.00` default budget ceiling before finishing, reproducing
> Docs/12 M5's own finding 3 (which raised the cap from $0.50 to $1.00) — $1.00 alone still isn't
> always enough. A 10-question hand-checked correctness sample also caught the exact same
> `ASGIRunner` confabulation Docs/12 Risk #7's own six-stage table recorded in a *separate*
> evaluation (`DC-01` here, `XF-07` there) — two independent occurrences, no longer plausibly
> one-off noise. Full reasoning on what this run does and doesn't establish (the two bugs
> confound the depth-2-vs-3 read this benchmark was designed to produce) is in the results doc's
> own §5, not repeated here.
>
> Full suite green under the exact CI invocation after every milestone (270 tests as of M1; M2
> added none of its own, being a pure relocation; 294 as of M3; 302 as of M4; M5 added no new
> XCTest cases, unchanged at 302; M6: `OrionApp`'s own suite at 117 tests, 0 failures; **M7 added
> no new XCTest cases** — a CLI command, verified live per this codebase's own established
> precedent — full `OrionMacOs` suite reconfirmed unchanged at 302 after adding it).
> `OrionApp.xcodeproj` build + test: `** TEST SUCCEEDED **`.
>
> **M8 (hardening)**: three real fixes, all three directly traceable to M7's own live findings —
> exactly the "whatever real bugs the live milestones actually surfaced" this milestone was
> always going to be, not planned in advance. (1) **The guardrail false-decline (Risk #1) —
> root-caused, not just patched.** `AppleFoundationDepthClassifier` was classifying every
> question with *zero* grounding in which repository was actually under analysis; a question
> that plainly named the repo ("What are the major components of Starlette...") read as a
> request to recite general public-library trivia, not a request to investigate this specific
> analyzed instance. Fixed by threading `repositoryName` into the classifier (constructed inside
> `AgentSession.init`'s body from `config.repoRoot.lastPathComponent`, since a bare parameter
> default has no access to `config`) and rewriting its instructions to say so explicitly, with a
> worked example matching the exact failed shape. **Verified live, for free, on-device**: both
> `AR-01`/`AR-05`'s real question text, run through the real classifier with
> `repositoryName: "starlette"`, are no longer declined; the same questions *without* a
> repository name still reproduce the original bug, confirmed side by side in the same test
> file. (2) **The budget-
> ceiling failure message (Risk #7) now names the actual fix** — the configured cost ceiling and
> the `--max-budget-usd` flag to raise it — instead of only repeating the CLI's own generic
> error, so hitting this (now twice-documented) wall is actionable without reading source. (3)
> **`--resume` verified live against a real `claude` CLI session (Risk #3), closing the single
> highest-named risk in this entire plan** — see Risk #3's own entry for the real evidence
> (a cross-turn checkpoint-recall test, $1.00 real cost, unambiguous). 5 new tests (4 live
> `AppleFoundationDepthClassifierLiveTests`, added to the CI `--skip` list alongside the other
> five per this codebase's own defense-in-depth precedent; 1 `AgentSessionTests` budget-message
> regression, which does run in CI). **303 tests, 0 failures** under the exact CI invocation
> (302 + the 1 new non-live test — the guardrail fix itself is a behavior change to an
> already-covered path, not new library surface, so it added no test of its own beyond the live
> ones); `OrionApp.xcodeproj` still builds clean. Depends on Phase 1
> ([10_phase1_deterministic_code_intelligence.md](10_phase1_deterministic_code_intelligence.md)),
> Phase 2 ([11_phase2_semantic_analysis.md](11_phase2_semantic_analysis.md)), Phase 3
> ([12_phase3_mlx_agent.md](12_phase3_mlx_agent.md)), Phase 4
> ([13_phase4_architecture_ui.md](13_phase4_architecture_ui.md)), and Phase 4.5
> ([14_phase4_5_ui_ux_redesign.md](14_phase4_5_ui_ux_redesign.md)) — all complete (Phase 4.5's
> SwiftUI implementation is committed on `main`, not only prototyped; its own status line saying
> otherwise is stale).

## 1. Scope of this document, and why it's larger than Docs/08's own Phase 5

[08_development_phases.md](08_development_phases.md) scopes Phase 5 narrowly:

```
Implement:
Simple -> MLX
Investigative -> MLX + tools
Complex -> Claude Code

Benchmark routing quality and latency.
```

The routing *mechanism* itself is already built and shipping — Phase 3's `DepthModel` +
`AgentSession` (Docs/12 M0-M6) already implements exactly this three-way split, and Phase 4/4.5's
`AskView` already exposes it end to end. What Docs/12 and Docs/13 both explicitly deferred to
"Phase 5" is the **systematic benchmark** against the full corpus — Docs/12 M5 ran only 13
hand-picked questions ("Phase 5 owns turning this into one, not a substitute for one"), and
Docs/13's own "not a routing-quality benchmark. Phase 5" repeats the same deferral.

This plan folds in two more pieces of real product scope the user asked to land in the same
phase, because both sit on the exact same seam (`AgentSession.ask`, the Depth Model, the `Ask`
destination) the benchmark already has to touch:

1. **Guardrails** — decline questions unrelated to the analyzed repository, rather than let
   `AgentSession` spend a local-model or Claude-Code call on them (or worse, answer confidently
   from the model's own general knowledge and get ingested as if it were repository-grounded).
2. **Conversational sessions** — today, per Docs/12 "What Phase 3 is not" and Docs/13 "Not real
   multi-turn conversational memory," every `AgentSession.ask(_:)` call is a fully independent
   question; Docs/14's `AskHistory` only *tags* a question with a component name for display
   grouping, it does not thread any context between questions. This phase adds real, persisted,
   resumable sessions: a developer can open a session scoped to one component (or to the whole
   repository), ask an initial question, keep asking follow-ups that build on what was already
   established, close it, come back to it later, or start a second, independent session about the
   same component without polluting the first one's context.

None of this is a routing-mechanism change — depth 1/2/3 stays exactly as Docs/12 built it. It's
what surrounds one `ask()` call: whether it should run at all (guardrails), what context it starts
from (sessions), and how well the whole thing performs at scale (the benchmark). Sections 4-6
below map directly onto Docs 08's "Benchmark routing quality and latency," and to guardrails/
sessions respectively; §7-9 are the concrete schema/CLI/UI; §10 is testing; §11 is milestones.

### What Phase 5 is not

- Not a change to `DepthModel`'s own depth-1/2/3 decision logic, `ActionLoop`, or
  `ClaudeCodeInvestigator`'s core investigation contract — all of Docs/12's resolved Risk #3/#7
  design stays exactly as shipped. Phase 5 adds a **gate before** routing (guardrails) and
  **context threading around** routing (sessions); it does not re-litigate how depth 1/2/3
  themselves work.
- Not Teaching Mode (Docs/05 Stage 7, Docs/14 §4.8) or Model Changes' real backing data (Docs/14
  §4.7) — both are explicitly out of scope here, already flagged in Docs/14 as needing their own
  planning.
- Not a rewrite of Docs/14's Ask UI shell (sidebar destination, master-detail layout, glass
  materials) — this phase extends what Docs/14 built (promotes the list's unit from "question" to
  "session"), it does not re-do Docs/14's own redesign work.
- Not multi-repository session management — a session belongs to one repository, matching every
  prior phase's single-repo-per-invocation/per-window posture.

---

## 2. Decisions (made with the user)

1. **One document, not three.** Guardrails, sessions, and the benchmark are one Phase 5 plan,
   matching the one-doc-per-phase convention Docs 10-13 already established, rather than three
   separate documents for three sub-concerns of the same phase.
2. **Guardrail mechanism: extend the existing Depth Model fallback classification call, not a
   separate classifier.** `AppleFoundationDepthClassifier` (Docs/12 Decision #2a) already makes one
   `@Generable`/`@Guide` guided-generation call per non-heuristic-matched question. Rather than add
   a second model call purely to check topical relevance, `DepthClassificationOutput` gains one
   more field in the same call. Zero added latency/cost on top of what the Depth Model already
   does; `DepthHeuristics`-matched questions (Docs/03's six worked L1/L2 examples) skip the check
   entirely, on the reasoning that a question that already matches one of those fixed code-shaped
   patterns is repository-related by construction.
3. **Local-model (depth 1/2) session continuity: reconstruct from the persisted transcript on
   every turn, not a live in-memory `ChatSession` kept alive per session id.** Matches Docs/04 §6
   ("the Codebase Model should be queryable independently of any individual conversation") and
   avoids inventing session-lifetime/memory-management machinery the app doesn't have anywhere
   else — every existing piece of state in this app (repository, analysis run, investigations) is
   already DB-backed and reconstructed on demand, not held live across relaunches.
4. **Claude Code (depth 3) session continuity: use the CLI's own `--resume <session_id>`.**
   `investigations.session_id` (Claude's own session identifier, captured since Phase 2) already
   exists in the schema for exactly this kind of use, previously only used for cost/turn
   bookkeeping. A follow-up question in the same Orion session resumes the same Claude
   conversation — Claude keeps its own investigation context (which files it already read, what it
   already concluded) rather than Orion re-deriving and re-sending a compressed summary of the
   prior turn. **This requires a real, load-bearing change to `ClaudeCodeInvestigator`**: it
   currently always passes `--no-session-persistence` (`buildArguments`, Docs/12 M3), which would
   make `--resume` a no-op. §6.3 below covers the exact change and its own risk (§12.3).

---

## 3. Guardrails

### 3.1 What "out of scope" means here

Orion is a repository-understanding tool (Docs/01 §1, §4: "not an AI chatbot... a knowledge
reconstruction and learning system"). A question is **in scope** when answering it means reasoning
about the analyzed repository's code, structure, behavior, dependencies, tests, or the Codebase
Model built from it — including meta-questions like "what does this codebase model track" that
are about *Orion's own understanding of this repository*. A question is **out of scope** when it
has nothing to do with the repository at all: general knowledge, chit-chat, requests to write new
code unrelated to explaining existing code, or a request to have the agent do something outside
read-only investigation (Docs/06 §6's own "no bypass mechanisms" principle already rules out
Bash/Edit/Write tool access at the mechanism level — §3.4 covers the residual risk that this alone
doesn't cover).

### 3.2 Where the check runs

```
question
  -> DepthHeuristics.classify(question)   -- matched: proceed directly, no guardrail check
       (unmatched)
  -> AppleFoundationDepthClassifier.classify(question)   -- ONE call, extended output:
       { depth, intent, confidence, rationale, isRepositoryRelated, offTopicRationale }
  -> isRepositoryRelated == false?
       yes -> AgentSession declines, never loads Qwen3 / invokes Claude Code
       no  -> existing confidence-based depth 1/2/3 escalation, unchanged
```

`DepthClassificationOutput` (`AppleFoundationDepthClassifier.swift`) gains:

```swift
@Generable
struct DepthClassificationOutput {
    let depth: Int
    let intent: String
    @Guide(.anyOf(["high", "medium", "low"]))
    let confidence: String
    let rationale: String
    /// New in Phase 5. `true` unless the question has nothing to do with the analyzed
    /// repository's code, structure, or behavior.
    let isRepositoryRelated: Bool
    /// Populated only when `isRepositoryRelated == false` -- the reason shown to the developer,
    /// e.g. "This looks like a general knowledge question, not one about the analyzed repository."
    let offTopicRationale: String
}
```

extending the classifier's own instructions with the scope rule from §3.1 and a couple of worked
examples ("what's a good recipe for pasta" -> out of scope; "what does `AuthService` do" ->
in scope; "what is this codebase model tracking" -> in scope, meta-question about the tool's own
understanding of the repository).

`DepthDecision` gains `isInScope: Bool = true` (defaulted so **every existing call site compiles
unchanged** — `DepthHeuristics.classify`'s six hand-written decisions, `--force-depth`'s override
in `AgentSession.resolveDepth`, and every existing `DepthModel`/`DepthDecision` test all construct
a decision without ever mentioning this field and get `true`, correctly, for free).
`AppleFoundationDepthClassifier` maps `isRepositoryRelated`/`offTopicRationale` onto it;
`ModelBackedDepthClassifier` (Docs/12's superseded, still-tested fallback) is **not** touched —
it stays `isInScope: true` always, documented as a known gap of the option nobody currently routes
through anyway.

`DepthModel.classify` gains one branch, checked **before** the existing confidence-based
escalation and only for a model-backed (non-heuristic) result:

```swift
let decision = try await classifyWithTimeout(question)
guard decision.isInScope else { return decision }   // short-circuits AgentSession below
switch decision.confidence { /* existing medium/low escalation, unchanged */ }
```

A timed-out fallback (Docs/12's existing 20s watchdog) still returns `isInScope: true` — a
classifier that couldn't even respond gets escalated to depth 3 exactly as today, never silently
declined; declining is a positive, confident classification outcome, not a fallback for "the
classifier didn't answer."

### 3.3 What `AgentSession` does with a declined question

```swift
public func ask(_ question: String, sessionId: String? = nil) async throws -> AgentSessionResult {
    ...
    let decision = try await resolveDepth(question)
    guard decision.isInScope else {
        return try declineOutOfScope(question: question, decision: decision, store: store, run: run)
    }
    switch decision.depth { ... }   // unchanged
}
```

`declineOutOfScope` never loads `Qwen3Agent`, never builds a `ClaudeCodeInvestigator` — the whole
point is that an out-of-scope question costs nothing and takes no meaningful time. It:

- inserts one `investigations` row (`complexity = "none"`, `model_used = nil`,
  `outcome = InvestigationOutcome.declined.rawValue` — a **new enum case**, additive to the
  existing `verified|partially_verified|unverified|incomplete|rejected` set; every exhaustive
  switch over `InvestigationOutcome` in `OrionCodeIntel`/`OrionAgent`/`OrionApp` needs one more
  case added, tracked as an M1 checklist item, not a schema change since `outcome` is a plain
  `TEXT` column),
- persists the routing decision as usual (`routing_decisions`, `method`/`confidence`/`rationale`
  carry the classifier's own account of *why* it judged the question off-topic — visible via
  `--explain`/the Diagnostics destination exactly like any other routing decision, per Docs/05 §8),
- returns an `AgentSessionResult` whose `answerText` is a fixed, honest decline —
  `"I can only help with questions about the analyzed repository. Try asking about a specific
  file, symbol, component, or how something works."` — with `claimCount: 0`, `partial: false`
  (a decline is a *correct, complete* outcome, not a failed or incomplete one).

### 3.4 What this does not cover

A guardrail on the *question text* does not defend against a multi-turn conversation drifting
off-topic mid-session, or a crafted question that reads as repository-related but is actually a
prompt-injection attempt to get Claude to reveal something outside its intended scope. Two
existing mechanisms already bound the worst case regardless: `ClaudeCodeInvestigator`'s
`--tools Read,Grep,Glob` restriction (no `Bash`/`Edit`/`Write` — the CLI session has no destructive
capability to be tricked into using, per Docs/06 §6) and depth 1/2's local loop having no shell
access at all. This phase's guardrail is a **relevance/UX** control, not a security boundary on its
own; §12.4 records this explicitly as a residual risk rather than implying the classifier is a
complete defense.

---

## 4. Conversational sessions

### 4.1 What a session is

A session is an ordered sequence of question/answer turns that share context, scoped to either:

- **one component** (`scope_type = "component"`) — "dig deeper" into `AuthService` across several
  follow-up questions, all primed with that component's members/dependencies/claims in addition to
  the whole-repo Code Graph; or
- **the whole repository** (`scope_type = "repository"`) — a general architectural conversation
  with no single-component anchor.

A session is **not** a new store of question/answer text. Docs/04 §6's rule ("the Codebase Model
should be queryable independently of any individual conversation") already shapes every table
Phase 2/3 built: an `investigations` row (plus its `claims`/`evidence`/`routing_decisions`/
`agent_tool_calls`) is already the complete record of one question and its answer. A session is a
thin, ordered **pointer** over existing `investigations` rows, not a duplicate transcript store —
consistent with how `component_relationships` was kept as its own table instead of reusing/
duplicating Phase 1's `relationships` (Docs/11 Decision), and how `routing_decisions` was kept
distinct from `investigations.complexity` (Docs/12) specifically so each concept has exactly one
place it's recorded.

The developer can, at any time:
- continue an existing session (ask another question; it's appended as the next turn),
- open a **second**, independent session about the **same** component (a fresh start, no context
  from the first one),
- open a session at the whole-repository level instead.

### 4.2 Schema (`v4_phase5_schema` migration, `OrionCodeIntel`)

Additive only — no Phase 1-3 table altered, following the same discipline every prior migration
used.

```sql
CREATE TABLE ask_sessions (
    id                TEXT PRIMARY KEY,
    repository_id     TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
    commit_hash       TEXT NOT NULL,
    scope_type        TEXT NOT NULL,      -- 'repository' | 'component'
    component_id      TEXT REFERENCES components(id) ON DELETE CASCADE,  -- NULL iff scope_type='repository'
    title             TEXT NOT NULL,      -- derived from the first turn's question; user-renamable later
    claude_session_id TEXT,               -- Claude CLI's own id from the most recent depth-3 turn, for --resume
    turn_count        INTEGER NOT NULL DEFAULT 0,
    created_at        TEXT NOT NULL,
    last_active_at    TEXT NOT NULL
);
CREATE INDEX idx_ask_sessions_repo ON ask_sessions(repository_id, commit_hash, last_active_at);
CREATE INDEX idx_ask_sessions_component ON ask_sessions(component_id);

CREATE TABLE ask_session_turns (
    id               TEXT PRIMARY KEY,
    session_id       TEXT NOT NULL REFERENCES ask_sessions(id) ON DELETE CASCADE,
    turn_index       INTEGER NOT NULL,
    investigation_id TEXT NOT NULL REFERENCES investigations(id) ON DELETE CASCADE,
    created_at       TEXT NOT NULL,
    UNIQUE (session_id, turn_index)
);
CREATE INDEX idx_ask_session_turns_session ON ask_session_turns(session_id, turn_index);
```

**Naming callout, to avoid confusion with an existing field**: `ask_sessions.id` (our new
conversational-session identity) and `investigations.session_id` (Claude CLI's own internal
session id, captured since Phase 2 purely for cost/turn bookkeeping) are two unrelated
identifiers that happen to sit one column apart conceptually. `ask_sessions.claude_session_id`
denormalizes the *latest* turn's `investigations.session_id` for `--resume` (§4.4) specifically so
`AgentSession` doesn't need a join to find it; it is not itself a foreign key, since Claude's
session ids are opaque strings scoped to the `claude` CLI's own state, not a row in this database.

`component_id` references a `components` row from one specific past investigation (Docs/11:
`components` is scoped to an `investigation_id`, not a stable cross-investigation identity — a
component named "Authentication" in one semantic investigation and a later re-investigation are
two different rows). A session's component anchor is therefore always "the specific component the
developer clicked on in the Architecture Overview at the time," which is always the *current*
(latest) investigation's component per `ArchitectureModelLoader` (Docs/13 M4) — see Risk §12.2 for
what happens if a newer investigation later supersedes it.

### 4.3 Local-model (depth 1/2) continuity: reconstructed context, not a live session

`ContextBuilder.build(exportDir:)` gains a defaulted parameter:

```swift
public static func build(exportDir: URL, priorTurns: [PriorTurn] = [], componentContext: String? = nil) -> String?
```

(`priorTurns: []`/`componentContext: nil` preserve every existing call site — Docs/12 M4's
`AgentSession.runLocal` and every `ContextBuilderTests` case — unchanged.)

`PriorTurn` (new, small): `{ question: String, answerText: String, outcome: String }`. When
`sessionId` is provided, `AgentSession.ask` loads the session's prior turns (bounded to the most
recent **5** — a fixed window, not the full history, so a long-running session's primed context
stays bounded regardless of how many turns preceded it; each turn's `answerText` truncated to
Phase 3's own `ContextBuilder.maxCharsPerFile` convention) via a new `Store.priorTurns(sessionId:)`
read (joins `ask_session_turns` -> `investigations` -> that investigation's stored answer, which
`SemanticImporter.ingestAnswer` already returns as `SemanticIngestOutcome.answer`, or `nil` for a
Claude failure path that never reached ingestion — treat that turn's `answerText` as its
recorded failure message instead of dropping the turn entirely, so a follow-up question can still
reference "you said that failed because...").

`componentContext`, only for `scope_type == "component"` sessions, reuses `ComponentDetailLoader`
(Docs/13 M5, already built for the app's own Component Exploration panel) to slice that
component's members/dependencies/claims into a compact block — the same reuse-not-duplicate
discipline as every prior context-priming decision in this project (Phase 2's `build_structured_
context`, Phase 3's `ContextBuilder` itself). Since `ComponentDetailLoader` today lives in
`OrionApp/Orion/Model/` (app-target only), and `ContextBuilder` lives in `OrionAgent` (so both
`orion-agent` CLI and the app can prime the same way), this phase moves `ComponentDetailLoader`'s
pure-logic half (no SwiftUI) down into `OrionCodeIntel` or `OrionAgent` — a real, small refactor
this milestone has to do, not a restyle; see §11 M2.

### 4.4 Claude Code (depth 3) continuity: `--resume`

`ClaudeCodeInvestigator` gains:

```swift
public func investigate(question: String, resumeSessionId: String? = nil) async throws -> ClaudeCodeInvestigationResult
```

`buildArguments(prompt:resumeSessionId:)`:
- when `resumeSessionId` is `nil` **and** the call is not part of any Orion session (the existing,
  unchanged single-shot `orion-agent ask` path with no `--session`) — behavior is **byte-for-byte
  identical to today**: `--no-session-persistence` is still passed, nothing about the non-session
  CLI path changes.
- when the call **is** part of an Orion session — `--no-session-persistence` is **not** passed
  (this is the load-bearing change; see §12.3), and:
  - first turn in the session (`resumeSessionId == nil`, session has no `claude_session_id` yet):
    plain invocation, no `--resume`; the resulting wrapper's own `session_id` becomes
    `ask_sessions.claude_session_id` for next time.
  - a later turn: `--resume <claude_session_id>` inserted; the prompt itself is just the new
    question (Claude already has the prior conversation's context from its own session state — no
    need to re-send `priorTurns` text the way the local-model path does), still followed by the
    same evidence-anchor/claim-type rules and `AGENT_ANSWER_SCHEMA` requirement every investigation
    already carries.
- `AgentSession` decides which mode applies based on whether it was called with a `sessionId` at
  all — a bare `agentSession.ask(question)` (no session) keeps today's exact behavior; a session
  turn opts into persistence deliberately.

### 4.5 `AgentSession.ask` signature and persistence

```swift
public func ask(_ question: String, sessionId: String? = nil) async throws -> AgentSessionResult
```

(defaulted `nil` — every existing call site, `orion-agent ask` and `OrionApp`'s `AskRunner`, keeps
compiling and behaving exactly as today when no session is passed). When `sessionId` is provided:

1. Loads the `ask_sessions` row (throws a new, typed `AgentSessionError.sessionNotFound` if
   missing — a stale/deleted session id is a caller bug, not a silent no-op).
2. Loads `priorTurns` (§4.3) and, for a component-scoped session, `componentContext`.
3. Runs the guardrail + depth routing exactly as §3 describes (a session does not bypass the
   guardrail — an off-topic follow-up mid-session is still declined, and does **not** advance
   `turn_count`/`last_active_at`, so a declined attempt isn't recorded as if it were a real turn).
4. For depth 1/2: `ContextBuilder.build(exportDir:priorTurns:componentContext:)`.
5. For depth 3: `ClaudeCodeInvestigator.investigate(question:resumeSessionId: session.claudeSessionId)`.
6. On success, appends one `ask_session_turns` row (`turn_index = session.turnCount`), and updates
   `ask_sessions.turn_count`/`last_active_at`/`claude_session_id` (only overwritten on a depth-3
   turn that returned one) — one `Store.recordSessionTurn(sessionId:investigationId:claudeSessionId:)`
   call bundling all three writes transactionally.
7. `title`: set once, from the first turn's question (truncated), when the session is created —
   not re-derived per turn.

### 4.6 Session lifecycle (creation)

`Store.createAskSession(repositoryId:commitHash:scopeType:componentId:title:)` — called explicitly
by the caller (CLI or app), not implicitly by `ask()`. `ask(_:sessionId:)` always requires an
existing session id; it never silently creates one on first use, so "ask a one-off question" and
"start a session" stay two distinct, deliberate actions matching Docs/05 §5's "the user should not
need to understand the routing mechanism" — but a *session* is a real, visible product concept the
user does deliberately choose to start, unlike routing itself.

---

## 5. Ask UX evolution (building on Docs/14, not replacing it)

Docs/14 §4.6 already built a master-detail Ask destination: a component-grouped list on the left,
selected item's detail on the right, reusing exactly the "scannable list, click through to detail"
pattern the rest of the app uses instead of a chat transcript — and it was right to reject a flat
scrolling transcript for the reason it gives (Docs/04 §6: a developer returns to a specific answer
as reference material). This phase's job is narrower than it sounds: **promote the list's unit
from "one question" to "one session,"** so the reference-tool framing Docs/14 already argued for
extends naturally to a multi-turn conversation instead of flattening it back into one row per turn.

- **Left column — sessions, not individual questions**, grouped exactly as Docs/14 already
  groups: a "General" section (repository-scoped sessions) plus one collapsible section per
  component that has at least one session. Each row: the session's `title`, a turn count, last
  active time, and the same outcome dot Docs/14 already computes — now reflecting the session's
  **most recent** turn's outcome, not a single question's.
  - A "+" affordance per group ("New session about {component}" / "New general session").
  - `ComponentDetailView`'s existing "Ask about {name}" button (Docs/14 §4.5) changes behavior:
    if an open session for that component already exists, it selects and opens that session
    directly (continuing it) instead of always starting a new one — a real product decision to
    surface: *should* clicking "Ask about X" a second time always resume the same session, or ask
    the developer which they want (continue vs. start fresh)? Recommended default: resume the most
    recently active session for that component, with the "+ New session" affordance in the list
    always available for the deliberate fresh-start case. Flagged as a UX decision worth
    confirming during implementation (§11 M5), not presupposed here as final.
- **Right column — the selected session's turn history**, each turn rendered as Docs/14's existing
  `AskEntryView` content (outcome label including the depth-1 "Not independently checked"
  treatment, answer text, claims with clickable evidence, routing detail behind "Explain") stacked
  in order, oldest first — this *is* the one place a scrolling column is the right shape, because
  within one session the turns genuinely are one continuous conversation, unlike across sessions.
  A declined (§3.3) turn renders with its own distinct, neutral treatment — not the orange
  "partial" warning styling, not the green verified seal; a plain "Outside this repository's scope"
  label, so a developer never reads a guardrail decline as the system having failed to answer.
- **The input bar** now always asks *within* whichever session is currently open; asking with no
  session open first shows a lightweight "Start a session" prompt (general or, if a component's
  inspector panel is currently showing, pre-offered as that component's scope) rather than silently
  creating a same-question-forever throwaway session per keystroke.

No change to `EvidenceView`, `ComponentDetailView`'s other content, or the shell/navigation
structure Docs/14 §4.1 built — this is additive to the Ask destination specifically.

---

## 6. Routing quality & latency benchmark

Docs/08's own, original Phase 5 ask — closing the deferral both Docs/12 M5 and Docs/13 explicitly
left open.

### 6.1 Corpus

The full 55-question `Agent Feasibility Study/benchmark/benchmark.resolved.json` set (Phase 0's
own benchmark, already carrying `category`/`relevant_symbols`/`evidence`/`expected_answer` per
question) — not just Docs/12 M5's 13 hand-picked ones. Every question asked **independently**
(`sessionId: nil`) — this benchmark measures the routing mechanism and single-question quality, the
same shape Docs/12 M5 already used; it does not exercise §4's session continuity, which is a
separate, later evaluation if the sessions feature warrants its own benchmark once real usage
exists.

### 6.2 What gets measured

For each question, `routing_decisions` + `investigations` (already written by every `ask()` call,
no new persistence needed for this) directly give: depth chosen, method (heuristic/model),
confidence, outcome, cost, turns, latency (`durationMs`). This phase adds:

- **Routing-quality signal**: does the chosen depth correlate with the benchmark's own `category`
  (`code_understanding`/`cross_file_reasoning`/`architecture`/`dependency_change_impact`/
  `behavioral_reasoning`) and with whether the answer was actually correct against
  `expected_answer`? Docs/12 M5's own finding (depth 1 wrong 4/4, depth 3 correct 7/7 on its small
  sample) is the hypothesis this benchmark either confirms or revises at full scale (n=55 instead
  of n=13).
- **Latency**: p50/p95 per depth, and total wall-clock for the full run.
- **Cost**: total and per-depth-3-question `total_cost_usd`, compared against Docs/12 M5's
  $0.17-$1.77/question baseline.
- **Correctness**: graded by hand against `expected_answer`, the same posture Docs/12 M5 used — an
  automated LLM-judge axis was explicitly deferred as a stretch goal in Phase 2 and is **not**
  built here either (§12.5); this phase's real deliverable is the routing/latency/cost
  instrumentation at full scale, with correctness spot-checked the same manual way, not a new
  grading mechanism.

### 6.3 `orion-agent bench` (new CLI subcommand)

```
orion-agent bench <path> --questions <benchmark.resolved.json> --out <report-dir>
  [--max-budget-usd <per-question ceiling>] [--limit <n>] [--category <name>]
```

Loops the question set through `AgentSession.ask(_:)` **in-process** (no session, no subprocess
per question — cheaper and faster than shelling out 55 separate `orion-agent ask` invocations),
writing `<report-dir>/routing_benchmark.jsonl` (one line per question: id, category, depth,
method, confidence, outcome, cost, turns, latency, answer text) and a summary
`routing_benchmark_summary.json` (per-depth/per-category aggregate counts, cost, p50/p95 latency).
`--limit`/`--category` support a partial/smoke run without spending the full corpus's cost every
time this is re-run (e.g. after a `DepthModel` change) — matches the cost-consciousness already
built into every real-usage-costing command in this project (`--max-budget-usd` everywhere,
Docs/13's explicit-confirmation gate for semantic investigations).

Real execution against the full 55 questions and cost is **manual, not CI** — same posture as
Docs/12 M5 and Docs/11 M4/M6 (real Claude usage, not something to run per-commit).

---

## 7. CLI (`orion-agent`) additions

- **`ask <path> "<question>" ... [--session <id>]`** — new optional flag on the existing `ask`
  command (Docs/12 M4). Absent: today's exact behavior, unchanged. Present: routes through
  `AgentSession.ask(question, sessionId: id)`; a guardrail decline still exits `0` (a decline is a
  successful, expected interaction, not a failure) and is distinguished only by
  `outcome == "declined"` in `--json` output or a `[declined]` marker in the formatted view —
  **not** a new exit code, so existing scripts checking only `ExitCode` aren't affected by this
  addition.
- **`session create <path> [--component <anchor>] [--title <text>]`** — `--component` resolves a
  component by member anchor or component name against the latest investigation (reusing
  `Store.components(investigationId:)`, erroring clearly if none matches or no semantic
  investigation exists yet); omitted means `scope_type = "repository"`. Prints the new session id.
- **`session list <path> [--json]`** — id, scope, title, turn count, last active, for the
  repository's current commit.
- **`session show <path> <session-id> [--json]`** — full turn-by-turn history (question, answer,
  outcome, depth) for one session, the CLI-level equivalent of §5's right column.
- **`bench`** — §6.3.

---

## 8. Testing & verification (planned — no live results yet)

**Unit (`OrionCodeIntelTests`/`OrionAgentTests`, no model load, no network)**

- `v4_phase5_schema` migration applies cleanly on top of `v3_phase3_schema`; all Phase 1-4 tests
  stay green (no regression) — the same bar every prior additive migration was held to.
- `DepthClassificationOutput`/`AppleFoundationDepthClassifier` guardrail field: a scripted stub
  returning `isRepositoryRelated: false` correctly short-circuits `DepthModel.classify` before any
  confidence-based escalation runs; `isRepositoryRelated: true` behaves exactly as today's existing
  `DepthModelTests` already verify (regression, not new behavior, for the in-scope path).
- `AgentSession.ask` guardrail path: a fake fallback classifier returning out-of-scope produces an
  `AgentSessionResult` with zero cost, `outcome == "declined"`, and confirms `Qwen3Agent`/
  `ClaudeCodeInvestigator` were never invoked (the seam `AgentSessionTests` already uses for
  depth-1/2/3 coverage, extended with one more stub path).
- `ContextBuilder.build(exportDir:priorTurns:componentContext:)`: empty `priorTurns` produces
  byte-identical output to today's `build(exportDir:)` (regression guard for the signature change);
  a non-empty `priorTurns` list appears in the output, bounded to 5 entries when more are passed.
- Session persistence: `Store.createAskSession`/`recordSessionTurn`/`priorTurns(sessionId:)`
  against a fixture repo — turn ordering, `turn_count`/`last_active_at` updates, and
  `claude_session_id` only updating on a depth-3 turn that returned one.
- `ClaudeCodeInvestigator.buildArguments`: the existing non-session call site still produces
  `--no-session-persistence` with no `--resume` (regression); a session-mode call with no prior
  `claude_session_id` omits both; a session-mode call **with** a prior id inserts
  `--resume <id>` and omits `--no-session-persistence` — all via the existing stand-in-`claude`-
  script pattern (Docs/12 M3), no live API call in this tier.

**Model-dependent (real `Qwen3-8B-4bit`/`FoundationModels`/`claude` CLI, `XCTSkip`-gated exactly
like every prior phase's live tests)**

- A real off-topic question ("what's a good pasta recipe") against
  `AppleFoundationDepthClassifier` actually comes back `isRepositoryRelated: false` — confirms the
  guided-generation field behaves as designed on the real model, not just against a scripted stub.
- A real two-turn session against vendored Starlette: turn 1 establishes a fact about a component,
  turn 2 ("and what does it depend on?", deliberately under-specified without the session's prior
  context) is answered correctly **only** because the session's `priorTurns`/`--resume` actually
  carried context forward — the concrete regression this whole feature exists to prevent
  (an under-specified follow-up silently regressing to a generic or wrong answer).

**Manual, not CI** — the full §6 benchmark run (real cost, ~similar order of magnitude to Docs/12
M5's $6.08/235-turns for 13 questions, scaled to 55 — budget accordingly before running); the CLI
`session`/`bench` subcommands click-tested against vendored Starlette; the app's session-grouped
Ask UI click-tested the same way Docs/13/14's own manual passes were (screenshot each new state).

**CI**: stays network-free exactly as every prior phase — schema/guardrail-stub/session-
persistence tests run in CI; model-load, `FoundationModels`, and live-`claude` tests stay
`XCTSkip`'d there, matching the existing `--skip` list convention (Docs/12 M6).

---

## 9. Implementation order

- **M0 — Schema. [done]** `v4_phase5_schema` migration (`ask_sessions`, `ask_session_turns`),
  typed `AskSessionRecord`/`AskSessionTurnRecord`, `AskSessionScope` enum,
  `InvestigationOutcome.declined` case — no exhaustive `switch` over that enum exists anywhere in
  the codebase (checked directly), so no other call site needed updating, simpler than the
  plan's own "checklist" framing anticipated. Bare CRUD `Store` primitives included (matching the
  precedent Docs/12 M1 set for `routing_decisions`), session lifecycle logic deferred to M3 as
  planned. 11 new tests, full suite green (264 tests, 0 failures) under the exact CI invocation;
  `OrionApp.xcodeproj` still builds clean. No behavior change.
- **M1 — Guardrails. [done]** `DepthClassificationOutput` gains
  `isRepositoryRelated`/`offTopicRationale`; `DepthDecision.isInScope`; `DepthModel.classify`'s
  short-circuit; `AgentSession.declineOutOfScope`; a new injectable `depthFallback` parameter on
  `AgentSession.init` (a real seam gap found while writing this milestone's own tests, not
  anticipated by the plan — see the status banner above). Ships independently with zero session
  dependency, exactly as hoped. 14 new tests, full suite green (270 tests, 0 failures).
- **M2 — `ComponentDetailLoader` relocation. [done]** Landed in `OrionCodeIntel` (not
  `OrionAgent`) as `Query/ComponentDetailQuery.swift`, alongside `QueryEngine` — the cleaner
  direction once attempted, since it only ever needed `Store`, and putting it in `OrionCodeIntel`
  means `OrionAgent`'s `ContextBuilder` (M3) and any future `OrionCodeIntel`-only consumer can
  both reach it without an extra dependency hop. Not a verbatim move: it operates on `Store`
  directly (not the app's `CodebaseModelStore` passthrough) and drops the
  `ArchitectureNode`/`ArchitectureLayer` parameters entirely — both are app-target UI types this
  module can't depend on — returning `nil` instead of an `ArchitectureNode`-shaped empty
  placeholder, which only `OrionApp`'s own thin adapter still constructs. **One real coupling
  found and fixed**: the claim-confidence mapping depended on `ConfidenceBadge` (a SwiftUI
  `View`), which would have pulled a SwiftUI dependency into `OrionCodeIntel`; moved to
  `ConfidenceTier.label(forScore:)` instead, with `ConfidenceBadge.tierLabel(forScore:)` reduced
  to a thin, unchanged-signature forwarder so `AskRunner` needed no changes. `OrionApp`'s own
  `ComponentDetailView` needed zero changes. No new tests (a relocation, not new logic) — its
  correctness rests on the full pre-existing suite staying green (270 `OrionMacOs` tests, 116
  `OrionApp` tests, both 0 failures) plus real `xcodebuild build`/`test` passes, not just `swift
  build`.
- **M3 — Session persistence + context threading. [done]** `Store.createAskSession`/
  `recordSessionTurn`/`priorTurns`; `ContextBuilder`'s new `priorTurns`/`componentContext`
  parameters; `AgentSession.ask(_:sessionId:)`. **Real, unanticipated prerequisite found and
  fixed**: `investigations.answer_text` didn't exist — nothing persisted a turn's answer text
  anywhere, making prior-turn context impossible without it (full story in the status banner
  above). Depth-3 delegation is not yet context-aware within a session (that's `--resume`, M4) —
  a session's depth-3 turns still run fresh in M3, though the returned Claude session id is
  already captured into `ask_sessions.claude_session_id` ahead of M4 using it. 26 new tests (12
  `AskSessionStoreTests`, 6 `ContextBuilderTests`, 8 `AgentSessionTests`), full suite green (294
  tests, 0 failures).
- **M4 — Claude `--resume`. [done]** `ClaudeCodeInvestigator.ClaudeSessionContinuity`
  (`.none`/`.newSession`/`.resume(id)`) replaces the plan's originally-sketched bare
  `resumeSessionId: String?` — a single optional can't distinguish a session-less call from a
  session's first depth-3 turn, since both have no id yet but need different flags. `buildPrompt`
  also branches on it (a resumed turn skips the repository-orientation intro, a real cost/token
  saving, not just flag plumbing). `AgentSession.runDelegated` derives the right case from
  `session?.claudeSessionId`. 8 new tests, including one real, harmless flakiness caught and
  fixed (`AgentAnswerSchema.cliJSONSchema()`'s dictionary-to-JSON key order isn't stable across
  calls — a naive full-argument-array equality assertion flaked on that alone). Verified end to
  end through `AgentSession` with a real two-turn stand-in-`claude` session, not just at
  `ClaudeCodeInvestigator`'s own unit level. Full suite: 302 tests, 0 failures.
- **M5 — CLI. [done]** `orion-agent session create/list/show` (a new nested command group),
  `ask --session`. The "Ask about X twice" resume-vs-fresh-start decision (§5) is finalized here
  even though it has no CLI-level analog: resume the most recently active session for that
  component by default, always-available "+ New session" for the deliberate fresh-start case —
  actual implementation is M6's job. Verified live against a real analyzed fixture repo (no
  automated CLI-level tests, matching this codebase's own existing precedent of never
  unit-testing its `ArgumentParser` command structs directly). Full suite unchanged at 302 tests,
  0 failures (this milestone added no new library-level logic to test).
- **M6 — App UI. [done]** `AskHistory` rewritten into a real, DB-backed session model; Ask's list
  promoted to one row per session with a stacked, oldest-first turn history in the detail pane;
  "+" affordances (resume-by-default vs. always-create, two distinct paths); declined-turn
  treatment; `ComponentDetailView`'s "Ask about" hand-off implements the finalized
  resume-or-create decision for real. Past turns reconstruct from persisted data via a new
  `AskRunner.loadPersistedTurn`, with two small, explicitly documented fidelity gaps
  (`droppedClaimCount`/loop-level `partial` were never persisted). The plan's own "lightweight
  prompt" wording for submitting with nothing selected was implemented as resume-or-create
  instead — a recorded simplification, not a silent substitution. `AskHistoryTests` rewritten
  entirely against the new API (13 tests); one real fixture bug caught by the suite itself
  (a 15-char scripted answer under Docs/12 M5's own 20-char floor). `OrionApp` suite: 117 tests,
  0 failures.
- **M7 — Benchmark. [done]** `orion-agent bench` built and zero-cost-verified first, then run for
  real against all 55 questions with explicit user approval at each paid step ($1.01 total).
  Written up in `Agent Feasibility Study/PHASE5_ROUTING_BENCHMARK.md` (raw data in
  `results/phase5_routing_benchmark/`). Two real, load-bearing bugs found, not just routing
  noise: the guardrail false-declined two in-scope architecture questions (Docs/15 §12.1's own
  named risk, now measured); the one real depth-3 attempt hit the $1.00 budget ceiling, the same
  wall Docs/12 M5 hit at the previous $0.50 default. A 10-question correctness sample caught the
  same `ASGIRunner` confabulation recurring from a separate Docs/12 evaluation. Full reasoning in
  the results doc's own §5.
- **M8 — Hardening. [done]** Three real fixes, all traced directly to M7's own findings, not
  planned in advance (confirming the placeholder framing this entry originally had was correct):
  (1) the guardrail's root cause — zero repository grounding — fixed and live-verified for free
  against the exact two questions that failed; (2) the budget-exhausted failure message now names
  the real fix; (3) `--resume` verified live against a real `claude` CLI session ($1.00 real
  cost) via an unambiguous cross-turn checkpoint-recall test, closing the plan's single
  highest-named risk. 5 new tests (4 live, 1 in the regular CI suite); full suite at 303 tests,
  0 failures. This closes Phase 5's full implementation order.

---

## 10. Risks / open questions

1. **CONFIRMED, at M7 — the guardrail is a single guided-generation call's judgment, not a
   hardened classifier, and it does misclassify real, unambiguous in-scope questions.** Not just
   the borderline case this risk originally anticipated: the real 55-question run (§6,
   `PHASE5_ROUTING_BENCHMARK.md` §4.2) declined **AR-01** ("What are the major components of
   Starlette, and how are they layered...") and **AR-05** ("How does the WebSocket request path
   diverge from the HTTP path...") — both squarely about the analyzed repository, AR-01 nearly
   identical to a question Docs/12 M5 itself answered correctly at depth 3. The classifier's own
   rationale for both: "This looks like a general knowledge question, not one about the analyzed
   repository." A real, measured false-positive on exactly the class of question this feature
   exists to route to Claude — not a hypothetical any more. **Not yet fixed**: the prompt-wording
   revision this risk originally called for is real follow-up work, out of this milestone's own
   scope (M7 measures, M-next fixes) — tracked here so it isn't lost between the two.
2. **A component-scoped session can outlive the component it points to.** `components` rows are
   scoped to one investigation (Docs/11); if a developer re-runs "Build Architecture Model" after
   opening a session against an older investigation's component, that session keeps working (the
   FK is never invalidated) but no longer reflects the *current* architecture. Worth a visible
   "this session references an earlier investigation" note in the UI if this proves confusing in
   practice — not built preemptively here, since it's unclear how often re-investigation actually
   happens against the same repository in real use.
3. **RESOLVED, at M8 — `--resume` verified live against a real, paid `claude` CLI session, not a
   stand-in script.** A real Orion session against vendored Starlette: turn 1 (depth 3, real
   Claude call, $0.61) asked Claude to embed a specific, made-up marker
   (`CHECKPOINT-ORION-91`) at the end of its answer; turn 2 (same session, $0.39) asked, with
   *zero* restated context, "What checkpoint string did you include in your previous answer?" —
   Claude answered correctly (`CHECKPOINT-ORION-91`) using only its own real, server-side
   `--resume`d conversation memory. Confirmed in the database too: both investigations recorded
   the identical `claude_session_id` (`8b3e...`), and `ask_sessions.claude_session_id` never
   changed between turns. This is the concrete, unambiguous evidence this risk called for —
   `--resume` genuinely carries context forward on the real binary, not just on stand-in scripts.
   Total real cost of the verification: $1.00.
4. **Guardrails are a UX control, not a security boundary** — see §3.4. Do not present this
   feature, internally or to a user, as having closed off prompt-injection or scope-escape risk
   entirely; it reduces the odds of an accidental off-topic call succeeding, it does not audit
   Claude's own read-only tool sandboxing (which is what actually bounds the worst case).
5. **No automated correctness grading.** §6.2's "hand-checked against `expected_answer`" is the
   same manual posture Docs/12 M5 used at n=13; at n=55 this is a materially larger manual grading
   task. An LLM-judge axis (Phase 2's own explicitly-deferred stretch goal) would reduce that
   burden but introduces its own reliability question this plan does not attempt to resolve —
   flagged as a real limitation of the benchmark's own conclusions, not silently assumed away.
6. **Session continuity for depth 1/2 grows the primed context linearly with session length,
   bounded only by the fixed 5-turn window (§4.3).** A long-running session against a large
   component's `componentContext` plus 5 truncated prior turns plus the whole-repo
   `code_graph.json`/`semantic_model.json` slices could approach context-length limits Qwen3-8B
   handles poorly (Docs/12 never stress-tested a context this large). Watch real token counts once
   M3 ships; reducing the turn window or per-turn truncation further is a cheap fix if this proves
   to be a real problem, not a redesign.
7. **CONFIRMED, at M7 — the $1.00 default depth-3 budget ceiling is still sometimes too tight,
   for the second time.** Docs/12 M5 hit this exact wall at the *original* $0.50 default (`CU-07`)
   and raised it to $1.00; the real 55-question run hit it again at $1.00 itself (`XF-01`, a
   genuine multi-file trace question, 24 turns/$1.01 before being cut off) —
   `PHASE5_ROUTING_BENCHMARK.md` §4.2 finding 2. Raising the number a second time by feel would
   likely only defer the same finding a third time; worth considering a question-complexity-aware
   ceiling (or at minimum a documented "some questions genuinely need more than $1" acceptance)
   rather than another flat bump, before the next real run.
8. **CONFIRMED, at M7 — a specific hallucination reproduces across independent evaluation runs.**
   `PHASE5_ROUTING_BENCHMARK.md` §4.3's `DC-01` fabricated a connection to
   `benchmarks/routing_benchmark.py::ASGIRunner`, the exact same real-but-unrelated symbol Docs/12
   Risk #7's own six-stage table recorded `XF-07` inventing in a *separate* evaluation session.
   Two independent occurrences is no longer plausibly one-off model noise — worth a targeted look
   at why this specific symbol keeps surfacing (a retrieval-relevance artifact, most likely) before
   the next benchmark run, rather than filing it as generic hallucination risk.
