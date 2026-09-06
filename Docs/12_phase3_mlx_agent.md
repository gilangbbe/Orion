# 12 — Phase 3: MLX Agent (Development Plan)

> Status: **M0 done** (skeleton builds, `swift test` green — 158 tests). **M1 done, including a
> resolved architecture pivot** — heuristics + persistence work and are fully unit-tested; the
> model-backed fallback classifier was originally Qwen3 tool-calling, which hung 10+ minutes and
> then crashed the process on real `Qwen3-8B-4bit` (kept in the codebase, documented, no longer
> the default); replaced with Apple's on-device `FoundationModels` framework
> (`@Generable`/`@Guide`) for classification **only** — it never investigates or answers —
> verified live at ~2-8s per classification with no hangs or crashes.
> **Risk #3 fully resolved, and M2 done.** Rather than pick a tool-calling mechanism for L2's
> *answering* model, the real fix separates reasoning from tool execution — plain-chat
> generation on `Qwen3-8B` (no native tool-calling at all), prompted for a small JSON action
> decision each turn, executed by Swift code (`ActionLoop`). Keeps Qwen3-8B (the Task-3
> benchmark winner) as one model for both L1 and L2. M2 built this for real: `AgentTool`s over
> `QueryEngine`, `ActionLoop`'s state machine (with a real off-by-one bug caught by its own unit
> tests before shipping), `agent_tool_calls` persistence, 21 new tests. **Verified live,
> end-to-end**: real `Qwen3-8B-4bit` + real tools + a real analyzed repo, 11.8s, no hang, no
> crash — via a testing-infrastructure fix also found in M2 (`xcrun xctest` after
> `build-for-testing` inherits the shell's env vars; `xcodebuild test` doesn't). See M1's and
> M2's entries and Risk #3 for the full story, including two other mechanisms (FoundationModels'
> own `Tool` protocol; a non-thinking Qwen checkpoint via native tool-calling) verified working
> and kept as documented fallbacks. Package platform floor bumped to macOS 26. **M3 done**:
> `ClaudeCodeInvestigator` (L3 delegation, ported from Phase 2's `investigate.py`),
> `ProcessRunner` (a hand-built wall-clock timeout — Swift's `Process` has none — verified live
> against real `/bin/sleep`), `AgentAnswerSchema`/`ingestAnswer` (Phase 2's validation pipeline
> reused via three extracted shared helpers, not rebuilt). 234 tests total. **Real live `claude`
> CLI run confirmed**: a genuine end-to-end investigation against vendored Starlette (real
> question, real repo, real API call) — 93.6s, `claude-sonnet-5`, 23 turns, $0.77, ingested as
> `partially_verified` with 13 surviving claims, 0 dropped. Also found in the process: plain
> `swift test` (not just `xcodebuild build-for-testing` + `xcrun xctest`) honours
> `ORION_AGENT_LIVE_*` env vars fine — the earlier env-var gap was specific to `xcodebuild test`.
> **M4 done**: `AgentSession` orchestrator (`DepthModel` -> local `ActionLoop` (depth 1/2) or
> `ClaudeCodeInvestigator` (depth 3) -> `SemanticImporter.ingestAnswer` ->
> `routing_decisions`/`agent_tool_calls` persistence), `ContextBuilder` (primes local sessions
> from `code_graph.json`/`semantic_model.json`), `EvidenceAnchors` (extracts anchor-shaped
> evidence from a local tool-call trace so depth-2 answers can be validated the same way a
> Claude-delegated one is, without asking Qwen3-8B itself to emit structured `claims` JSON —
> Risk #3 already showed that's unreliable), `orion-agent ask` wired fully end to end
> (`--force-depth`, `--max-budget-usd`, `--timeout`, `--explain`, `--json`). 15 new tests, 250
> total. **Verified live against real vendored Starlette, all three depths**: depth 1 (plain
> chat, no tools, correctly `.verified` with 0 claims — nothing was asserted), depth 2 (real
> tool call to `lookup_symbol`, real anchor `starlette/routing.py::Router` extracted and
> resolved, 1 claim, `.verified`, and factually correct — "defined in starlette/routing.py,
> line 573"), depth 3 (already covered by M3's live `claude` run, now reachable through the same
> `ask` command). Two real bugs found only by running the actual CLI, not just unit tests: (1)
> `swift run`/`swift build` never compiles `mlx-swift`'s Metal shaders at all (`CudaBuild` is
> genuinely CUDA-only and a no-op on macOS) — only `xcodebuild` produces
> `mlx-swift_Cmlx.bundle/.../default.metallib`, so any MLX-touching *executable* (not just
> xctest bundles, which is where this was previously discovered) needs
> `xcodebuild -scheme orion-agent -destination 'platform=macOS' -derivedDataPath .build/xcodebuild
> -skipPackagePluginValidation -skipMacroValidation build`, then run the binary straight out of
> `.build/xcodebuild/Build/Products/Debug/`; (2) a depth-1 (budget-0) answer returned Qwen3-8B's
> raw `<think>...</think>` reasoning trace as the user-visible answer — unlike budget>0 paths,
> which extract just the `{...}` JSON action and incidentally skip over it, budget-0 returns the
> model's raw text with no extraction step at all. Fixed in `ActionLoop` (strips everything up
> to the last `</think>` at every point it returns model-authored text); regression test added.
> **M5 done**: 13 real benchmark questions run through the real `ask` binary (no `--force-depth`)
> against real vendored Starlette — $6.08/235 turns across 18 investigations including retries.
> **Headline finding: depth 1 was factually wrong 4 times out of 4** it was chosen, yet still
> labeled `verified` (nothing was asserted, so nothing failed to substantiate — a real, flagged
> UX gap for Phase 4, not a bug in the label's logic); **depth 2 was never reached naturally**
> (every non-trivial question escalated straight to depth 3, confirming M1's
> medium-confidence-skips-to-3 design has that side effect); **depth 3, when it didn't fail on
> CLI reliability grounds, was correct 7 times out of 7**. Two real bugs found and fixed: the
> CLI's own failure reason (`errors`/`subtype`) was parsed and then silently discarded instead of
> shown; a schema-conformant-but-degenerate placeholder answer (`"test"`) could previously be
> ingested as `verified` — both fixed with a regression test each. Full table in "Testing &
> verification". **Risk #7 settled, after several rounds of live-verified experiments (full
> history in Risk #7 below).** Final, stable state: `DepthModel` routes `"medium"` confidence to
> depth 2 instead of depth 3 (`"low"` still escalates fully — real, measured win, kept); `
> ActionLoop` enforces an attempted tool call at depth 2 (one corrective nudge, then accepts as
> `partial` if still refused; waived when no tools exist — cost-free, bounded, kept). A further
> round of fixes (②-⑤: tolerant action parsing, a `symbol_detail` tool exposing
> `signature`/`docstring`, missing-information tracking, a claim-vs-evidence lexical check) was
> implemented, tested, and verified live, then **deliberately reverted** — each worked exactly as
> designed, but the resulting six-stage failure analysis showed the next bottleneck (retrieval
> *selection* — asking tools for the right thing) sitting past what more scaffolding can reliably
> fix on an 8B model, so the decision was to stop adding mechanism and settle on the simpler,
> already-verified state instead of chasing diminishing returns. Two things remain honestly
> unresolved by design, not oversight: Risk #5 (depth-1 answers are unreliable and still labeled
> `verified`) and imperfect tool-retrieval selection at depth 2 — both real, both left for Phase 4
> (UX presentation) or a future phase to address differently rather than more Phase 3 mechanism.
> 254 tests, 0 failures, at this settled state. **M6 done** (hardening, all four items): first-run
> model-download progress reporting (confirmed live, including on a cached load); L3's
> `--max-budget-usd`/`--timeout` enforcement verified end to end through `AgentSession` itself
> (a real subprocess's argv, a real killed-on-timeout process); CI's `swift test` invocation now
> explicitly `--skip`s all six live test classes as defense in depth (GitHub-side behavior against
> this package's `.macOS(.v26)` floor is otherwise unverified — nothing from Phase 3 has been
> pushed this session); README gained a real, verified cache-location + `xcodebuild`-requirement
> section. 261 tests, 0 failures. **Phase 3 (M0-M6) is now feature-complete** per this plan;
> M5's hand-picked validation and Risk #7's live experiments are the evidence base Phase 5 should
> build its real benchmark from, not a substitute for one. Depends on Phase 1
> (`orion-index analyze`/`export`/`query`, complete —
> [10_phase1_deterministic_code_intelligence.md](10_phase1_deterministic_code_intelligence.md))
> and Phase 2 (`orion-index ingest-semantic`, Claude Code CLI investigation contract, complete —
> [11_phase2_semantic_analysis.md](11_phase2_semantic_analysis.md)).

## Context

Phase 1 produced a deterministic Code Graph. Phase 2 proved that whole-repo semantic structure
can be reconstructed via a delegated Claude Code CLI investigation and verified against that
graph. Neither phase has an agent — Phase 2's Python `ClaudeInvestigator` stood in by hand for
a step [06_claude_code_integration.md](06_claude_code_integration.md) explicitly assigns to
the MLX agent ("the agent doesn't exist yet, so Phase 2's Python script performs that step by
hand"). Phase 3 builds that agent for real, per
[08_development_phases.md](08_development_phases.md):

```
intent classification -> depth routing -> local model execution
                       -> deterministic tool use -> Claude delegation -> state management
```

Goal: **answer an arbitrary developer question about the repository**, routing it through the
minimum computation that reliably answers it — first evidence for **H3** (local sufficiency),
**H4/H5** (selective escalation and whether the router can recognize it), building directly on
**H2/H6** (Phase 2 already showed a persistent model can be built and Claude findings verified
without making Claude the orchestrator).

### What Phase 3 is not

- Not a full routing-quality benchmark. [08_development_phases.md](08_development_phases.md)
  assigns "benchmark routing quality and latency" to **Phase 5**. Phase 3 validates that the
  mechanism works end to end on a small hand-picked question set (M5); a systematic benchmark
  against the full 55-question set is Phase 5's job, run against whatever this phase ships.
- Not the continuous-model-update UX ("Understanding updated / Previously / Now / Reason",
  [05_user_flow_and_ux.md](05_user_flow_and_ux.md) Stage 6, contradiction/diff handling) — that's
  **Phase 6**. Phase 3 writes one `model_revisions` row per successful delegated ingestion, the
  same coarse-log approach Phase 2 already used, and stops there.
- Not a UI. Phase 4. Phase 3 is a CLI, like `orion-index`.
- Not multi-turn conversational memory. Each `orion-agent ask` invocation is a single
  question against the persisted Codebase Model; conversation-level state is a product-UI
  concern for Phase 4+.

### Decisions (made with the user)

1. **Runtime: Swift, native MLX Swift bindings** (`mlx-swift-lm`), not a Python/mlx-lm agent
   shelling into the Swift CLI. The agent links `OrionCodeIntel` in-process — no subprocess for
   deterministic tool calls — and becomes part of the same binary family (`OrionCodeIntel` +
   `OrionAgent` libraries, `orion-index` + `orion-agent` CLIs) that Phase 4's Xcode app target
   will eventually depend on, the same way Phase 1's library was built with that dependency in
   mind. This retires Python's role as a stand-in for the agent; Phase 2's Python harness
   (`ClaudeInvestigator`, `schema.py`, `score.py`) stays as-is for Phase 2's own reproducibility
   and is not extended further.
2. **Local model: `Qwen3-8B-4bit`** (`mlx-community/Qwen3-8B-4bit`, `LLMRegistry.qwen3_8b_4bit`
   in `mlx-swift-lm`) **for L1/L2 answering**. Task 3's real benchmark
   (`Agent Feasibility Study/results/LEADERBOARD.md`) scored it the composite winner (0.848 vs.
   0.832 for `qwen2.5-coder-14b-4bit`), with the best cross-file reasoning (0.99) and evidence
   accuracy (1.89/2) of the three models benchmarked, at roughly two-thirds the peak memory
   (8.03 GB vs. 12.82 GB) and faster time-to-first-token (10.58s vs 14.78s). Native Qwen
   tool-calling format needs no special `toolCallFormat` configuration in `mlx-swift-lm`
   (unlike GLM4/LFM2, which do). Single-model commitment for now; nothing here blocks adding a
   second model later if Phase 5's benchmark finds a real gap.
2a. **Depth Model classification: Apple's on-device `FoundationModels` framework
   (`SystemLanguageModel.default` + `@Generable`/`@Guide`), not Qwen3.** Added mid-M1, after
   live testing found Qwen3's tool-calling path unusable for this (Risk #3 / M1's entry below).
   `MODEL_CANDIDATES.md` §7 had already anticipated this exact split: "the eventual shipping app
   on Apple Foundation Models would use `@Generable` guided generation." Real, working
   constrained generation (verified against the actual `FoundationModels.swiftinterface` in the
   Xcode 26.5 SDK, not vendor docs) from a small on-device model purpose-built for fast
   structured classification — the opposite profile from Qwen3-8B's "hybrid thinking," and
   exactly the profile the Depth Model needs. Verified live: 1.4-8.2s per classification call,
   no hangs, no crashes, builds/runs under plain `swift build`/`swift test`/`swift run` (no
   Xcode-only Metal-shader workaround, unlike anything touching `mlx-swift-lm`). Requires
   macOS 26+ and an Apple-Intelligence-enabled device; when unavailable
   (`SystemLanguageModel.default.availability != .available`), `AppleFoundationDepthClassifier`
   returns a low-confidence result that `DepthModel` escalates straight to depth 3, per the same
   policy as any other low-confidence classification — no second local model as a
   fallback-of-fallback.
3. **Claude delegation ported to native Swift `Process` invocation**, not a call back into the
   Python harness. `ClaudeCodeInvestigator` (Swift) reuses the exact CLI contract Phase 2's
   `investigate.py` already validated live against real `claude` 2.1.260 output (`-p
   --output-format json`, `--tools Read,Grep,Glob`, `--add-dir <export_dir>`,
   `--permission-mode bypassPermissions`, `--max-budget-usd`, `--json-schema` without the
   `$schema` key) — same flags, same reasoning, ported rather than re-derived.
4. **One execution path for L1 and L2, differentiated by tool-call budget, not by code
   branch, and one model — `Qwen3-8B-4bit` — for both.** Rather than hand-writing two separate
   answer strategies or loading a second, smaller model for L2, the agent always runs one
   bounded loop on the same Qwen3-8B session; the Depth Model sets how many live tool calls that
   loop is allowed before it must answer from what it already has. L1 gets a budget of **0**
   (must answer from the primed Codebase Model context alone — this is what actually enforces
   [03_agent_and_model_routing.md](03_agent_and_model_routing.md)'s "L1: MLX + Codebase Model,"
   not merely a label); L2 gets a small positive budget (default **6**) to call deterministic
   tools; L3 skips the local loop entirely and delegates to Claude Code. This keeps the depth
   decision consequential (it changes what the model is *allowed* to do) rather than advisory.
   **The loop itself never uses `mlx-swift-lm`'s native `tools`/`toolDispatch` mechanism** — see
   Risk #3's resolution and "Local execution & tool loop" below for why and what replaces it.

---

## Project layout (additions to `OrionMacOs/`)

| Target | Type | Purpose |
|---|---|---|
| `OrionAgent` | library | Depth Model, tool dispatch, local model wrapper, Claude Code delegation, state persistence. Depends on `OrionCodeIntel` + `mlx-swift-lm`'s `MLXLLM`/`MLXLMCommon`/`MLXHuggingFace` + `swift-huggingface`/`swift-transformers`. No AppKit/SwiftUI — same discipline as `OrionCodeIntel`. |
| `orion-agent` | executable | Thin CLI over `OrionAgent` (swift-argument-parser), mirrors `orion-index`'s pattern. |
| `OrionAgentTests` | test | Unit + fixture-driven; model-loading/Claude-CLI tests `XCTSkip` under the same conditions Phase 1/2 already established (no network, no `claude` binary, no cached model weights). |

```
Sources/OrionAgent/
  Model/        AgentModel protocol, Qwen3Agent (ModelContainer + ChatSession wrapper)
  Depth/        DepthModel, DepthHeuristics (rule table), DepthFallbackClassifying,
                AppleFoundationDepthClassifier (default fallback, FoundationModels-backed),
                ModelBackedDepthClassifier (superseded Qwen3 tool-calling design, kept/tested)
  Context/      ContextBuilder (primes L1/L2 prompts from semantic_model.json + code_graph.json
                slices) -- deferred to M4, needs a real AgentSession to wire it into
  Tooling/      [M2, done] AgentTool protocol + QueryEngineTools (LookupSymbolTool,
                ModuleSymbolsTool, CallersTool, CalleesTool -- plain functions, not
                MLXLMCommon.Tool<Input,Output>, per Risk #3), TurnGenerating (ChatSession
                conformance, for testability), ActionLoop (the manual JSON-action state
                machine), AgentAnswer/ExecutedToolCall
  Delegation/   [M3, done] ProcessRunner (standalone watchdog-timeout subprocess runner),
                ClaudeCodeInvestigator (Process-based, ported from investigate.py) --
                AgentAnswerSchema/AgentAnswerFindings and the SemanticImporter.ingestAnswer
                extension live in OrionCodeIntel/Semantic/ instead (next to SemanticFindings/
                SemanticImporter, which they extend directly and need private access to)
  Persistence/  v3_phase3_schema migration, AgentRecords (RoutingDecision, AgentToolCall),
                Store extensions
  Agent.swift   AgentSession: ties Depth -> Context/Tooling (via ChatSession) or Delegation ->
                Persistence -> AgentAnswer
Sources/orion-agent/  OrionAgentCLI.swift + Commands/AskCommand.swift
Tests/OrionAgentTests/  Unit/  Fixtures/  ValidationSet/ (the M5 hand-picked questions)
```

---

## Dependency (SwiftPM addition)

> **M0 update, verified against the real tagged source** (not vendor docs or AI-summarized
> web search, which is what the rest of this section originally relied on and got wrong in
> three ways: there is no `MLXGuidedGeneration` product in `mlx-swift-lm` at all; its manifest
> declares swift-tools-version **6.1**, not 6.2; and it needs two additional dependencies for
> model downloading. Corrected below — this is exactly the kind of drift M0 exists to catch).

| Package | URL | Pin | Why |
|---|---|---|---|
| mlx-swift-lm | `github.com/ml-explore/mlx-swift-lm` | `from: "3.31.4"` (latest tag as of M0; resolves cleanly against our 5.10 root manifest despite its own 6.1 tools-version) | Native MLX Swift LLM runtime, used for `Qwen3Agent` (L1/L2 answering) only as of M1. Products used: `MLXLLM` (model registry incl. `LLMRegistry.qwen3_8b_4bit`), `MLXLMCommon` (`ModelContainer`, `ChatSession`, the `Tool`/`ToolCall` tool-calling types), `MLXHuggingFace` (macro-based Hub integration, below). **There is no constrained/guided-generation product** — its tool-calling path was tried for structured output and abandoned for the Depth Model (see Risk #3); still used for L1/L2's own tool loop pending M2's re-evaluation. |
| swift-huggingface | `github.com/huggingface/swift-huggingface` | `from: "0.10.0"` | `HubClient`, wrapped by `mlx-swift-lm`'s `#hubDownloader()` macro into the `Downloader` protocol it needs to fetch model weights. |
| swift-transformers | `github.com/huggingface/swift-transformers` | `from: "1.3.4"` | `Tokenizers.AutoTokenizer`, wrapped by `#huggingFaceTokenizerLoader()` into the `TokenizerLoader` protocol. |
| FoundationModels | *(system framework, no SwiftPM package)* | SDK-provided; `@available(macOS 26.0, *)` confirmed directly against `FoundationModels.swiftinterface` in the installed Xcode 26.5 SDK, not vendor docs | Apple's on-device LLM + real guided generation (`SystemLanguageModel`, `LanguageModelSession`, `@Generable`/`@Guide`). Backs `AppleFoundationDepthClassifier`, the Depth Model's fallback classifier as of M1. `import FoundationModels` links automatically under plain SwiftPM — no `linkerSettings`, no Xcode-only build step, unlike anything touching `mlx-swift-lm`'s Metal shaders. |

Concretely: `Qwen3Agent.load()` calls `LLMModelFactory.shared.loadContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: LLMRegistry.qwen3_8b_4bit)` — the package's own documented "MLXHuggingFace macros" integration path, chosen over hand-implementing the `Downloader`/`TokenizerLoader` protocols directly. Verified building end to end at M0 (`swift build`/`swift test` both green, 158 tests, 0 failures — see M0's entry below).

**Platform floor: `.macOS(.v26)`, bumped from `.v14` for the whole package** (M1 decision — a
single declaration was chosen over scoping the floor to just `OrionAgent`, even though
`OrionCodeIntel`/`orion-index` don't need it). `.v26` requires `swift-tools-version: 6.2`
(bumped from 5.10); every target is pinned back to Swift 5 language mode via
`swiftLanguageModes: [.v5]` in `Package.swift` so the tools-version bump doesn't also silently
switch the whole codebase to Swift 6's strict concurrency checking — Phase 1 deliberately
avoided that churn on the shared pipeline context, and this preserves it.

No new Python dependency. `Agent Feasibility Study/harness/` is untouched by this phase.

---

## Depth Model

Implements [03_agent_and_model_routing.md](03_agent_and_model_routing.md) §2-3 directly:
**explicit rules first**, a model-backed fallback only when the rules don't confidently match —
not a fully autonomous router from day one.

1. **`DepthHeuristics`** — regex/keyword matchers over the exact example shapes
   [03_agent_and_model_routing.md](03_agent_and_model_routing.md) §2 gives per level:
   - L1 patterns: "what does `X` do", "what is the responsibility of", "which files belong to".
   - L2 patterns: "which components depend on", "where is ... persisted", "what tests cover",
     "who calls `X`".
   - Anything not confidently matched falls through to the model-backed classifier.
2. **`DepthClassification`** (fallback) — `AppleFoundationDepthClassifier`
   (`Depth/AppleFoundationDepthClassifier.swift`), backed by Apple's on-device
   `SystemLanguageModel` via `LanguageModelSession.respond(to:generating:)` with a
   `@Generable struct DepthClassificationOutput { depth: Int; intent: String; @Guide(.anyOf(...))
   confidence: String; rationale: String }`. **Superseded design, kept for the record**: the
   original plan used `mlx-swift-lm`'s tool-calling path (`ChatSession` + a `classify_depth`
   `Tool<Input,Output>`) as a structured-output workaround, since `mlx-swift-lm` has no real
   constrained-generation facility. That path is `ModelBackedDepthClassifier`
   (`Depth/ModelBackedDepthClassifier.swift`) — kept in the codebase and still tested, because
   it hung 10+ minutes and then crashed the process against real `Qwen3-8B-4bit` (Risk #3), not
   because the idea itself was reasonable to keep pursuing. `AppleFoundationDepthClassifier`
   uses real `@Generable`/`@Guide` guided generation instead — verified live at 1.4-8.2s per
   call, no hangs. When `SystemLanguageModel.default.availability != .available` (no Apple
   Intelligence on this device/region), it returns a low-confidence result rather than throwing.
   **Revised after M5** (Docs/12 Risk #7): a `"low"` confidence result still escalates straight
   to depth 3, directly implementing [03_agent_and_model_routing.md](03_agent_and_model_routing.md)
   §3's "if local model confidence is low: escalate to Claude Code" — but `"medium"` now routes
   to depth 2, not depth 3. **Observed live**: the model rarely if ever reports `"high"`
   confidence even on genuinely simple questions outside `DepthHeuristics`' coverage — every
   non-heuristic question tested at M1, and every one of M5's 9 non-trivial real benchmark
   questions, came back `"medium"` and (under the original all-non-high-escalates-to-3 policy)
   jumped straight past depth 2 every single time. `DepthHeuristics`' fixed patterns can't cover
   the open-ended space of real questions, so treating `"medium"` the same as `"low"` made
   depth 2 unreachable except by explicit heuristic match or `--force-depth 2` — decided,
   directly in Risk #7, to bias `"medium"` toward depth 2 instead: it's free, fast, and grounds
   an uncertain classification in real tool evidence before ever paying for delegation.
3. Every classification (heuristic or model-backed) is persisted as a `routing_decisions` row
   (see schema below) — Phase 5's later benchmark reads this table directly rather than
   re-deriving routing decisions from logs.

**Test set**: the depth/intent examples are lifted verbatim from
[03_agent_and_model_routing.md](03_agent_and_model_routing.md) itself (six sentences, two per
level) — a small, high-signal, zero-cost unit test that the classifier agrees with the doc that
defines it.

---

## Local execution & tool loop (L1/L2)

> **Built in M2 — the mechanism changed from what was originally planned here, on purpose.**
> The original design ran the whole loop through `ChatSession` +
> `tools`/`toolDispatch` — `mlx-swift-lm`'s native tool-calling — which M1 found hangs 10+
> minutes and crashes the process on `Qwen3-8B`. Rather than switch the *answering* model to
> work around a broken mechanism (FoundationModels' small on-device model is real-world weak at
> source-code investigation; a non-thinking Qwen variant would mean giving up Qwen3-8B's
> Task-3-benchmark-winning capability for L2), the fix separates **reasoning from tool
> execution**: the model never sees a `tools` parameter or native tool-calling format at all —
> it just does plain-chat generation, prompted to emit a small structured JSON action decision
> each turn, which *Swift code*, not the model's own tool-calling loop, parses and executes.
> Verified live, twice: a full multi-turn investigation (call a tool, receive its result,
> produce a grounded final answer) on real `Qwen3-8B-4bit`, **~3.0-3.1s total**, no hangs, no
> native tool-calling path touched at all. This keeps Qwen3-8B as the one model for both L1 and
> L2, per the user's own real-world experience that a small on-device classifier model is the
> wrong tool for actual code investigation — exactly what led to trying this in the first place.

`AgentSession.answer(question:)`:

```
question
  -> DepthModel.classify(question)      -- routing_decisions row written (FoundationModels;
                                            classification only, never sees tool results,
                                            never answers the user -- see Decision #2a)
  -> ContextBuilder.prime(question, depth)
       L1/L2: semantic_model.json + relevant code_graph.json module/class slice
              (same structure-first slicing EXPORT.md already describes for Phase 2's
              build_structured_context — reused, not re-invented)
  -> ActionLoop.run(qwen3Session, budget: depth==1 ? 0 : 6)
       -- Manually driven, NOT ChatSession's tools/toolDispatch (Risk #3: that mechanism is
       -- confirmed broken on Qwen3-8B). One ChatSession per investigation, instructions
       -- describe the available tools and require ONE JSON object per turn, nothing else:
       --   {"action": "call_tool", "tool": "<name>", "arguments": {...}}
       --   {"action": "answer", "text": "..."}
       -- Loop, budget times at most:
       --   1. session.respond(to: turnPrompt)  -- plain generation, no tools param
       --   2. tolerantly extract the JSON object from the raw text (first "{" to last "}" --
       --      verified live to survive stray/malformed <think> wrapper text around it, the
       --      same "don't trust the model to format perfectly" posture as Phase 2's
       --      extract_json for Claude's output)
       --   3. "call_tool" -> look up the named AgentTool, execute it in-process against
       --      OrionCodeIntel's Store/QueryEngine (deterministic, no model involved), feed the
       --      result back as the next turn's prompt ("Tool result: ..."), loop
       --   4. "answer" -> done; unparseable JSON or an unknown tool name also ends the loop
       --      (treated as a malformed-final-answer case, not silently retried forever)
       --   5. budget exhausted without "answer" -> forced final turn asking directly for
       --      {"action": "answer"} with whatever's been gathered so far, tagged partial
  -> AgentAnswer { text, evidence_anchors[], epistemic_tags } parsed from the final "answer" turn
  -> Persistence: investigations row (question, complexity=L1|L2, model_used, tools_used,
     outcome), agent_tool_calls rows (one per executed tool call, from the loop's own log),
     claims/evidence rows for any assertion in the answer that isn't a verbatim tool-result quote
  -> AgentAnswer returned to the CLI
```

**Tools** (`Tooling/`, all read-only, all in-process — no subprocess, no `Bash`-equivalent):
plain Swift functions (no `MLXLMCommon.Tool<Input,Output>` wrapper needed — the model never
calls them directly, `ActionLoop` does, after parsing the model's JSON) wrapping Phase 1's
`QueryEngine` (`--symbol`, `--callers`, `--callees`, `--module`) and Phase 2's `Store`
component/claim read methods. No new deterministic capability is built here — Phase 3 only
exposes what Phase 1/2 already computed as agent-callable functions. Each tool's name/argument
shape/description is still declared once (for the instructions prompt describing available
tools to the model), just not through `mlx-swift-lm`'s `Tool` schema type.

**Epistemic tagging carries forward from Phase 1/2's vocabulary**
([04_codebase_mental_model.md](04_codebase_mental_model.md)): a sentence in the final answer
that quotes a tool result directly is `FACT`; anything the model synthesizes across multiple
facts is tagged `INTERPRETATION`/`INFERENCE` in the persisted claim, matching Docs/04's rule
that the UI (eventually) must not present inference as fact. The CLI prints these tags inline
even without a UI, so the distinction is visible from the first working version.

---

## Claude delegation (L3)

> **Built in M3.** `ClaudeCodeInvestigator` (Swift, `Delegation/`) — the same contract Phase 2
> already validated live, ported instead of re-derived. In-memory end to end: unlike Phase 2
> (Python CLI bridge → file → separate Swift `ingest-semantic` process), `investigate(question:)`
> hands its candidate JSON directly to `SemanticImporter.ingestAnswer` as `Data` — no temp file,
> since both halves now run in the same Swift process. 32 new tests (`ProcessRunnerTests`,
> `ClaudeCodeInvestigatorTests`, `AgentAnswerImporterTests`), 233 total.

`ClaudeCodeInvestigator` (Swift, `Delegation/`) — the same contract Phase 2 already validated
live, ported instead of re-derived:

- Working directory: the analyzed repo checkout. Tool access: `Read`/`Grep`/`Glob` only.
  `--add-dir <export_dir>` for the Code Graph + semantic export. `--permission-mode
  bypassPermissions` (safe specifically because `--tools` already forbids mutation, same
  justification Phase 2 recorded). `--max-budget-usd` as the hard cost ceiling.
- **New structured contract, `AGENT_ANSWER_SCHEMA` (`phase3.v1`)** — narrower than Phase 2's
  whole-repo `SEMANTIC_SCHEMA` because an L3 investigation answers **one question**, not a full
  component decomposition:

  ```json
  {
    "schema_version": "phase3.v1",
    "answer": "Prose answer to the user's question.",
    "claims": [
      {
        "claim_type": "INTERPRETATION",
        "statement": "...",
        "evidence": ["starlette/routing.py::Router.app"],
        "confidence": "high"
      }
    ],
    "uncertainties": ["..."]
  }
  ```

  Same evidence-anchor discipline as Phase 2 (`<path>::<Dotted.Name>`, verbatim against
  `symbols.jsonl`), same `claim_type` restriction (`INTERPRETATION`|`INFERENCE`|`UNKNOWN` —
  never `FACT`, never Claude's own `CONTRADICTED`).
- **Ingestion reuses Phase 2's validation pipeline**, not a rebuilt one: schema validation →
  evidence-anchor resolution → the same structural consistency check
  (`Store.relationshipExists`/`relationshipExistsAmongAnyPair`, parent-symbol-aware per Phase
  2's M2 fix) → persistence as `claims`/`evidence` rows against this question's `investigation_id`
  → one `model_revisions` row. Concretely: `SemanticImporter.ingestAnswer(candidateData:meta:
  question:run:now:)` — `candidateData: Data` in-memory rather than `ingest()`'s `candidateURL:
  URL` (see the callout above for why), and it creates its own `investigations` row internally
  with the real free-form `question` text (like `ingest()` does for its own fixed
  `"phase2_semantic_grouping"` question), rather than accepting a pre-existing
  `investigationId` as this doc originally sketched — there is no `AgentSession` yet to have
  created one first (that orchestration is M4's job). Implemented by extracting three shared
  private helpers off `SemanticImporter` (`resolveClaimEvidence`/`checkClaimConsistency`/
  `buildClaimRecords`) that both `ingest()` and `ingestAnswer()` now call — a refactor, not a
  rewrite, confirmed behavior-preserving by all 19 pre-existing `SemanticImporterTests` staying
  green throughout.
- **Timeout**: unlike Python's `subprocess.run(timeout=...)`, Swift's `Process` has no built-in
  wall-clock timeout. Built as a standalone, executable-agnostic `ProcessRunner` (drains both
  pipes via `readabilityHandler` as data arrives, not after exit — the classic pipe-buffer
  deadlock this would otherwise risk; races `Process.terminationHandler` against a
  `DispatchQueue.asyncAfter` deadline, `terminate()`-ing on expiry). **Verified live, not just
  read as correct**: `ProcessRunnerTests.testTimeoutTerminatesLongRunningProcessAndReportsTimedOut`
  runs a real `/bin/sleep 30` against a 1s timeout and confirms it returns in ~1s, not 30 —
  reproduced again end-to-end through `ClaudeCodeInvestigator.investigate` itself against a
  slow stand-in `claude` script.
- `investigations.outcome` computed the same way Phase 2 computes it: Swift's own verdict from
  what survived validation, never copied from Claude's self-report. Component-free version:
  `classifyAnswerOutcome` treats a pure-prose answer with zero `claims`/`uncertainties` as
  `.verified` (nothing was asserted, so nothing failed to substantiate) rather than
  `.unverified` — a real difference from `ingest()`'s `classifyOutcome`, which requires *some*
  surviving component or claim to call anything `.verified` at all.
- **Confirmed live, end to end**: `ClaudeCodeInvestigatorTests` still mocks the CLI with a
  stand-in shell script (mirrors Phase 2's own Python tests, which mocked `subprocess.run`
  rather than calling the real binary) for CI-safe coverage of prompt/argument construction,
  read-only tool restriction, and wrapper parsing. On top of that,
  `ClaudeCodeInvestigatorLiveTests` (gated on `ORION_AGENT_LIVE_CLAUDE_CLI_TEST=1`, not run in
  CI) runs a real `claude` CLI investigation against a real analyzed repo (vendored Starlette)
  and feeds the result straight into `ingestAnswer`: "What does Starlette's Router class do,
  and how does it dispatch an incoming request to a matching route handler?" resolved in 93.6s
  as `claude-sonnet-5`, 23 turns, $0.77, and ingested as `partially_verified` with 13 surviving
  claims and 0 dropped — the real process boundary this whole milestone exists to cross is now
  exercised for real, not just read as correct.

---

## SQLite schema (GRDB `DatabaseMigrator`, migration `v3_phase3_schema`)

Additive only — no Phase 1 or Phase 2 table is altered.

- **`investigations`** (existing table, no migration needed) — Phase 3 is the first consumer
  that writes a real free-form `question` (Phase 2 always wrote the fixed
  `"phase2_semantic_grouping"`) and a real `complexity` (`low`|`medium`|`high`, mapped from
  depth 1/2/3) instead of Phase 2's constant `"high"`.
- **`routing_decisions`** — `id`, `investigation_id`, `depth_level` (1|2|3), `method`
  (`heuristic`|`model`), `confidence`, `rationale`, `created_at`. The Depth Model's own decision,
  kept distinct from `investigations.complexity` (the path actually taken) so a later
  routing-quality benchmark (Phase 5) can compare "what the router chose" against "was that
  choice actually necessary" without re-deriving it from prose.
- **`agent_tool_calls`** — `id`, `investigation_id`, `turn_index`, `tool_name`, `arguments`
  (JSON), `result_summary`, `latency_ms`, `created_at`. The ReAct-loop trace —
  [05_user_flow_and_ux.md](05_user_flow_and_ux.md) §8 lists "internal tool traces" as hidden by
  default, not undiscoverable; this table is exactly that hidden-by-default record, surfaced
  only via `orion-agent ask --explain`.
- `claims`/`evidence`/`model_revisions` (existing Phase 2 tables) — reused as-is; every claim
  Phase 3 inserts (local-loop synthesis or Claude-delegated) carries this question's
  `investigation_id`, same as Phase 2's component-investigation claims did.

`knowledge_states` stays reserved and unbuilt — Phase 7 (Teaching).

---

## CLI (`orion-agent`)

- **`ask <path> "<question>"`** (M4, built) — `<path>` is the repository checkout, positional
  and required, mirroring `orion-index analyze <path>` exactly (both default their output
  directory to `<path>/.orion`, so `ask` "just works" against whatever `analyze` already
  produced with no extra flags). `--out <dir>` overrides that default; `--commit` answers
  against a specific analyzed run instead of the latest one; `--force-depth 1|2|3` (overrides
  the Depth Model — `validate()` rejects anything outside 1-3 as a usage error);
  `--max-budget-usd`/`--timeout` (L3 cost ceiling / watchdog, defaults `1.00`/`400`); `--explain`
  (prints the routing decision + full tool-call trace — the opt-in "advanced diagnostic view"
  [05_user_flow_and_ux.md](05_user_flow_and_ux.md) §8 anticipates); `--json` (structured object
  instead of formatted text). Prints the answer plus a one-line claim/outcome summary by
  default; hides routing/tool-trace detail unless `--explain` is passed, matching Docs/05's
  "expose epistemic transparency, hide computational complexity." Exit: `0` answered (fully or
  partially), `1` depth-3 investigation `rejected`/`unverified`, `2` usage (ArgumentParser's own
  `ValidationError` path, same as `orion-index analyze`), `3` no analyzed run found / pipeline
  failure. *Not implemented*: per-claim/evidence citations inline in the default (non-`--explain`)
  view — `AgentSessionResult` currently reports counts (`claim_count`/`dropped_claim_count`),
  not the claims themselves; revisit once M5's hand-picked validation shows whether that detail
  is actually needed for a first cut.
- *Deferred*: a `chat`/REPL subcommand for multi-turn sessions — out of scope per "What Phase 3
  is not" above; Phase 4's UI is where conversational continuity actually belongs.

---

## Testing & verification

**Unit (`OrionAgentTests`, no model load, no network)**

- `DepthHeuristics`: the six worked examples from
  [03_agent_and_model_routing.md](03_agent_and_model_routing.md) §2 classify to the right level.
- `AgentTool` fixtures: each tool wraps a known small analyzed repo (reuse Phase 1/2's fixture
  pattern) and returns the expected result shape; a bogus symbol name returns a typed "not
  found," never throws.
- `AnswerSchema`/`AnswerImporter`: valid minimal candidate round-trips; an unresolvable evidence
  anchor is dropped + diagnosed, not inserted; a claim with no confirmable Phase 1 relationship
  is reclassified `CONTRADICTED`, mirroring `SemanticImporterTests`' existing coverage for the
  same logic (this is deliberately the *same* code path, so most of the risk is already
  retired by Phase 2's tests — Phase 3's new tests only need to cover the schema difference and
  the "no component mutation" boundary).
- `routing_decisions`/`agent_tool_calls` persistence: a full loop run against a fixture repo
  writes the expected row counts.

**Model-dependent (real `Qwen3-8B-4bit` load, `XCTSkip` without an explicit opt-in env var, same
posture as Phase 1's `npx`-gated SCIP tests and Phase 2's live-`claude` tests)**

- Model loads and produces a schema-conformant classification/tool-call/final-answer on a
  trivial prompt.
- The `classify_depth` tool-call round-trip actually decodes into `DepthOutput` reliably across
  repeated calls (no free-text escape, no malformed-arguments failure) — the concrete check for
  Risk #3 below: record the real schema-conformance rate, don't just assume the native
  tool-calling path works.

**M5 — Hand-picked validation set. [done, manual, not CI — real Claude usage: 18 investigations,
$6.08, 235 turns].**

13 questions reused verbatim from `Agent Feasibility Study/benchmark/benchmark.resolved.json`
(no re-authoring), run through the real `orion-agent ask` binary against real vendored Starlette
— no `--force-depth`, so the Depth Model chose for real. `--max-budget-usd` started at $0.50,
raised to $1.00 after CU-07 genuinely needed more (see finding 3 below).

| id | category | depth chosen | outcome | claims | turns | cost | correct? |
|---|---|---|---|---|---|---|---|
| CU-01 | code_understanding | 1 (model, high) | verified | 0 | — | $0 | **No** — generic made-up example, never names `ServerErrorMiddleware`/`ExceptionMiddleware`, no mention of the list being reversed |
| CU-05 | code_understanding | 1 (model, high) | verified | 0 | — | $0 | **No** — omits the `_stream_consumed` guard, `ClientDisconnect`; wrongly claims a re-read "returns nothing" (it raises `RuntimeError`) |
| CU-07 | code_understanding | 3 (model, medium) | partially_verified | 7 | 9 | $0.17 | **Yes** — sequential `await` loop, sync→`run_in_threadpool`, all named correctly |
| CU-08 | code_understanding | 1 (model, high) | verified | 0 | — | $0 | **No** — says 302; the real default is 307 (chosen specifically to preserve method/body) |
| XF-01 | cross_file_reasoning | 3 (model, medium) | partially_verified | 10 | 15 | $0.37 | **Yes** — full, accurate trace through `request_response` → `ExceptionMiddleware` → `ServerErrorMiddleware` |
| XF-04 | cross_file_reasoning | 3 (model, medium) | rejected (both attempts) | 0 | 16, 9 | $0.37, ~$0.85 | **Failed** — CLI structured-output schema conformance failure once, degenerate placeholder answer once (see findings 3-4) |
| XF-07 | cross_file_reasoning | 3 (model, medium) | partially_verified | 11 | 7 | $0.19 | **Yes** — portal/thread mechanism and lifespan-only-in-`with`-block both correct |
| AR-01 | architecture | 3 (model, medium) | partially_verified | 20 | 19 | $0.52 | **Yes** — all major components and the full request-layering order, correct |
| AR-06 | architecture | 3 (model, medium) | partially_verified | 12 | 17 | $0.51 | **Reasonable** — a defensible, differently-curated file list (leads with `types.py` over `exceptions.py`), not wrong |
| DC-02 | dependency_change_impact | 1 (model, high) | verified | 0 | — | $0 | **No** — never mentions `TestClient`/`raise_server_exceptions`, misses that client-visible behaviour is unchanged |
| DC-05 | dependency_change_impact | 3 (model, medium) | verified (2nd attempt) | 12 | 34, 23 | $0.85, $0.47 | **Yes** (2nd attempt) — 1st attempt was the "test" placeholder bug (findings 4) |
| BR-02 | behavioral_reasoning | 3 (model, medium) | partially_verified | 16 | 29 | $0.69 | **Yes** — 405 + exact `Allow` header mechanism, HEAD-with-GET, both call paths (with/without `Starlette` wrapper) |
| BR-03 | behavioral_reasoning | 3 (model, medium) | verified (3rd attempt) | 10 | 16, ?, ? | $0.34 + 2 more | **Yes** (3rd attempt) — 307 + method/body preservation + `redirect_slashes=False` behaviour, correct; 1st was the "test" bug, 2nd was a schema-conformance failure |

Depth actually chosen: **4/13 landed on depth 1, 9/13 escalated straight to depth 3, 0/13 landed
on depth 2** (Depth Model's local classifier reported "medium," not "high," confidence for
every question harder than a `code_understanding` one-liner, and medium/low confidence escalates
straight past depth 2 to depth 3 by design — Docs/12 M1's Risk #3 resolution). Every claim ever
submitted with resolvable evidence survived intact — **0 evidence anchors were ever dropped**
across all 18 investigations, i.e. when the model (local or Claude) cited an anchor at all, it
was always real.

**Findings** (first data point for H3/H4/H5, not a benchmark — Phase 5 owns turning this into
one):

1. **Depth 1 was wrong 4 times out of 4.** Every depth-1 answer in this sample had a real,
   confirmable defect against the actual source — from a generic, half-invented example (CU-01)
   to a flatly wrong HTTP status code (CU-08, 302 vs the real 307). All four were still labeled
   `verified`, because `classifyAnswerOutcome` correctly reports "nothing was asserted as a
   claim, so nothing failed to substantiate" — but that label is easy to misread as "checked and
   correct" when it actually means "not checked at all." This is the single most important
   finding of M5: **depth 1's "verified" outcome should not be presented to a user the same way
   a grounded depth-2/3 "verified" is** — worth a UX-level distinction in Phase 4, not just a
   Phase 3 internal label. n=4 is small; still, 4/4 is a strong enough signal to flag now rather
   than wait for Phase 5's larger benchmark.
2. **Depth 2 was never reached naturally.** All 9 non-trivial questions jumped straight to depth
   3, none landed on depth 2 — confirming that, as tuned *at the time of this run*, the
   free/fast/tool-grounded middle path was reachable only via an explicit L2-shaped heuristic
   match (Docs/03's "who calls"/"what tests cover" phrasing) or `--force-depth 2`, not via the
   model-backed classifier's own judgment. M4's live verification already showed depth 2 works
   correctly when reached; this finding was about how *rarely* it was reached for realistic
   questions. **Resolved as Risk #7**: `DepthModel` now routes `"medium"` confidence to depth 2
   instead of depth 3 — this specific M5 run predates that change and was the evidence that
   motivated it. Re-verified live afterward, separately from M6: depth 2 is reachable now (9/13
   landed there), but see Risk #7's full write-up for the real trade-off that came with it
   (cost/honesty improved, hard-question answer quality did not).
3. **`--max-budget-usd` needs headroom above Phase 2's own per-run costs.** CU-07's first
   attempt hit `budget_exhausted` at the initial $0.50 cap after 9 turns ($0.53 spent, no answer
   produced) — confirmed by reproducing the exact CLI call by hand: `terminal_reason:
   "budget_exhausted"`. Raised to $1.00 for the rest of the run; every subsequent successful
   investigation finished under $0.85. Real per-question depth-3 cost in this sample: $0.17-0.85,
   7-34 turns, 34-203s.
4. **The `claude` CLI itself occasionally returns a degenerate, schema-conformant placeholder
   answer.** DC-05's and BR-03's first attempts both returned the literal 4-character answer
   `"test"` — `is_error: false`, 34 and (in a later BR-03 attempt) real turns/cost spent, yet a
   clearly non-answer. `AgentAnswerSchema.cliJSONSchema()`'s `minLength: 1` on `answer` didn't
   stop the CLI from accepting its own degenerate output as schema-valid. **Fixed as a direct
   result of this finding**: raised to `minLength: 20` in the CLI schema (so the CLI's own
   generation more often gets a loud retry instead of silently accepting a placeholder), plus a
   matching Swift-side floor in `SemanticImporter.validateAnswerSchema` (the only gate a
   locally-synthesized depth-1/2 candidate ever passes through, since those never touch the
   CLI's schema validator at all) — regression test added
   (`testValidateAnswerSchemaRejectsSuspiciouslyShortAnswer`). Retrying both questions produced
   correct, well-grounded answers immediately afterward, so this looks like real but occasional
   CLI-side flakiness (this session also saw one straightforward schema-conformance failure,
   "Failed to provide valid structured output after 5 attempts," on XF-04 twice and BR-03 once)
   rather than something wrong in Orion's own prompt or schema.
5. **The CLI's own failure reason wasn't being surfaced.** Before finding 3-4 were even
   diagnosable, `AgentSession`'s L3 failure message was a generic "failed to produce output" with
   empty `stderr` — the *real* reason (`errors`/`subtype` in the CLI's JSON wrapper, e.g.
   `"Reached maximum budget ($0.5)"`) was being parsed by `ClaudeCodeInvestigator` and then
   silently discarded. **Fixed**: `ClaudeCodeInvestigationResult` gained an `errorMessage: String?`
   field extracting `wrapper["errors"]`/`wrapper["subtype"]`, surfaced in `AgentSession`'s failure
   text instead of the old generic message — regression test
   (`testInvestigateSurfacesBudgetExhaustedErrorMessage`) added.

**CI**: stays network-free like Phase 1/2 — routing-heuristic, tool-fixture, and
schema/ingestion tests run in CI; model-load and `claude`-CLI tests stay `XCTSkip`'d there.

---

## Implementation order

- **M0 — Skeleton. [done]** Added `mlx-swift-lm` (`from: "3.31.4"`), `swift-huggingface`
  (`from: "0.10.0"`), `swift-transformers` (`from: "1.3.4"`). **Real findings corrected three
  assumptions this plan started with** (see the Dependency section's M0 note): no
  `MLXGuidedGeneration` product exists, `mlx-swift-lm`'s own tools-version is 6.1 not 6.2, and
  loading a model needs the two HuggingFace packages, not `mlx-swift-lm` alone — found by
  downloading the actual tagged source and grepping it, not by trusting vendor docs/web-search
  summaries a second time. New targets `OrionAgent` (library), `orion-agent` (executable),
  `OrionAgentTests` — `Package.swift` products list updated too. `Qwen3Agent.load()` wraps
  `LLMModelFactory.shared.loadContainer(from: #hubDownloader(), using:
  #huggingFaceTokenizerLoader(), configuration: LLMRegistry.qwen3_8b_4bit)`; `respond(to:)`
  wraps `ChatSession.respond(to:)`. `orion-agent ask "<question>"` loads the model and prints
  its raw reply (no routing/tools/persistence yet — that's M1-M4). `swift build` and
  `swift test` both clean (0 warnings after one `@Sendable` fix); full suite green at **158
  tests** (156 Phase 1/2 + 2 new: an offline `ModelConfiguration.name` check, and a live model
  round-trip gated behind `ORION_AGENT_LIVE_MODEL_TEST=1`, correctly `XCTSkip`'d by default).
  **Not yet measured**: real load/decode latency (M0's smoke test doesn't run without the env
  var set — Swift-side load latency vs. Python mlx-lm's 47.1s stays open until someone runs it
  with the flag on).
- **M1 — Depth Model. [done].** `DepthHeuristics` (six explicit rules, one per Docs/03 §2
  worked example), `DepthFallbackClassifying` protocol, `DepthModel` (heuristics-first
  orchestration + confidence-based escalation + a timeout safety net, below), `routing_decisions`
  table (`v3_phase3_schema`, added to `OrionCodeIntel`'s existing migrator/Store rather than a
  separate `OrionAgent` persistence stack — Phase 2 already established "one shared DB," so
  Phase 3 follows that instead of what this plan originally sketched). A `classify` debug CLI
  subcommand was added (not planned, but needed to exercise the fallback path live without
  waiting for M4). 20 new tests, 176 total.

  **Live testing found a real, load-bearing problem with the originally-planned fallback
  mechanism, and it was fixed by switching providers, not patching around it.** Running the
  first design (`ModelBackedDepthClassifier`, Qwen3 tool-calling) against real `Qwen3-8B-4bit`:
  1. The classification tool-call hung for **10+ minutes with zero output** on a genuinely hard
     question — Qwen3's hybrid-thinking chat template generates an extended `<think>` trace
     before the tool call, and constraining that turned out to be much harder than expected.
  2. `additionalContext: ["enable_thinking": false]` (the mechanism `mlx-swift-lm`'s own
     `IntegrationTestHelpers` use in its own tool-calling tests) did **not** fix it, reproduced
     twice, including on a trivial question ("what color is the sky") once a tool schema was
     offered — isolating the problem to *tool-calling specifically*, not question difficulty.
  3. A literal `/no_think` suffix in the message — confirmed to work perfectly on the
     plain-chat path (1.7s round trip, empty think block) — **also did not fix the tool-calling
     path**, reproduced again on the same trivial question.
  4. `DepthModel` was extended with a bounded timeout (default 20s) that escalates to depth 3
     on either low confidence *or* a hung fallback — verified correct with a fast synthetic
     unit test (a fallback stubbed to sleep for an hour still returns in under 2s). The losing
     task is deliberately never cancelled — an earlier version called `cancelAll()` on timeout
     and that alone crashed the process; polling an actor-boxed result instead avoids ever
     sending cancellation into in-flight MLX/Metal generation. Kept as defense-in-depth even
     after the provider switch below.
  5. Even without cancellation, the process still crashed (SIGSEGV) shortly after a
     timeout-driven escalation returned, reproducibly, root cause never isolated — plausibly an
     mlx-swift/Metal-level issue with an orphaned generation task still executing at process
     exit, not a bug in `DepthModel`'s own logic.

  **Resolution**: rather than keep debugging an MLX/Metal-level crash with no isolated cause,
  `DepthModel`'s default fallback was switched to `AppleFoundationDepthClassifier` (Apple's
  on-device `FoundationModels` framework — see Decision #2a above and Risk #3). Verified live,
  repeatedly: 1.4-8.2s per classification, correct depth/confidence output, correct escalation
  behavior, zero hangs, zero crashes. `ModelBackedDepthClassifier` and its live tests stay in
  the codebase — still passing, still documenting a real bug — but are no longer wired up as
  the default anywhere. Package platform floor bumped to `.macOS(.v26)` as a result (all targets
  pinned to Swift 5 language mode via `swiftLanguageModes: [.v5]` to avoid a second, unrelated
  churn from the required `swift-tools-version: 6.2` bump).
- **M2 — Tool loop (L1/L2). [done].** Built exactly to the resolved Risk #3 design — plain
  Swift `AgentTool` functions (`LookupSymbolTool`/`ModuleSymbolsTool`/`CallersTool`/
  `CalleesTool`, wrapping `QueryEngine` — no new deterministic capability), `ActionLoop` (the
  manual JSON-action state machine: budget 0 skips the protocol and answers directly; budget >
  0 loops call-tool/answer turns, checking for "answer" *before* checking budget so a model
  that lands on it exactly at the limit isn't treated as partial — a real off-by-one bug caught
  by `testAnsweringExactlyAtBudgetIsNotPartial` before it shipped), `TurnGenerating` (a
  single-method protocol `ChatSession` conforms to, so the loop's state machine is testable
  with a scripted stub instead of a live model), `AgentAnswer`/`ExecutedToolCall` (coarse
  epistemic split: the tool results are the `FACT`-tier material, the model's final text is
  always `INTERPRETATION`, never per-sentence claim decomposition — that's M3/M4 scale). 21 new
  tests (10 `ActionLoopTests` against the stub, 8 `QueryEngineToolsTests` against a real
  analyzed fixture repo, 3 schema/persistence), 201 total.

  **`agent_tool_calls`** added to the same pre-release `v3_phase3_schema` migration
  (`id`, `investigation_id`, `turn_index`, `tool_name`, `arguments`, `result_summary`,
  `latency_ms`, `created_at`) — same "amend, don't version" precedent `routing_decisions` (M1)
  and Phase 2's own M2 both used.

  **Verified live, end to end, not just unit-tested**: real `Qwen3-8B-4bit` driving
  `ActionLoop` against real `QueryEngine`-backed tools (not the toy canned-string tool the Risk
  #3 experiments used) over a small analyzed fixture repo — **11.8 seconds**, at least one real
  tool call executed, the final answer grounded in what that tool actually returned. No hang,
  no crash. This is also where the `xcrun xctest` runner fix (above) was found and confirmed —
  `ActionLoopLiveTests` is a permanent, re-runnable test now, not a temporary CLI experiment.

  *Not built, deliberately deferred*: `ContextBuilder` (priming from `semantic_model.json`/
  `code_graph.json`) and full epistemic claim/evidence persistence. Both need a real
  `AgentSession` orchestrator wiring `DepthModel` → `ActionLoop` → `Store` together, which is
  M4's job ("State management + CLI"), not M2's ("Tool loop") — M2 proves the loop mechanism
  works against real tools and a real model; M4 wires it into the product-facing command.
- **M3 — Claude delegation (L3). [done].** `ProcessRunner` (standalone watchdog-timeout
  subprocess runner, `readabilityHandler`-based pipe draining, verified live against real
  `/bin/sleep`/`/bin/echo`/`/bin/sh` — no deadlock, no hang past the deadline);
  `ClaudeCodeInvestigator` (prompt/argument construction ported from Phase 2's
  `investigate.py`, wrapper parsing for structured-output/result-text/is_error/dominant-model,
  all verified against a stand-in `claude` shell script); `AgentAnswerSchema`
  (`phase3.v1`)/`AgentAnswerFindings` (reuses `SemanticClaimInput` directly — identical claim
  shape); `SemanticImporter.ingestAnswer` (three shared helpers extracted and reused by
  `ingest()`, not duplicated). 33 new tests, 234 total, all 19 pre-existing
  `SemanticImporterTests` still green after the refactor. Manual live `claude` CLI run
  confirmed working end to end (`ClaudeCodeInvestigatorLiveTests`, real vendored-Starlette
  question, $0.77, 23 turns, ingested as `partially_verified`/13 claims) — see the risk-list
  entry above for the full result.
- **M4 — State management + CLI. [done].** `AgentSession` orchestrator wiring `DepthModel` ->
  local `ActionLoop` (depth 1/2, injectable session factory so it's unit-testable without a live
  model — same seam `ActionLoopTests` already uses) or `ClaudeCodeInvestigator` (depth 3) ->
  `SemanticImporter.ingestAnswer` -> `routing_decisions`/`agent_tool_calls` persistence (the
  `v3_phase3_schema` migration itself needed no changes — both tables were already added in
  M1/M2 under the "amend, don't version" precedent). `ContextBuilder` (primes local sessions
  from `code_graph.json`/`semantic_model.json`, truncated per-file so context size doesn't scale
  unbounded with repo size). `EvidenceAnchors` (regex-extracts anchor-shaped strings from a
  depth-2 tool-call trace so a local answer's claim can cite real evidence without ever asking
  Qwen3-8B to emit structured `claims`/`evidence` JSON itself — deliberately not attempted,
  since Risk #3 already showed this model is unreliable at extra structured fields; a bogus
  extracted anchor gets exactly the same drop-if-unresolved protection a Claude-invented one
  would). `orion-agent ask` wired end to end with `--force-depth`/`--max-budget-usd`/`--timeout`/
  `--explain`/`--json`, matching Docs/12's exit-code spec (0 answered, 1 L3
  rejected/unverified, 3 pipeline failure). Needed two small `SemanticImporter` API extensions
  to support all three depths through one shared path: `ingestAnswer` gained `complexity`
  (previously hardcoded `"high"`, now `"low"`/`"medium"`/`"high"` per depth) and `createdBy`
  (`"qwen3_local"` vs `"claude_code"`) parameters, both defaulted to preserve M3's existing
  call sites and tests untouched; `SemanticIngestOutcome` gained an `answer: String?` field
  (only `ingestAnswer` populates it — `ingest()`'s whole-repo grouping has no single
  natural-language answer to report) since the CLI needs the actual answer text back, not just
  the persistence outcome. 15 new tests (`AgentSessionTests` covering all three depths plus the
  no-analyzed-run and L3-timeout error paths, `EvidenceAnchorsTests`, `ContextBuilderTests`),
  250 total.

  **Verified live against real vendored Starlette, all three depths, through the actual `ask`
  binary** (not just unit tests): depth 1 answered "What is Starlette?" from the model's own
  knowledge with 0 tool calls, correctly `.verified` (nothing asserted, nothing to fail); depth
  2 answered "find the Router class" with a real `lookup_symbol` call, extracted the real anchor
  `starlette/routing.py::Router`, resolved it, persisted 1 claim, `.verified`, and got the fact
  right ("defined in starlette/routing.py, line 573" — matches the tool's own real output);
  depth 3 reuses M3's already-verified live `claude` CLI path. A first, unprompted depth-2
  question (no explicit "use your tools" nudge) demonstrated the epistemic design working as
  intended from the other direction: the model answered fluently from pretrained knowledge
  without calling anything, so 1 claim was submitted with empty evidence, correctly dropped, and
  correctly landed on `.unverified` — visibly different from depth 1's `.verified`, exactly the
  "tried and failed to ground" signal the design (Docs/12 M4's `assertClaim` logic) exists to
  produce.

  Two real bugs found only by exercising the actual CLI, not caught by any unit test: (1)
  `swift run`/`swift build` never builds `mlx-swift`'s Metal shaders at all on this machine —
  the only plugin attached to `mlx-swift`'s package (`CudaBuild`) is genuinely CUDA-only and a
  no-op on macOS, so plain SwiftPM produces no `default.metallib` anywhere and any MLX model
  load fails immediately (`Failed to load the default metallib`). Only `xcodebuild` (which
  compiles `.metal` sources as a native build phase) produces one, at
  `.build/xcodebuild/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`
  — confirmed working via `xcodebuild -scheme orion-agent -destination 'platform=macOS'
  -derivedDataPath .build/xcodebuild -skipPackagePluginValidation -skipMacroValidation build`
  (the two `-skip...Validation` flags are needed non-interactively; Xcode's GUI would otherwise
  prompt to trust the package's plugin/macro once). This generalizes the M1/M2 finding that
  `xcodebuild`, not plain `swift build`/`test`, is required for anything MLX-touching — M1/M2
  only ever needed this for *xctest bundles*; M4 is the first place an MLX-touching
  *executable* needed to actually run, and the same gap applies there too, for the same
  underlying reason. (2) A depth-1 (budget-0) answer returned Qwen3-8B's raw
  `<think>...reasoning...</think>` block as the visible answer text — invisible to every prior
  milestone's tests because budget>0 paths extract just the `{...}` JSON action and incidentally
  skip over surrounding `<think>` prose, while budget-0 returns the model's raw response with no
  extraction step at all. Fixed in `ActionLoop` (strips through the last `</think>` at every
  point the loop hands back model-authored text, anchored only on the closing tag so a
  missing/malformed opening tag still gets cleaned up); `ActionLoopTests` gained a regression
  test.
- **M5 — Hand-picked validation. [done].** 13 real benchmark questions run through the actual
  `orion-agent ask` binary (no `--force-depth`) against real vendored Starlette: $6.08/235 turns
  across 18 investigations (retries included). Depth 1 was wrong 4/4 times it was chosen (still
  labeled `verified` — a real, flagged UX concern for Phase 4); depth 2 was never reached
  naturally (every non-trivial question escalated straight to depth 3); depth 3, when it
  succeeded, was correct 7/7 times. Two real bugs found and fixed along the way: the CLI's own
  failure reason (`errors`/`subtype`) was being parsed and then discarded instead of surfaced,
  and a degenerate schema-conformant placeholder answer ("test") could previously slip through
  as `verified` — both fixed with a regression test each. Full table and findings in "Testing &
  verification" above.
- **M6 — Hardening. [done].** `ModelDownloadProgressReporter` reports first-run model-weight
  download progress to stderr (throttled to whole percentage points), wired into
  `AgentSession`'s default `sessionFactory` — **confirmed live** even a cached load prints a
  real, two-line `\r0%\r100%\n` (verified byte-for-byte), so the common case stays quick and
  non-spammy while a genuine first-run download (real weight, ~4.3GB, confirmed on this machine
  at `~/.cache/huggingface/hub/models--mlx-community--Qwen3-8B-4bit`) is now visible instead of
  reading as a hung process. `--max-budget-usd`/`--timeout` enforcement for L3 verified end to
  end through `AgentSession` itself, not just at `ClaudeCodeInvestigator`'s own unit level: a
  configured budget is confirmed to reach the real subprocess's argv unchanged, and a configured
  timeout is confirmed to actually kill a real 30-second-sleeping stand-in process within its
  ~2-second bound. CI workflow hardened with an explicit `--skip` list naming all six live test
  classes (defense in depth on top of their own runtime env-var gating, verified locally to
  still pass — 253 tests, 0 skipped, 0 failures with the list applied) plus a diagnostic Xcode-
  version step, since CI's actual GitHub-side behavior against this package's `.macOS(.v26)`
  floor has not been verified (nothing from Phase 3 has been pushed this session — that
  verification needs a real push/PR, not something checkable from a local session). README gained
  an "OrionAgent (Phase 3)" section: the cache-location resolution order (`HF_HUB_CACHE` >
  `HF_HOME` > `~/.cache/huggingface/hub`), confirmed against this machine's real cache, plus the
  `xcodebuild`-not-`swift build` requirement for any MLX-touching binary (a recurring finding
  from M4/M5 that had never been written down anywhere a new contributor would actually find it).
  7 new tests, 261 total.

---

## Risks / open questions

1. **`mlx-swift-lm` is young and version-churns fast** — confirmed directly at M0: this plan's
   first draft (written from vendor docs + AI-summarized web search, before downloading the
   actual tagged source) had the product list, the tools-version, and the dependency set all
   wrong. Mitigation going forward: same posture as Phase 1's `tree-sitter-python` pin lesson —
   an exact tag is now pinned (`3.31.4`) and verified to resolve/build/test clean; re-verify
   against real source again (not docs) before bumping it.
2. **Swift-side latency, now partially measured, is worse than Python's for anything
   tool-calling-shaped.** M1 measured: plain chat (`ask`, cached weights) ~15s for a trivial
   question including a full `<think>` trace, ~1.7s with a `/no_think` suffix — both
   reasonable. But `classify` (tool-calling) hangs 10+ minutes on the same class of question.
   Task 3's 47.1s load / 22.0 tok/s numbers (Python `mlx-lm`, no tool-calling) are not
   comparable to this failure mode at all — the gap isn't raw throughput, it's specifically
   tool-calling + hybrid-thinking interacting badly on this Swift stack.
3. **RESOLVED — for the Depth Model, and for M2's L2 tool loop.** `ModelBackedDepthClassifier`
   (Qwen3-8B tool-calling) is confirmed broken: hybrid-thinking generates an unbounded reasoning
   trace before a tool call; neither `enable_thinking: false` nor a literal `/no_think` suffix
   fixes this specifically for tool-calling sessions (both work fine on plain chat); and even
   with `DepthModel`'s timeout+escalation safety net catching the hang correctly, the process
   then crashed (SIGSEGV) shortly afterward, root cause never isolated. `mlx-swift-lm`'s own
   format-parser list (JSON, GLM4, Llama3, Mistral, Pythonic, XML, auto-detected) was never
   reached as the blocker — the problem was upstream of parsing, in generation itself never
   terminating. `AppleFoundationDepthClassifier` (Apple's on-device `FoundationModels`
   framework) replaced it as `DepthModel`'s default fallback and does not exhibit this failure
   mode — verified live, 1.4-8.2s per call, repeatedly, no hangs, no crashes.

   **Both options for M2's L2 tool loop were then verified live, not assumed, and both work:**
   - **(a) `FoundationModels`' own `Tool` protocol** (separate from the `@Generable` path
     `AppleFoundationDepthClassifier` uses) — `FoundationModelsToolCallingLiveTests`: a
     single-tool lookup and a two-tool multi-step question, both completed in 0.85-1.9s across
     repeated runs, both correctly grounded in the tools' real results. One caveat found:
     the model sometimes paraphrases numerals as words ("3" -> "three"), so M2's evidence
     grounding can't assume a verbatim quote back from a tool result.
   - **(b) A non-thinking Qwen checkpoint** (`mlx-community/Qwen3-4B-Instruct-2507-4bit`,
     confirmed to exist and pulled successfully, ~2.3GB) through the *exact same*
     `mlx-swift-lm` `ChatSession`/`Tool` mechanism that hung on `Qwen3-8B` —
     `Qwen3NonThinkingToolCallingLiveTests` / a temporary CLI experiment (built via
     `xcodebuild`, run directly, then removed): ~2.0-2.1s per call across two independent runs,
     correct `classify_depth` arguments both times, no hang, no crash. This isolates the
     original bug precisely to Qwen3-8B's *hybrid-thinking* architecture, not to
     `mlx-swift-lm`'s tool-calling mechanism in general — the same `ChatSession`/`Tool` code
     path that hung for 10+ minutes on the thinking checkpoint works fine on a non-thinking one.

   **Superseded by a better option, found by questioning the framing rather than picking
   between (a) and (b).** Both (a) and (b) work, but both were still answering the wrong
   question — "which model/mechanism should handle native tool-calling" — when the real fix is
   not to use native tool-calling *at all* for the model that does the actual investigating.
   Per real-world feedback (Apple's on-device model is weak at source-code investigation
   specifically, not just slow at tool-calling — a small classifier-shaped model is the wrong
   tool for that job regardless of speed) and confirmed live: **(d) separate reasoning from
   tool execution** — plain-chat generation on `Qwen3-8B` (no `tools` parameter, no native
   tool-calling format at all), prompted each turn for a small JSON action decision
   (`{"action":"call_tool",...}` / `{"action":"answer",...}`), parsed tolerantly in Swift (same
   posture as Phase 2's `extract_json`), with the *actual* tool execution done by Swift code,
   never the model. Verified live, twice: a full call-tool-then-answer loop in ~3.0-3.1s total,
   correct JSON both turns, correctly grounded final answer, zero native tool-calling path
   touched. This is now M2's design (see "Local execution & tool loop" above) — it keeps
   Qwen3-8B (the Task-3 benchmark winner) as the one model for both L1 and L2, needs no MLX
   `Tool` schema type at all, and there is no real constrained/guided generation in
   `mlx-swift-lm` to enforce the JSON shape (checked: only the low-level `LogitProcessor`
   per-token hook exists, the same primitive Python `mlx-lm`'s `logits_processors` is — building
   a real JSON-grammar sampler on it would be its own project, out of scope here), so the JSON
   is prompted-for and tolerantly parsed, not hard-enforced — acceptable because Phase 2 already
   established that pattern works in practice for Claude's output, and M1/M2's live testing
   confirms Qwen3-8B follows the requested shape reliably even through stray `<think>` wrapper
   text around it.

   Options (a) and (b) stay validated and recorded as real, working fallbacks if (d)'s
   tolerant-JSON-parsing approach turns out unreliable at scale (M5 should watch the real
   parse-failure rate, not assume 3 test runs generalize) — (a) if Qwen3-8B's JSON discipline
   degrades and a schema-enforced path is worth the small-model capability trade-off for L2
   specifically, (b) if a second, non-thinking Qwen checkpoint's native tool-calling ever
   becomes preferable to hand-rolled JSON parsing. Option (c) (subprocess-per-generation
   isolation) is not needed by any of (a)/(b)/(d).

   **A real testing-infrastructure gap was found while verifying this — and resolved, in M2.**
   An MLX-touching live test (env-var-gated `XCTest`) cannot run under plain `swift test` (can't
   build the Metal shaders `mlx-swift-lm` needs at runtime) or `xcodebuild test` (doesn't
   propagate env vars exported in the invoking shell to the test host process — confirmed
   directly, twice). **Fix, confirmed live in M2**: `xcodebuild build-for-testing` (builds the
   `.xctest` bundle with Metal shaders, same as any build) then run it directly with `xcrun
   xctest -XCTest <Target>.<Class>/<method> <path-to-.xctest>` — this *does* inherit the
   invoking shell's environment. Verified working for `Qwen3AgentTests` (M1) and
   `Qwen3NonThinkingToolCallingLiveTests`/`ActionLoopLiveTests` (M2) — see
   `Qwen3NonThinkingToolCallingLiveTests`'s doc comment for the exact commands. This is now the
   documented way to run any MLX-touching live test; no CLI-command workaround needed. Not
   needed for `FoundationModels` tests at all — they already run fine under plain `swift test`.
4. **No native `Process` timeout in Swift** — the L3 watchdog is hand-built, unlike Python's
   one-line `subprocess.run(timeout=...)`. Get this right in M3; a stuck `claude` invocation
   with a leaked/unterminated process is worse than Phase 2's Python equivalent ever risked.
5. **CONFIRMED — the L1 budget-zero bet did not pay off in M5's sample.** All 4 depth-1 answers
   in M5's 13-question validation were factually wrong when checked against the real source (see
   "Testing & verification" M5 table) — not for lack of primed context (`ContextBuilder` did
   supply `code_graph.json`) but because a compact skeleton doesn't contain the specific
   mechanism detail these questions needed (exact HTTP status codes, exact exception-handling
   order, exact re-raise semantics), and the local model filled the gap from its own pretrained
   knowledge instead of admitting it didn't know. Widening the primed context (this risk's
   original proposed fix) wouldn't obviously help — `code_graph.json` is already a skeleton by
   design, not full source, and the questions that failed needed exact source-level detail no
   skeleton carries. The more honest fix belongs at the UX layer, not the context layer: stop
   presenting depth 1's `verified` the same way a grounded depth-2/3 `verified` is presented
   (Docs/12 M5 finding 1) — n=4 is small, but 4/4 wrong is a strong enough signal to act on
   before Phase 5's larger benchmark, not just note and wait.
6. **One investigation per question, not batched** — like Phase 2's M6 repeatability tooling,
   `orion-agent ask` runs exactly one question per invocation. Multi-question sessions are a
   Phase 4 UI concern, not built here.
7. **RESOLVED, from M5 — depth 2 was effectively unreachable via the model-backed classifier.**
   Every one of M5's 9 non-trivial questions escalated straight from "local classification
   confidence was medium" to depth 3, none landed on depth 2 — a direct, and until then
   unmeasured, side effect of M1's "escalate straight to depth 3 on anything less than high
   confidence" decision. As tuned at the time, the free/fast/tool-grounded middle path Docs/03
   describes was reached only via an explicit heuristic match (`DepthHeuristics`' "who
   calls"/"what tests cover" phrasing) or `--force-depth 2` — never via the classifier's own
   judgment call on a question it isn't already confident about.

   **Decision**: route `"medium"` confidence to depth 2 instead of depth 3 — `DepthHeuristics`'
   fixed patterns can't cover the open-ended space of real user questions, so a classifier that
   is merely uncertain (not clueless) should get real tool evidence before anything is paid for
   or delegated, rather than skipping straight past it. `"low"` confidence (and a timed-out
   fallback, treated as `"low"`) still escalates all the way to depth 3, unchanged — a
   classifier that can't even guess still gets the full-confidence path. Implemented in
   `DepthModel.classify`, `DepthModelTests.testMediumConfidenceFallbackRoutesToDepth2`.

   **Re-verified live, same 13 questions, separately from M6** (real cost: $0.71, 18 turns, 1
   real Claude call — vs the original run's $6.08/235 turns/9 Claude calls). Depth distribution
   flipped as intended: 3 depth 1, 9 depth 2, 1 depth 3 (previously 4/0/9). Net effect is a real
   trade-off, not a strict improvement:
   - **Cost dropped ~88%** and **epistemic honesty measurably improved**: questions that
     previously got a confidently-wrong `verified` depth-1 answer (CU-08's 302-vs-307, DC-02's
     missing `TestClient` mechanism) now land on depth 2 and — even on the turns where the local
     model still answers directly with **zero tool calls** — correctly come back `unverified`
     instead of `verified`, because a depth-2 claim is always asserted and evidence-checked
     (`AgentSession`'s `assertClaim` logic) rather than silently skipped the way depth 1's is.
     The wrong content didn't get better, but it stopped being mislabeled as checked.
   - **Real quality regression on questions that need genuine investigation.** AR-01, AR-06,
     BR-02, BR-03, and XF-07 previously reached depth 3 and got excellent, thoroughly-grounded
     Claude answers (12-20 claims each); this run they landed on depth 2 instead, and the local
     model chose to answer directly with **no tool calls at all** on 7 of the 9 depth-2
     questions — producing generic or outright hallucinated content (BR-02 invented a
     `HTTPEndpoint.method_not_allowed()` method that doesn't exist; BR-03 repeated the
     302-vs-307 error) that is honestly labeled `unverified` but is a real step down from what
     Claude delegation previously produced for the same questions. Only 2 of 9 depth-2 answers
     (XF-04, DC-05) actually invoked a tool, and both were correctly grounded and free.
   - **The local classifier's confidence is noisy run to run, not just question to question.**
     CU-07 reported `"medium"` in the first run (escalated to depth 3, got a correct, grounded
     answer) and `"high"` in this run (stayed at depth 1, got a wrong, hallucinated one — the
     same `ThreadPoolExecutor`/"runs concurrently" error pattern as CU-01/CU-05/CU-08). Same
     question, same model, different confidence reading — depth 1's reliability problem (Risk #5)
     is not confined to a fixed set of questions and is not fixed by this routing change at all,
     since it only ever touches `"medium"`, not `"high"`.

   **Conclusion (superseded by the follow-up below)**: the decision was confirmed as a net
   improvement in cost and honesty, exactly as intended, but traded away real answer quality on
   hard questions rather than recovering it — because reaching depth 2 didn't make the local
   model actually *use* its tools; it only made an ungrounded answer at that depth get flagged
   instead of trusted.

   **Follow-up, implemented and re-verified live a third time**: `ActionLoop` now enforces an
   attempted tool call rather than merely asking for one in the prompt. When a budget>0 loop's
   model tries to `"answer"` without ever having called a tool, the loop rejects it once with a
   corrective re-prompt ("you must call at least one tool before answering") instead of
   returning it; if the model still refuses after that one nudge, the answer is accepted but
   marked `partial: true`. Waived entirely when no tools are configured at all (nothing to
   require a call to). Bounded by construction — one nudge, never an infinite loop — verified in
   `ActionLoopTests` (`testAnswerWithoutToolCallIsNudgedThenAccepted`,
   `testAnswerAfterNudgeStillMakesNoToolCallsWhenModelRefusesTwice`,
   `testAnswerWithoutToolCallIsAcceptedWhenNoToolsAreConfigured`).

   Re-ran the same 13 questions live a third time (real cost: **$0**, all 13 landed on depth 1
   or 2, none reached depth 3 this run — the local classifier's confidence is noisy enough that
   which questions escalate varies run to run, as already noted above). Real, measured effect:
   **10 of the 11 depth-2 answers now actually called a tool** (up from 2 of 9 without
   enforcement); the eleventh (DC-02) tried to call one but got the JSON action's field name
   wrong (`{"action": "lookup_symbol", ...}` instead of `{"action": "call_tool", "tool":
   "lookup_symbol", ...}`), which the loop correctly treats as an unparseable action rather than
   a valid tool call or a valid answer — a separate, pre-existing gap (no corrective nudge for a
   *malformed* tool-call attempt, only for a bare answer), not something this change addresses.

   Tool use went up sharply, but this did **not** turn out to be a strict quality fix, and the
   real reasons why are themselves useful findings:
   - **Some questions have no answer inside the tools this system offers at all.** CU-08 (default
     status code) and BR-03 (a constructor parameter's effect) both called tools 1-3 times and
     still got the wrong answer (302, not 307) — `lookup_symbol`/`module_symbols`/`callers`/
     `callees` expose symbol *existence and relationships*, never a function's actual default
     parameter values or body. No amount of forcing a call fixes a question the available tools
     structurally cannot answer; that needs a `read_source`-shaped tool, not more insistence.
   - **A grounded claim's evidence anchor resolving is not the same as that claim's *content*
     being correct.** XF-07 called `callers` on `Starlette.__call__`, got back a real anchor, and
     was ingested as `verified` — while its answer still confabulated a nonexistent `ASGIRunner`
     class. `SemanticImporter`'s evidence resolution (Docs/11 "step 2") only ever checks that a
     cited anchor *exists*, never that the claim's statement is actually what that anchor shows.
     This limitation predates today's change (it's true of every depth and of Claude-delegated
     answers too) but forcing more tool calls made it visible here for the first time in this
     document — a real, deeper gap worth its own follow-up, well beyond today's scope.
   - **Quality on genuinely broad questions (AR-01, AR-06, XF-01) improved but still didn't match
     depth 3.** All three now cite at least one real anchor and read noticeably better than the
     zero-tool-call run, but none approached the 12-20-claim, fully-traced answers Claude
     produced for the same questions — a single local tool call surfaces one relevant symbol,
     not the kind of multi-step investigation Claude's agentic loop does across a whole
     conversation.

   **Revised conclusion**: worth keeping — it measurably increases genuine tool use and doesn't
   regress anything (bounded, waived when no tools exist, all existing tests still pass) — but
   it is not a substitute for depth 3 on questions that need either real source-reading (not
   just symbol lookup) or genuinely multi-step investigation. Both remaining gaps are now
   concretely identified rather than assumed away, which is the actual value of having verified
   this live instead of stopping at the code change.

   **Second follow-up: make retrieval and evidence verification explicit parts of the system,
   not things the model is asked to infer.** Decided directly against the two gaps above —
   "some questions have no answer inside these tools" and "a resolved anchor isn't the same as
   a supported claim" — six concrete items, ① kept as a no-op, ②-⑤ implemented, ⑥ re-run live a
   fourth time to check the actual effect:

   - **① Keep the current workaround.** No further effort on native `mlx-swift-lm` tool-calling
     for `Qwen3-8B` — unchanged, Risk #3 already settled this.
   - **② Formalize the context-request protocol — tiny, deterministic, tolerant.** A stricter
     schema wouldn't have helped: the model already had the correct
     `{"action": "call_tool", "tool": "<name>", "arguments": {...}}` shape in its instructions
     and still, live, produced `{"action": "lookup_symbol", "query": "ServerErrorMiddleware"}`
     instead (DC-02, the earlier re-verification run). `ActionLoop.resolveToolCall` now
     tolerates this specific, observed confusion deterministically — if `action` itself names a
     configured tool, the rest of the JSON object is passed through as that tool's arguments —
     rather than dropping the turn as an unrecognized action. `ActionLoopTests
     .testActionNamedDirectlyAsToolIsTolerated`.
   - **③ Add explicit tool capability / "cannot provide" metadata — addresses CU-08/BR-03 at the
     architectural level.** Phase 1 already extracts and stores `signature`/`docstring` per
     symbol (`symbols.signature`/`symbols.docstring`); no tool exposed them until now. New
     `QueryEngine.symbolDetail(anchor:commit:)` + `SymbolDetailTool` ("symbol_detail") return a
     symbol's exact signature/docstring by anchor — confirmed live against the real repo that
     `starlette/responses.py::RedirectResponse.__init__`'s signature literally contains
     `status_code: int = 307`, the exact fact CU-08 needed and could never reach through
     `lookup_symbol`/`module_symbols`/`callers`/`callees` alone. When an anchor doesn't resolve,
     or resolves but has neither, the tool returns a result prefixed with a new shared marker,
     `AgentToolNotice.notAvailablePrefix` ("NOT AVAILABLE: ") — a third, explicit outcome
     alongside a real answer and an `"Error: ..."` (bad arguments), so "I looked, it isn't here"
     is distinguishable from both "you asked wrong" and "here's what I found." Five tools now,
     not four; `QueryEngineToolsTests` (4 new cases).
   - **④ A retrieval loop with missing-information tracking (the budget itself was already
     hard).** New `MissingInformation.extract(from:)` scans a tool-call trace for
     `AgentToolNotice.notAvailablePrefix` results, parallel to `EvidenceAnchors`' scan for real
     ones. `AgentSession` now folds these straight into the local candidate's `uncertainties`
     array (previously always `[]` for depth 1/2 — only Claude's own contract ever populated
     it), which `SemanticImporter` already turns into `UNKNOWN`-type claims. A local answer can
     now say "I don't know" as a first-class, persisted outcome instead of that gap only ever
     showing up as a wrong guess. `MissingInformationTests`,
     `AgentSessionTests.testForceDepth2ToolNotAvailableBecomesAnUncertainty`.
   - **⑤ Redesign `SemanticImporter` verification — distinguish anchor resolved from claim
     supported by anchor. Addresses XF-07.** New `SemanticDiagnostic
     .claimEvidenceUnrelatedToStatement` case: after step 2's evidence resolution (does the
     anchor exist? — unchanged), a new check asks whether the claim's own `statement` text
     mentions, case-insensitively, at least one dotted-name token from at least one of its
     evidence anchors. Deliberately a shallow, honestly-described proxy — lexical co-occurrence,
     not semantic entailment — recorded as a new, purely-informational `CLAIM_EVIDENCE_UNRELATED`
     diagnostic (never changes `claimType` or outcome by itself, so it adds visibility without
     asserting a falsity this cheap a check can't actually prove).
     `AgentAnswerImporterTests.testIngestAnswerFlagsClaimTextUnrelatedToItsEvidence`.
   - **⑥ Re-run and classify.** Ran the same 13 questions live a fourth time (real cost: **$0**
     again — no question escalated to depth 3 this run, the classifier's noise cuts both ways).
     Six-stage classification, one row per question (Retrieval decision: did it try a tool at
     all past depth 1? Retrieval selection: was the *right* thing asked for? Tool capability:
     could any tool in this set have answered even if asked perfectly? Evidence resolution: did
     the cited anchor(s) resolve? Claim grounding: does the claim's own text connect to that
     evidence, per item ⑤'s new check? Final answer: correct against the benchmark's
     `expected_answer`, checked by hand):

     | id | decision | selection | capability | evidence | grounding | answer |
     |---|---|---|---|---|---|---|
     | CU-01 | no (depth 1) | — | — | — | — | **wrong** — generic, never names `ServerErrorMiddleware`/`ExceptionMiddleware` or the reversal |
     | CU-05 | no (depth 1) | — | — | — | — | **wrong** — omits `_stream_consumed`/`RuntimeError`, wrongly says a re-read "returns nothing" |
     | CU-07 | no (depth 1) | — | — | — | — | **wrong** — implies threadpool-parallel execution; real behavior is sequential |
     | CU-08 | yes | **wrong** — asked `symbol_detail` for the class, not `.__init__` | yes (would have worked if asked right) | not available (honestly reported) | n/a | **wrong** — still 302, real default is 307 |
     | XF-01 | yes | reasonable (`callers`) | insufficient alone (a single edge query can't trace multi-hop exception flow) | resolved, but result was empty | supported (arg-anchor only) | partial — right shape (500 via default handler), doesn't name `ServerErrorMiddleware` |
     | XF-04 | yes | good, real results | insufficient (shows *who calls it*, not the internal guard) | resolved | **flagged unrelated** (new ⑤ check) | partial — captures "frozen after init," misses the exact `self.middleware_stack is not None` check |
     | XF-07 | yes | reasonable | insufficient (symbol listing, no behavior) | resolved (33 anchors) | **contradicted** (pre-existing >=2-evidence check) | **wrong** — fabricates a real-but-unrelated `ASGIRunner` class from `benchmarks/` |
     | AR-01 | yes | reasonable | insufficient (one module's symbol list can't cover a whole architecture) | resolved (broad) | **contradicted** | partial — correct components named, less complete than depth 3's version |
     | AR-06 | yes | reasonable | insufficient | resolved | **contradicted** | reasonable — a defensible, different file list, not wrong |
     | DC-02 | yes | reasonable (`lookup_symbol`) | insufficient (existence, not the `TestClient`/`raise_server_exceptions` interaction) | resolved | supported | incomplete — never reaches the actual mechanism asked about |
     | DC-05 | yes | good | insufficient (existence/location, not the exact `render()` call) | resolved | supported | reasonable — correct real test files named, right high-level impact |
     | BR-02 | yes | **good — used `symbol_detail` correctly** | partial (signature has no body, so *what* `dispatch` does still isn't shown) | resolved | supported | partial — a real, valid alternate code path, not the benchmark's canonical one |
     | BR-03 | no (depth 1) | — | — | — | — | **wrong** — says 301/302, real default is 307 |

     Reading the table: **every depth-1 row is wrong**, confirming Risk #5 is untouched by any
     of today's work. Among depth-2 rows, retrieval *decision* is now reliably "yes" (item ②/the
     tool-call requirement), but retrieval *selection* is still hit-or-miss — only CU-08 and
     BR-02 asked for a signature at all, and only BR-02 asked for the *right* one. No row was
     blocked by tool *capability* in the sense of "the toolset fundamentally cannot express
     this" (③'s `symbol_detail` closes exactly that gap for parameter-default questions) — every
     remaining miss is a selection or synthesis problem, not a missing capability, which is a
     narrower and more tractable remaining problem than where this started. The two `⑤`-style
     mechanisms (the pre-existing `>=2`-evidence `CONTRADICTED` check and the new single-evidence
     `CLAIM_EVIDENCE_UNRELATED` diagnostic) together caught 4 of the 13 answers' evidence as
     disconnected from their own prose — real signal, not theoretical: XF-07's fabrication would
     have been persisted as a plain, confident `verified` claim without them.

   **FINAL DECISION — ②③④⑤ reverted; ① and the tool-call requirement are what actually
   ships.** Items ②-⑤ above are a real historical record (each was implemented, tested, and
   verified live — the table above is genuine data, not hypothetical) but **are not in the
   codebase any more**. Explicit call, made after this whole risk's arc: an 8B local model
   cannot be made to reliably get retrieval *selection* right through more scaffolding — the
   six-stage table's own verdict was "capability is no longer the blocker, selection still is,"
   and selection is a model-judgment problem, not a wiring problem. Chasing it further (a
   smarter tool-selection prompt, more tool metadata, a second-guessing pass) is the same
   diminishing-returns spiral ②-⑤ already were one iteration of — more moving parts for the same
   underlying 8B ceiling. Stopping here, deliberately, rather than continuing to optimize for
   behavior this size of model won't reliably deliver:

   - **Kept**: `DepthModel` routing `"medium"` confidence to depth 2, not depth 3 (the first
     follow-up above) — real, measured, and orthogonal to everything below it.
   - **Kept**: `ActionLoop`'s enforced tool-call requirement (one corrective nudge, `partial` if
     still refused, waived when no tools exist) — cost-free (local model, no extra API spend),
     bounded by construction, and its value is independent of whether the resulting *content* is
     always right: it converts a silently-wrong `verified` depth-1-shaped guess into a
     `partially_verified`/`unverified` one at depth 2, which is a genuine, permanent epistemic
     improvement (Docs/04's whole premise — surfacing uncertainty honestly — matters more here
     than raw answer accuracy from a model this size ever will). Without it, depth 2 frequently
     collapses into depth 1 with extra ceremony, which would make the three-tier design
     incoherent.
   - **Reverted**: `ActionLoop`'s action/tool-name tolerance (②), `symbol_detail` +
     `AgentToolNotice`/"NOT AVAILABLE" (③), `MissingInformation`/`uncertainties` wiring (④), and
     `SemanticDiagnostic.claimEvidenceUnrelatedToStatement`/`CLAIM_EVIDENCE_UNRELATED` (⑤) — back
     to exactly the state right after the tool-call requirement alone landed. `QueryEngineTools`
     is four tools again; `AgentSession`'s local candidates never populate `uncertainties`.
     **Not** because any of them was broken — every one passed its own tests and its live
     verification — but because the six-stage table they produced showed the *next* bottleneck
     (selection) sitting past where this architecture can reliably reach with an 8B model, and
     Docs/03's own native-tool-calling lesson (Risk #3) already established the principle this
     follows: know where the model's ceiling is and design around it, rather than layering more
     scaffolding onto a size of model that cannot make good use of it.
   - **Unresolved, by design, not by oversight**: Risk #5 (depth-1 answers are unreliable and
     labeled `verified` regardless) and the CU-08/BR-03-style "the right *fact* exists in
     `signature`/`docstring` but nothing reliably finds it" gap. Both are real; neither gets
     fixed by continuing this specific line of work, and Phase 4's UX layer (how a `verified`
     label is *presented*) is a more promising place to spend effort on the former than another
     Phase 3 mechanism would be.

   Verified: 254 tests, 0 failures, after the revert — the exact count from immediately after
   the tool-call requirement landed, confirming the revert is clean and nothing else regressed.
