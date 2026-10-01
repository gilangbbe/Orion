# 19 — iOS companion: explore and learn on iPhone, analysis stays on the Mac

> Status: **M0 done.** A probe (`OrionMobile/Probe/FMProbe.swift`) ran on a real iPhone 17 and on
> the Mac. The two devices get **different system models**:
>
> | | iPhone 17 (iOS 27) | Mac (macOS 27) |
> |---|---|---|
> | Variant | AFM 3 Core | AFM 3 Core Advanced |
> | `contextSize` | **4,096** | 8,192 |
> | Tokenizer | identical (8,856 tokens for the 38.7K-char sample) | identical |
> | 1.9K-token prompt: TTFT / decode | 2.8–3.5 s / ~64 tok/s | 1.5–1.6 s / ~42 tok/s |
> | Guided judge call | 2.3–2.7 s | 1.4 s |
>
> - **Reasoning is unsupported on both.** Any `reasoningLevel`, even `.custom("none")`, throws.
>   Today's `FoundationModelsGuidedSession` always passes one, so it fails on the system model (M1 fix).
> - Tool calling and guided generation work, and **guided fields are filled in declaration
>   order** (unlike Core AI, Docs/18 M5), so a one-call "quote → reasoning → verdict" judge works.
> - **The Mac can't stand in for the phone.** There is no API to pick a variant, so quality
>   benchmarks for M6/M7 must run on the device.
>
> Also in M0:
> - The iOS project exists: `OrionMobile/OrionMobile.xcodeproj`, with team `S3AP74B5TH` and bundle ID
>   `com.gilangbbe.orion.mobile`. It installs on the device. The Mac app's `project.yml` now carries
>   the same team, with bundle ID `com.gilangbbe.orion.mac`.
> - Results are in `Agent Feasibility Study/results/ios_companion/m0/`.
>
> **M1 done.** `OrionCore` and `OrionAgent` now build for iOS
> (`xcodebuild -scheme OrionCore|OrionAgent -destination 'generic/platform=iOS'`).
> - `OrionCore` is the GRDB-only half of the old `OrionCodeIntel`: the Codebase Model, queries,
>   semantic layer and teaching logic. `OrionCodeIntel` re-exports it, so no caller changed.
> - `OrionAgent` now depends on `OrionCore`, not `OrionCodeIntel`. Its Claude and `Process` code is
>   Mac-only, and Core AI is linked on the Mac only.
> - There is a new `system` backend, and a capability guard keeps `reasoningLevel` away from models
>   that can't take it.
> - `OrionDatabase` has an `.importedSnapshot` mode that never erases and refuses a newer schema.
> - `orion-agent ask … --local-backend system` answers on the Mac end to end.
> - Suites: 496 package tests (487 + 9), 148 app tests, 0 failures. The 3 live system-model tests pass.
> - Found: the two-turn guided judge got an easy "met" wrong on the system model, while M0's
>   single-call probe judge got it right (n = 1). This is input for M7.
>
> **M2 done.** `orion-index snapshot <repo> [--commit]` writes `<name>.orionsnap` (lzfse SQLite)
> plus `<name>.manifest.json`. It contains:
> - the run the Mac app shows, with its semantic model, revisions, teaching concepts and verified
>   questions;
> - the source lines every evidence view cites, sliced by the same `EvidenceSlice` the Mac's
>   evidence view now uses.
>
> It leaves out the Mac's own learning, ask sessions, traces and paths.
>
> Real sizes:
>
> | Snapshot | Components | Concepts | Snippets | File (database) |
> |---|---|---|---|---|
> | Starlette @ 4f250d6b | 33 | 60 | 462 | **0.80 MB** (5.2 MB) |
> | Pulsed | 8 | 25 | 156 | 0.28 MB (2.0 MB) |
>
> Both are far below CloudKit's 50 MB asset limit. Suites: 512 package tests (+16), 148 app tests,
> 0 failures.
>
> **M3 done.** `KnowledgeSnapshotImporter` installs a snapshot into the device's `LocalLibrary`
> (`<root>/<libraryKey>/orion.db` + `manifest.json`). On a re-import it carries the device's own
> learning and asking across:
> - attempts, mastery and misconceptions;
> - questions the device drafted or answered;
> - ask sessions and their answers, claims and revisions.
>
> Concepts are matched **by name**, not id, so a re-analysis at a new commit keeps the learner's
> progress. Links into the old analysis are cleared rather than lost, and a concept the Mac dropped
> is kept as stale. The swap is atomic, a damaged or newer snapshot is refused, and the result
> passes `foreign_key_check`. Suites: 519 package tests (+7), 148 app tests, 0 failures.
>
> **M4 done.** The iOS app has a real shell and the **Explore** tab works on the phone:
> - the architecture map, plus the component list with confidence;
> - component detail;
> - code evidence from the snapshot's snippets;
> - open questions and model changes.
>
> It shares the Mac's loaders and views through `OrionApp/Shared/`, which both projects compile.
> **Library** imports `.orionsnap` files from the Files picker or the app's Documents folder.
> Ask and Learn are placeholders until M6/M7.
>
> - Real Starlette and Pulsed snapshots import and render in the simulator, walked screen by screen
>   by an XCUITest.
> - **On the real iPhone 17**, a Starlette snapshot copied into Documents imported (sha `ef664473`).
> - Found and fixed on the way: **the architecture map never drew node labels, on the Mac either**.
>   Grape's `String?` annotation overload discards the string.
> - Suites: 519 package tests, 148 Mac app tests, 7 iOS tests, 0 failures, plus the walkthrough.
>
> **M5 done.** "Sync to iPhone" works end to end on real devices: Orion on the Mac publishes a
> repository's snapshot to the user's **private iCloud**, and the iPhone installs it.
> - Both apps use `CKSyncEngine`, with the shared `OrionSync` package target.
> - Xcode's automatic provisioning registered the container `iCloud.com.gilangbbe.orion` itself.
> - Verified on the real Mac and iPhone 17: a first sync, an update picked up by the *running*
>   app on returning to the foreground, and the Mac stopping sync (the phone keeps its copy,
>   marked "no longer synced").
> - **Not observed:** a silent push waking a suspended app (the phone was locked).
> - Found and fixed live: switching sync off on a fresh launch didn't delete the iCloud record.
> - Suites: 526 package tests (+7), 148 Mac app tests, 10 iOS tests (+3), 0 failures.
>
> **M6 done.** **Ask works on the iPhone**, answered by the on-device system model, following
> `.agents/skills/apple-foundation-models-skill`.
> - **Context:** the same `AgentSession` the Mac uses, with a **token-budgeted, retrieval-first
>   context** (`CompactContextBuilder`, measured with `tokenCount`).
> - **Tools:** four snapshot tools (`SnapshotTools`) with capped results.
> - **Behavior:** streaming; an overflow retry with less context; the Mac's honest outcome labels.
>   On the phone, a question the classifier routes to depth 3 is answered at depth 2.
> - **On a real iPhone 17**, for the 10 hand-graded questions at depth 2: **10.0/20 at a median of
>   13 s**. Core AI Qwen3 on the Mac scored 7.0–8.0/20 at a median of 45–99 s.
> - **All 55 with real routing:** 53 answered with tools (35 verified, 18 partially verified), a
>   median of 19 s, and 2 safety-guardrail false positives.
> - Found and fixed: the phone's classifier sent 35% of questions to depth 3; `symbol_details`
>   resolved names to modules; the multi-line composer's return key never sent.
> - Suites: 538 package tests (+12), 148 Mac app tests, 14 iOS tests (+4), 0 failures.
>
> **M7 done.** **Learn works on the iPhone.**
> - **Questions:** Mac-shipped first, then drafted on the device for bands 1–2 by a guided drafter
>   whose schema allows only the concept's own anchors, always through the verifier.
> - **Grading:** a single-call guided judge (greedy, k = 1), about 23 s per answer.
> - **On the real iPhone 17:** the gold set gives **κ 0.62** (bar 0.60), with weak verdict tiers
>   (0.53) and weak misconception detection. **The gate is held**: grades are a self-check, and no
>   mastery is written.
> - **Drafting:** 9 of 10 drafts are kept, in 12–14 s, but by my reading only about 3 of 27 are good
>   questions. They're labelled as such, and Mac-shipped questions are the recommended supply
>   (an M8 follow-up).
> - Shared with the Mac: the teaching loader and grade views, three display fixes, and
>   the calibration harness.
> - Suites: 551 package tests (+13), 149 Mac app tests (+1), 20 iOS tests (+6), 0 failures.
>
> **M8 done.** **The iOS app is redesigned** to Apple's HIG, using the `apple-hig` and
> `swiftui-pro` skills. The Mac app's screens are unchanged.
> - **Layout:** split views on iPad (Explore, Ask, Learn), and a repository title menu on every
>   tab.
> - **Explore:** a searchable list with purposes, and a zoomable map on its own screen.
> - **Evidence:** an evidence sheet that scrolls code and scales its gutter.
> - **Ask:** starter questions and a Liquid Glass composer.
> - **Learn:** leads with the question and keeps its actions in a bottom bar.
> - **Accessibility:** Dynamic Type works to AX5, and the accessibility audit's real findings are
>   fixed.
> - **Large repository:** a 2,638-file repository makes a 21.9 MB snapshot and opens in under
>   a second after an SQL fix (was 6 s).
> - **Drafting:** device drafts now see the cited code: 10/10 kept, more concrete, still weak
>   questions.
> - Suites: 554 package tests, 149 Mac app tests, 30 iOS tests, 0 failures.

## Context

Orion's analysis only runs on the Mac. It uses tree-sitter, `scip-python` via npx, `git`, Claude Code and Core AI Qwen3. This phase adds an iPhone companion. It receives the Mac's analyzed knowledge and lets the user explore the codebase, ask questions and learn it through Teaching Mode. Every AI interaction on iOS runs on Apple's on-device Foundation Models system model.

**Decisions (user, 2026-09-30):**

1. **Transport: CloudKit sync**, Mac → iPhone.
2. **Source text: evidence snippets only.** The phone gets the cited line ranges ± context, never full files.
3. **Model: on-device `SystemLanguageModel` only.** No Private Cloud Compute, no Core AI Qwen, no Claude on iOS.
4. **Sync is one-way for v1.** Progress made on the phone stays on the phone and survives re-syncs: attempts, mastery and ask history.

**What exploration of the current code found:**

- **The portable core is almost free.** `OrionCodeIntel`'s `Model/`, `Persistence/`, `Query/`, `Graph/`, `Export/`, `Semantic/` and `Teaching/` folders depend only on GRDB. Nothing in them references the analysis folders, so a portable target is mostly a file move.
- **The iOS blockers are narrow.**
  - `Process()` in three places: `Ingest/GitRunner.swift:31`, `Scip/ScipIndexer.swift:46` and `OrionAgent/Delegation/ProcessRunner.swift:40`.
  - The package declares `platforms: [.macOS("27.0")]` only.
  - AppKit in `DesignTokens.swift`, `OrionApp.swift` and `LocalModelSetupNotice.swift`.
  - `HSplitView` in the Ask, Teaching and Model Changes views.
- **The DB has no source text.** `EvidenceSourceLoader` (`OrionApp/Orion/Model/EvidenceSnippet.swift:33`) reads the checkout on disk. The agent tools (`QueryEngineTools`) only query the DB.
- **Context size is the real iOS constraint.**
  - `ContextBuilder` produces about 10K tokens in the typical case and 140K+ characters in the worst case. It was built for Qwen3's 40K-token window.
  - On OS 27, `SystemLanguageModel.contextSize` is a runtime value (the OS 26 fallback was 4096), and `tokenCount(for:)` is available.
  - So iOS needs a token-budgeted context that retrieves only what the question needs.
- **Most agent and teaching code runs on iOS unchanged.**
  - `FoundationModelsAgent<Model: LanguageModel>` already accepts `SystemLanguageModel`, which is a `LanguageModel` on OS 27.
  - Backend-agnostic: `NativeToolLoop`, `TeachingQuestionGenerator`, the `Guided*Judge` types, `RubricGrader`, `TeachingQuestionVerifier` and `TeachingPlanner`.
- **Opening a DB would wipe an imported snapshot.** `OrionDatabase.init` turns on WAL and runs migrations on open. In DEBUG builds it also sets `eraseDatabaseOnSchemaChange = true`, which would erase an imported snapshot. This must be handled.
- **Grape and data size are fine.** Grape (vendored) already declares iOS 17. The Starlette DB is 9.1 MB.
- **CloudKit needs real signing.** The Mac app is ad-hoc signed today (`CODE_SIGN_IDENTITY: "-"`, no team). CloudKit requires a paid Apple Developer team, an iCloud container, and real signing on both apps. **This is a hard prerequisite.**

## Architecture

```
Mac (OrionApp, unsandboxed)                               iPhone (OrionMobile, iOS 27)
 analysis → <repo>/.orion/orion.db
 KnowledgeSnapshotBuilder ──► .orionsnap (lzfse SQLite + manifest)
 SnapshotPublisher (CKSyncEngine) ──► iCloud private DB ──► SnapshotSubscriber (CKSyncEngine)
                                     zone OrionKnowledge     KnowledgeSnapshotImporter
                                     record KnowledgeSnapshot  (verify → migrate → carry over
                                     payload = CKAsset          learner rows → atomic swap)
                                                            Library/<libraryKey>/orion.db
                                                            Explore · Ask · Learn (SystemLanguageModel)
```

The whole DB syncs as one CloudKit asset, rather than mapping each table to CloudKit records. That keeps schema changes to plain migrations, and the importer reuses `Migrations` to upgrade older snapshots. For the user it is still automatic CloudKit sync.

## Milestones

### M0: Feasibility spikes (no product code) `[done]`

**Plan (as written):**

- **Spike on a real iPhone** (iOS 27, Apple Intelligence on) and record:
  - `SystemLanguageModel.default` availability, `variant` and `contextSize`.
  - `capabilities`: tool calling, guided generation, and whether `reasoningLevel` is accepted.
  - Tokens/s and time to first token for a ~2K-token prompt.
  - Whether the iPhone and the Mac report the same variant. This decides whether benchmarks run on the Mac predict the phone.
- **Prerequisites:**
  - An Apple Developer team.
  - An iCloud container ID. Bundle IDs likely need a team-unique prefix instead of `com.orion`.
  - CloudKit's per-asset and per-record limits, confirmed against Apple's docs.

**What was built:**

- **`OrionMobile/` is a separate Xcode project**, generated by xcodegen from `OrionMobile/project.yml`.
  It is not a target in `OrionApp`, because the user asked for a new project. M4 references the
  shared sources by path from it.
  - `OrionMobile` is the iOS 27 app. At M0 it only hosts the probe screen, which becomes the real
    shell in M4.
    - It signs with Apple Development. Automatic provisioning needs `-allowProvisioningUpdates`.
    - Launching it with `FM_PROBE_AUTORUN=1` starts a run.
    - It writes `Documents/fm-probe-latest.json`, and `UIFileSharingEnabled` makes that file visible
      in the Files app.
  - `fm-probe` is a macOS command-line tool that builds the same `Probe/` sources. It prints the
    report, and also writes it to `FM_PROBE_OUT` if that is set.
- **`Probe/FMProbe.swift`** records availability, variant, `contextSize`, capabilities and locale
  support. It then runs these checks, each catching its own error:
  - `tokenCount` at 1K–38.7K characters;
  - a plain turn;
  - a ~2K-token answering turn;
  - three reasoning levels;
  - a streamed guided judge that records the order fields appear in;
  - a `lookup_symbol` tool call;
  - a two-turn KV-cache check;
  - a deliberate context overflow.
- **`Probe/SampleContext.swift`** is generated by `scripts/make-sample-context.sh` from the vendored
  Starlette analysis. It holds components, claims and a `code_graph.json` excerpt: the same kinds of
  text `ContextBuilder` sends.
- **Signing:** team `S3AP74B5TH` in both `project.yml` files, which keeps the change the user made in
  Xcode from being lost on the next `xcodegen generate`.
  - Mac: `com.gilangbbe.orion.mac` (+ `.tests`). It is still "Sign to Run Locally" until M5 needs
    iCloud entitlements.
  - iOS: `com.gilangbbe.orion.mobile`.
  - Planned iCloud container: `iCloud.com.gilangbbe.orion`. It is created at M5, when the
    entitlements are added.

**Results.** One Mac run and two iPhone 17 runs, all on the same Starlette sample. JSON is in
`Agent Feasibility Study/results/ios_companion/m0/`.

| Check | iPhone 17 (AFM 3 Core, 4,096) | Mac17,2 (AFM 3 Core Advanced, 8,192) |
|---|---|---|
| Availability, locale | available, supported | available, supported |
| Capabilities | guided ✓, tools ✓, vision ✓, **reasoning ✗** | same |
| Characters per token (Orion context) | 4.4 (38.7K chars) – 5.0 (1K chars) | identical counts |
| Plain turn, 67 tokens in: TTFT | 1.8 s cold, 1.3 s warm | 0.4–0.6 s |
| Answering turn, 1,896 tokens in / ~190 out | TTFT 2.8–3.5 s, decode 63–65 tok/s, **5.7–6.5 s total** | TTFT 1.5–1.6 s, decode 42 tok/s, 6.2 s total |
| `reasoningLevel` none / light / deep | all throw "does not support reasoning" | same |
| Guided judge (4 fields) | 2.3–2.7 s, declaration order ✓, correct verdict | 1.4 s, same |
| Tool call (`lookup_symbol`) | 1 correct call, grounded answer, 1.5–2.2 s | same, 1.1 s |
| Same-session second turn | run 1: 1,430 / 1,447 tokens cached (TTFT 0.5 s); **run 2: 0 cached** (2.2 s) | 1,436 cached (0.6 s) |
| 26.6K-token prompt | `contextSizeExceeded` (26,628 > 4,096) | same (> 8,192) |

**Findings and what they change:**

1. **The phone's window is 4,096 tokens, and the Mac's model is different (Risk 6 realized).**
   - The shared tokenizer means *budgets* computed on the Mac are exact.
   - *Quality* and *latency* are not transferable: `SystemLanguageModel` has no variant selector.
     - M6 and M7 therefore gain an on-device bench runner: a debug screen that runs the bench
       questions or the gold set and writes JSON, pulled with `devicectl` exactly like the probe.
     - `--local-backend system` on the Mac stays a development convenience, not a gate.
2. **The ask budget on the phone** (derived from the numbers above):
   - 4,096 − ~500 reply reserve − ~400–1,000 instructions and tool schemas (~386 tokens with one tool)
     leaves **~2,300–2,800 tokens, ≈ 10–12K characters, for retrieved context and tool results**.
   - A turn of that size costs ~3 s to first token and ~6 s in total.
3. **No reasoning on the system model, and requesting it throws.**
   - M1 must set `reasoningLevel` only when `capabilities.contains(.reasoning)`. That applies to
     `FoundationModelsGuidedSession.contextOptions`, the `benchmarkTurns` context, and the no-think
     role path in `LocalModelLoader`.
   - M7 can't lean on a "thinking judge". Docs/18 M4 showed no-think *text* judges say "met" ~95%
     of the time, so the on-device judge must be guided.
4. **Guided output keeps declaration order.** M7 can use a single-call judge (quote, reasoning,
   then verdict) instead of Docs/18 M5's two-turn workaround. That halves the calls per vote:
   ~2.5 s per vote, so ~15 s for 6 criteria at k=1, or ~45 s at k=3.
5. **KV reuse on the phone is opportunistic.** It helped in one run and not the other. Don't design
   depth-2 latency around it; assume each tool round re-prefills.
6. **Cold start** adds ~0.5 s to the first call. M6 can prewarm the session when the Ask tab opens.
7. **CloudKit limits:** a record's non-asset data is limited to 1 MB, and each asset to 50 MB
   ([CloudKit Web Services Reference, Data Size Limits](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html),
   the documented figure, treated as the ceiling). The 9.1 MB Starlette DB fits in one asset.
   M2/M5 must split a snapshot into ordered 45 MB chunk assets once its compressed size exceeds that.

**Caveats:** n = 2 on one iPhone model, one short sample, greedy decoding. The reasoning, guided and
tool results are capability facts; the latencies are indicative, not benchmarks.

**How to re-run:**
- Mac: `cd OrionMobile && xcodebuild -scheme fm-probe -configuration Release -derivedDataPath .build/xcodebuild build`,
  then `FM_PROBE_OUT=results/mac-probe.json .build/xcodebuild/Build/Products/Release/fm-probe`.
- iPhone:
  1. Build: `xcodebuild -scheme OrionMobile -configuration Release -destination 'id=<udid>' -allowProvisioningUpdates …`
  2. Install: `xcrun devicectl device install app --device <udid> …/Release-iphoneos/Orion.app`
  3. Launch: `xcrun devicectl device process launch --device <udid> --terminate-existing --environment-variables '{"FM_PROBE_AUTORUN":"1"}' com.gilangbbe.orion.mobile`
     The phone must be unlocked, because the model only serves foreground apps.
  4. Collect: after ~30 s, `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.gilangbbe.orion.mobile --source Documents/fm-probe-latest.json --destination …`

### M1: Multi-platform package split `[done]`

**Plan (as written):**


- **`OrionMacOs/Package.swift`:**
  - Add `.iOS("27.0")`.
  - Add a new target, **`OrionCore`** (GRDB only), holding `Model/`, `Persistence/`, `Query/`, `Graph/`, `Export/`, `Semantic/` and `Teaching/`, moved from `OrionCodeIntel`.
  - `OrionCodeIntel` depends on `OrionCore` and adds `@_exported import OrionCore`, so every existing caller compiles unchanged.
- **Make `OrionAgent` platform-conditional instead of splitting it:**
  - The `CoreAILM` dependency gets `condition: .when(platforms: [.macOS])`.
  - Put `#if os(macOS)` around `ProcessRunner`, `ClaudeCodeInvestigator`, `ClaudeTeachingDrafter`, `LocalModelLoader`/`CoreAIModelLocator`, `AgentSession.runDelegated` and the default factories.
  - On iOS, a depth-3 question gets an honest "this needs a deeper investigation on your Mac" answer.
- **Add a `.system` case to `LocalModelBackend`:** `FoundationModelsAgent(model: SystemLanguageModel.default, modelIdentifier: "system:<variant>")`. With it, `--local-backend system` lets the Mac CLI benchmark the phone's model family in M6 and M7.
- **Guard reasoning by capability (M0 finding 3):** only set `reasoningLevel` when
  `model.capabilities.contains(.reasoning)`. This covers `FoundationModelsGuidedSession`,
  `benchmarkTurns` and `LocalModelLoader`'s no-think roles.
- **Add an `OpenMode` to `OrionDatabase`:** `.analysis` (the default) or `.importedSnapshot`. `.importedSnapshot` never sets `eraseDatabaseOnSchemaChange`.
- **Tests:** the `OrionCore` tests (the Teaching* tests, Store, and so on) either move to a new `OrionCoreTests` target or stay in `OrionCodeIntelTests` via the re-export. Keep them green.

**What was built:**

- **`OrionCore` target** (`Sources/OrionCore/`, GRDB only, product `OrionCore`). It holds
  `Model/ Persistence/ Query/ Graph/ Export/ Semantic/ Teaching/`, moved with `git mv`.
  - `OrionCodeIntel/Exports.swift` does `@_exported import OrionCore`.
  - `Package.swift` declares `.iOS("27.0")`.
  - The only code that had to change for the move: the six Phase 1 records (`AnalysisRunRecord`,
    `FileRecord`, `ExternalDependencyRecord`, `SymbolRecord`, `RelationshipRecord`,
    `DiagnosticRecord`) relied on Swift's implicit memberwise init. That init is always
    `internal`, so the analysis code in the other module couldn't call it anymore.
  - They now have explicit `public init`s, in declaration order with `= nil` for optional
    `var`s, so every call site is unchanged. This matches the Phase 7 records' convention.
- **`OrionAgent` depends on `OrionCore`, not `OrionCodeIntel`** (a deviation from the plan).
  - Its only real use of the analysis half was `Timestamp`, a pure ISO 8601 helper, which moved to
    `OrionCore/Model/Timestamp.swift`.
  - Without this change `OrionAgent` would have dragged tree-sitter and the `Process`-based
    analysis into the iOS app.
  - `orion-agent` and `OrionAgentTests` now list `OrionCodeIntel` directly.
- **Platform-conditional `OrionAgent`:**
  - `CoreAILM` is linked `.when(platforms: [.macOS])`.
  - `LocalModelLoader` compiles its Core AI half under `#if canImport(CoreAILanguageModels)`. On iOS
    a `.coreAI` backend throws `CoreAIUnavailable`.
  - Mac-only (`#if os(macOS)`): `ProcessRunner.swift`, `ClaudeCodeInvestigator.swift`,
    `ClaudeTeachingDrafter` (+ its error type), and the body of `AgentSession.runDelegated`.
  - On iOS, depth 3 records an honest `incomplete` investigation: "needs a deeper investigation…
    ask it in Orion on your Mac". It is persisted, so ask history and the routing trace stay whole.
- **`LocalModelBackend.system`** (parsed from `system`, also via `ORION_LOCAL_BACKEND`).
  - `Model/SystemModel.swift` (`SystemModelInfo`) holds the variant name, `contextSize`,
    availability, and an agent with its own options: a 1,024-token reply cap and the model's own
    sampling. The Core AI default of 8,192 tokens is twice the iPhone's whole window.
  - `modelIdentifier` is `system:<variant>`, e.g. `system:AFM 3 Core Advanced`.
  - Every role resolves to `.system` unchanged; the role table doesn't apply.
  - `missingVariants` is empty for it.
  - `LocalModelBackend.platformDefault` is `defaultCoreAI` on the Mac and `.system` on iOS, and
    `.default` falls back to it.
  - `createdBy` is `system_local` for system-model answers; `qwen3_local` stays for Core AI.
    Nothing reads this value.
  - The CLI's `--local-backend` help text lists `system`.
- **Reasoning guard.** `FoundationModelsAgent` records `model.capabilities.contains(.reasoning)`,
  and `supported(_:reasoning:)` strips `reasoningLevel` otherwise.
  - Every path goes through it: the stored context options (so `with(contextOptions:)` no-think
    roles), `FoundationModelsGuidedSession` (now given its context options by the agent) and
    `benchmarkTurns`.
  - **Core AI is unaffected.** `CoreAILanguageModel` reports `.reasoning` when the tokenizer
    contains the thinking tag, and both exported Qwen3 bundles' `tokenizer.json` contain `"<think>"`.
- **`OrionDatabase.OpenMode`** (`.analysis` by default, or `.importedSnapshot`).
  - `OrionMigrations.makeMigrator(eraseOnSchemaChange:)` defaults to the old DEBUG-only erase.
  - `.importedSnapshot` never erases.
  - It throws `OpenError.newerSchema(unknownMigrations:)` when the file has migrations this build
    doesn't know, and otherwise migrates older snapshots up.
- **Tests (+9, and one live class):**
  - `OrionDatabaseOpenModeTests` (4): never erases, v3 → current migrates up, a
    `v99_future_schema` row is refused, a fresh file opens.
  - `LocalModelBackendTests` (+3): `system` parsing and environment, every role resolving to
    `.system` even under `*=qwen3-4b-4bit:off`, no missing bundles, the Mac platform default, and
    `LocalModelLoader` serving `.system` as a tool-calling, guided model.
  - `FoundationModelsAgentTests` (+2): `EchoLanguageModel` takes `supportsReasoning:`. A no-think
    agent on a model without reasoning sends no level on the one-shot, multi-turn and tool paths,
    and `supported` keeps `includeSchemaInPrompt`.
  - `SystemModelLiveTests` (3, `ORION_AGENT_LIVE_SYSTEM_TEST=1`, added to the CI skip list): a
    no-think role, the guided judge and a native tool turn, all through the real system model.
    Before M1, each of these threw.
  - 50 test files got `@testable import OrionCore` next to `@testable import OrionCodeIntel`.

**Results.**
- `swift test` with CI's skip list: **496 passed, 0 failed** (487 + 9).
- `OrionApp` `xcodebuild test`: **148 passed, 0 failed**.
- iOS builds: `OrionCore` and `OrionAgent` both `BUILD SUCCEEDED` for `generic/platform=iOS`.
- `SystemModelLiveTests`: 3/3 on the Mac (AFM 3 Core Advanced).
- `orion-agent ask <starlette> "Where is the Router class defined, and what does its add_route method do?" --local-backend system --force-depth 2 --explain`
  (on a copy of the Starlette DB) answered in ~18 s.
  - It made two native tool calls (`lookup_symbol` Router → `callees` Router), recorded one
    verified claim, and cited `starlette/routing.py`.
  - The answer was shallow: it didn't explain `add_route`.
  - It ran on `ContextBuilder`'s existing context, which fit the Mac's 8,192-token window. It
    would not fit the phone's 4,096; M6's `CompactContextBuilder` exists for that.

**Finding for M7 (n = 1).** On the Mac's system model, the existing two-turn `GuidedCriterionJudge`
called a plainly-met criterion "not met". It reasoned that "sits outside the router" contradicts
"wraps routing". M0's single-call probe judge, with a different prompt, got the same example right
on both devices. The two-turn shape was built around Core AI's field-order bug, which the system
model doesn't have. `SystemModelLiveTests` therefore checks that the judge *runs* and quotes the
answer, not that its verdict is right; judge quality is measured on the device in M7.

### M2: Knowledge snapshot (Mac side) `[done]`

**Plan (as written):**


- **v7 migration:** a new table `evidence_snippets(file_path, start_line, end_line, text, file_sha256)`. It stays empty on the Mac and is only filled in snapshots.
- **`KnowledgeSnapshotBuilder`** lives in `OrionCodeIntel` because it reads the checkout. It runs these steps:
  1. `VACUUM INTO` a temporary file.
  2. Strip learner tables, Mac-only traces and superseded runs.
     - Learner tables: `teaching_attempts`, `teaching_criterion_results`, `knowledge_states`, `teaching_misconceptions`, and `ask_sessions` with its turns.
     - Mac-only traces: `routing_decisions` and `agent_tool_calls`.
  3. Scrub `repositories.local_path`.
  4. **Keep** components, claims, evidence, revisions, `teaching_concepts`, and *verified* `teaching_questions` with their criteria. Questions drafted on the Mac (Claude for band 3, the 8B model for bands 1–2) are the best questions the phone will ever have.
  5. Collect snippets for every anchor in `evidence`, `teaching_concepts.evidence_anchors`, `teaching_questions.reference_anchors` and `teaching_rubric_criteria.evidence_anchors`.
     - Each snippet is ±3 lines, capped at N lines.
     - Skip the snippet when `files.sha256` doesn't match the checkout.
     - Reuse the slicing logic from `EvidenceSourceLoader`.
  6. Write the manifest: format version, last migration ID, `libraryKey`, repo name, remote URL, commit, run ID, counts and sha256.
  7. Compress with lzfse.
- **CLI:** `orion-index snapshot <repo> [--out]`. Report the snapshot size for Starlette and Pulsed.

**What was built:**

- **v7 migration `v7_ios_snapshot`** (additive), with two tables that are empty on the Mac:
  - `evidence_snippets(file_path, start_line, end_line, first_line, text, truncated, file_sha256)`.
    Its primary key is the *cited* range, which is exactly the `(anchor → file, startLine, endLine)`
    an `EvidenceDetail` asks for, so the phone's lookup is a primary-key hit. `first_line` + `text`
    hold the range plus context.
  - `snapshot_manifest`: a single row holding the manifest JSON, so a snapshot file describes itself.
- **`OrionCore/Snapshot/`**, portable, for M3's importer:
  - `KnowledgeSnapshotFormat`:
    - `formatVersion` 1 and the `.orionsnap` extension;
    - lzfse compress/decompress (Foundation's `NSData` API, on macOS and iOS);
    - `sha256Hex`;
    - `libraryKey`: 24 hex chars of SHA-256 over the source URL, or the Mac checkout path when
      there is none. It is stable across commits and re-analyses, and the path itself never leaves.
  - `KnowledgeSnapshotManifest`: format, schema version, library key, repository name, source URL,
    commit, run, `analyzedAt`, `createdAt`, Orion version, and counts, including snippets and
    `snippetsSkipped`.
    - The database size, file size and sha256 are only set in the outside `.manifest.json`, because
      the copy inside can't know the final bytes of the file it lives in.
  - `EvidenceSnippetRecord` and the `Store` accessors: `insertEvidenceSnippets`,
    `evidenceSnippet(filePath:startLine:endLine:)`, `snapshotManifest()`.
  - `EvidenceSlice`: the one "which lines does an evidence view show" rule (range ±3 lines, or the
    first 200 lines without a range, plus an optional cap).
- **The Mac's `EvidenceSourceLoader` now slices with `EvidenceSlice`**, uncapped. Behavior is
  unchanged (its 7 tests pass), and a snippet is by construction exactly what the Mac would show,
  up to the phone's 80-line cap.
- **`OrionCodeIntel/Snapshot/KnowledgeSnapshotBuilder`**, in these steps:
  1. `VACUUM INTO` a temp copy. This is consistent even with an open WAL, and leaves the Mac
     database untouched apart from the additive v7 migration on open.
  2. Keep the run the Mac app shows: `latestRun(commitHash:)` (the latest *succeeded* run, or
     `--commit`'s) and its repository row. Delete every other repository row and run; everything
     scoped to them goes by `ON DELETE CASCADE`.
  3. Delete the Mac's attempts, criterion results, knowledge states, misconceptions and ask
     sessions; `routing_decisions`, `agent_tool_calls` and `diagnostics`; and unverified questions.
  4. Set `repositories.local_path` to the repository's name.
  5. Collect every range an evidence view can open:
     - claim `evidence`;
     - semantic component members;
     - the anchors of the kept questions (`reference_anchors`) and criteria (`evidence_anchors`),
       resolved to symbol ranges the way `TeachingLoader.gradeCard` resolves them.
     Then slice each from the checkout with an 80-line cap, and only when the file's bytes still
     match `files.sha256`.
     - Skipped on purpose: structural (module) members, which would amount to the whole codebase,
       and concept `evidence_anchors`, which the grader and drafter only ever read as signature or
       docstring text from the database.
  6. Embed the manifest.
  7. Switch the journal to DELETE mode (no WAL) and `VACUUM`.
  8. Check `integrity_check` and `foreign_key_check`.
  9. Compress, then write `<repo>-<commit12>.orionsnap` and `.manifest.json`, the latter with size
     and sha.
- **CLI:** `orion-index snapshot <path> [--out] [--destination] [--commit] [--json]`. The default
  destination is `<path>/.orion/snapshot/`.
- **Tests (+16):**
  - `KnowledgeSnapshotBuilderTests` (9), on a real temp checkout and database:
    - Which run is kept: the latest *succeeded* one is chosen over a newer failed run and an older
      repository row; `--commit` picks the other run, with the same library key.
    - What is dropped: learning, asks, traces and unverified questions.
    - The local path is scrubbed.
    - Snippets are exact: range ±3, a duplicate range stored once, the cap truncates, a
      sha-mismatched file is skipped and counted, an unresolvable anchor is ignored.
    - The manifest matches the file (sha and sizes), and the embedded copy equals it.
    - The file is DELETE-journal, `integrity_check` ok, with no foreign-key violations.
    - The Mac database is left alone.
    - No succeeded run is an error.
  - `KnowledgeSnapshotFormatTests` (2): compression round-trips; the library key prefers the
    source URL and is stable.
  - `EvidenceSliceTests` (5).

**Results.** All runs used copies of the databases; the live ones were not touched.

| Snapshot | Build | File / database | Components · claims · evidence · revisions | Concepts · verified questions | Snippets (skipped) |
|---|---|---|---|---|---|
| Starlette, latest run (what the Mac app shows) | ~4 s | 0.53 / 3.4 MB | 0 · 5 · 99 · 5 | 0 · 0 | 32 (0) |
| Starlette `--commit 4f250d6b` | ~4 s | **0.80 / 5.2 MB** | 33 · 108 · 752 · 101 | 60 · 0 | 462 (0), 59 truncated |
| Pulsed, latest run | ~4 s | 0.28 / 2.0 MB | 8 · 23 · 84 · 7 | 25 · 3 | 156 (0) |

- **Checked by hand on the decoded Starlette file:**
  - `integrity_check` ok, no foreign-key violations, journal `delete`;
  - one repository row with `local_path = starlette`, one run, and 0 rows in every stripped table;
  - **no `/Users/biru` anywhere in a full `.dump`** (the one case-insensitive `/users/` hit is a
    Starlette route in an answer);
  - the cited range 63–83 of `starlette/applications.py` is byte-identical to lines 60–86 of the
    real file, and a 1–125 module range stops at exactly 80 lines.
- The manifests are in `Agent Feasibility Study/results/ios_companion/m2/`. The `.orionsnap` files
  themselves are not kept: they contain source code, and Pulsed's is private.
- `swift test` with CI's skip list: **512 passed, 0 failed** (496 + 16). `OrionApp`: **148 passed**.
  `OrionCore` builds for iOS.

**Findings:**

1. **"What the Mac shows" is sometimes thin.** Both databases carry two repository rows: the
   analyzed commit and a later `unversioned` re-analysis (2026-09-17).
   - The app shows the latest succeeded run. For Starlette that's the unversioned one, which has no
     architecture model, while the 33-component model sits on the commit run.
   - The builder follows the app, so the phone matches the Mac. `--commit` snapshots a specific
     run. M5's "Sync to iPhone" publishes what the Mac shows; whether it should also offer a run
     picker is a UI question for then.
2. **Sizes are a non-issue for CloudKit.** A few hundred KB compressed, versus the 50 MB asset
   limit; lzfse gets about 6–7×. Chunking stays a documented fallback for very large repositories
   (M8).
3. **Few verified questions exist to ship.** The Starlette database has no teaching questions at
   all (Phase 7's bench runs used copies), and Pulsed has 3. The phone's Learn tab will lean on
   on-device drafting (M7) until the Mac generates more.

### M3: Snapshot import + learner carry-over (portable, `OrionCore`) `[done]`

**Plan (as written):**


- **`KnowledgeSnapshotImporter`** runs these steps:
  1. Verify the sha256 and the manifest.
  2. Reject a snapshot newer than the app's known migrations, with an "Update Orion" message.
  3. Open it in `.importedSnapshot` mode, so older snapshots are migrated up.
  4. `ATTACH` the phone's current DB and copy the phone-owned rows across.
     - The phone-owned rows are:
       - attempts, criterion results, `knowledge_states` and misconceptions;
       - questions and criteria drafted on the phone;
       - ask sessions and turns, with their `investigations` rows.
     - Concepts are matched by **natural key (kind + subject_label)**, not by ID. `repository_id` is a random UUID and may differ between snapshots.
  5. Report orphans. Stale concepts remain, because `ConceptExtractor` marks concepts stale instead of deleting them.
  6. Swap the files atomically.
- **`LocalLibrary`:** one folder per repository, `Application Support/Library/<libraryKey>/`, holding `orion.db` and `manifest.json`.
- **An `EvidenceSourceProviding` protocol:**
  - The Mac implementation reads the checkout (today's `EvidenceSourceLoader`).
  - The iOS implementation reads `evidence_snippets`.

**What was built** (all in `OrionCore/Snapshot/`, so it builds for iOS):

- **`LocalLibrary`**:
  - It holds `<root>/<libraryKey>/orion.db` and `manifest.json`, with the default root
    `Application Support/Orion/Library`.
  - `entries()` lists repositories sorted by name. It skips hidden `.incoming-*` files and folders
    left by an interrupted first import.
  - It also has `entry(for:)` and `remove(libraryKey:)`.
- **`KnowledgeSnapshotImporter.importSnapshot(at:expected:)`**, in these steps:
  1. When a manifest travelled with the file, check its sha256, then decompress.
     A non-lzfse file is `notASnapshot`.
  2. Write the incoming database *inside the library root* (the same volume, so the swap is a
     rename), and record which migration it was at (`migratedFromSchema`).
  3. Open it with `OrionDatabase(mode: .importedSnapshot)`. A newer schema is `newerSchema` (M1);
     an older one migrates up.
  4. Check the embedded manifest: it must exist, have a `formatVersion` this app reads, and have
     the `libraryKey` the expected manifest names.
  5. **If the repository is already on the device:** open the previous database (which migrates it
     too), checkpoint its WAL, close it, and run the carry-over below.
  6. Switch the journal to DELETE mode, run `integrity_check` and `foreign_key_check`, and write
     the manifest.
  7. `replaceItemAt` (or move) over `orion.db`, then remove any stale `-wal`/`-shm`. The temp
     files are always cleaned up.
  - `Report` gives `replacedExisting`, `migratedFromSchema`, `carried[table]`, `orphaned[table]`
    and `staleConceptsKept`.
  - **Contract:** no connection to that repository's database may be open during an import (M4/M5
    close theirs).
- **Carry-over (`LearnerCarryOver`).** SQL with the previous database `ATTACH`ed as `old`, in one
  transaction. A generic `copy(table, where:, overrides:)` reads the column list from the schema
  and overrides only the remapped columns.
  - **Context:** the snapshot's single repository, run and commit are what carried rows are
    re-homed onto.
  - **Questions carried:** the ones the new snapshot lacks that the device *drafted*
    (`generated_by = 'device'`, the new `TeachingQuestionSource.device`) or has *attempts* on,
    together with their criteria. A question the Mac still ships keeps its id, and the device's
    attempts on it just resume.
  - **Concepts** map old → new by `(kind, subject_label)`. The natural key includes
    `repository_id`, which changes when the Mac re-analyzes at a new commit, so ids can't be used.
    A concept the device has progress on that the Mac dropped is copied across as `stale`, with its
    `source_*` links cleared.
  - **Teaching rows:** attempts (on any question now present), criterion results (both parents
    present), knowledge states (concept remapped) and misconceptions.
  - **Asks:** the device's investigations, i.e. those behind its ask turns or routing decisions.
    A session-less ask has only the latter.
    - Those investigations and their claims are re-homed to the new repository, run and commit.
    - Evidence `file_id`/`symbol_id` are cleared when they no longer resolve.
    - Routing decisions and tool calls come across.
    - Ask sessions come across, and a component-scoped session whose component is gone becomes
      repository-scoped. Turns come across.
  - **Revisions** triggered by the device's investigations, with their entries, are
    **re-chained**: `previous_revision` and `revision_number` continue after the snapshot's newest
    revision, in creation order.
  - **Not carried:** diagnostics, which are traces, as on the Mac (M2).
  - **Reported, never left dangling:** anything whose parent is gone is counted in `orphaned`.
- **Phone-side evidence:** `Store.evidenceSlice(anchor:startLine:endLine:)` resolves the same
  triple an `EvidenceDetail` holds to an `EvidenceSlice.Slice` from `evidence_snippets`, which is
  the shape the Mac's `EvidenceSourceLoader` builds from the checkout. `Slice` gained a public init.
  - **Deviation:** the app-level `EvidenceSourceProviding` protocol moves to M4, where
    `EvidenceView` becomes shared. M3 ships the portable lookup it will wrap.
- **`TeachingQuestionSource.device`** is the provenance of a device-drafted question; M7's drafter
  must use it. Nothing switches over the enum.
- **Tests (+7), `KnowledgeSnapshotImporterTests`.** They use real snapshots from
  `KnowledgeSnapshotBuilder` over a hand-made Mac database and checkout.
  - **First import:** the library entry and manifest are written; the evidence slice comes out
    17-25 around 20-22; a range-less or unknown range is `nil`.
  - **The re-import scenario:**
    - v1 has concepts App and Gone. On the device: an answer to a shipped question, an answer to
      the Gone question, a device-drafted question and its answer, two knowledge states, a
      misconception, a component-scoped ask session whose answer carries a claim, evidence, a tool
      call and a model revision, and a session-less ask.
    - v2 is a re-analysis at a new commit, with a new repository id, new run/file/symbol/component
      ids, Gone dropped, and a Mac revision.
    - Checks: exact per-table carried counts across 15 tables, `orphaned == [:]`,
      `staleConceptsKept == 1`, mastery on the new App concept id, the dropped concept kept as stale
      under `r2`, questions remapped, the session downgraded to repository scope, investigations and
      claims on `run2`, evidence links cleared, and the device's revision numbered 2 after `rev-mac`.
  - **A second re-import** carries the same counts again, so repeated syncs don't erode anything.
  - **Refusals:** a sha mismatch or a garbage file changes nothing (the device's attempt is still
    there, and no `.incoming` files are left). A newer schema and a newer format (edited inside a
    real snapshot) are refused, as is a `libraryKey` mismatch.
  - **`remove`** empties the library.

**Results.**
- `swift test` with CI's skip list: **519 passed, 0 failed** (512 + 7).
- `OrionApp`: **148 passed**.
- `OrionCore` and `OrionAgent` build for iOS.
- **Not run yet:** a real-data import (the Starlette/Pulsed snapshots). That happens on the
  simulator through M4's debug file import.
- An *older* snapshot migrating up goes through the same `.importedSnapshot` path M1 tested
  (v3 → current). An importer-level test lands with the first migration after v7.

**Findings:**

1. **Never edit text inside a shipped `CREATE TABLE`, comments included.** Adding `'device'` to the
   `generated_by` comment in v6's SQL would have changed the schema text SQLite stores. DEBUG builds
   compare that text (`eraseDatabaseOnSchemaChange`), so every existing Mac database would have been
   **erased** on its next debug open. The edit was caught and reverted before anything ran, and the
   v1–v6 SQL is byte-identical to before. The same now holds for v7.
2. **Asking on the device writes more than the ask tables.** `ingestAnswer` also writes claims,
   evidence, diagnostics and **model revisions**, through `RevisionDiffer`. Carry-over had to
   follow all of it, and to re-chain revision numbering after the Mac's.

### M4: iOS app shell + exploration (no AI yet) `[done]`

**Plan (as written):**


- **`OrionMobile/project.yml`** (the separate project created in M0): the probe screen becomes a
  debug tab, and an `OrionMobileTests` target is added. The app depends on the `OrionMacOs` package
  (`OrionCore`, `OrionAgent`) and `Vendor/Grape` by relative path, like `OrionApp`.
- **Shared sources** move to a new `OrionApp/Shared/` folder. Both projects compile it:
  `OrionMobile/project.yml` references it as `../OrionApp/Shared`. The portable set is:
  - Loaders: `ArchitectureModel`, `ComponentDetail`, `ModelChangeLoader`/`Summary`, `TeachingLoader` and `CodebaseModelStore`.
  - Models: `EpistemicTag` and `AppShellState`.
  - Views: `ArchitectureOverviewView`, `ComponentDetailView`, `EvidenceView`, `OpenQuestionsPanel`, and everything in `Views/Shared/` except `LocalModelSetupNotice`.
- **Required edits to shared code:**
  - `DesignTokens`: replace `NSColor(name:dynamicProvider:)` with `#if os(iOS)` `UIColor { traits in … }`.
  - `EvidenceView`: drop the fixed `minWidth`, and take an `EvidenceSourceProviding`.
  - `TeachingLoader.concepts(bootstrap:)` must not write to the DB on iOS.
- **Navigation:** a `TabView` (`.sidebarAdaptable` on iPad) with a `NavigationStack` per tab:
  - **Library**
  - **Explore:** diagram or list → component → evidence, plus Changes and Open Questions
  - **Ask**
  - **Learn**
- **A debug-only "Import snapshot file"** (`.fileImporter`) runs the same importer. It lets simulator testing go ahead before CloudKit and signing are ready.

**What was built:**

- **`OrionDatabase.OpenMode.platformDefault`** (package): `.analysis` on macOS, `.importedSnapshot`
  on iOS, and the default for `OrionDatabase(path:)`. The shared loaders open `<dir>/orion.db`
  without naming a mode, so on the phone they can never erase an imported snapshot in a DEBUG build
  (see M3's finding 1).
- **`OrionApp/Shared/`**, moved with `git mv` and compiled by both projects. The Mac target lists it
  in `OrionApp/project.yml`; `OrionMobile/project.yml` uses `../OrionApp/Shared`. Its imports moved
  from `OrionCodeIntel` to `OrionCore`.
  - `Model/`: `ArchitectureModel`, `ComponentDetail`, `ModelChangeLoader`, `ModelChangeSummary`,
    `CodebaseModelStore` (needed by the first and third), `EpistemicTag`, `EvidenceSnippet`.
  - `Views/`: `ComponentDetailView`, `EvidenceView`, `OpenQuestionsPanel`, `ConfidenceBadge`,
    `EpistemicBadge`, `MarkdownText`, `MasteryMeter` and `DesignTokens`, plus two new files:
    - `ArchitectureDiagram.swift` (`ArchitectureDiagramView` + `ArchitectureLayerBanner`), extracted
      from `ArchitectureOverviewView`;
    - `ModelChangeViews.swift` (`ModelChangeRowLabel` + `ModelChangeDetailView`), extracted from
      `ModelChangesView`.
  - **Not shared:** `TeachingLoader` (M7, where its bootstrap write must be dealt with), and
    `AppShellState` (the phone has its own navigation).
- **Decoupling from the Mac shell:**
  - **`ComponentDetailView`** takes an evidence source plus optional `onAskAbout` and
    `onShowRevision` closures instead of `repoRoot`, `AppShellState` and `AskHistory`. A `nil`
    closure hides its button. The Mac's resume-or-scope "Ask about" logic and its rationale moved
    into `ContentView`'s inspector call site, unchanged.
  - **The architecture overview, Model Changes and inspector containers stay Mac-only**, built from
    the shared pieces.
  - **`DesignTokens.dynamicColor`** resolves light/dark with `NSColor(name:)` on the Mac and
    `UIColor { traits in … }` on iOS.
  - **`EvidenceView`** gained `.accessibilityLabel("Close")` on its icon-only close button (a real
    VoiceOver gap), and its fixed minimum size applies on macOS only.
- **Evidence:** `EvidenceSourceProviding` has two implementations.
  - `CheckoutEvidenceSource(repoRoot:)` is the Mac's existing `EvidenceSourceLoader`.
  - `SnapshotEvidenceSource(outputDirectory:)` is M3's `Store.evidenceSlice`; a missing range throws
    `.notInSnapshot` with a plain explanation.
  - `EvidenceSnippet` gained `truncated`. `EvidenceView(evidence:source:)` notes when a snippet was
    shortened ("the full code is in Orion on your Mac").
  - The Mac's three call sites (component inspector, Ask, Teaching) pass `CheckoutEvidenceSource`.
- **`OrionMobile/project.yml`:**
  - depends on `OrionCore` (`../OrionMacOs`) and the vendored Grape, with the app in Swift 5 mode
    like `OrionApp`;
  - adds an `OrionMobileTests` target, with `TEST_HOST` overridden because xcodegen derives it from
    the target name, `OrionMobile.app`, while the product is `Orion.app`;
  - adds an `OrionMobileUITests` target with its own `OrionMobileWalkthrough` scheme, so it isn't
    part of the default test run.
- **The app** (`OrionMobile/OrionMobile/`):
  - **`RootView`:** a `TabView` (`.sidebarAdaptable`) with Explore, Ask, Learn and Library. Explore
    is rebuilt per repository and per import (`generation`). It starts on Explore when a repository
    is open, and on Library with the probe sheet when `FM_PROBE_AUTORUN=1`, which keeps M0's re-run
    path.
  - **`LibraryModel`** (`@Observable`, main actor):
    - `entries`; `selectedKey`, persisted in `UserDefaults`;
    - `importPickedFile` (security-scoped, copied out first, with a sibling `.manifest.json` used
      when readable);
    - `importInbox` (every `*.orionsnap` in Documents, checked against its sibling manifest, then
      removed; failures move to `Documents/Failed Imports/`, so they aren't retried every launch);
    - `remove`, and a status message.
    - A first import opens the repository. Inbox import runs at launch and whenever the app becomes
      active.
    - Documents was already Finder-visible (`UIFileSharingEnabled`), so a snapshot can be dropped in
      from Finder, with `devicectl device copy to`, or with `simctl`.
  - **`LibraryView`:** one row per repository (name, commit, analysis date, and counts), with a
    checkmark for the open one. Swipe-to-remove has a confirmation that says the device's own
    learning goes too. A ⋯ menu offers Import Snapshot… and On-Device Model… (the M0 probe as a
    sheet). There is an empty state, plus an import progress overlay and status bar.
  - **`ExploreView`:**
    - the shared layer banner, and a Map/List switch;
    - Map is the shared Grape diagram, where tapping a node pushes it;
    - List shows rows for Open Questions and Model Changes, then the components with their
      confidence badges; it's also the accessible path through the map;
    - toolbar shortcuts to Open Questions and Model Changes.
    - Destinations: `ComponentDetailView` with `SnapshotEvidenceSource` and `onShowRevision`,
      `OpenQuestionsPanel`, and `ChangesListView`, a list that pushes `ModelChangeDetailView`. It
      opens a superseded claim's revision directly.
  - **Ask and Learn** are honest "Coming Soon" screens.
- **Records:** `ComponentRecord`, `ComponentMemberRecord`, `ComponentRelationshipRecord`,
  `ClaimRecord`, `EvidenceRecord` and `ModelRevisionEntryRecord` gained explicit `public init`s. It
  is the M1 memberwise-boundary issue again, now hit from the iOS test target. Declaration order is
  kept, with `= nil` for optional `var`s, so no call site changed.
- **Tests:**
  - **`OrionMobileTests`** (7, iOS simulator). They use `SnapshotFixture`, a minimal snapshot built
    with `OrionCore` alone, because the Mac builder doesn't build for iOS.
    - Inbox import installs the repository, opens it, and empties the inbox.
    - A broken file moves aside, and a tampered manifest is refused.
    - The selection persists across a relaunch, and removing a repository clears it.
    - `platformDefault` is `.importedSnapshot` on iOS.
    - The shared `ArchitectureModelLoader`, `ComponentDetailLoader` and `ModelChangeLoader` read an
      imported snapshot.
    - `SnapshotEvidenceSource` returns lines 17–25 around 20–22, and `.notInSnapshot` otherwise.
  - **`OrionMobileUITests.ExploreWalkthroughUITests`** walks Library → Map → List → a component →
    its evidence → Model Changes → a change, attaching a screenshot per screen. It runs on demand
    against the simulator's library, and skips when the library is empty.

**Results:**

- **Real data, simulator (iPhone 17).**
  - The M2 Starlette (`--commit 4f250d6b`) and Pulsed snapshots were rebuilt from database copies,
    because the scratchpad had been cleaned between sessions. Sizes were identical to M2.
  - Dropped into Documents with `simctl`: both imported at launch, the inbox emptied, and the
    library manifests carried the snapshots' sha.
  - The walkthrough passed. Screenshots are in `Agent Feasibility Study/results/ios_companion/m4/`
    (Starlette only):
    - **Map:** 11 semantic components and their edges, labelled.
    - **List:** Open Questions (5), Model Changes, and 11 components with confidence badges.
    - **Component detail:** Purpose with an Interpretation badge, five members by kind, three
      dependencies, and claims including a Contradicted one.
    - **Evidence:** the `Starlette` member's snippet, lines 17–19 of context and then the highlighted
      range from 20.
    - **Model Changes:** the timeline, and a "Claim refined" detail with Previously / Now / Reason,
      inline code rendered.
- **Real device (iPhone 17).**
  - A Debug build was installed with `devicectl`.
  - `starlette-4f250d6b8145.orionsnap` + `.manifest.json` were copied into the app's Documents with
    `devicectl device copy to`, and the app was launched.
  - The library manifest read back from the device: starlette 4f250d6b, 33 components, 462 snippets,
    sha `ef664473e327`, and the inbox was empty.
  - **The repository is now in the app on that iPhone.**
- **Suites:** `swift test` with CI's skip list: **519 passed**. `OrionApp`: **148 passed**, so the
  refactor is behavior-neutral on the Mac. `OrionMobileTests`: **7 passed**. The walkthrough passed.

**Findings:**

1. **The architecture map has never drawn its node labels, on the Mac either.**
   - Grape's `annotation(_ string: String?, …)` overload builds `TextAnnotation(nil, …)`; it
     discards the string. This is true in the tagged 1.1.0 release as well as the vendored `main`.
   - `.annotation(node.name, …)` with a `String` variable resolves to it, so every map since Phase 4
     showed unlabelled circles.
   - The shared diagram now uses the builder overload with an explicit `Text`, offset below each
     circle by its radius plus 8 pt (Grape anchors the label near the node's center). That fixes
     both apps.
   - Worth reporting upstream. `Vendor/Grape` itself is unchanged.
2. **At phone width the map is dense.** Labels in the middle cluster overlap. Grape's pinch-zoom and
   List mode cover it for now; force tuning or label collision is M8.
3. **The evidence code font** (monospaced `.callout`) needs horizontal scrolling on a phone. A
   smaller iOS size is M8 polish.
4. **xcodegen derives a test target's `TEST_HOST` from the app target's *name*.** With
   `PRODUCT_NAME: Orion` that points at a nonexistent `OrionMobile.app`; it is overridden in
   `project.yml`.

### M5: CloudKit sync `[done]`

**Plan (as written):**


- **A new `OrionSync` package target** (CloudKit + `OrionCore`, both platforms):
  - Storage: the private database, custom zone `OrionKnowledge`, record type `KnowledgeSnapshot`. The recordName is the `libraryKey`; the record holds the manifest fields plus a `payload` CKAsset.
  - `CKSyncEngine` runs on both sides behind a `SnapshotTransport` protocol, so tests can use a fake.
- **Mac:** a per-repo "Sync to iPhone" toggle, stored next to `RecentRepositories`.
  - While it is on, the Mac republishes after each successful analysis, Build Architecture Model or teaching generation.
  - It shows the sync status: when it last synced, and the snapshot size.
  - The UI tells the user that code snippets are uploaded to their private iCloud.
- **iPhone:**
  - It fetches changes, downloads the asset, runs the M3 importer, and shows an "Updated to <commit>" banner.
  - If the record is deleted on the Mac, the phone keeps its local copy, marked "no longer synced".
- **Entitlements:**
  - Mac: a new entitlements file with iCloud/CloudKit and push only. The app stays unsandboxed (Docs/13 Decision 4).
  - iOS: iCloud, push and background fetch.
  - Both apps need team signing. CI keeps building unsigned and only tests the fake transport.

**What was built.** It follows `.agents/skills/cloudkit` (the user-installed CloudKit skill): its
workflow, its `CKSyncEngine` pattern and its review checklist.

- **`OrionSync`** (new package target; CloudKit + `OrionCore`; macOS and iOS):
  - **`SnapshotCloud`** defines how a snapshot looks in iCloud:
    - container `iCloud.com.gilangbbe.orion`, the **private** database, custom zone `OrionKnowledge`
      (the default zone has no change tracking);
    - one `KnowledgeSnapshot` record per repository, named by its `libraryKey`, so a newer snapshot
      replaces the old one;
    - `payload` is `[CKAsset]` (encrypted by default), the `.orionsnap` chunked into ordered 45 MB
      parts, below the 50 MB asset limit;
    - `manifest` is the manifest JSON in **`encryptedValues`** (it names the repository and is
      never queried or sorted on); only `formatVersion` is plain;
    - `chunk`, `populate` and `assemble` (which runs inside the fetch event, because CloudKit's
      asset files are temporary).
  - **`SyncStateStore`** (files) persists two things:
    - the engine's `State.Serialization` (change tokens and pending changes), so a relaunch
      resumes instead of refetching everything;
    - each record's last-saved **system fields** (`encodeSystemFields`), so a save carries the
      server's change tag.
    - `reset()` runs after an account sign-out or switch.
  - **`SnapshotOutbox`** + **`SnapshotPublisher`** (the Mac):
    - **Staging comes first.** A snapshot is staged on disk (atomic replace), and only then are
      `.saveZone` and `.saveRecord` enqueued. That's the skill's "make the local change durable,
      then enqueue".
    - **Building records:** `nextRecordZoneChangeBatch` builds each record on its last-saved
      system fields and filters with `context.options.scope.contains`.
    - **Failure handling:**
      - `serverRecordChanged`: keep the server's change tag, put the Mac's content back on top, and
        save again. The Mac is the only writer, so the skill's three-way merge reduces to that.
      - `zoneNotFound` / `userDeletedZone`: recreate the zone and resend.
      - `unknownItem`: start a fresh record.
      - Transient errors (network, `zoneBusy`, `serviceUnavailable`, rate limiting): kept pending
        for the engine to retry.
      - `quotaExceeded` and `notAuthenticated` become user-visible statuses.
    - **Account changes:** sign-in re-enqueues the outbox; sign-out resets state; a switch resets
      state and then re-enqueues.
    - **Deletions:** a confirmed deletion clears that record's system fields.
  - **`SnapshotReceiver`** (the iPhone) only fetches. For each changed `KnowledgeSnapshot` it
    assembles the file and calls `install`; each deletion goes to `removed`. Status moves through
    idle, fetching, up-to-date and failed. A sign-out or switch resets state.
- **Entitlements and signing** (both via `project.yml`):
  - **iOS:** `aps-environment`, `icloud-container-identifiers`, `icloud-services: CloudKit`, and
    `UIBackgroundModes: remote-notification`.
  - **Mac:** `com.apple.developer.aps-environment`, the same container, and CloudKit. The app now
    signs with **Apple Development** (`CODE_SIGNING_REQUIRED: YES`) and stays unsandboxed
    (Decision 4).
  - With `-allowProvisioningUpdates`, Xcode **created the container and both App ID capabilities
    itself**. Both embedded profiles list `iCloud.com.gilangbbe.orion` (development and
    production), so no portal visit was needed.
- **Mac app:**
  - **`IPhoneSync`** (`@Observable`, shared):
    - **Switch:** per-repository and **off by default**, persisted in `UserDefaults` by
      `libraryKey`.
    - **Lazy start:** the publisher is created only once something syncs.
    - **Account gate:** every publish checks the iCloud account first.
    - **Publishing:** it builds the snapshot off the main thread (`KnowledgeSnapshotBuilder`, which
      is what the app shows). It **skips the upload** when the knowledge hasn't changed (same run,
      commit and counts), so reopening a repository doesn't re-upload it. "Sync Now" forces a
      rebuild and upload.
  - **`IPhoneSyncSection`** in the sidebar footer:
    - the "Sync to iPhone" switch;
    - status (Preparing / Uploading / Synced *relative time* / the error);
    - "Sync Now";
    - "Sends this repository's knowledge, with the code snippets its evidence cites, to your private
      iCloud."
  - **`ContentView` republishes** when a repository becomes ready (after an analysis, or when
    opened) and when Build Architecture Model completes.
  - **DEBUG launch hook** for the headless end-to-end check: `ORION_SYNC_PUBLISH=<repo>`, plus
    `ORION_SYNC_ACTION=unpublish`. It's an environment variable, never a positional argument
    (AppKit would try to open that as a file).
- **iPhone app:**
  - **`CloudSync`** (`@Observable`) works in three steps:
    1. Check `accountStatus()`; a missing, restricted or temporarily unavailable account is shown
       in the Library.
    2. Start the `SnapshotReceiver`.
    3. Fetch at launch, on returning to the foreground, on pull-to-refresh, and on
       `CKAccountChanged`.
    - It never touches iCloud under XCTest.
  - **`AppDelegate`** registers for remote notifications (the engine's database subscription
    pushes).
  - **`LibraryModel.installFromCloud`** goes through the same path as a manual import (sha check
    against the record's manifest, M3 carry-over). It is **skipped when that sha is already
    installed**, so an unchanged record never rebuilds the repository.
  - **`markNoLongerSynced`** keeps the repository and marks it, persisted across launches; syncing
    it again clears the mark.
  - **`LibraryView`:**
    - an iCloud status row: "Up to date with your Mac · checked *time*", "Checking iCloud…", the
      error, or "Sign in to iCloud in Settings…";
    - pull-to-refresh;
    - "No longer synced from your Mac" on a dropped repository;
    - an empty state pointing at Sync to iPhone.
- **Tests:**
  - **`OrionSyncTests` (+7, `swift test`, no iCloud needed):**
    - the record round-trips its manifest and file;
    - the manifest is encrypted, not a plain field;
    - 2,500 bytes in 1,000-byte parts reassemble in order;
    - foreign and payload-less records are rejected;
    - the outbox stages, replaces and removes;
    - system fields survive a relaunch, and `reset` forgets everything.
  - **`OrionMobileTests` (+3):**
    - a cloud install of an already-installed sha is a no-op (`generation` doesn't move);
    - the Mac stopping sync keeps the repository and marks it, remembered across launches, and a
      re-sync clears the mark;
    - a bad payload throws, so the receiver can report it.

**Results (real Mac + real iPhone 17, same Apple ID, CloudKit Development environment).**
Starlette only: it's public code. Pulsed was not uploaded.

| Step | What happened |
|---|---|
| Publish | The Mac app (signed, entitlements verified with `codesign -d --entitlements`) staged the Starlette snapshot it shows. **CloudKit confirmed the save**: the record's system fields were written, which only happens on `savedRecords`. |
| First receive | The iPhone app was launched. Its library now held exactly the Mac's snapshot (sha `5cc361fe…`, same `createdAt`), **replacing** M4's `4f250d6b` copy through M3's importer. |
| Update, app still running | The Mac republished (sha `ff7ce72f…`, uploaded in ~5 s). With the iPhone app left running, **no update arrived within 4 min** (the phone had auto-locked). Bringing the **same process** (pid 3673) to the foreground fetched and installed it **within ~35 s**. |
| Mac stops syncing | `ORION_SYNC_ACTION=unpublish` removed the outbox and deleted the record. Within ~10 s of foregrounding, the iPhone **marked Starlette "no longer synced" and kept its copy** (sha `ff7ce72f…`). |
| Cleanup | Sync for Starlette is off on the Mac (the enabled list is empty). The iPhone's Starlette was restored to the 33-component commit snapshot from M4. |

- **Suites:** `swift test` with CI's skip list: **526 passed** (519 + 7). `OrionApp`: **148 passed**,
  now signed and entitled. `OrionMobileTests`: **10 passed**. iOS and Mac builds are signed with
  the new profiles.

**Findings:**

1. **Switching sync off on a fresh launch didn't delete the iCloud record.**
   - The publisher is created lazily, and `setEnabled(false)` called `publisher?.unpublish`, which
     did nothing on `nil`, so the outbox and the record stayed.
   - Caught by the live unpublish run. It now starts the publisher (behind the account check)
     before unpublishing.
   - It is the realistic case: you'd usually switch a repository off after relaunching Orion.
2. **A silent push waking the app isn't demonstrated yet.**
   - The app registers for remote notifications and the engine's subscription exists. But with the
     phone locked, iOS defers silent pushes for suspended apps, and nothing arrived in 4 min.
   - The launch, foreground and pull-to-refresh paths are all verified.
   - **Follow-up for M8:** repeat with the phone unlocked and Orion backgrounded, or just
     foregrounded.
3. **No portal step was needed.** Automatic provisioning with `-allowProvisioningUpdates` created
   the container, the iCloud and Push capabilities, and new per-app profiles for both bundle IDs.
4. **Schema rollout** (the skill's checklist):
   - The `KnowledgeSnapshot` record type exists only in the container's **Development**
     environment, where it was auto-created by the first save.
   - **Before any TestFlight or App Store build, deploy the schema to Production** in CloudKit
     Dashboard. After that, only add fields; never change or remove `manifest`, `payload` or
     `formatVersion`.
5. **Latency:** about 5 s Mac → iCloud. On the phone, a foreground fetch took about 10 s for a
   deletion and about 35 s for an update, including decompression and carry-over. That's fine for
   a "sync when I pick up my phone" flow.

**Skill review checklist:**
- **Done:**
  - capability on both apps;
  - account checked before syncing, with the no-account case shown in the UI;
  - private database only, in a custom zone;
  - `serverRecordChanged` merged onto `serverRecord`;
  - transient errors kept pending (the engine honors `retryAfterSeconds`);
  - `CKSyncEngine` with remote notifications enabled;
  - state serialization persisted;
  - zone deletion handled by recreating the zone;
  - encryption: the manifest is in `encryptedValues`, assets are encrypted by default, and no
    encrypted field is ever queried.
- **Not applicable:** SwiftData; `NSUbiquitousKeyValueStore`; per-item `partialFailure`, which the
  engine already splits into `failedRecordSaves`.

### M6: On-device Ask `[done]`

**Plan (as written):**


- **`CompactContextBuilder`** (portable) replaces the export-file `ContextBuilder` on iOS:
  - It picks the most relevant components, claims and symbols for the question by word match, reusing `AnchorAlignment`'s tokenization. An FTS5 table built into the snapshot is an optional upgrade.
  - It packs them into a token budget measured with `tokenCount(for:)`: `contextSize` minus a reply
    reserve minus the cost of the tool schemas. On the iPhone that is ~2,300–2,800 tokens
    (≈ 10–12K characters, M0 finding 2).
  - It keeps at most one prior turn, summarized.
- **Answering is always a `NativeToolLoop`**, with a small tool budget (~3 calls):
  - Tools: the 4 `QueryEngineTools`, plus new `evidence_snippet(anchor)`, `component_summary(name)` and `search_claims(text)`.
  - Tool results are truncated to fit the budget.
- **Generation and error handling:**
  - Lower `LocalGenerationDefaults.maximumResponseTokens` (currently 8192) for the system model.
  - On `contextSizeExceeded`, shrink the context and retry once, then fail honestly.
- **Routing:** `DepthHeuristics` plus the Phase 5 guardrail. There is no depth 3. The Phase 3 "not independently checked" labeling carries over.
- **App behavior:**
  - The app shows clear states when the model is unavailable: the device isn't eligible, Apple Intelligence is off, or the model isn't ready yet.
  - Answers stream in.
  - `ask_sessions` are saved on the phone.
- **Bench on the device (M0 finding 1):** the Mac runs a different, larger model, so its numbers
  don't transfer.
  - A debug bench screen in `OrionMobile` runs the 55 Starlette questions against the imported
    snapshot and writes JSON. The JSON is pulled with `devicectl`, the same way as the M0 probe.
  - Hand-grade a sample against the Docs/18 M6 Core AI numbers.
  - `orion-agent bench --local-backend system` on the Mac stays a quick development check only.
  - Write the results up in `Agent Feasibility Study/IOS_COMPANION_EVAL.md`.

**What was built.** It follows `.agents/skills/apple-foundation-models-skill` (the user-installed
Foundation Models skill). The references loaded were system-language-model, session-lifecycle,
error-handling, concurrency, tool-calling, streaming, performance, prompting-techniques and
transcripts.

- **`CompactContextBuilder`** (`OrionAgent/Context/`) primes the model with only what the question
  is about.
  - **What it ranks:** lexical retrieval over the latest architecture investigation's components,
    the run's claims, and symbols whose names contain a code-like word from the question.
    Identifiers are split on `_` and case, and stopwords are dropped.
  - **What it never includes:** `CONTRADICTED` claims, which the consistency check already
    rejected (48 of Starlette's 108).
  - **What always comes first:** the repository overview, a component-scoped session's focus, and
    the previous turn, summarized.
  - **How it packs:** greedily into `budgetTokens`, estimated at 4 characters per token, then
    checked with the model's own `tokenCount` and trimmed (up to 3 passes).
- **`SnapshotTools`** (`OrionAgent/Tooling/`), four tools, because every schema costs context (the
  skill: "limit tools"):
  - `lookup_symbol` and `callers`: the Mac's own.
  - `symbol_details`: signature, docstring, and up to 30 lines of **code from
    `evidence_snippets`** when the snapshot carries them; otherwise it says the code isn't on the
    device. A bare name prefers the symbol actually named that, then non-module symbols, after a
    test caught `"Router"` resolving to `pkg/router.py`.
  - `search_claims`: checked claims ranked by overlap, never `CONTRADICTED`.
- **`AgentSession` seams.** Mac behavior is unchanged by default.
  - `contextProvider` receives a `ContextRequest`: the question, prior turns, focus, store, run, the
    instructions without context, the tools, and the attempt number.
  - `toolsProvider` supplies the tool set.
  - `toolResultCharLimit` caps each result through `AgentToolAdapter`, and the ledger records what
    the model saw.
  - `ask(_:sessionId:onPartialAnswer:)` streams the answer. `ToolCallingTurnGenerating` gained a
    streaming requirement with a default implementation; `FoundationModelsToolSession` streams via
    `streamResponse`.
  - **Overflow recovery (the skill):** on `LanguageModelError.contextSizeExceeded`, with a provider,
    one retry asks it for less (attempt 1 halves the budget). Without a provider, the error
    propagates as before.
  - **`AgentSessionConfig.canDelegate`:** when `false`, a depth-3 routing runs at depth 2, and the
    rationale says so (see the findings).
- **`SystemModelAsk`** (`OrionAgent/Model/SystemModel.swift`) is the phone's whole configuration in
  one place:
  - **Budget:** `contextSize − tokenCount(base instructions) − tokenCount(tools) −
    tokenCount(question) − 512 reply − 3 × 225 tool results − 96 margin`.
  - **Tools:** `SnapshotTools`, results capped at 900 characters, a budget of 3.
  - **Model:** `.system` (reply cap 512 tokens), with `canDelegate = false`.
  - **The Mac CLI** routes `orion-agent ask` and `bench` with `--local-backend system` through it, as
    a development check of the phone's path.
- **Shared with the Mac** (`OrionApp/Shared/`): `AskTurnSummary.swift` holds `AskResultSummary`,
  `AskClaimSummary`, `AskToolCallSummary`, `AskOutcome`, and `AskTurnLoader`, the persisted-turn
  loader moved out of `AskRunner`, which keeps forwarding calls and a typealias. `AskOutcomeLabel`
  holds the declined → not independently checked → partial → verified rule. Both apps label an
  answer the same way.
- **iOS app:**
  - **`AskModel`:**
    - **Gate:** availability before any session exists, with each reason a state (not eligible,
      Apple Intelligence off, model not ready).
    - **Conversations:** persisted `ask_sessions` per repository (which M3 carries across
      re-syncs). "Ask about" from a component resumes that component's latest conversation, or
      scopes a new one.
    - **Asking:** `SystemModelAsk` runs off the main actor, and the streamed text updates the UI.
    - **Errors:** the skill's OS 27 mapping (context, guardrail, refusal, language, rate limit,
      timeout, concurrent requests, assets, tool calls) in plain words.
    - **Prewarm** happens while idle.
  - **`AskView`:**
    - a conversation (question, Markdown answer, the shared outcome label, evidence that opens the
      snapshot's code);
    - streaming with "Looking through the repository…";
    - a multi-line composer, conversations in a sheet, new conversation, and unavailable states.
    - A typed newline sends, because a multi-line `TextField`'s return key inserts a newline instead
      of submitting. The Ask walkthrough caught this.
  - **"Ask about"** from Explore's component detail switches to Ask (`AskRequest`).
- **On-device benchmark:**
  - **`AskBench`** runs the bundled questions against a copy of the open repository's database, so
    benchmark answers stay out of the user's history and model changes. It copies the WAL files
    too, and writes JSON after each question.
  - Questions come from `starlette-ask-bench.json`, generated by `scripts/make-ask-bench.sh`.
  - **Two ways to start it:** Library ⋯ → Ask Benchmark…, or `ORION_ASK_BENCH=all|<ids>` plus
    optionally `ORION_ASK_BENCH_DEPTH=2` at launch.
- **Tests:**
  - **`CompactAskTests` (12):**
    - identifier terms and code words;
    - retrieval with no contradicted claims, and evidence on claims;
    - packing keeps mandatory items and drops the lowest scores first;
    - trimming against a pessimistic counter;
    - `search_claims` skips contradicted claims;
    - `symbol_details` resolves by name and reports when its code isn't on the device;
    - the four-tool set;
    - the overflow retry runs attempts 0 then 1, with capped tool results;
    - an overflow without a provider still propagates;
    - the streaming callback;
    - depth 3 without delegation runs at depth 2.
  - **`AskModelTests` (4, iOS):** "Ask about" resumes or scopes, conversations load and delete,
    errors in plain words.
  - **`AskWalkthroughUITests`** (on demand) asks one question in the simulator.

**Results** (full write-up: `Agent Feasibility Study/IOS_COMPANION_EVAL.md`; raw:
`results/ios_companion/m6/`):

- **10 hand-graded questions at depth 2, iPhone 17:** **10.0/20, median 13.0 s, max 17.2 s, 2.2 min
  total.**
  - Core AI on the Mac, same rubric and questions: 7.0–8.0/20 at a median of 45–99 s.
  - Graded by Claude, single grader, n = 10.
- **All 55, real routing, after the depth-3 fix:**
  - 53 answered at depth 2, all with tool calls (2.8 calls on average): 35 verified, 18 partially
    verified.
  - 0 "ask on your Mac".
  - 2 guardrail false positives.
  - Median 19.3 s, p90 23.3 s, max 38.6 s; answer text starts streaming at a median of 14.2 s.
- **Mac check of the same path** (`--local-backend system`, Starlette at `4f250d6b`): a depth-1
  answer gave `add_route`'s real parameters in 13 s, from the packed symbol signature; M1's answer
  had been shallow. A forced depth-2 answer used 3 capped tool calls in about 20 s.
- **Simulator** (host model): one question asked, streamed, and answered with
  `add_route`'s parameters, labelled "Not independently checked" because heuristics routed it to
  depth 1 with no tools (screenshot `m6/simulator-ask-answer.png`).
- **Suites:** package **538** (+12 `CompactAskTests` = 526 + 12), Mac app **148**, iOS **14**
  (+4), 0 failures.

**Findings:**

1. **The iPhone's classifier sends 35% of questions to depth 3** (19/55), against 1/55 for the Mac's
   larger model. With no deeper tier, those got "ask on your Mac". Fixed with `canDelegate = false`,
   which answers them at depth 2: 53/55 answered afterwards.
2. **The safety guardrail false-positives on benign code questions about 2–4% of the time**
   (CU-05 in both routed runs, BR-03 once). Shown honestly, not worked around.
3. **Context beats model size here.** The phone's ~4K window, primed with the right claims and
   signatures, outscored Qwen3 primed with a 20K-character export dump. The Mac's own Ask might
   benefit from `CompactContextBuilder` too, as a follow-up.
4. **Bugs caught on the way:**
   - `symbol_details("Router")` returned the `pkg/router.py` module (a substring match on the path);
     it now prefers exact names.
   - The multi-line composer's return key inserted a newline instead of sending.
5. **Latency is tool rounds.** About 14 s before text streams and about 19 s to completion. Fewer
   or cheaper rounds (or reliable KV reuse) are the lever.

### M7: On-device Learn (teaching) `[done]`

**Plan (as written):**

- **Where questions come from**, in this order:
  1. Questions verified on the Mac and shipped in the snapshot (all bands).
  2. Questions drafted on the device, bands 1–2 only, by `LocalTeachingDrafter` over the system model. They always go through `TeachingQuestionVerifier`, which is in `OrionCore` and so runs on the phone.
  3. Band 3 questions are only available when shipped from the Mac.
- **Grading:** `RubricGrader` with a system-model judge.
  - The judge must be guided. The system model can't think (M0 finding 3), and Docs/18 M4 showed a
    text judge without thinking says "met" to about 95% of criteria.
  - Use a **single-call** guided judge (quote → reasoning → verdict → confidence). The system model
    keeps declaration order (M0 finding 4), so the two-turn `GuidedCriterionJudge` isn't needed here.
    At ~2.5 s per vote, choose k (1 or 3) from on-device timing.
- **Calibration gate (mirrors Decision 10):** run the gold set `starlette_teaching_grader.gold.json`
  **on the device**, through the M6 bench screen, since the Mac's model differs.
  - Until it clears the bar, the phone shows "self-check only" with `persistMastery: false`, exactly like the Mac today.
  - The planner still ranks concepts by centrality and open misconceptions.

**What was built.** It follows `.agents/skills/apple-foundation-models-skill`. The references loaded
were guided-generation (including `DynamicGenerationSchema`), prompting-techniques and performance
(`tokenCount(for: GenerationSchema)`), on top of M6's.

- **`SingleCallCriterionJudge`** (`OrionAgent/Teaching/GuidedGrading.swift`): one guided turn into
  `CriterionJudgement { evidenceQuote, reasoning, answerStatesThisIdea, confidence }`, generated in
  that order.
  - Same kind-neutral prompt and quote grounding as `GuidedCriterionJudge`. Its instructions add the
    skill's "say how to use the reasoning field" steps.
  - `confidence` carries a description: "how sure you are of your true or false verdict" (see
    finding 3).
  - `JudgeOutput.single` (`--judge-output single`) selects it in the CLI.
- **`GuidedTeachingDrafter`** (`OrionAgent/Teaching/`): drafts by guided generation into a
  **`DynamicGenerationSchema` built per concept**.
  - Every anchor field (the reference anchors, each point's evidence) is an enum of **that
    concept's anchors**, so the model can't produce an invented or misspelled anchor, which is the
    verifier's most common rejection on the Mac.
  - The prompt is the task plus the grounding. The schema carries the structure, so there's no
    `promptHint` JSON.
  - The task is chosen in code per band and concept kind (finding 4), and the grounding is ranked
    by words shared with the concept's label (finding 5).
  - **Budget:** grounding lines are dropped until `tokenCount(instructions + prompt + schema)` fits
    `contextSize − 1,000 reply − 96`. On `contextSizeExceeded` it retries once with half the
    grounding (the skill's overflow rule).
  - The result is re-encoded as a `phase7.v1` candidate, so `TeachingQuestionGenerator` and the
    verifier treat it like any other draft.
  - A new `TeachingQuestionDrafting.draft(inputs:)` requirement (default: build
    `TeachingPromptBuilder`'s prompt) lets a drafter shape its own prompt. `TeachingPromptInputs`
    gained `evidenceAnchors`.
- **`SystemModelTeaching`** (`OrionAgent/Model/SystemModel.swift`): the phone's drafter and judge in
  one place, both writing as `device` (so M3 carries the rows across re-imports). It sets
  `judgeVotes = 1`. `orion-agent teach next --local-backend system` drafts through the same drafter.
- **`GraderCalibration`** (`OrionAgent/Teaching/`): the gold file, seeding, per-item evaluation,
  `CalibrationRow` and `CalibrationSummary`, moved out of the `orion-agent teach bench` executable
  so the phone runs the identical harness. The CLI keeps only the console report.
- **`OrionCore` changes:**
  - `RubricGrader.grade(…, onProgress:)`: (judged, total) after each criterion, for the phone's
    progress bar.
  - **The verifier's contradicted-claim diagnostic now names the claim** and steers the next draft
    off it. Steering it off the claim, not just its citations, avoids teaching a drafter to keep the
    same answer and cite different symbols.
  - `RubricScoring.correctionText` no longer says "You covered every required point" while points
    await review (finding 6).
- **Shared with the Mac** (`OrionApp/Shared/`):
  - `TeachingLoader` moved there.
    - Concept bootstrap is off by default on iOS: the phone must never invent concepts the next
      import can't match.
    - New `nextQuestion(conceptId:band:excluding:)`: a Mac-shipped question first, then the
      device's own; unanswered before answered.
    - `TeachingQuestionCard.generatedBy` records who wrote a question.
  - `TeachingGradeViews.swift`: the verdict header, criterion checklist, misconception outcome,
    eyebrow and vocabulary, pulled out of the Mac's `TeachingView`, which now uses them.
  - `MarkdownText` escapes Python dunders outside code spans (finding 6).
- **iOS app (`Learn/`):**
  - **`LearnModel`:**
    - **Gate:** availability first; the unavailable states are shared with Ask via
      `ModelUnavailableView`.
    - **Concepts:** the planner-ranked list, read only.
    - **Questions:** opening a concept resumes its best question, else offers Recall, Comprehension
      and Transfer. Transfer comes only from the Mac. A rejected draft says why, with the
      verifier's reasons under Details.
    - **Grading:** `RubricGrader(k: 1, persistMastery: LearnModel.isCalibrated)` off the main actor,
      with per-point progress. "Another question" and "One level up" follow.
    - **Prewarm** happens while idle.
  - **`LearnView`:**
    - the concept list with mastery bands, a "Practise Next" shortcut and the self-check note;
    - the practice screen: question with its origin ("From your Mac" / "Written on this iPhone"),
      answer, "Checking point n of m", the shared breakdown with evidence that opens the snapshot's
      code, correction, follow-up.
  - **`LearnBench`:** on-device calibration at each requested k, plus drafts for the top concepts,
    on throwaway database copies.
    - **Two ways to start it:** Library ⋯ → Learn Benchmark…, or `ORION_LEARN_BENCH` /
      `ORION_LEARN_BENCH_K` / `ORION_LEARN_BENCH_DRAFTS` at launch.
    - The gold set is bundled from `Agent Feasibility Study/benchmark/`, a single copy.
- **Tests:**
  - **Package (+13):**
    - **single-call judge:** one call, and the declaration order in `x-order`;
    - an ungrounded "stated" verdict is unconfident;
    - `LocalGrading.single`;
    - **guided drafter:** a verified `device` question end to end;
    - the anchor enums hold only the concept's anchors;
    - budget trim, and the overflow retry;
    - band and concept come from the request;
    - grounding priority, by kind and by relevance;
    - no plain-prompt drafting;
    - one task per kind, no "or" alternatives;
    - the verifier names the contradicted claim;
    - the correction never claims coverage during review.
  - **iOS `LearnModelTests` (6):**
    - concepts are never extracted;
    - a shipped question comes before the device's own;
    - drafting goes through the verifier;
    - a rejection shows its reasons and keeps nothing;
    - transfer questions come only from the Mac;
    - grading keeps the attempt but writes no mastery.
  - **Mac app (+1):** the `MarkdownText` dunder test.
  - **`LearnWalkthroughUITests`** (on demand): practise one concept in the simulator.

**Results** (full write-up: `Agent Feasibility Study/IOS_COMPANION_EVAL.md`; raw:
`results/ios_companion/m7/`). **On a real iPhone 17:**

- **Grader calibration**, the 15-answer gold set at k = 1. Full table in the eval doc.
  - **Shipped (greedy, `confidence` undescribed): κ 0.62** (required 0.76, anti 0.51), verdict
    accuracy 0.53, 35% of points unconfident.
  - About 23 s per graded answer; a judge call takes 2.8–3.5 s (p50).
  - The other runs: sampled κ 0.69. k = 3 scored κ 0.60 at 3.3× the time. With `confidence`
    described, κ was 0.58 sampled and 0.51 greedy.
- **On-device drafting**, 10 top-ranked concepts:
  - 9/10 kept in each of three runs, at a median of 12–14 s.
  - Every rejection was the contradicted-claim check, and no draft failed on an anchor.
  - About 3 of 27 kept drafts are usable as written (finding 1).
- **Simulator walkthrough** (host model): concepts → a drafted question → an answer → the breakdown
  (screenshots in `m7/`). Its off-topic answer found finding 6.
- **Mac check** (`--local-backend system`): `teach bench --judge-output single` κ 0.77 on 3 items at
  about 2.1 s a call; `teach next` drafts a verified question in 8–25 s.
- **Suites:** package **551** (+13), Mac app **149** (+1), iOS **20** (+6), 0 failures.

**Gate decision: held.** `LearnModel.isCalibrated` stays `false`.
κ 0.62 clears the 0.60 bar, but:
- verdict tiers are right only 53% of the time (expert off-track → "shaky" for 3 of 6);
- misconceptions are caught 5 times out of 11;
- a third of the points are left for review;
- the gold set has the limits that held the Mac's gate at κ 0.89: single author, synthetic answers,
  n = 15.

A calibration set with real answers and a second labeller is still the way to clear it, now on
both devices.

**Findings:**

1. **On-device drafting produces grounded questions but not good ones.** The schema's anchor enums and
   the verifier make every kept draft *cite* real, uncontradicted code. Still, most rubrics miss
   their question, state tautologies, or get a fact wrong. At least 6 of 27 contain a wrong point,
   such as the inheritance direction between `BackgroundTask` and `BackgroundTasks` flipping between
   runs. The drafter sees signatures, not code.
   - So device drafts are labelled in the app ("its points can be wrong, so check them against the
     evidence"), and Mac-shipped questions always come first.
   - **But the Starlette snapshot ships 0 questions:** the Mac DB has none.
   - **Recommended for M8:** generate a question set on the Mac before syncing, and give the drafter
     the cited code from `evidence_snippets`, not just signatures.
2. **k = 3 doesn't pay on the phone.** It took 3.3× as long and agreed with the expert less (κ 0.60
   vs 0.69). With greedy decoding a second vote would only repeat the first, so the phone grades
   with k = 1 and greedy.
3. **Describing a field can hurt.** Giving `confidence` a description ("how sure you are of your true
   or false verdict") made the model stop hedging (unconfident points 35% → 5–9%) but turned correct
   points into confident "not stated": κ −0.11 in both sampling modes. Undescribed it stays. An
   eval-driven reversal, as the skill advises.
4. **"X, or Y" in a prompt gets you both.** Offered "relate to or differ from…, or which way a
   dependency runs", the model asked all of it in one question. The task is now chosen in code per
   band and concept kind (the skill's "move conditionals into code"). Relationship sides are named,
   after "the first side" leaked into questions verbatim.
5. **The grounding cap picked the wrong symbols.** The concept's anchors arrive sorted by name, so
   "Routing & Endpoint Dispatch" got a question about convertors. Grounding is now ranked by words
   shared with the concept's label.
6. **Bugs found on the way, shared with the Mac:**
   - The correction said "You covered every required point" when every point was unconfident (the
     off-topic walkthrough answer).
   - The header read "0 of 0 key points".
   - `MarkdownText` rendered `RedirectResponse.__init__` as "RedirectResponse.**init**".
7. **The verifier's contradicted-claim diagnostic now names the claim.** It steers the next draft off
   the claim, not off its citations, which would only teach the drafter to keep the same answer and
   cite different symbols. On Starlette the retry rarely escapes, because the flagged claim is the
   concept itself.

### M8: Hardening + iOS redesign `[done]`

**Plan (as written, M0):**

- iPad layout and accessibility: Dynamic Type, and VoiceOver on the diagram's list mode.
- Snapshot size and build time on a large repository.
- Multiple repos, deleting a repo from the phone, and upgrading an old snapshot format.
- Update the READMEs and the `Docs/README.md` status.

**Added (user, 2026-10-01): a redesign of the iOS app.** It follows
`.claude/skills/apple-hig` (the 16 foundations plus iOS, iPadOS, split views, multitasking,
gestures, pointing devices, tab bars, sidebars, lists and tables, sheets and toolbars) and the
`swiftui-pro` skill (modern API, views, data flow, navigation, design, accessibility). Scope is
**the iOS app only** (user decision): the Mac app's screens are unchanged. Shared views change only
for fixes both apps want.

**Problems in the current UI** (screenshots before the redesign, `results/ios_companion/m8/before/`):

1. **The map is unreadable on a phone.** Labels overlap in a ~360 pt canvas. It's also the default
   view.
2. **Colour means two things.** The Explore header ("Semantic view…") and evidence anchors use
   link and accent colour for text that isn't always tappable. The HIG says to avoid using the
   same colour to mean different things.
3. **Noise.** A "High" confidence badge sits on every component row and every dependency, though
   almost all are high. Component detail shows the raw `depends_on` predicate.
4. **Overloaded titles.** A long claim used as a concept's label becomes a ten-line title on the
   practice screen.
5. **Clipping and fixed sizes.** Evidence code is clipped horizontally. There's a fixed 40 pt
   line-number column, and widespread `caption2`.
6. **No iPad layout.** Every tab is a single `NavigationStack`, stretched.
7. **Switching repositories means a trip to the Library tab.**

**Design** (Apple rule quoted, then how it applies):

- **Navigation.** "Prefer split views in a regular environment."
  - Explore, Ask and Learn become `NavigationSplitView`s: a list and a detail. They collapse to a
    stack on iPhone, opening on the detail where that's the common case (Ask).
  - The tab bar stays: Explore · Ask · Learn · Library, `sidebarAdaptable` on iPad. It minimizes
    on scroll (`tabBarMinimizeBehavior`).
- **Repository switching.** The repository name is the title, with a title menu listing the
  library's other repositories (`toolbarTitleMenu`). Library stays a tab for managing them.
- **Explore home** is a list:
  - a repository summary;
  - Map, Open Questions and Model Changes rows;
  - components with their purpose as a subtitle, filtered by `searchable`.

  Confidence is shown only when it isn't high: "show state with shapes or icons in addition to
  colour", without the noise. The map moves to its own screen, with labels on a material so
  they stay legible, plus a VoiceOver representation that lists its components.
- **Component screen:** an inset-grouped list.
  - **Header:** name, confidence and epistemic status, purpose.
  - **Members** carry a symbol per kind. **Dependencies** are humanized, and each opens the
    component it points to. **Claims** have their sources in a disclosure.
  - "Ask About This" is a toolbar action. "Toolbar: a toolbar acts on content."
- **Evidence:** a sheet with a navigation bar. The title is the symbol, the subtitle the file and
  lines, with a Close button.
  - Code scrolls horizontally, or wraps lines (toggle).
  - The line-number gutter scales with Dynamic Type.
  - Medium and large detents, with a grabber.
- **Ask:** a conversation.
  - The question sits in a trailing bubble; the answer is full-width text with its outcome label
    and a "Sources" disclosure.
  - The empty state suggests questions drawn from the repository's own components: "provide clear
    next steps on any blank screens".
  - The composer is a Liquid Glass bar at the bottom. "Use Liquid Glass for controls … floating
    above content."
- **Learn:**
  - a concept list with an "Up Next" card, then the concepts grouped by kind in planner order;
  - the practice screen leads with the question, with the concept as a short, expandable header;
  - "Check My Answer" in a bottom bar: "Middle or lower controls tend to be easier to reach".
- **Library:**
  - repository rows with a tinted symbol tile;
  - remove by swipe *and* context menu ("give people more than one way to interact");
  - the benchmarks and probe in a "Developer" section of the menu.
- **Throughout:**
  - text styles only (no `caption2` for content), system hierarchical colours;
  - `ContentUnavailableView` for empty states, `Label` for icon + text;
  - a text label on every icon-only button, ≥ 44 × 44 pt targets;
  - one type per file for new views (`swiftui-pro`).

**Hardening:**
- iPad and Dynamic Type (AX5) screenshot passes, and VoiceOver labels on the map, lists and grade
  checklist.
- Snapshot size and time on the largest analyzed repository available.
- Multiple repositories: the title menu, plus per-repository state.
- Verify that a silent push wakes the app (open since M5).
- Folded in from M7: device-drafted questions get the cited code from `evidence_snippets`, not
  just signatures.

**What was built.**

- **Shell (`Shell/`):** `RootView` (a tab bar, a sidebar on iPad, minimizing on scroll; the app
  tint), `RepositoryScoped` (an empty state that points to Library) and `RepositoryTitleMenu`
  (`.repositoryTitleMenu()`: the title menu that switches repositories, plus "Manage
  Repositories"). The library goes into the environment; `showLibrary` is an `@Entry`.
- **Explore (`Explore/`):**
  - **Layout:** a `NavigationSplitView`. The list column (`ExploreHomeList`) holds
    `RepositorySummary`, the Map, Open Questions and Model Changes rows, and searchable
    `ComponentRow`s. The detail column is a `NavigationStack` (`ExploreDetail`).
  - **Screens:**
    - `ComponentScreen` / `ComponentDetailList`: header, members by kind, relationships that open
      their component, claims with a sources disclosure.
    - `MapScreen`: wider spread, labels on a background, pinch to zoom and drag; a VoiceOver
      representation; at most 150 nodes.
    - `OpenQuestionsScreen`, and `ChangesListView` with `ModelChangeRow` (a symbol per kind of
      change).
  - **Navigation:** routes are `ExploreRoute` values. No `NavigationLink(destination:)` remains.
- **Evidence (`Evidence/`):** `EvidenceSheet`: title is the symbol, subtitle is the file and
  lines, with a Close button, a wrap-lines toggle, and medium/large detents. `CodeLinesView` /
  `CodeLineRow` scale the gutter with `@ScaledMetric` and scroll sideways.
- **Ask (`Ask/`):**
  - **Layout:** a split view that opens on the conversation on iPhone
    (`preferredCompactColumn: .detail`), with `ConversationsList` one step back.
  - **Conversation:** `ConversationScreen` holds `AskIntro` with starter questions
    (`AskSuggestions`, drawn from the architecture model), `AskTurnView` (`QuestionBubble`,
    answer, outcome, `SourcesDisclosure`) and `PendingTurnView`.
  - **Composer:** `AskComposer` sits on Liquid Glass in a `safeAreaBar`.
- **Learn (`Learn/`):**
  - **Layout:** a split view. `LearnSidebar` / `LearnConceptList` show `UpNextCard`, then
    concepts by kind in planner order.
  - **Practice:** `LearnPracticeView` shows `ConceptHeader` (collapsible), `DepthPicker`,
    `QuestionCard`, `AnswerField`, `GradingProgress` and `GradeSummary`. `PracticeActionBar` sits
    in a bottom `safeAreaBar`.
  - Opening and closing a concept follows the selection.
- **Library (`Library/`):** `LibraryRepositoryRow` (a tile; stacks at accessibility sizes;
  swipe *and* context menu), `CloudStatusRow`, `LibraryEmptyState`, `LibraryMessageBar` (glass),
  and a "Developer" section in the menu.
- **Design (`Design/`):** `ConfidenceNote` (only when confidence isn't high), `AdaptiveStack` (a
  row that becomes a column at accessibility sizes), `scaledLineLimit`, `readableWidth`
  (720 pt on iPad), `PlainText`.
- **Shared with the Mac:**
  - **Fixes:** `StatusLabel` (colour on the symbol, text in a label colour) in `AskOutcomeLabel`;
    badges kept to one line; `MasteryMeter` as one accessibility element.
  - **Additions:** the `DesignTokens.tint` token; `ArchitectureDiagramView` options (`spread`,
    `labelsOnMaterial`, `zoomable`, all off by default).
  - **Speed:** `ModelChangeSummary: Hashable`; the structural architecture model filters symbols
    and imports in SQL (`Store.symbols(runId:kinds:)`, `relationships(runId:type:)`).
- **Drafter (`OrionAgent`):** `TeachingPromptInputs.codeExcerpts`. `TeachingQuestionGenerator`
  takes each concept anchor's cited lines (14) from `evidence_snippets`. `GuidedTeachingDrafter`
  shows code under the top 3 symbols, and drops code before symbols when over budget.
- **Tests:**
  - **iOS `RedesignLogicTests` (9):** search, confidence wording, member groups, relationship
    verbs, change symbols, evidence titles, library counts, starter questions, concept sections.
  - **iOS `LargeSnapshotTests`:** opt-in timing.
  - **Package (+3):** the drafter sees snapshot code; code is dropped before symbols; excerpt
    capping.
  - **UI (on demand):** the Explore, Ask and Learn walkthroughs redone, plus
    `IPadLayoutUITests` and `AccessibilityAuditUITests`.

**Results** (screenshots before and after in `results/ios_companion/m8/`):

- **iPhone:** every tab redesigned, walked screen by screen in the simulator.
- **iPad Pro 13":** split views in Explore (the map preselected), Ask and Learn, with the tab bar
  at the top and the repository title menu.
- **Dynamic Type at AX5:** no overlap.
  - Library rows and badge rows stack. Badges stay on one line. Line limits loosen (3 → 9).
  - Before these fixes, AX5 broke "Unversioned" mid-word and wrapped "Interpretation" into a
    circle of syllables.
- **Xcode's accessibility audit**, on Explore, a component, Ask, Learn, practice and Library:
  - **Fixed:**
    - orange and green status text (2.3:1 against the 4.5:1 required; now the colour is on the
      symbol);
    - white text on system blue in prominent buttons (3.5:1; now a `tint` token, 5.3:1 in light
      and 3.5:1 under bold text in dark, and a solid button inside content);
    - the "More" hit area;
    - the standalone mastery gauge on the Up Next card.
  - **Remaining:**
    - the disabled "Check My Answer" (inactive controls are exempt);
    - the practice screen's mastery gauge, still reported as a small hit area even inside a padded
      44 pt element; it isn't interactive;
    - five contrast findings the audit attaches to no element, one or two on every tabbed screen
      (likely the floating tab bar);
    - "nearly passed" contrast on system secondary text;
    - Dynamic Type and clipping flags on standard list rows, section headers and the search field.
- **A large repository**, a structural analysis of `transformers` (2,638 files, 132,018
  symbols, 23,532 relationships):

  | Measure | Result |
  |---|---|
  | Analysis on the Mac | 235 s |
  | Snapshot build | 5.2 s |
  | Snapshot size | **21.9 MB** (146 MB database), one CloudKit asset |
  | Import, simulator | 0.54 s |
  | Explore model | 6.25 s → **0.77 s** after the SQL filter |
  | Component search, 2,637 modules | 2 ms |
  | Ask context | 4–24 ms |

  The map is replaced by "2,637 modules are too many to draw. Use the list or search."
- **On-device drafting with code excerpts** (iPhone 17, the same 10 concepts as M7):
  - **10/10 kept**, at a median of 11.2 s. That includes the Exception Handling relationship
    every earlier run rejected.
  - Points are more code-specific and correct (`await self.func(...)` when async; 405 with an
    `Allow` header; the 307 default).
  - About 3 in 10 still carry a wrong point.
  - By my single reading, about 2–3 in 10 are usable as written: better grounded, not yet good
    questions.
- **Suites:** package **554** (+3), Mac app **149**, iOS **30** (+10, one opt-in skipped), 0
  failures. The walkthroughs pass on iPhone (standard text and AX5) and on iPad.

**Findings:**

1. **The map doesn't scale to a phone, or to a large repository.** Even 11 components needed a
   wider spread, legible labels and zoom on a phone. A structural model of a large repository has
   thousands of nodes, so the list and search are the way in, and the map is capped at 150.
2. **A material can't render in Grape's canvas.** View annotations are drawn into a canvas, where
   `.regularMaterial` became solid black bars. Labels use a translucent page colour instead.
3. **`ViewThatFits` doesn't stack text.** Wrapped text always "fits", so it never chose the
   vertical layout at AX5. `AdaptiveStack` decides from `dynamicTypeSize` instead.
4. **The accessibility audit found what screenshots didn't.** Orange and green status text, white
   on system blue, and a frame outside a borderless button (which doesn't grow the hit area).
   `StatusLabel` fixes the first everywhere, the Mac included.
5. **Loading everything to filter in Swift was 8× slower than filtering in SQL** for the structural
   model (132k symbols). The Mac gets the fix too.
6. **The manifest's component count disagreed with the screen** (33 against 11: it counts every
   investigation's components). The Library and Explore summaries show files, concepts and claims
   instead.
7. **Not done:**
   - **Push wake.** Verifying that a silent CloudKit push wakes a suspended app needs the Mac to
     publish while the phone is locked; that's left as a manual check, since it changes what's
     synced.
   - **Mac-shipped question sets.** Generating a question set on the Mac before syncing, the
     recommended main question supply, isn't built.
   - **Production CloudKit schema.** It still needs deploying to Production before a TestFlight
     build.

## Reuse (don't rebuild)

- **Move into `OrionCore` unchanged:** `Store`, `Migrations`, `QueryEngine`, `ComponentDetailQuery`, `AnchorAlignment`, `TeachingPlanner`, `TeachingQuestionVerifier`, `RubricGrader` + `RubricScoring`, `KnowledgeUpdate` and `CalibrationStats`.
- **Use as-is on iOS with the `.system` model:** `FoundationModelsAgent`, `NativeToolLoop` / `ToolCallLedger` / `AgentToolAdapter`, `QueryEngineTools`, `EvidenceAnchors`, `TeachingQuestionGenerator`, `LocalTeachingDrafter`, and `Guided*Judge` / `Guided*Comparer`.
- **App code:** the loaders and views listed in M4, Grape for the diagram, and the slicing logic in `EvidenceSourceLoader`.
- **Benchmarks:** `bench`, `teach bench` and the gold sets get one more backend value, not new harnesses.

## Risks

1. **The system model's context and quality are far below Qwen3-8B.**
   - Mitigation: retrieve only what the question needs, use tool calls, and fall back honestly to "ask this on your Mac".
   - M0 measures the real `contextSize` before any design is locked.
2. **Grading quality without thinking.** Docs/18 M4 measured κ 0.04 for text judges without thinking.
   - Mitigation: the guided judge plus the calibration gate.
   - Grades stay self-check only until the gate clears.
3. **Signing and CloudKit prerequisites block M5 until a developer team exists.** M4's file-import path keeps every other milestone unblocked.
4. **Repository identity across snapshots.** `repository_id` is a random UUID.
   - Carry-over matches concepts by natural key.
   - M3 tests a re-analysis at a new commit.
5. **Snippet privacy.** Code snippets are uploaded to the user's private iCloud.
   - The UI discloses this.
   - Sync is off by default for each repo.
6. **The iPhone and the Mac run different model variants. Confirmed in M0:** AFM 3 Core with
   4,096 tokens on the phone, AFM 3 Core Advanced with 8,192 on the Mac. The M6 and M7 benchmarks
   run on the device.

## Verification

- **Every milestone:**
  - `cd OrionMacOs && swift build && swift test --skip <live classes>` is green.
  - The Mac app tests pass: `xcodebuild -project OrionApp/OrionApp.xcodeproj -scheme Orion -destination 'platform=macOS' test -skipPackagePluginValidation -skipMacroValidation`.
- **M0:** the probe re-run steps listed under M0.
- **M1:**
  - `xcodebuild -scheme OrionCore -destination 'generic/platform=iOS'` builds, and so does `OrionAgent`.
  - `orion-agent ask <starlette> "…" --local-backend system` answers on the Mac.
- **M2:** `orion-index snapshot` on vendored Starlette produces a snapshot whose DB opens and has snippets for ≥95% of evidence anchors (sha-checked). Record the size.
- **M3:** unit tests cover:
  - Import, grade an attempt, then import a newer snapshot: the attempt and its `knowledge_state` survive (natural-key remap).
  - A snapshot in a newer format is rejected.
  - A snapshot in an older format is migrated.
  - A DEBUG build never erases an import.
- **M4:**
  - `xcodebuild -scheme OrionMobile -destination 'platform=iOS Simulator,name=iPhone 17' test` passes.
  - Manually: import the Starlette snapshot in the simulator, then browse diagram → component → evidence snippet.
- **M5:**
  - With signing set up: turn sync on in the Mac app; the iPhone receives, imports and shows the new commit.
  - A re-analysis on the Mac reaches the phone.
  - Fake-transport unit tests run in CI.
- **M6/M7:**
  - The on-device bench screen produces numbers in `IOS_COMPANION_EVAL.md`.
  - On a real iPhone, ask 5 Starlette questions and complete 3 teaching items end to end, recording latency.
