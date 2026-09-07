# 13 — Phase 4: Architecture UI (Development Plan)

> Status: **M0-M8 done — this plan's full implementation order is complete.**
> `OrionApp.xcodeproj` (target/scheme `Orion`) builds and runs end to end: open a repository →
> analyze it with live progress → optionally build a real Claude Code semantic model → explore
> it as a Grape architecture diagram (with a fully-accessible List fallback) → tap a node for a
> real Component Exploration card → click an evidence anchor for a real source-snippet view →
> ask an arbitrary question and get a real, depth-routed answer (local Qwen3-8B or Claude Code
> delegation) with its own clickable evidence — a real app icon, About panel, and README included
> — 88 passing tests, plus real bugs found live and fixed after M5 (a repository-reopen crash,
> and a GUI-app `PATH` gap breaking Claude CLI invocation, hit and fixed twice — once for "Build
> Architecture Model," once for "Ask," both through the same `ClaudeBinaryLocator`). See each
> milestone's own entry below. Depends on Phase 1
> ([10_phase1_deterministic_code_intelligence.md](10_phase1_deterministic_code_intelligence.md),
> complete), Phase 2
> ([11_phase2_semantic_analysis.md](11_phase2_semantic_analysis.md), complete), and Phase 3
> ([12_phase3_mlx_agent.md](12_phase3_mlx_agent.md), complete — M0-M6, 261 tests). Milestone
> entries below gain `[done]` markers and real findings as each is actually built, the same way
> Docs 10-12 did.

## Context

Phases 1-3 built a complete, tested, CLI-only backend: `orion-index` (Code Graph: files,
symbols, relationships — all `FACT`-tier) and `orion-agent` (Depth Model routing, local
Qwen3-8B answering, Claude Code delegation, semantic components/claims/evidence). Both are
libraries (`OrionCodeIntel`, `OrionAgent`) plus thin CLI wrappers, deliberately built with **no
AppKit/SwiftUI, no stdout/`exit`** — Docs 10 and 12 both say so explicitly, precisely so a UI
target could depend on them directly. Phase 4 is that UI, per
[08_development_phases.md](08_development_phases.md):

```
Build:
- architecture overview
- component cards
- relationship visualization
- evidence view
- confidence and uncertainty
```

and per [05_user_flow_and_ux.md](05_user_flow_and_ux.md) Stages 1-5 + 8 (Stage 6 — continuous
model-update UX — is Phase 6; Stage 7 — teaching — is Phase 7).

Goal: give a developer the actual product experience described in Docs 01/05 —
open a repository, watch it get analyzed, see an architecture overview with evidence and
confidence attached to every claim, explore components, and ask questions that are answered by
the *minimum* computation needed (Docs/03's adaptive-compute principle) — **without** exposing
the routing/agent machinery underneath, per Docs/05 §8's "expose epistemic transparency, hide
computational complexity." This is also the first real test of **H7** (epistemic transparency
beats exposing raw agentic traces for trust) — Phase 4 is the first time anything Docs/04's
FACT/INTERPRETATION/INFERENCE/UNKNOWN/CONTRADICTED vocabulary is *shown to a person* instead of
only stored.

### What Phase 4 is not

- Not a routing-quality benchmark. Phase 5.
- Not the continuous-model-update diff UX ("Understanding updated / Previously / Now / Reason",
  Docs/05 Stage 6) or contradiction-resolution workflow. Phase 6. Phase 4 shows a `CONTRADICTED`
  claim as a fact of the current model's state; it does not build the revision-history/diff view.
- Not teaching mode (Docs/05 Stage 7). Phase 7.
- Not real multi-turn conversational memory. `AgentSession.ask(_:)` stays one self-contained
  question per call (Docs/12 "What Phase 3 is not"); Phase 4 keeps a UI-local
  transcript of past Q&As for readability, but does not add cross-question agent state — that
  would be new Phase 3 mechanism disguised as a UI feature.
- Not a rewrite or behavioral change of `orion-index`/`orion-agent`. Both CLIs keep working
  exactly as documented in Docs 10-12; the app links the same libraries in-process instead of
  shelling out to them, the same way `orion-agent`'s `AgentSession` already links
  `OrionCodeIntel` in-process rather than calling `orion-index` as a subprocess.
- Not App Store distribution. A locally-run developer utility, signed for local execution — see
  Decision 2 and Risk 1 below.

### Decisions (made with the user)

1. **New Xcode project, not a 4th SwiftPM executable target.** `OrionApp.xcodeproj` at the repo
   root (sibling to `OrionMacOs/`), with a single macOS App target ("Orion") that adds
   `OrionMacOs` as a local Swift Package dependency and links `OrionCodeIntel` + `OrionAgent`.
   This produces a real, signed `.app` bundle (icon, `Info.plist`, entitlements) — the standard
   shape for a distributable macOS app and exactly what Docs 10
   ("no SwiftUI/app target (that is Phase 4)") and Docs 12 ("the same binary family... that
   Phase 4's Xcode app target will eventually depend on") both anticipated. `OrionMacOs/`'s own
   `Package.swift` is untouched — the app target's dependencies (SwiftUI, AppKit, the diagram
   library from Decision 3) live in the Xcode project, not in `OrionCodeIntel`/`OrionAgent`,
   preserving Phase 1/3's "no AppKit/SwiftUI in the library" discipline.
2. **Repository input: local path or a GitHub URL, and the app clones the URL itself.** Closer to
   Docs/01's literal user journey ("GitHub Repository" is step one) than local-path-only. A new
   `RepositoryCloner` (app-target only, `Process`-based, modeled directly on `OrionAgent`'s
   `ProcessRunner` watchdog-timeout pattern from Docs/12 M3) runs `git clone --depth 1 <url>
   <dest>` into an app-managed cache directory before handing the resulting local path to the
   existing `AnalysisPipeline`, unchanged. **v1 scope is public HTTPS URLs only** — no
   credential/PAT flow, no SSH — see Risk 3.
3. **Relationship/architecture diagrams: a third-party SwiftUI graph-layout package**, not a
   hand-rolled `Canvas` layout. **`SwiftGraphs/Grape`** (`github.com/SwiftGraphs/Grape`),
   pinned `from: "1.1.0"` — **verified at M0 against the real tagged source**, not vendor docs
   (Docs/12's own M0 lesson: check the actual tagged `Package.swift`, don't trust a second-hand
   summary). Real findings: swift-tools-version 5.9, platforms macOS 14 / iOS 17 / watchOS 10
   (comfortably under this project's `.macOS(.v26)` floor), products `ForceSimulation` +
   `Grape` (depends on `ForceSimulation`), API confirmed from the real `1.1.0` README:
   `ForceDirectedGraph`/`NodeMark`/`LinkMark`/`ForceDirectedGraphState`. Resolved and built
   cleanly against `OrionMacOs` at M0 with no version conflicts. If it later turns out
   unsuitable in practice (API friction building M4's real diagram, accessibility gaps), fall
   back to a hand-rolled `Canvas` layout — the component/relationship counts Phase 2 actually
   produces (~10 components, ~17 relationships on Starlette) are small enough that either
   approach is layout-wise sufficient.
4. **Unsandboxed app.** Phases 1-3 already shell out to `git`, `npx` (`scip-python`), and
   `claude` via `Process`, and `OrionAgent` downloads multi-gigabyte model weights from the
   Hugging Face Hub. macOS App Sandbox restricts child-process execution and network access
   tightly enough that reproducing all of that under sandbox entitlements would be a substantial
   new project on its own, disproportionate to what a local developer utility (Docs/01 — not an
   App Store product) needs. Ship signed for local execution (Developer ID or ad-hoc, per the
   user's existing signing setup), unsandboxed. Revisit only if the project later wants App Store
   distribution — see Risk 1.

---

## Project layout

```
Orion/                          (repo root)
  OrionMacOs/                   Package.swift -- unchanged by this phase
    Sources/OrionCodeIntel/     -- gains one additive change: Pipeline/AnalysisProgress.swift (M2)
    Sources/OrionAgent/         -- unchanged
  OrionApp/                     New. Owned by the Xcode project below.
    OrionApp.xcodeproj
    Orion/                      App target sources
      OrionApp.swift            @main App, single WindowGroup
      Repository/
        RepositorySession.swift        current repo: path/URL, output dir, analysis state
        RepositoryCloner.swift         git-clone Process wrapper (Decision 2)
        RecentRepositories.swift       small JSON file under Application Support, not the DB
      Ingestion/
        AnalysisRunner.swift           drives OrionCodeIntel.AnalysisPipeline on a background
                                        Task, maps AnalysisProgress -> Docs/05 Stage 2 strings
        SemanticInvestigator.swift      [M3] app-local port of Phase 2's whole-repo investigation
                                        contract (investigate.py/schema.py) -- not
                                        OrionAgent.ClaudeCodeInvestigator, which answers a single
                                        question against a different schema (M3's own findings)
        SemanticInvestigationRunner.swift  drives SemanticInvestigator + SemanticImporter.ingest,
                                        gated behind an explicit user action + cost confirmation
      Model/
        CodebaseModelStore.swift       thin read-only wrapper over OrionCodeIntel.Store's
                                        existing read methods (Store already exposes
                                        symbols/relationships/components/claims/evidence/
                                        investigations -- no new Store API needed for reads)
        EpistemicTag.swift              FACT|INTERPRETATION|INFERENCE|UNKNOWN|CONTRADICTED ->
                                        display (color, icon, label) -- Docs/04's vocabulary,
                                        one mapping used everywhere
      Views/
        OpenRepositoryView.swift       Decision 2's local-path/GitHub-URL sheet
        AnalysisProgressView.swift     Docs/05 Stage 1-2
        ArchitectureOverviewView.swift Docs/05 Stage 3 (M4)
        ComponentDetailView.swift      Docs/05 Stage 4 (M5)
        EvidenceView.swift             source-snippet panel (M5)
        AskView.swift                  Docs/05 Stage 4-5 question box (M7)
        Shared/EpistemicBadge.swift    (M6)
      Support/
        AppPaths.swift                 Application Support directory layout for cloned repos
  Tests/OrionAppTests/                 XCTest target (matches OrionMacOs's own convention),
                                        sibling to Orion/ inside OrionApp/, not the repo root
```

`OrionApp/` is a new top-level directory, sibling to `OrionMacOs/` and `Agent Feasibility
Study/` — not nested inside `OrionMacOs/`, since it is a separate Xcode project with its own
`.xcodeproj`, not an SPM target.

---

## Dependencies

| Package | Scope | Pin | Why |
|---|---|---|---|
| `OrionMacOs` (local) | Xcode project → local Swift Package dependency | path-based, no version | `OrionCodeIntel` + `OrionAgent`, linked in-process. |
| `SwiftGraphs/Grape` | Xcode project only (not `OrionMacOs/Package.swift`) | `from: "1.1.0"` — verified at M0 against the real tagged source (Decision 3) | Architecture/relationship diagram rendering. |

No new dependency touches `OrionCodeIntel` or `OrionAgent` — both stay AppKit/SwiftUI-free,
matching Docs 10/12's existing discipline, so `orion-index`/`orion-agent` remain buildable and
testable exactly as they are today regardless of what happens in `OrionApp/`.

---

## Additive `OrionCodeIntel` change (M2) [done]

`AnalysisPipeline.run(_:)` ran synchronously to completion with no progress signal — fine for a
CLI that prints a final `stats` summary, not enough for Docs/05 Stage 2's "Mapping repository
structure / Identifying components / Verifying dependencies / Building architecture" progress
text. Added exactly as planned, in a new `Pipeline/AnalysisProgress.swift`:

```swift
public protocol AnalysisProgressReporting: Sendable {
    func pipelineDidStart(stage: PipelineStageID)
}
```

`PipelineStageID` names the 8 stages (`.ingestion`, `.ast`, `.symbols`, `.imports`, `.scip`,
`.relationships`, `.testMapping`, `.assembly`) **in the order the real code executes them**, not
Docs/10's own numbering — the actual `AnalysisPipeline.run` runs the imports/dependency-graph
stage *before* SCIP resolution, the reverse of Docs/10's stage-4/stage-6 numbering; the enum
follows the code. `AnalysisPipeline.run(_:progress:)` gained the optional, defaulted
`progress: (any AnalysisProgressReporting)? = nil` parameter with 7 call sites inserted (one
per stage boundary in execution order); `.relationships` only fires inside the SCIP `.success`
case — there is no separate relationship-building work to report when SCIP is unavailable or
skipped. **Strictly additive**: every pre-existing call site (`orion-index analyze`, 4 test
files) keeps calling `.run(input)` positionally, unmodified.

**Verified live**: the complete pre-existing suite — **261 tests, 7 skipped, 0 failures** —
stays green after the change, exactly Docs/12's last recorded count. One real build-tooling
gotcha hit along the way, not a code problem: the first two `swift test` runs after this edit
failed to *link* with "symbol not found" for the *old* `run(_:)` signature, even though the
library itself had recompiled correctly — stale incremental-build object files for
`OrionAgentTests` (`ActionLoopLiveTests`, `AgentSessionTests`, `ClaudeCodeInvestigatorLiveTests`,
`QueryEngineToolsTests`) weren't invalidated by SwiftPM's own build-graph despite their
dependency's public interface changing. Fixed by `swift package clean` + a full rebuild, not by
touching any source; a second `swift test` alone (no clean) reproduced the identical stale
failure, ruling out a one-off fluke.

---

## Screens & flows (mapped to Docs/05)

### 1. Open Repository (Docs/05 Stage 1)

Segmented choice: local folder (`.fileImporter`) or GitHub URL (text field). A GitHub URL goes
through `RepositoryCloner` first; a local path is used as-is. Once resolved, the header shows
exactly Docs/05 Stage 1's four bullets: repository identity (path or URL), detected language(s)
(Python only, per Phase 1's current scope — the UI does not imply multi-language support that
doesn't exist yet), file/module count, analysis/readiness status. **Internal agent loops are not
exposed here** (Docs/05 Stage 1's own instruction) — no mention of tree-sitter, SCIP, or pipeline
stage names at this point.

### 2. Analysis (Docs/05 Stage 2)

`AnalysisRunner` drives `AnalysisPipeline` on a background `Task`, mapping each
`AnalysisProgress` callback to one of Docs/05's four progress strings (multiple internal stages
collapse onto each label — e.g. `.ast`/`.symbols` both read "Mapping repository structure"). A
"Details" disclosure (closed by default, Docs/05 §8) reveals the raw per-stage names and timings
for anyone who wants them. On completion, `AnalysisResult`/`GraphSummary` populate the Stage 1
header for real (actual file/symbol counts, actual resolver used — `scip-python@<ver>` or
`none`, surfaced honestly per Docs/06 §7's failure-transparency rule rather than hidden).

Building the **semantic** layer (Phase 2's Claude Code investigation) is a separate, explicit
action from this screen (or a toolbar item once analysis is done) — never automatic. Docs/06 §6
("respect account limits") and the real per-run costs Docs 11/12 measured ($0.17-$1.77 per
investigation) both argue against ever spending money without the user asking. The confirmation
sheet states the cost ceiling (`--max-budget-usd`, defaulting to Phase 3's own $1.00) before
`SemanticInvestigationRunner` invokes `SemanticInvestigator` (M3's app-local port of Phase 2's
whole-repo contract — not `OrionAgent.ClaudeCodeInvestigator`, which answers one question
against a different schema) + `SemanticImporter.ingest` in-process.

### 3. Architecture Overview (Docs/05 Stage 3, Docs/08 "architecture overview")

Grape-rendered node-link diagram:
- **With a semantic investigation**: nodes = `components` (sized by member count, colored by
  `confidence_tier`), edges = `component_relationships` (labeled by `relationship_type`; solid
  for `confidence_tier == high`, dashed for `unresolved` — an unconfirmed relationship is drawn,
  never hidden, per Docs/04 "contradictions stay visible").
- **Without one yet**: falls back to the Phase-1-only module dependency graph
  (`code_graph.json`'s `modules[]` import matrix) — architecture is explorable from `FACT`-tier
  structure alone; a semantic layer enriches it, it is never a hard prerequisite for anything in
  this screen.
- A visible, non-blocking banner states which layer is showing ("Structural view — no
  architecture investigation yet" vs. "Semantic view — N components, investigated <date>") so
  the epistemic status of what's on screen is never ambiguous.

Each node opens Component Exploration.

### 4. Component Exploration + Evidence (Docs/05 Stage 4, Docs/08 "component cards"/"evidence
view")

Component card mirrors Docs/05 Stage 4's own example layout exactly: Purpose (the `description`,
tagged `INTERPRETATION`), member list (grouped by `SymbolKind`), Dependencies
(`component_relationships`), Evidence (clickable anchors), Confidence (`confidence_tier` badge).
Clicking an evidence anchor opens a source panel: read the file from the analyzed checkout at
`repoRoot + anchor.file`, slice to the claim/member's line range, monospace + line numbers
(real syntax highlighting is a stretch goal, not required for v1 — Docs/08 asks for an "evidence
view," not a code editor). A component reached via the Phase-1-only fallback (no investigation)
shows its module/symbol membership plainly labeled as structural, not a semantic grouping.

### 5. Confidence & uncertainty (Docs/08, Docs/04 throughout)

One shared `EpistemicBadge` (color + icon + label for `FACT`/`INTERPRETATION`/`INFERENCE`/
`UNKNOWN`/`CONTRADICTED`) used on every claim, relationship, and component wherever it appears —
this is the one hard rule Docs/04 states outright ("The UI must not present inference as fact"),
so it is a single shared component, not five ad-hoc renderings. Each investigation's
`uncertainties[]` (imported as `UNKNOWN` claims, Docs 11) surface as a visible "Open questions"
list on that component/investigation, not buried behind a disclosure. `CONTRADICTED` claims stay
visible with their own distinct treatment rather than being filtered out.

### 6. Ask (Docs/05 Stage 4-5, Docs/08's adaptive-exploration UX)

A question box wired directly to `AgentSession.ask(_:)` — in-process, no CLI
subprocess. Renders `AgentSessionResult`: answer text, per-claim `EpistemicBadge`s, evidence
links (reusing the same Evidence view as M5). **A depth-1 (`claimCount == 0`) "verified" answer
gets a visibly different treatment from a grounded depth-2/3 one** — e.g. "Not independently
checked" instead of a green checkmark — directly implementing the fix Docs/12 Risk #5 explicitly
deferred to Phase 4 ("depth 1's `verified` outcome should not be presented to a user the same
way a grounded depth-2/3 `verified` is... worth a UX-level distinction in Phase 4"). Routing
decision and tool-call trace are hidden by default; an "Explain" disclosure mirrors
`orion-agent ask --explain` (Docs/05 §8's advanced diagnostic view). The screen keeps an
in-memory list of past Q&As for this repository session (a UI-only transcript, not new agent
state — each question is still an independent `AgentSession.answer` call).

---

## Testing & verification

**Unit (`OrionAppTests`, no UI rendering, no live model/network)**

- `RepositorySession` state transitions (idle → cloning/opening → analyzing → ready → error) for
  every input combination (valid local path, missing path, valid GitHub URL, malformed URL,
  clone failure, analysis pipeline failure).
- `RepositoryCloner`: argument construction (`git clone --depth 1 <url> <dest>`), timeout
  behavior — reuse `OrionAgent`'s `ProcessRunnerTests` pattern (a real short-lived process
  against a short timeout), not a re-derived mechanism.
- `AnalysisRunner`'s stage→progress-string mapping is a pure function — table-tested against
  all 8 `PipelineStageID` cases.
- `EpistemicBadge`'s claim/component → (color, icon, label) mapping is a pure function — table-
  tested against all 5 vocabulary values, including that `CONTRADICTED` and `UNKNOWN` are never
  styled indistinguishably from `FACT`.
- `CodebaseModelStore`'s read wrappers against a real small analyzed fixture repo (reuse Phase
  1/2's fixture pattern) — no new persistence logic, so this is mostly confirming the wrapper
  passes `Store`'s existing methods through correctly.
- Depth-1-vs-grounded answer treatment: given a synthetic `AgentSessionResult` with
  `claimCount == 0` vs. `> 0`, the correct badge/label is chosen — the actual UX fix Risk #5
  exists to make, tested as a pure function of the result struct.

**Manual, per milestone (not CI)** — launch the real app (`xcodebuild -project
OrionApp.xcodeproj -scheme Orion -destination 'platform=macOS' build`, run the produced `.app`)
against vendored Starlette, screenshot each new screen, confirm against the Docs/05 stage it
implements. `OrionAgent`'s existing MLX/`xcodebuild`-only build requirement
(`OrionMacOs/README.md`) carries over unchanged — the app target needs the same `xcodebuild`
path, not plain `swift build`, for the same Metal-shader reason.

**CI**: `OrionApp.xcodeproj` gets a build-only CI job (`xcodebuild build`, no `test`) as a
starting point — full UI test automation (screenshot diffing, accessibility snapshot tests) is
an open item, not required to ship M0-M8; live-model and live-`claude` paths stay excluded from
CI exactly as they already are for `OrionMacOs`.

---

## Implementation order

- **M0 — Xcode app shell. [done]** No `xcodegen`/`tuist` was present in the environment; installed
  `xcodegen` (Homebrew, `2.46.0`) rather than hand-writing a `.pbxproj` — a project spec
  (`OrionApp/project.yml`) is the source of truth, regenerated with `xcodegen generate`; the
  generated `OrionApp.xcodeproj` is committed too so cloning and opening in Xcode doesn't require
  `xcodegen` installed. Grape verified against its real tagged `1.1.0` source (Decision 3) — see
  the Dependencies table above — and added directly; no fallback needed. Single macOS App target
  `Orion`, local package dependency on `OrionMacOs` (`OrionCodeIntel` + `OrionAgent`), deployment
  target macOS 26.0 (matches `OrionMacOs/Package.swift`'s `.macOS(.v26)` floor). Unsandboxed (no
  entitlements file, `ENABLE_APP_SANDBOX: NO`); signed ad-hoc (`CODE_SIGN_IDENTITY: "-"`,
  `CODE_SIGNING_REQUIRED: NO`) since no Apple Developer Team is configured in this environment —
  switch to a real team/Developer ID in Xcode's Signing & Capabilities tab whenever distribution
  is actually needed. `ContentView` renders the empty state (Docs/05 Stage 1's "no repository
  open" starting point) with a toolbar "Open Repository…" action (still a no-op, wired in M1) and
  a small footer that calls real, side-effect-free API from both linked libraries
  (`OrionCodeIntel.version`, `DepthHeuristics.classify(_:)`) rather than merely declaring the
  dependency — proof of real linkage, not just package resolution.

  **Verified live**: `xcodebuild -project OrionApp.xcodeproj -scheme Orion -destination
  'platform=macOS' build` resolved all 21 transitive packages (including `mlx-swift-lm`
  3.31.4 and its own dependents) against `OrionMacOs`'s existing pins with zero conflicts, and
  **`** BUILD SUCCEEDED **`** with zero warnings/errors in any Orion-authored code (the only 5
  warnings are pre-existing upstream noise: 4 from `mlx-swift`'s own vendored Metal-shader C++
  headers, 1 from Xcode's AppIntents metadata processor correctly noting we don't use
  AppIntents). This also confirms building through an actual Xcode project — which is what this
  whole phase does by construction — compiles `mlx-swift`'s Metal shaders correctly, the exact
  thing Docs/12's README note says plain `swift build`/`swift run` cannot do; Phase 4 does not
  need to rediscover or work around that gotcha itself. Launched the real produced
  `.app` (`open .../Orion.app`): the process stayed up (no crash), and a screenshot confirmed a
  real window titled "Orion" showing the empty state and toolbar button, with the footer reading
  "OrionCodeIntel 0.1.0 · OrionAgent linked (sample depth: 1)" — `DepthHeuristics` correctly
  classified the sample question ("What does AuthService do?") as depth 1, matching Docs/03's own
  worked L1 example exactly.
- **M1 — Repository input & session model. [done]** `RepositorySession` (`@Observable`,
  `idle -> opening -> analyzing -> ready`, `failed` reachable from any step), `RepositoryCloner`
  (public-HTTPS-only `git clone --depth 1`, reusing `OrionAgent.ProcessRunner` directly rather
  than re-implementing its watchdog-timeout/pipe-draining logic), `RecentRepositories` (JSON
  under Application Support), `OpenRepositoryView` (segmented Local-Folder/GitHub-URL sheet +
  recents list), `AppPaths` (stable content-addressed clone destinations via `CryptoKit.SHA256`).
  `RepositorySession.open(_:)` drives `idle -> opening -> analyzing`/`failed` for real (local-path
  validation or a real clone); `analysisSucceeded`/`analysisFailed`/`reset` are the seam M2's
  `AnalysisRunner` will call from outside once it exists — M1 already defines and tests all five
  states, per the plan. New Xcode test target `OrionAppTests` (added to `project.yml`,
  `GENERATE_INFOPLIST_FILE: YES` needed on it too, matching the app target). **26 tests, 0
  failures**: `RepositorySessionTests` (11 — every state-machine transition the plan called for:
  valid local path, missing path, path-that's-a-file, valid GitHub URL via a fake cloner, cloner
  validation failure, clone failure, analysis success/failure, reset, the `.orion` output-dir
  convention), `RepositoryClonerTests` (7 — non-HTTPS/no-host rejection, missing-`git` error, a
  stand-in `git` shell script asserting the exact `clone --depth 1 <url> <dest>` argv and that an
  existing checkout short-circuits without invoking git at all, non-zero exit, and a real 1s
  timeout against a `sleep 5` stub — same pattern `ClaudeCodeInvestigatorTests`/`ProcessRunnerTests`
  already established, no live network call anywhere in the suite), `RecentRepositoriesTests` (5),
  `AppPathsTests` (3).

  **Verified live**: `xcodebuild ... test` — real gotcha, not anticipated in the plan: `xcodebuild
  test` (unlike M0's plain `build`) re-triggers Xcode's package-plugin approval gate even with
  `-skipPackagePluginValidation`/`-skipMacroValidation` already passed for `build`; fixed by
  passing both flags to the `test` invocation too. A second real gotcha: the new
  `OrionAppTests` target failed to code-sign for testing with "target does not have an
  Info.plist file" — needed its own `GENERATE_INFOPLIST_FILE: YES`, not just the app target's.
  After both fixes: **`** TEST SUCCEEDED **`**, 26/26. Manually confirmed the actual UI too, not
  just the logic: launched the built `.app`, clicked the real toolbar button via `System Events`
  UI scripting, and screenshotted the "Open Repository" sheet mid-interaction — segmented
  control, "Choose Folder…" button, all rendering as designed.

  **Recurring gotcha, same as M0**: building/testing `OrionApp.xcodeproj` again dirtied
  `OrionMacOs/Package.resolved` with the same stray `Grape` pin (Risk 9) — reverted with `git
  checkout` again after confirming `swift package resolve` inside `OrionMacOs/` alone still
  reproduces the original file byte-for-byte.
- **M2 — Analysis run & progress. [done, revised post-M5 — see Risk 12]** `AnalysisRunner` now
  also detects and reuses an already-analyzed repository's existing run instead of blindly
  re-analyzing it (a real bug found live after M5, not part of M2's original scope). The additive `AnalysisProgressReporting` change to
  `OrionCodeIntel` (see its own section above — only change to Phases 1-3's libraries this whole
  phase makes, 261 pre-existing tests stay green). `AnalysisRunner` (drives
  `AnalysisPipeline.run` on a `Task.detached`, maps the real `AnalysisResult` into a fleshed-out
  `RepositorySummary` — languages/file/symbol/relationship counts, resolver, parse-error/
  diagnostic counts, total stage-timing ms — replacing M1's placeholder shape exactly as that
  milestone said M2 would; gained a `resolve: Bool = true` passthrough so tests can skip the
  `npx`/`scip-python` dependency the same reason `orion-index` itself has `--no-resolve`).
  `AnalysisProgressTracker` (`@Observable`, `@unchecked Sendable` + `NSLock` — the callback
  arrives from a background thread, same shape `OrionAgent.ModelDownloadProgressReporter`,
  Docs/12 M6, already established) maps `PipelineStageID` onto Docs/05's four progress strings.
  `AnalysisProgressView` (repo identity header + linear progress + a closed-by-default
  "Details" disclosure listing every raw stage/timestamp). `ContentView` gained a
  `.task(id: session.state)` that fires `AnalysisRunner.run` exactly when state becomes
  `.analyzing`, and a real populated `.ready` view (repo path, languages, file/symbol/
  relationship counts, resolver, parse errors/diagnostics if any, total analysis time) —
  Architecture Overview itself stays M4's job, but Stage 1's "readiness status" bullet is now
  real, not a placeholder.

  **8 new tests, 34 total, 0 failures**: `AnalysisProgressStageTests` (2 — every one of the 8
  `PipelineStageID` cases maps to its expected label, and a second test that fails loudly if a
  future stage is ever added to the enum without updating the mapping test), `AnalysisProgressTrackerTests`
  (3, incl. a real concurrent-callers check across a `DispatchGroup`), `AnalysisRunnerTests` (3 —
  a *real* `AnalysisPipeline` run against a real tiny fixture repo reaching `.ready` with real
  counts and `resolver == "none"` under `resolve: false`; every non-`.relationships` stage
  actually reported; a file-not-a-directory `repoRoot` correctly reaching `.failed`).

  **Verified live**: full `xcodebuild ... test` — **34/34, 0 failures, zero warnings** in any
  Orion-authored code. One pre-existing warning surfaced only now (M1's `RepositoryCloner`
  default `destinationDirectory` closure wasn't `@Sendable`, harmless under Swift 5 mode but
  flagged as "an error in Swift 6 mode") — fixed by marking it `@Sendable` and wrapping the
  default value as an explicit closure literal (a bare function reference,
  `AppPaths.clonedRepositoryDirectory(for:)`, still warned even once marked `@Sendable` at the
  parameter type). Manually re-confirmed the empty state and "Open Repository" sheet still
  render correctly after all the changes; a full click-through to a real `.ready` screen was
  attempted via `System Events` UI scripting but the NSOpenPanel's "Choose Folder…" button
  didn't respond to a name-based click (likely an accessibility-label/ellipsis-character
  mismatch) — not pursued further given `AnalysisRunnerTests` already exercises the identical
  real-pipeline-to-`.ready` path directly.
- **M3 — Semantic investigation trigger. [done]** **Real finding that changed the plan**: Phase
  3's `OrionAgent.ClaudeCodeInvestigator` turned out to implement a *different* contract than
  this milestone needs — it answers one question (`AgentAnswerSchema`/`phase3.v1`, ingested via
  `SemanticImporter.ingestAnswer`, never touching `components`/`component_relationships`).
  Phase 2's *whole-repo* component-grouping investigation (`SEMANTIC_SCHEMA`/`phase2.v1`, the
  contract `SemanticImporter.ingest()` actually populates `components` from) was only ever
  implemented in **Python** (`investigate.py`) — Phase 3 deliberately built a parallel Swift
  contract for its own single-question need rather than porting this one. Since M4's Architecture
  Overview needs real `components`/`component_relationships` rows to render at all, and this
  phase's own constraint is "no further changes to `OrionCodeIntel`/`OrionAgent`," the only
  correct option was a **new, app-local `SemanticInvestigator`** — ported field-for-field from
  `investigate.py`/`schema.py` (prompt, `SEMANTIC_SCHEMA` as a Swift `[String: Any]` literal,
  wrapper-parsing) the same way Docs/12 M3 itself ported Phase 2's CLI contract into
  `ClaudeCodeInvestigator` for the single-question case — reusing `OrionAgent.ProcessRunner`
  directly (the one piece that *is* shared) rather than duplicating its watchdog-timeout logic.
  `SemanticInvestigationRunner` drives it, writes the candidate (+ a hand-built meta JSON —
  `InvestigationMeta` is `Decodable`-only, no `Encodable`, so the sidecar is assembled as a plain
  `[String: Any]` rather than encoded from a value) to temp files under `<outputDirectory>/`, and
  calls `SemanticImporter.ingest(candidateURL:metaURL:run:now:)` in-process — no `orion-index`
  subprocess. `CodebaseModelStore` (thin read-only wrapper over `Store`'s existing methods, no
  new `OrionCodeIntel` API needed) and `BuildArchitectureModelSheet` (the cost-confirmation gate,
  stepper over `$0.25-$5.00`, states the real Phase 2/3-measured cost range up front) round out
  the milestone. `SemanticInvestigationSession` is a state machine deliberately separate from
  `RepositorySession`'s (`idle -> investigating -> completed`/`failed`) — a repository is fully
  explorable at `.ready` with zero investigations ever run, matching Docs/13's own design.

  **17 new tests, 51 total, 0 failures, zero warnings**: `SemanticInvestigatorTests` (8 — prompt/
  argument construction with no process launched; wrapper parsing via stand-in `claude` scripts:
  `structured_output` preferred over `result`-text extraction, `errors[]` surfaced, timeout,
  dominant-model-by-cost selection — mirrors `RepositoryClonerTests`'/Docs/12's own
  stand-in-script posture, no network, no real API cost anywhere in the suite),
  `SemanticInvestigationSessionTests` (5, pure state machine),
  `SemanticInvestigationRunnerTests` (4 — genuinely end-to-end: a **real** `AnalysisPipeline` run
  against a real fixture repo first, so real anchors exist to cite, then a stand-in `claude`
  script returning a real `phase2.v1` payload referencing those exact anchors, ingested via the
  real `SemanticImporter.ingest`, verified both via the returned summary and by reading the
  persisted `investigations` row back through `CodebaseModelStore`; an unresolvable-anchor case
  confirming a dropped component is reported as `.completed`, not mistaken for a crash; a
  `claude`-side error and a never-analyzed repo both correctly reaching `.failed`).

  **One real SwiftUI bug caught by the build, not by review**: `Text("Cost: \(cost, format:
  .currency(code: "USD"))" + (turns ?? ""))` doesn't compile — a `Text` string interpolation
  using a `format:` argument produces a `LocalizedStringKey`, which has no `+` operator with a
  plain `String`. Fixed by formatting the cost to a plain `String` first
  (`cost.formatted(.currency(code:))`) and interpolating two strings instead of concatenating a
  formatted `Text` literal with one.
- **M4 — Architecture Overview. [done]** **Grape's real per-mark API had to be verified from its
  actual source, not just its README** — the README's only full example uses `Int` node ids and
  shows no styling beyond `.foregroundStyle()`, and `LinkMark`'s label/stroke-color/dash-array
  *initializer parameters* are commented out in the real 1.1.0 source (a stub for a future
  version). Shallow-cloned the real tagged source to check: `NodeMark<NodeID: Hashable>` (a
  `String` id, as `CodebaseModelStore`'s ids already are, works directly — confirmed against the
  docc tutorial's own `NodeMark(id: "A")` example, not just the README's `Int` one); the
  solid-vs-dashed styling the plan called for turned out to be a `GraphContent.stroke(_:
  StrokeStyle?)` *modifier* (real SwiftUI `StrokeStyle`, `dash:` included) applicable to any
  mark, not a `LinkMark` init argument — so `.stroke(color, StrokeStyle(dash: [4,3]))` on each
  `LinkMark` does exactly what the plan needed, just via a different, real API shape. Tap-to-
  select uses `.graphOverlay { proxy in ... }` + `proxy.node(of: String.self, at:)`, confirmed
  against Grape's own Mermaid example, not guessed.

  `ArchitectureModel`/`ArchitectureModelLoader` (pure logic, no SwiftUI — Model/, per the
  project layout): loads the latest investigation's `components`/`component_relationships` when
  at least one component actually persisted, else falls back to the Phase-1-only module
  `imports` graph (`symbols` filtered to `kind == "module"/"package"`, `relationships` filtered
  to `type == "imports"` between two such symbols) — reading directly off `CodebaseModelStore`,
  no `code_graph.json`/JSONL round-trip, confirming Docs/13's own "no new export needed" design.
  **Docs/13's own docc-confirmed warning — "Grape does not protect you from linking to a
  non-existing node; the view crashes" — is treated as a hard invariant, not a suggestion**: both
  builders filter every edge to endpoints that exist among that same load's nodes (also dropping
  self-loops and de-duplicating parallel edges) *before* constructing `ArchitectureModel`, so
  `ArchitectureOverviewView` never has to re-check this itself. `ArchitectureOverviewView`
  renders the banner ("Structural view — no architecture investigation yet" /
  "Semantic view — N components, investigated <date>" — Docs/13's own exact wording), the
  diagram, and a minimal node-tap popover (`NodeQuickLookView`) as an explicit stand-in for real
  Component Exploration (M5) — not required by this milestone's own scope, added because Grape's
  tap-detection was already confirmed working and the cost was low. `ContentView`'s `.ready`
  state was restructured: the Architecture Overview is now the primary content, with the Docs/05
  Stage 1 stats/Build-Architecture-Model header (M2/M3) compacted into a bar above it (a
  `DisclosureGroup` for the full stat list) rather than a separate screen.

  **6 new tests, 57 total, 0 failures, zero warnings**: `ArchitectureModelLoaderTests` — no
  analyzed run -> empty structural model; a real two-module repo with a real `import` -> a
  correct 2-node/1-edge structural model, with every edge endpoint asserted to exist among the
  node set (the crash-prevention invariant, checked directly, not just trusted); a real
  investigation (via `SemanticImporter.ingest` directly, no `claude` stub needed — this test
  only cares what the loader does with already-persisted rows) -> correct semantic model with
  member counts as node size; a self-referential `component_relationship` correctly dropped, not
  passed to Grape; an investigation whose only component gets dropped for an unresolvable anchor
  (Docs/11 step 2) correctly falls back to the structural model rather than rendering an empty
  semantic one. **Grape itself compiled cleanly on this first real usage, zero warnings** —
  M0's build-only verification (linking, no actual marks/modifiers used yet) didn't exercise the
  parts of the API that mattered here.

  **Manual GUI verification was not completed this milestone** — after M2/M3 already found
  `System Events` unreliable against this SwiftUI app's custom controls (segmented picker,
  NSOpenPanel button), a further attempt here (coordinate-based clicking, `click at {x,y}`) also
  failed (`System Events got an error: -25200`), and the toolbar itself didn't consistently
  render across relaunches in these automation attempts. Given the crash-prevention invariant is
  directly unit-tested and Grape's exact API was verified against its real source (not guessed),
  this is judged sufficient without a visual screenshot of the live diagram; revisit with a real
  manual click-through (a human, not `osascript`) before relying on this milestone's visual
  polish specifically.
- **M5 — Component exploration + evidence view. [done]** `ComponentDetail`/
  `ComponentDetailLoader` (Model/, pure logic): for a semantic component, resolves
  `component_members` to real `SymbolRecord`s (grouped by kind), `component_relationships`
  where this component is the source, and — the one real design decision this milestone had to
  make since the schema has no `claims.component_id` column (Docs/11: a claim is investigation-
  scoped, not component-scoped) — a "Claims & Evidence" section built from a genuine data-derived
  link: any investigation claim whose evidence anchors intersect this component's own member
  anchors, not a fabricated association. For a structural (Phase-1-only) module node: same-file
  symbols as members, its own `imports` edges as dependencies, zero claims — and `isStructural`
  drives `ComponentDetailView` to plainly label it as such, per Docs/13's own instruction.
  `EvidenceSnippet`/`EvidenceSourceLoader` (Model/): reads the real file at
  `repoRoot/<anchor's file>`, slices to the cited range plus a few lines of context, clamped at
  file boundaries; no range known (a bare module anchor) falls back to a capped whole-file view.
  `ComponentDetailView`/`EvidenceView` (Views/): plain monospace + line numbers, highlighted
  range — Docs/08 asks for an "evidence view," not a code editor. `ArchitectureOverviewView`'s
  node-tap `.popover` (M4's `NodeQuickLookView` placeholder) is now a `.sheet` presenting the
  real `ComponentDetailView`, which itself sheets `EvidenceView` on any evidence click — the
  full explore-to-evidence chain Docs/05 Stage 3→4 describes now actually works end to end.

  **11 new tests, 68 total, 0 failures, zero warnings**: `ComponentDetailLoaderTests` (4 — a
  semantic component's members/dependencies/claims all correct, including that a claim citing
  *either* of a two-member component's anchors correctly surfaces (the overlap check isn't
  first-anchor-only); a claim citing a **different** component's member is correctly excluded;
  an unknown component id falls back to an empty detail rather than throwing; a structural
  module's same-file grouping and `imports`-derived dependency both correct), `EvidenceSourceLoaderTests`
  (7 — exact highlighted range plus context, context clamped at both file boundaries without
  under/overflowing, a capped whole-file view when no range is known, a missing file and an
  out-of-range start line both throwing the right typed error, the file path correctly split off
  an anchor's `::` separator).

  **Two real compile-time bugs caught by the build, both fixed without weakening any check**:
  (1) a `compactMap` closure returning `nil` on one branch and a concrete type on another needs
  its return type spelled out (`{ claim -> ComponentClaimDetail? in ... }`) — Swift had inferred
  the closure's result type from the last `return` statement alone and rejected the earlier
  `return nil`; (2) `ClaimRecord.confidence` is stored as `ConfidenceTier.score` (a `Double` —
  0.9/0.6/0.3/0.1), unlike `ComponentRecord`/`ComponentRelationshipRecord`, which keep the tier
  *string* alongside the score — assigning it straight into `ComponentClaimDetail.confidence:
  String` didn't type-check. Fixed by reversing the exact score mapping
  (`ConfidenceTier.allCases.first { $0.score == claim.confidence }`) rather than inventing a new
  confidence representation just for claims.

  **One real, non-bug finding from the test suite itself**: the structural fixture test's first
  version asserted a module's members were exactly its function/class definitions, and failed —
  `import b` creates a real `import_alias` symbol living in the *same file*, so it correctly
  appears as a same-file "member" too under the loader's own (correct) file-based grouping. Fixed
  by widening the test's expectation, not the loader — a case of the test being wrong, confirmed
  by re-deriving what the real schema actually guarantees before changing anything.

  **Manual GUI verification stayed limited to a launch-and-render smoke check** (no crash after
  wiring two new sheet layers deep), consistent with M4's own documented `System Events`
  limitations against this app's custom SwiftUI controls — the explore-to-evidence chain's
  correctness rests on the 11 new tests above, not a live click-through.
- **M6 — Confidence & uncertainty. [done]** `EpistemicTag` (Model/): the one FACT/INTERPRETATION/
  INFERENCE/UNKNOWN/CONTRADICTED → (color, icon, label) mapping, with a tolerant `.from(_:)`
  factory (falls back to `.unknown`, never silently defaults an unrecognized value to `.fact`).
  `EpistemicBadge`/`ConfidenceBadge` (Views/Shared/): the two axes Docs/08 asks for —
  epistemic *type* ("what kind of knowledge is this") and confidence *tier* ("how sure are we")
  are genuinely orthogonal (Docs/04 vs Docs/07), so they're two small shared views, not one
  overloaded badge. `ConfidenceBadge.color(forTier:)` is `static` specifically so
  `ArchitectureOverviewView`'s node coloring shares the exact same mapping instead of a second,
  driftable copy of the same four cases — retrofitted there directly, replacing a duplicate
  `switch`. `ComponentDetailView`'s M5-era ad-hoc capsule badges (`epistemicTag(_:)`,
  `confidenceBadge(_:)`) are gone, replaced by the shared views everywhere they appeared
  (Purpose, header confidence, dependencies, claims).

  **A real gap found while implementing "Open questions," not before**: `uncertainties[]` import
  as `UNKNOWN`-type claims with **zero evidence** (Docs/11's own design). `ComponentDetailLoader`
  (M5) only ever surfaces a claim whose evidence anchors overlap a component's members — an
  empty evidence list can never pass that check, so every uncertainty was silently invisible
  everywhere in the app despite being correctly persisted in the database the whole time. Fixed
  by adding `uncertainties: [String]` directly to `ArchitectureModel` (investigation-scoped, not
  component-scoped — matching where the data actually lives) and a visible, **not** disclosure-
  hidden "Open questions" section on the Architecture Overview banner, per Docs/13's own explicit
  instruction not to bury it. The Architecture Overview banner itself also gained an
  `EpistemicBadge` (`.fact` for the structural layer, `.interpretation` for the semantic one) —
  a direct, cheap reinforcement of "the epistemic status of what's on screen is never ambiguous"
  that M4 hadn't done on the banner itself. `CONTRADICTED` claims needed no separate fix: `Store
  .claims(investigationId:)` already returns every claim regardless of type, so they were already
  reaching `ComponentDetailView`'s claims list — only the *visual* distinct treatment was
  missing, which `EpistemicBadge(.contradicted)` now provides automatically.

  **15 new tests, 83 total, 0 failures, zero warnings**: `EpistemicTagTests` (5 — case-
  insensitive `.from(_:)` across all 5 vocabulary values, unrecognized input falls back to
  `.unknown` rather than defaulting to `.fact`, every tag has a non-empty label/icon, and —
  Docs/13's own stated testing plan for this milestone — every non-FACT tag is checked to differ
  from FACT in *both* color and icon, plus a full pairwise check that all 5 tags are mutually
  distinct, not just each individually unequal to FACT), `ArchitectureModelLoaderTests` (+3 —
  uncertainties populated correctly from investigation-wide `UNKNOWN` claims, empty when an
  investigation has none, always empty for the structural fallback).
- **M7 — Ask / adaptive exploration. [done]** **Correction to this plan's own assumed API**:
  the real entry point is `AgentSession(config:).ask(_ question: String)`, not
  `.answer(question:)` as originally sketched here — found by reading `orion-agent`'s own
  `AskCommand.swift` rather than guessing. `AskRunner`/`AskResultSummary` (Ingestion/): a UI
  projection of the real `AgentSessionResult` (`DepthDecision`, `ExecutedToolCall`,
  `InvestigationRecord.outcome`). **The exact same GUI-app `claudeBinary`-`PATH` gap Risk 13
  already fixed for "Build Architecture Model" applies here too** — depth-3 "Ask" delegation
  builds its own `ClaudeCodeInvestigator` inside `AgentSession` using whatever `claudeBinary`
  string the config carries, so `AskRunner`'s production path resolves it via the same
  `ClaudeBinaryLocator` before constructing the session, rather than rediscovering the bug live
  a second time. `AskView`/`AskEntryView` (Views/): a question box, a UI-local transcript
  (`AgentSession` itself has no cross-question memory, unchanged from Docs/12), and — the actual
  point of this milestone per Docs/12 Risk #5 — a depth-1 answer with zero claims renders as
  "Not independently checked" rather than the same green-checkmark treatment a grounded
  depth-2/3 `verified` answer gets. Routing method/confidence/rationale and the full tool-call
  trace are hidden behind a closed-by-default "Explain" disclosure, mirroring `orion-agent ask
  --explain` exactly (Docs/05 §8).

  Unlike M3's "Build Architecture Model," **no cost-confirmation gate was added before asking a
  question** — a deliberate choice, not an oversight: depth is chosen automatically per-question
  by the Depth Model (mostly landing on the free local model per Docs/12 M5/Risk #7's own
  numbers), and gating every question behind a "this might cost money" dialog would directly
  undermine Docs/05 Stage 5's "the user should not need to understand the routing mechanism."
  `orion-agent ask`'s own CLI has no such prompt either — cost transparency happens through the
  existing `maxBudgetUsd`/`timeoutSeconds` ceilings plus the Explain disclosure, not a blocking
  dialog.

  **8 new tests, 88 total, 0 failures, zero warnings**: `AskRunnerTests` — depth 1 via a fake
  `TurnGenerating` (no MLX model load, mirroring `OrionAgent`'s own `AgentSessionTests` seam)
  correctly flagged `isUngroundedVerified`; depth 3 via the same stand-in-`claude`-script pattern
  used throughout this phase, both a grounded success and a budget-exhausted failure (confirming
  `AgentSession`'s own real behavior — a failed delegation is still `.answered` with the failure
  as prose and `partial: true`, not a distinct `AskRunner`-level failure case, which this test
  documents rather than assumes); a never-analyzed repository correctly reaching `.failed`.

  **One real bug caught by the test suite itself, not by review**: the first version of the
  depth-1 test used a 15-character fake answer and failed against Docs/12 M5's own real
  `minLength: 20` schema floor (added there after the `claude` CLI once accepted its own literal
  `"test"` as a schema-conformant answer) — confirming that floor applies to every locally-
  synthesized candidate this app produces too, not just Claude's. Fixed by lengthening the test
  fixture, not the validation. A second, purely mechanical fix: `AskTranscriptEntry`'s `id`
  needed to be a plain stored property (`let id: UUID`), not one with a default value (`let id =
  UUID()`) — Swift's memberwise-init synthesis silently drops a defaulted property from the
  generated initializer's parameter list entirely, so `AskTranscriptEntry(id: entryId, ...)`
  failed to compile ("extra argument 'id'") until the default was removed.

  **Caught the plan's own wording drifting from what was actually built, before shipping it**:
  this section originally said Ask would render "evidence links (reusing the same Evidence view
  as M5)," but the first implementation only showed claim *counts* — `AgentSessionResult` itself
  exposes only `claimCount`/`droppedClaimCount`, never the claims (Docs/12 M4 left this as a
  deliberate "revisit once M5's hand-picked validation shows whether that detail is actually
  needed"). Rather than quietly settle for less than the plan said, `AskRunner` now reads the
  real `claims`/`evidence` rows back through `CodebaseModelStore` using the answer's own
  `investigation.id` — the exact same tables/methods Component Exploration (M5) already reads —
  so `AskClaimSummary` carries real `EvidenceDetail`s that open the identical `EvidenceView`. One
  small shared-code cleanup came with it: the `ConfidenceTier.score → tier label` reversal
  (`ClaimRecord.confidence` is stored as a bare `Double`, not the tier string) was private to
  `ComponentDetailLoader` since M5; moved to `ConfidenceBadge.tierLabel(forScore:)` as a shared
  `static` so `AskRunner` doesn't carry a second, driftable copy of the same four-case mapping —
  the same "share the mapping, don't duplicate it" discipline M6 already established for
  `ConfidenceBadge.color(forTier:)`. The existing depth-3 test was strengthened in place to
  assert the real statement/type/confidence/evidence round-trip, not just a count, once this
  landed.
- **M8 — Hardening. [done]** **Failure-mode transparency** (Docs/06 §7): `resolver == "none"`
  (always a real `SCIP_UNAVAILABLE` in this app — it never passes `--no-resolve` itself) now
  shows an explanatory caption instead of a bare "none," so a user isn't left to guess why
  calls/extends/implements are missing; Ask's outcome label now names the *specific* outcome
  (`rejected`/`incomplete`/`unverified`/`partially_verified`) instead of one generic "Partial,"
  matching what "Build Architecture Model" already did. Clone failure and budget-exhausted were
  already surfaced with real messages by M1/M3/M7's own error handling — verified still true,
  not re-built.

  **App icon**: generated programmatically (Core Graphics via a standalone `swift` script, not a
  design asset) — a rounded-square gradient with the same three-connected-node motif the empty
  state's own SF Symbol already uses, so the icon and the in-app UI read as one product. Full
  `AppIcon.appiconset` (16 through 512@2x) via `sips`, wired through
  `ASSETCATALOG_COMPILER_APPICON_NAME`. Verified live: rendered the actual bundled `.icns` back
  out to a PNG to confirm what's really embedded, since a crowded Dock at screenshot resolution
  couldn't visually distinguish it from other running apps' icons.

  **About panel**: a real one (`NSApplication.orderFrontStandardAboutPanel(options:)` with custom
  credits text stating Docs/01's actual product thesis and the epistemic-tagging vocabulary),
  replacing the OS default's blank credits.

  **Baseline accessibility — verified, not assumed, and a real gap found**: Grape's own
  documentation describes tap/drag/zoom gestures but never mentions VoiceOver or accessibility
  support, and `NodeMark`/`LinkMark` render on a custom `Canvas`-like surface with no confirmed
  AX tree exposure. Rather than bolt cosmetic `.accessibilityLabel`s onto a canvas VoiceOver may
  never reach, `ArchitectureOverviewView` gained a second, fully-functional **List** view mode
  (a segmented toggle in the banner) — every node as a standard, natively-accessible `List` row
  with the identical tap-to-explore destination as a diagram node. This is a real accessibility
  affordance, not a label, and works regardless of what Grape itself does or doesn't expose.
  Decorative icons in the empty/error states (`Image(systemName:)` beside text that already says
  the same thing) got `.accessibilityHidden(true)` so VoiceOver doesn't read them twice.

  **README** (`OrionApp/README.md`, new): build/test commands, the `xcodebuild`-not-`swift-build`
  requirement (and the real finding that building through this actual Xcode project resolves
  Phase 3's own Metal-shader gotcha automatically, since Xcode's build system — not raw SwiftPM —
  is what compiles `mlx-swift`'s shaders), the first-run model-download and `claude`-CLI-`PATH`
  runtime requirements, and the unsandboxed/ad-hoc-signed posture from Decision 4.

  No new tests — M8 is UI polish and documentation, not new pure logic; the full pre-existing
  suite (88 tests) staying green through every change is this milestone's own verification.
  **Manually verified live**: full rebuild + test run after every change, zero warnings beyond
  the pre-existing AppIntents note; the app icon confirmed by rendering the bundled `.icns`
  directly rather than trusting a screenshot.

---

## Risks / open questions

1. **App Sandbox vs. subprocess dependencies.** Decided unsandboxed (Decision 4) for v1. If the
   project later wants Mac App Store distribution, every subprocess dependency Phases 1-3 built
   (`git`, `npx`/`scip-python`, `claude`, HF Hub downloads) needs its own sandbox-entitlement or
   XPC-helper story — a substantial follow-on project, not a Phase 4 task.
2. **Grape's real-world API surface beyond its README is still unverified.** M0 confirmed the
   package resolves, links, and builds cleanly at `1.1.0`, and read its documented
   `ForceDirectedGraph`/`NodeMark`/`LinkMark` API directly from the real tagged source — but no
   diagram has actually been built with it yet. M4 (the first real usage) is where API friction,
   styling limits, or accessibility gaps would actually surface; the hand-rolled `Canvas`
   fallback (Decision 3) stays available if that milestone finds Grape doesn't fit.
3. **GitHub URL cloning is new failure surface Phases 1-3 never had.** v1 is public HTTPS only —
   no PAT/SSH auth, no private repos, no submodules handling beyond whatever plain `git clone
   --depth 1` does. Large repos and slow networks need a real timeout + a cancelable UI, not just
   a spinner. Revisit private-repo auth as a later milestone if needed, not by default here.
4. **Cost exposure stays real.** Every semantic investigation (M3) and every depth-3 `Ask` (M7)
   can spend real API money (Docs 11/12 measured $0.17-$1.77 and $0.17-$0.85 per call
   respectively). The explicit-confirmation gate (M3) and a visible running-cost display are the
   only guardrails; there is no hard per-repository budget cap in this plan — worth adding if
   real usage shows it's needed.
5. **Depth-1's `verified` mislabeling is a UX problem this phase must actually fix, not just
   acknowledge.** Docs/12 explicitly left this for Phase 4 ("Phase 4's UX layer... is a more
   promising place to spend effort on the former than another Phase 3 mechanism would be"). M7's
   distinct treatment is the concrete fix; if user testing later shows it's still misread as
   "checked," that's this phase's own open item to revisit, not a new Phase 3 escalation.
6. **The `AnalysisProgressReporting` addition is a real, if small, change to a frozen Phase 1
   library.** Must land strictly additive (optional, default-`nil`, never altering existing call
   sites) and be verified by the complete pre-existing Phase 1/2/3 test suite (261 tests as of
   Docs 12) staying green — the same bar Phase 2/3's own additive changes to Phase 1 were held
   to.
7. **Single repository per window, no multi-repo session management.** Matches the CLIs' own
   single-repo-per-invocation posture (`orion-index analyze <path>`, `orion-agent ask <path>
   "..."`). A multi-repo library/switcher UI is plausible future scope, not required for Docs/08's
   Phase 4 bullet list.
8. **No real syntax highlighting in the evidence view.** Plain monospace + line numbers is
   scoped as sufficient for v1 (Docs/08 asks for an "evidence view," not a code editor); revisit
   only if it turns out to meaningfully hurt comprehension during actual use.
9. **`swift test` can link against a stale copy of a just-changed `OrionCodeIntel` API.** Found
   at M2: after adding `AnalysisPipeline.run(_:progress:)`, two consecutive `swift test` runs
   failed at the *link* step with "symbol not found" for the old `run(_:)` selector — some
   `OrionAgentTests` object files simply weren't recompiled despite their dependency's public
   interface changing. `swift package clean` + a full rebuild fixed it; no source change was
   needed. Treat a link-time "symbol not found" for a signature you just changed as a build-cache
   problem to clean past, not evidence the edit itself is wrong — confirm with a clean rebuild
   before spending time debugging the (correct) source.
10. **Building `OrionApp.xcodeproj` writes into `OrionMacOs/Package.resolved`.** Found at M0:
   because `OrionMacOs` is referenced as a *local* Swift Package dependency, Xcode's resolver
   merges the app-level `Grape` pin into the local package's own (committed, Phase 1-3-owned)
   `Package.resolved` rather than keeping a separate resolved file for `OrionApp.xcodeproj` —
   confirmed by `git diff` after a build, and confirmed harmless: `OrionCodeIntel`'s own
   `Package.swift` never declares Grape, so running plain `swift package resolve`/`swift
   build`/`swift test` inside `OrionMacOs/` on its own reproduces the original file byte-for-byte
   (verified live at M0). Before committing any Phase 1-3 change, check `git status
   OrionMacOs/Package.resolved` and `git checkout` it if a stray `OrionApp`-only build has dirtied
   it — this is a build-tool quirk to work around when committing, not a real dependency change.
11. **Three now-separate Claude Code CLI prompt/schema contracts exist across the codebase**:
    Python `investigate.py` (Phase 2, whole-repo, unchanged — still the reproducibility record
    for `PHASE2_EVAL.md`), Swift `OrionAgent.ClaudeCodeInvestigator` (Phase 3, single-question),
    and now Swift `SemanticInvestigator` (Phase 4 M3, whole-repo — ported from the Python one,
    not the Swift one). All three independently construct very similar `-p --output-format json
    --tools Read,Grep,Glob ...` invocations. This is real, accepted duplication (Docs/13's own
    constraint — no further `OrionAgent` changes this phase — made a shared abstraction
    off-limits without touching Phase 3), not an oversight; if a fourth contract is ever needed,
    that's the point to actually extract a shared "headless Claude Code CLI call" primitive
    (options in, wrapper-parsed result out) that all of them build on, in whichever phase does it.
12. **RESOLVED — reopening an already-analyzed repository crashed with a raw SQLite error,
    reported live by the user after M5.** `AnalysisRunner` (M2) always re-ran
    `AnalysisPipeline` unconditionally, including on a repository the app had already analyzed in
    a previous launch. Phase 1's file/symbol/relationship ids are content-addressed by
    `(repository, commit)` (Docs/12 M1's own manual-E2E note: "re-running `analyze` into the
    SAME `--out` for the same commit needs `--clean` first"), so re-running against an unchanged
    commit threw `SQLite error 19: UNIQUE constraint failed: files.id` instead of upserting —
    this was a real, live gap between what Docs/13 M2's own comment claimed ("a repo already
    analyzed via the CLI is picked up here with no re-analysis needed") and what the code
    actually did, never exercised by any test because every existing test used a fresh temp repo
    per case. **Fixed**: `AnalysisRunner.run` now checks for an existing `succeeded` run at the
    repository's *current* commit (via `GitRunner.headCommit()`, already-public Phase 1 API) and
    reuses it — reading the summary straight off `AnalysisRunRecord`'s own stored counts — before
    ever touching `AnalysisPipeline`. Two regression tests added
    (`testReopeningAnAlreadyAnalyzedRepoReusesTheExistingRunInsteadOfFailing`,
    `testReopeningAThirdTimeStillReusesRatherThanAccumulatingRuns`) that directly reproduce the
    reported scenario; 70 tests total, 0 failures. A real Swift-parser gotcha hit while writing
    the fix: `if let x = try await Task.detached(...) { ... }.value { ... }` doesn't parse the way
    it looks — the trailing closure attaches ambiguously across the `if let` condition — fixed by
    binding the `Task` to a local variable first and awaiting `.value` in a separate statement.
13. **RESOLVED — "Build Architecture Model" failed with "claude did not print a JSON wrapper on
    stdout," reported live by the user after M5.** `SemanticInvestigator` invokes `claude` via
    `env claude ...` (mirroring `OrionAgent.ClaudeCodeInvestigator`'s own established pattern),
    which searches `PATH` for a bare command name. A GUI app (launched by Finder, `open`, or
    Xcode's own Run) inherits a minimal `launchd` environment, not an interactive shell's `PATH`
    — every prior CLI invocation in this codebase (Phase 2's Python subprocess, Phase 3's
    `orion-agent`, this phase's own manual verification) ran from a real Terminal shell, so this
    gap was never exercised until the actual `.app` was launched the way an end user launches it.
    Confirmed live on the dev machine itself: a bare `which claude` in a fresh non-login shell
    fails to find it (exit 1) even though it's genuinely installed at `~/.local/bin/claude` —
    the exact failure mode a GUI app would hit. **Fixed**: new `ClaudeBinaryLocator` — checks a
    short list of common absolute install locations first (fast, no subprocess; now includes
    `~/.local/bin/claude`, confirmed as a real install location, added after initially missing
    it), falls back to asking a real login shell (`zsh -l -c "command -v claude"`, sourcing
    `.zprofile`/`.zshrc` and picking up nvm/asdf/a custom `PATH` export) when none of those
    match. `SemanticInvestigationRunner.run`'s `claudeBinary` parameter changed from a defaulted
    `String = "claude"` to `String? = nil`, resolving only when the caller doesn't override it —
    every existing test already passes an explicit stand-in path, so none needed updating. 5 new
    tests (`ClaudeBinaryLocatorTests`, all injecting a fake login-shell lookup — no real `/bin/zsh`
    call in the suite), 75 tests total, 0 failures. Verified live end-to-end on the dev machine
    (not just unit-tested): the login-shell fallback really does resolve `~/.local/bin/claude`
    when invoked exactly as the locator invokes it.
