# 18 — OS 27 upgrade: Foundation Models + Core AI backend for local Qwen3

> Status: **M0 done.** The package and app now target macOS 27. `AppleFoundationDepthClassifier`
> is on the OS 27 FoundationModels surface: `@Guide(.range(1...3))`, `LanguageModelError`
> escalation, and the system-model variant recorded in every rationale. CI runs on GitHub's
> `xcode-27` image. A new `orion-agent bench --classify-only` re-validates routing for free.
>
> **Headline finding:** the OS 27 system model ("AFM 3 Core Advanced") never reports `high`
> confidence on the 55 benchmark questions. It sends 54 to depth 2 and 1 to depth 3, so depth 1
> is no longer reachable naturally (Phase 5 on the OS 26 model: 9 / 43 / 3).
> The guardrail holds: 0 false declines, and the 4 live regression tests pass.
>
> Suites: `OrionMacOs` 464 tests (342 + 122), `OrionApp` 148 tests, 0 failures.
>
> **M1 done.** `scripts/coreai/export-qwen3.sh` and `CoreAIModelLocator` are in place, and a real
> Qwen3-8B bundle is exported: 4.3 GB, 440 s export, 14.7 GB peak memory, so it fits on the 24 GB M5.
> On `coreai-models`' own `llm-benchmark` it runs at **~915 tok/s prefill and ~28.3 tok/s decode**.
> The first load compiles on device in ~8–9 s; after that, Core AI's cache serves loads in ~1–2.5 s.
> AOT compilation was measured and rejected (slower, +4.3 GB).
>
> **Correction to the plan:** the tag `0.2.0` isn't usable for M2. We pin
> `coreai-models` main @ `e7b24da` instead (see M1).
> Suites: `OrionMacOs` 468 tests (342 + 126), 0 failures.
>
> **M2 done.** The backend seam is in place:
> - `LocalModelBackend` (`mlx` | `coreai[:variant]`, set by `--local-backend` or `ORION_LOCAL_BACKEND`, default `mlx`).
> - `LocalModelLoader` loads each backend once per process.
> - `FoundationModelsAgent<Model: LanguageModel>` wraps `CoreAILanguageModel` behind the existing `AgentModel`.
>
> **Call sites.** Every former `Qwen3Agent.load()` call site now goes through the loader: 5 in the CLI and app, plus `AgentSession`'s default factory. `model_used` is backend-qualified.
>
> **Live results on Starlette depth 2, same question.**
> - MLX: grounded answer (real `lookup_symbol` call, resolved anchor) in 3/3 runs.
> - Core AI: grounded in 2/4 runs.
> - The other 2 Core AI runs emitted `{"action": "lookup_symbol", ...}` instead of `"call_tool"`, a format slip the text-JSON loop can't recover from.
> - Sampling parity was verified, so this is not a seam bug. M3 measures it at scale; M5's guided generation removes the class.
> - The whole Core AI path runs under plain `swift build` / `swift test`, with no `xcodebuild`.
>
> Suites: `OrionMacOs` 476 tests (342 + 134), `OrionApp` 148 tests, 0 failures.
>
> **M3 in progress, paused by request.** The harness is built (`model-bench`, a preloading `bench`,
> `teach bench` run-info, a resumable `run_m3.sh`).
> - The runtime and depth-2 comparisons are complete.
> - Depth 1 has the MLX half only. The teaching grader has not run.
> - Interim results are in `Agent Feasibility Study/COREAI_BACKEND_EVAL.md`.
>
> **Headline so far:**
> - Core AI: **−37% peak memory** (10.9 vs 17.4 GB), parity prefill and short-context decode.
> - Core AI: **40% slower decode at 18K** context.
> - KV reuse is mirror-imaged: Core AI reuses across sessions, MLX within a session.
> - **Depth-2 format adherence fails:** a real tool call on 30/55 vs 49/55. Core AI writes the tool
>   name where `"call_tool"` belongs on its first action. This is the failure M5's guided
>   generation removes.
> - The MLX depth-1 baseline is in: 55/55 answered, p50 75 s, barely faster than depth 2.
> - The gate is **undecided**, and MLX stays the default.
> - Suites after the harness: `OrionMacOs` 476 tests, `OrionApp` 148 tests, 0 failures.
> - Resume: `Agent Feasibility Study/results/coreai_backend/m3/run_m3.sh`. It runs only the Core AI
>   depth-1 and the two `teach bench` runs.
>
> **M3 on hold (2026-09-29) until more benchmarking is requested.** The priority is now latency.
>
> **M3.5 done: native FoundationModels tool calling is Core AI's default.** On all 55 questions it made
> a real tool call on 55/55 with 0 unusable answers (json: 30/55 and 26). Hand-graded 8.0/20 (json 6.0, MLX 4.5).
> The p50 criterion failed as written (100 vs 80 s), but that baseline counts json's quick
> malformed exits. On questions both answered, native is faster (102 vs 108 s). MLX stays ~15 s
> faster per question at depth 2, and MLX keeps `ActionLoop`.
> Qwen3's thinking dominates latency. Next lever: thinking off for depth 2.
>
> **M4 done (short run; full run later).** `LocalModelRoles` gives each role its own Core AI variant
> and reasoning mode (set by `ORION_LOCAL_ROLES`). Measured on 10 questions and 6 teaching items:
> - Answering moves to **Qwen3-4B with thinking off**: p50 **45 s vs 99 s**, with hand-graded
>   quality flat (7.5 vs 8.0/20).
> - Judging stays on 8B with thinking: without thinking the judge calls nearly every criterion
>   "met" (κ 0.78 → 0.04).
> - INT8-KV is rejected (slower, ~2× peak memory).
>
> **M5 done (short run).**
> - A guided-generation judge exists as an opt-in (`--judge-output guided`). It is 2.5× faster but
>   reaches only κ 0.53 vs 0.78, so the thinking text judge stays the default. Parse failures were
>   already 0 on Core AI.
> - Found: on Core AI, `@Generable` field order isn't declaration order (xgrammar ignores `x-order`),
>   hence a two-turn analysis → decision design. An upstream issue is drafted.
> - Shipped: grading tolerates a failed judge or comparer call.
>
> **M3 gate closed (2026-09-29): Core AI passes by decision.** The project owner chose Core AI as the
> long-term path before the remaining M3 runs finished. The evidence and gaps at the time are
> recorded under M3 and in `COREAI_BACKEND_EVAL.md` §5. **M6 (cutover + MLX removal) is unblocked.**
>
> **M6 done: Core AI is the only local runtime.**
> - Removed: MLX (`mlx-swift-lm`, `Qwen3Agent`) and the text-JSON `ActionLoop` workaround.
> - Depth 2 is native tool calling; depth 1 is a direct answer.
> - No `xcodebuild` is needed: plain `swift run orion-agent` works.
> - The app shows the exact export command when a Core AI bundle is missing.

## Context

The dev machine is now on macOS 27 / Xcode 27 (Swift 6.4). The project still targets `.macOS(.v26)`. Its local-model stack uses two separate runtimes:

- **Apple `FoundationModels`** handles depth classification and the Phase 5 guardrail. It uses one `@Generable` struct in `AppleFoundationDepthClassifier`.
- **`mlx-swift-lm`** runs `Qwen3-8B-4bit` for depth-1/2 answering (`ActionLoop`) and for all of teaching mode (drafter, k=3 criterion judge, answer comparer).

That MLX path carries known costs:

- It requires `xcodebuild` (SwiftPM doesn't compile MLX's Metal shaders).
- It has no constrained decoding. The hand-rolled JSON-action loop exists only because native tool calling hung (Docs/12 Risk #3).
- The Phase 7 M7 teaching judge emitted unparseable JSON on 4 of 5 criteria.
- Every model call is plain text with lenient `{...}` extraction, running at the mlx-swift-lm defaults (temp 0.6, unbounded tokens, thinking on).

The macOS 27 SDK and Apple's `coreai-models` package, both checked directly, change this:

- **Core AI** is the new system inference framework (`CoreAIRuntime.AIModel` / `InferenceFunction` / `NDArray`, `SpecializationOptions` over CPU/GPU/Neural Engine). `xcrun coreai-build` is present.
- **FoundationModels OS 27** adds a `LanguageModel` protocol. `SystemLanguageModel`, `PrivateCloudComputeLanguageModel` and custom providers all plug into the same `LanguageModelSession`. It also adds `LanguageModelError`, `ContextOptions.reasoningLevel`, `Response.usage` and `SystemLanguageModel.variant` (`core3` / `coreAdvanced3`).
- **`apple/coreai-models`** (tagged `0.2.0`, product `CoreAILM`, macOS 27+) ships `CoreAILanguageModel: LanguageModel` and a **Qwen3-8B macOS recipe** (INT4 block-32, WikiText PPL 12.90 vs 12.19 fp16).
  - Constrained decoding is real (xgrammar), so it advertises `.guidedGeneration`, `.toolCalling` and `.reasoning`.
  - `<think>` output is routed into transcript reasoning segments.
  - `reasoningLevel .custom("none")` maps to `enable_thinking: false`.
  - It ships `llm-runner` and `llm-benchmark` CLIs.

**Goal:** one API, `LanguageModelSession`, for every local model call. Qwen3 moves from MLX to Core AI, **gated on a head-to-head benchmark**: MLX is only removed if Core AI matches or beats it on quality, latency and memory. The system classifier migrates to the OS 27 APIs. Per-role model sizes are chosen from data.

**Decisions made with you:**
- Gated replacement.
- **No Private Cloud Compute.** Claude Code stays the only cloud tier.
- Raise the floor to macOS 27.
- Evaluate model size and reasoning setting per role.

This lands as a new plan doc, **`Docs/18_os27_foundation_models_coreai.md`**. It follows the Docs/10–17 convention: a status banner and milestones that each get a `[done]` marker plus the real findings.

## Milestones

### M0: macOS 27 floor + FoundationModels OS 27 migration (no model change) `[done]`

**What was built.** Every FoundationModels symbol used was checked against the MacOSX27.0 SDK
swiftinterface, not just the skill references.

- **Floor.** `OrionMacOs/Package.swift` is now `.macOS("27.0")`. It uses the string form because
  PackageDescription 6.2 has no `.v27` case. The stale "5.10 root manifest" comment is fixed.
- **App project.** `OrionApp/project.yml` targets 27.0, and `xcodegen generate` was re-run. That
  replaced Xcode 27's uncommitted 45-line re-save drift of `project.pbxproj` with exactly the two
  intended `MACOSX_DEPLOYMENT_TARGET` lines.
- **Doc filename.** This file was renamed from `…coreai.md.md` to `…coreai.md`.
- **`AppleFoundationDepthClassifier`:**
  - `@Guide(.range(1...3))` on `depth` replaces the hand clamp.
  - A new `escalation(for:systemModel:)` maps the whole OS 27 error family to the same
    low-confidence depth-3 escalation the "unavailable" path already used. That covers every
    `LanguageModelError` case, `GeneratedContent.ParsingError` and
    `SystemLanguageModel.Error.assetsUnavailable`.
  - Previously any FM error failed the whole `ask`.
  - A failure is never a decline: Docs/15 §3.2 reserves `isInScope: false` for a confident
    off-topic judgement.
  - Anything outside those error families (for example cancellation) is rethrown unchanged.
  - Every model-produced rationale now ends with `(system model: <variant.displayName>)`, so
    `routing_decisions` shows which OS model made each call. The rationale is only surfaced in
    `--explain`, the app's Explain disclosure and Diagnostics.
  - Covered by 3 offline tests (`AppleFoundationDepthClassifierTests`). They build the real error
    values through their public initializers and run in CI.
- **`orion-agent bench --classify-only`.**
  - Runs only the Depth Model (heuristics plus the system-model fallback, built exactly as
    `AgentSession` builds it) over a question set.
  - No DB, no Qwen load, no cost.
  - Writes `routing_classification.jsonl` and `routing_classification_summary.json`.
  - Rejects `--force-depth`.
- **CI.** `.github/workflows/ci.yml` now uses `runs-on: xcode-27`. This is GitHub's only hosted
  image with the macOS 27 SDK: a public preview with a macOS 27 base since 2026-09-16
  (actions/runner-images#14404). Every other label ships the 26.x SDK and can't build this floor.
  The live-test `--skip` list is unchanged; Apple Intelligence isn't available on hosted runners
  anyway.
- **Prewarm (optional) was not done.** The classifier creates one stateless session per call, and
  `AgentSession` is created per question. A prewarmed session would never be the one that
  classifies, and whether `prewarm()` on one session speeds up another is undocumented (the
  skill's "don't infer undocumented behavior" rule). Revisit if M3's Instruments trace shows cold
  classifier starts actually matter. Measured classification is 2–4.5 s either way.

**Re-validation on the OS 27 system model.** The recorded variant is `AFM 3 Core Advanced`
(`coreAdvanced3`).

- **`AppleFoundationDepthClassifierLiveTests`:** 4 of 4 pass. The Phase 5 AR-01/AR-05
  false-decline regressions stay in scope, and a genuinely off-topic question is still declined.
- **`bench --classify-only`** over all 55 `benchmark.resolved.json` questions against vendored
  Starlette. Raw data is in `Agent Feasibility Study/results/os27_depth_classification/`.

  | | Phase 5 (OS 26 system model) | OS 27 (`AFM 3 Core Advanced`) |
  |---|---|---|
  | depth 1 (`high`) | 9 | **0** |
  | depth 2 (`medium`) | 43 | **54** |
  | depth 3 (`low`) | 3 | 1 (EV-01) |
  | declined | 2 (AR-01, AR-05; later fixed in Phase 5 M8) | **0** |
  | heuristic matches | 0 | 0 |
  | classification p50 / p95 | — | 2.8 s / 3.8 s |

- **Reading.** The new system model never reports `high` confidence on this set, so it has
  effectively collapsed to "everything is depth 2".
  - For answer quality this is arguably neutral to positive. Docs/12 M5 found depth-1 answers
    wrong 4/4 times, and depth 2 grounds answers in real tool calls.
  - But it means the router no longer discriminates between depths 1 and 2 at all, and it only
    escalates to Claude on 1 of 55 questions.
  - This is exactly the "re-test prompts when the system model changes with an OS update"
    scenario Apple's OS 27 guidance describes.
  - The routing prompt was deliberately **not** re-tuned in M0: the milestone's scope was "no
    model change", and a prompt change needs its own before/after measurement.
  - Carried into M3/M4. With depth 1 effectively gone, depth-2 latency is what the Core AI
    backend has to win on.

**Verification.**
- `swift build`: clean, with no warnings in Orion sources after a forced full rebuild of our own
  targets.
- `swift test` with the CI skip list: 464 tests (342 OrionCodeIntel + 122 OrionAgent), 0 failures.
- `xcodebuild … -scheme Orion test`: `** TEST SUCCEEDED **`, 148 tests, 0 failures, no warnings
  in Orion sources.

**Original plan for M0:**

**Floor and project files**
- `OrionMacOs/Package.swift`: change the floor to `.macOS("27.0")` and fix the stale "5.10 root manifest" comment.
- `OrionApp/project.yml`: set `deploymentTarget: macOS "27.0"`, then run `xcodegen generate`. This reconciles the uncommitted Xcode-27 `project.pbxproj` drift, which is currently target 27.0 vs project 26.0.

**`Sources/OrionAgent/Depth/AppleFoundationDepthClassifier.swift`**
- Add `@Guide(.range(1...3))` on `depth`.
- On `LanguageModelError` (`.guardrailViolation`, `.refusal`, `.contextSizeExceeded`, `.unsupportedLanguageOrLocale`) and `SystemLanguageModel.Error.assetsUnavailable`, return the same low-confidence depth-3 escalation the "unavailable" path already uses, instead of failing the whole `ask`.
- Append `SystemLanguageModel.default.variant` to the persisted rationale, because the system model changes with the OS.

**`OrionApp` Ask destination**
- Optionally `prewarm()` a classifier session on appear, per the skill's idle-time rule.

**CI**
- `.github/workflows/ci.yml` is `macos-15`. Move it to the newest runner image with a macOS 27 SDK. If none exists yet, record that CI can't build at this floor and keep the job clearly failing/disabled. Don't fake a green run.

**Re-validate on the OS 27 system model**
- Run `AppleFoundationDepthClassifierLiveTests` (AR-01/AR-05 false-decline regressions).
- Add a free `orion-agent bench --classify-only` mode that records the depth and in-scope distribution over the 55 questions. Compare it against Phase 5 (`results/phase5_routing_benchmark/`).

### M1: Core AI model asset pipeline `[done]`

**What was built.**

- **Pinning `coreai-models`: `main` @ `e7b24da85ea6` (2026-09-25), not tag `0.2.0`.** This came
  out of checking the checked-out source (Risk #4) rather than trusting the plan:
  - `0.2.0` (2026-07-08) depends on `xgrammar` via `branch: "main"`. SwiftPM refuses a
    version-pinned dependency (`from: "0.2.0"`) that pulls in a branch-based package, so M2's
    planned dependency line could never resolve.
  - `0.2.0` also lacks the `4bit_weights_8bit_kv_cache` preset that M4's matrix needs.
  - `e7b24da` pins `xgrammar` `exact: "0.2.2"`, has that preset, and keeps Qwen3-8B's macOS
    recipe.
  - The Python export and the Swift runtime must come from the same revision (the bundle format
    is `metadata_version 0.2`), so M2 depends on this exact `revision:`.
- **`OrionMacOs/scripts/coreai/export-qwen3.sh`:**
  - Clones or updates `apple/coreai-models` into `~/Library/Caches/Orion/coreai-models`, checks
    out the pinned commit and runs `uv sync`. It unsets any `VIRTUAL_ENV` the caller has active,
    which fixed a real leak from this repo's own `.venv`.
  - Always prints `coreai.llm.export --dry-run` first.
  - Exports to `$ORION_COREAI_MODEL_DIR/<model>-<compression>/`, defaulting to
    `~/Library/Application Support/Orion/CoreAIModels`. The bundle folder and its `.aimodel`
    share one explicit `--output-name`.
  - Options: `--model`, `--compression`, `--max-context-length`, `--overwrite`, `--dry-run`, `--aot`.
  - An existing finished bundle is reused only for `--aot`; anything else needs `--overwrite`.
- **Context ceiling: the registry default of 40960 is kept.**
  - That is Qwen3-8B's `max_position_embeddings`.
  - `ContextBuilder` caps each primed section at 20,000 characters. A session can add up to 5
    prior turns of 20,000 characters each, plus `ActionLoop` tool results, which is roughly
    30–40K tokens worst case, past Qwen3's native 32K.
  - On macOS the export is dynamic-shape, and `CoreAILanguageModel`'s `KVCacheStrategy.auto`
    starts at 256 tokens and grows. The high ceiling therefore reserves no memory up front.
- **`CoreAIModelLocator` (`Sources/OrionAgent/Model/`):**
  - Resolves `<root>/<variant>` using the same root as the script.
  - Treats `metadata.json` as the "export finished" marker; the exporter writes it last, after
    the `.aimodel` and the tokenizer (checked in `bundle.py`).
  - When no bundle is found, the error message names the exact export command to run.
  - Covered by 4 offline tests (`CoreAIModelLocatorTests`).
- **README:** `OrionMacOs/README.md` gained a "Core AI model bundles" section next to the
  Hugging Face cache section.

**Measured, M5 / 24 GB / macOS 27.** Raw JSON is in
`Agent Feasibility Study/results/coreai_backend/m1_smoke/`.

| | Qwen3-0.6B `4bit` (pipeline smoke) | Qwen3-8B `4bit` |
|---|---|---|
| export wall-clock / peak RSS | 495 s / 6.5 GB | 440 s / **14.7 GB** |
| bundle size | 331 MB | **4.3 GB** (MLX checkpoint: ~4.3 GB) |
| first load (on-device compile) | 6.4 s | 8.2–9.3 s |
| warm load (Core AI cache hit) | 0.13–0.22 s | 1.0–2.5 s |
| `llm-benchmark` prefill (512 tok) | — | **~915 tok/s** |
| `llm-benchmark` decode (1024 tok, greedy) | — | **~28.3 tok/s** |
| `llm-runner` peak RSS (19-tok prompt, 200 tok out) | 0.82 GB | 9.45 GB |

- **Risk #1 did not materialize.** The 8B export peaked at 14.7 GB and never needed swap to
  finish. (The 0.6B export's 6.5 GB peak had suggested it might not fit.)
- **Not yet an MLX comparison.** Those numbers are the next milestone's job. The recorded MLX
  baseline in `LEADERBOARD.md` is 22.0 tok/s decode with 8.03 GB `mx.get_peak_memory`, but it
  came from a different harness, prompt set and memory measure. Only M3's `model-bench` compares
  like with like.
- **The ~37 s "warmup" `llm-benchmark` prints is not overhead.** Its own source
  (`BenchmarkMain.swift:125`) shows it is one untimed full trial.
- **Built with plain `swift build`.** `llm-runner` and `llm-benchmark` built with no `xcodebuild`
  or Metal-shader workaround. That is early evidence for M6's claim that the MLX-only
  `xcodebuild` requirement can go away.

**AOT: measured and rejected.** Apple documents AOT as optional (models/README.md: compile, then
point `metadata.json` at the compiled file). The script implements exactly that for this Mac's
Core AI architecture, `h17g` (`AIModel.deviceArchitectureName`).

On an idle machine, with `llm-benchmark --clear-coreai-cache` for the cold numbers, the AOT asset
was **worse**:

| | on-device compile (default) | AOT `.h17g.aimodelc` |
|---|---|---|
| cold prepare | 8.2 s | 10.7 s |
| warm prepare | 1.0 s | 2.5 s |
| prefill / decode | 912 / 28.1 tok/s | 917 / 27.8 tok/s |
| extra disk | — | +4.3 GB |

- Core AI's own compile-on-first-load plus its specialization cache already does what AOT
  promises.
- Both bundles were reverted to the source `.aimodel`, and the compiled copies were deleted.
- `--aot` stays in the script, off by default, with these numbers in its help text. It may still
  matter for iOS or a shipped app bundle, neither of which is in scope.

**Verification.**
- `export-qwen3.sh --dry-run` resolves the expected config.
- Real 0.6B and 8B exports succeeded.
- `llm-runner` generates coherent text from both bundles, including Qwen3's `<think>` reasoning
  block.
- `llm-benchmark` ran as in the table above.
- `swift test` with the CI skip list: 468 tests (342 + 126), 0 failures.

**Original plan for M1:**

- Add `OrionMacOs/scripts/coreai/export-qwen3.sh`. It:
  - clones `apple/coreai-models` at tag `0.2.0` into a scratch dir;
  - runs `uv run coreai.llm.export Qwen/Qwen3-8B --dry-run` first, to read the resolved `max_context_length`;
  - then exports with an explicit `--max-context-length` that is large enough for `ContextBuilder`'s primed prompts (Phase 0 saw ~24K-token contexts);
  - supports variants: `--compression 4bit` (default), `4bit_weights_8bit_kv_cache`, and `Qwen/Qwen3-4B`;
  - optionally AOT-compiles with `xcrun coreai-build compile <asset> --platform macOS` to cut first-load time.
- Add `CoreAIModelLocator` to `OrionAgent`. It resolves `ORION_COREAI_MODEL_DIR`, else `~/Library/Application Support/Orion/CoreAIModels/<variant>/`. This mirrors the Hugging Face cache section in `OrionMacOs/README.md`.
- Smoke test with the package's own `swift run -c release llm-runner` and `llm-benchmark` against the exported folder.

### M2: Backend seam + Core AI backend (MLX stays the default) `[done]`

**What was built.** Every FoundationModels symbol was checked against the MacOSX27.0 SDK
swiftinterface, and every `coreai-models` symbol against its checkout at the pinned revision.

- **Dependency.**
  - `coreai-models` is added by `revision: e7b24da…`, with product `CoreAILM`, to the `OrionAgent`
    target only.
  - Resolution is clean. `swift-transformers` unifies at our 1.3.4, and `xgrammar` is exactly
    0.2.2.
  - SwiftPM pruned the server-only packages (hummingbird, NIO). New pins are `coreai-models`,
    `xgrammar` and `yyjson`, in both `OrionMacOs/Package.resolved` and the app workspace's
    `Package.resolved`.
- **`AgentModel` (the seam).**
  - It gained `modelIdentifier` (backend-qualified, persisted as `model_used`) and
    `makeSession(instructions:)`.
  - `makeSession` was promoted from `Qwen3Agent`, so nothing depends on a concrete backend type
    any more.
  - `Qwen3Agent` reports `mlx:mlx-community/Qwen3-8B-4bit`.
- **`LocalModelBackend`.**
  - Cases are `.mlx` and `.coreAI(variant:)`, parsed from `mlx` | `coreai` | `coreai:<variant>`.
  - `fromEnvironment()` reads `ORION_LOCAL_BACKEND` and **throws** on a typo, so a typo can't
    silently benchmark the wrong backend.
  - `.default` is the lenient environment-or-MLX form, used only by the app, which has nowhere to
    surface a configuration error.
  - Its `modelIdentifier` is known without loading, so `AgentSession` can record it.
- **`LocalModelLoader`.**
  - An actor that loads each backend **at most once per process**, with a `Task` cache, and
    un-caches a failed load so a later attempt can succeed.
  - The Core AI path is `CoreAIModelLocator.bundleURL`, then
    `CoreAILanguageModel(resourcesAt:mode: .eager)`, then `FoundationModelsAgent`.
  - **Side effect, intended:** `bench` and the app used to reload Qwen3 for every question or
    teaching call. They now pay the load once. M3 therefore re-measures the MLX baseline rather
    than reusing Phase 5's latencies, which include per-question loads.
  - The app also now keeps the local model resident after first use: ~6–9 GB, the same as the
    CLI during a run.
- **`FoundationModelsAgent<Model: LanguageModel>`.**
  - `respond` runs a one-shot `LanguageModelSession(model:instructions:)`.
  - `makeSession` returns `FoundationModelsTurnSession`, one `LanguageModelSession` driven turn
    by turn by `ActionLoop`. It is a wrapper, not a conformance, because
    `LanguageModelSession.respond(to:)`'s own overloads would make a conformance ambiguous.
  - Generic so it is testable offline.
- **`LocalGenerationDefaults.options` = `GenerationOptions(temperature: 0.6, maximumResponseTokens: 8192)`.**
  - This matches what MLX really runs: `ChatSession`'s default `GenerateParameters()` is
    temperature 0.6, top-p 1.0 and `maxTokens: nil`, checked in the `mlx-swift-lm` checkout.
  - On the Core AI side, `CoreAIExecutor.makeSamplingConfig` maps a temperature to
    `SamplingConfiguration(temperature:)`, with top-k, top-p and min-P all unset. That is the same
    pure-temperature sampler, so sampling parity holds.
  - The explicit 8192 cap is needed because a `nil` `maximumResponseTokens` makes
    `CoreAILanguageModel` cap a reasoning model at 2048. A long Qwen3 `<think>` can exhaust that
    before the answer.
  - Reasoning stays on, as on MLX. Core AI routes it into transcript reasoning entries, so
    `.content` never contains `<think>`, and `ActionLoop.stripThinking` is a no-op on this path.
- **Call sites and surfaces.** All former `Qwen3Agent.load()` sites now use `LocalModelLoader`:
  - `AgentSession`'s default `sessionFactory`, which is now `nil`-defaulted and built in `init`
    from `config.localBackend`, like `depthFallback`;
  - `teach next` / `teach answer` (`TeachCommand.swift`) and `teach bench`;
  - the app's `TeachingRunner` (both loads). `AskRunner` inherits the backend through
    `AgentSessionConfig(localBackend: .default)`.
  - New `LocalBackendOption` (`--local-backend`) on `ask`, `bench`, `teach next`, `teach answer`
    and `teach bench`. It validates up front as a usage error.
  - `AgentSessionConfig.localBackend` was added.
  - `ModelBackedDepthClassifier` still takes `Qwen3Agent` directly. It is superseded, and only
    its own live test uses it; it goes away in M6.
- **Tests.**
  - `FoundationModelsAgentTests` (4): an **offline custom `LanguageModel` provider** (the OS 27
    protocol, per the skill's custom-provider reference) driven through a real
    `LanguageModelSession`. It proves instructions, prompt and the MLX-matched options reach the
    executor, reasoning never reaches `.content`, and a turn session carries the transcript
    forward.
  - `LocalModelBackendTests` (4): parsing, environment, identifiers, and a missing-bundle error
    that names the export command.
  - `CoreAIAgentLiveTests` (2): gated on `ORION_AGENT_LIVE_COREAI_TEST=1` and added to the CI
    `--skip` list.

**Verified live, on the real exported Qwen3-8B bundle.**

- **`CoreAIAgentLiveTests`:** both pass under **plain `swift test`**. A one-shot answer took 29 s
  including the first load, with no `<think>` leak and identifier `coreai:qwen3-8b-4bit`. A
  two-turn session took 17 s and recalled a codeword.
- **`orion-agent ask <starlette> "Where is the Router class defined, and what does its app method
  do?" --force-depth 2 --explain`**, same question:

  | backend | binary | grounded runs (real tool call → resolved anchor → `verified`) | wall-clock |
  |---|---|---|---|
  | `mlx` | `xcodebuild` build | **3 / 3** | 46–82 s |
  | `coreai` | plain `swift build` | **2 / 4** | 27–75 s |

- **The Core AI grounded runs.** They called `lookup_symbol("Router")` and got
  `starlette/routing.py::Router (class) — starlette/routing.py:573-757`. That produced one
  claim, verified.
  - One Core AI run peaked at 6.1 GB memory footprint (9.3 GB RSS).
- **The two Core AI failures.** Both were the same format slip:
  `{"action": "lookup_symbol", "tool": "lookup_symbol", ...}`. The model put the tool name where
  `"call_tool"` belongs. `ActionLoop` treats an unknown action as a malformed final answer, so no
  tool ran and the outcome was `unverified`.
  - This is **not a seam bug**: sampling parity was checked in source, and instructions and
    options reach the executor (unit-tested).
  - With n = 3 vs 4 it's also not yet a conclusion.
  - Docs/12 Risk #7 already recorded that tolerant action parsing was tried and reverted, so the
    answer here is measurement, not a parsing patch:
    - **M3** measures format-adherence at scale (all 55 questions, forced depth 2, both backends).
    - **M5's guided generation** (`@Generable AgentAction`, xgrammar-constrained) removes this
      failure class structurally.
- **No `xcodebuild` on the Core AI path.** `orion-agent` built with plain `swift build` runs the
  Core AI backend end to end. MLX's Metal shaders are only needed when the MLX backend loads.

**Verification.**
- `swift test` with the CI skip list: 476 tests (342 + 134), 0 failures.
- `xcodebuild … -scheme Orion test`: `** TEST SUCCEEDED **`, 148 tests, 0 failures, no warnings in
  Orion sources.
- `--local-backend gguf` is rejected as a usage error.

**Original plan for M2:**

- Add the `coreai-models` package to the `OrionAgent` target only: product `CoreAILM`, pinned by
  `revision: "e7b24da85ea64a77d26324d7ce9607de9b955f57"`. M1 found that `from: "0.2.0"` can't
  resolve, because 0.2.0 depends on xgrammar `branch: main`. The Swift runtime must match the
  export revision.
  - It needs swift-transformers ≥ 1.1.0, which our 1.3.4 pin satisfies.
  - It also pulls in xgrammar `exact: 0.2.2` (its server-only dependencies, hummingbird and NIO,
    are pruned by SwiftPM because `CoreAILM` doesn't use them).
  - Check that `Package.resolved` unifies.
- **Seam**
  - Promote `makeSession(instructions:) -> any TurnGenerating` from `Qwen3Agent` into the `AgentModel` protocol (`Model/AgentModel.swift`).
  - Add `enum LocalModelBackend { case mlx, coreAI(URL) }`, plus a `LocalModelLoader` that loads once per process through an actor cache and returns `any AgentModel`.
- **`CoreAIAgent: AgentModel`** (new file `Model/CoreAIAgent.swift`)
  - Loads `CoreAILanguageModel(resourcesAt:mode: .eager)`.
  - `respond(to:instructions:)` builds a `LanguageModelSession(model:instructions:)` and returns `.content`.
  - `makeSession` returns a small `FMTurnSession: TurnGenerating` wrapper around one `LanguageModelSession`. This has to be a wrapper, not an extension, because `respond(to:)` would clash with FM's own overload.
  - Sampling is set explicitly via `GenerationOptions` so production matches MLX (temp 0.6). Reasoning stays on by default, as it is today.
  - `ActionLoop.stripThinking` becomes a harmless no-op on this path.
- **Replace the 7 `Qwen3Agent.load()` call sites with `LocalModelLoader`**
  - `AgentSession.swift:111–118` (default `sessionFactory`)
  - `orion-agent/Commands/TeachCommand.swift:220, 302`
  - `TeachBenchCommand.swift:116`
  - `OrionApp/Orion/Ingestion/TeachingRunner.swift:39, 86`
  - `AskRunner.swift:140` (indirect, through `AgentSession`)
- **Surfaces**
  - Add `--local-backend mlx|coreai` to `ask` / `bench` / `teach*`, with `ORION_LOCAL_BACKEND` env and an `AgentSessionConfig` field.
  - Persist a backend-qualified `model_used` (e.g. `coreai:Qwen3-8B-4bit`) instead of `Qwen3Agent.modelConfiguration.name` (`AgentSession.swift:271`).
- **Tests**
  - A `CoreAIAgent` unit test with a fake `LanguageModel` (the custom-provider protocol makes this possible offline).
  - A live test gated on `ORION_AGENT_LIVE_COREAI_TEST`, added to CI `--skip`.

### M3: Head-to-head benchmark, MLX vs Core AI (Qwen3-8B 4-bit) — decision gate `[closed — passed by decision, 2026-09-29]`

**Gate decision.** Core AI passes by the project owner's decision, taken before the remaining M3
runs finished. The rationale is strategic: Core AI is Apple's new system inference framework and
gives the project a clear long-term path.

**Evidence at the time of the decision.** Details are in `COREAI_BACKEND_EVAL.md` §5.
- **Measured in Core AI's favour:**
  - 37% lower peak memory;
  - prefill at parity or better;
  - 0 malformed depth-2 answers with native tool calling (M3.5);
  - equal or better hand-graded depth-2 answers;
  - a working teaching judge (κ 0.78 on the M4 subset);
  - no `xcodebuild` requirement.
- **Measured against it:**
  - ~40% slower decode at 18K context;
  - depth 2 ~15 s slower per question than MLX on the same questions with the same 8B model,
    because MLX reuses its KV cache across tool rounds;
  - M4's 4B no-thinking default recovers that (p50 45 s).
- **Not measured:**
  - Core AI depth 1;
  - the full 15-item teaching-grader comparison against MLX (only a 6-item Core AI subset exists);
  - the full per-role and guided-grading runs.

  These stay listed as follow-ups. They no longer gate the cutover.


**Harness (built).**
- **`RuntimeBenchmarking`** (`Sources/OrionAgent/Model/`), implemented by `Qwen3Agent` and
  `FoundationModelsAgent`.
  - Streams each turn of one session with greedy decoding and thinking off, using
    `ChatSession(additionalContext: enable_thinking false)` on MLX and
    `ContextOptions(reasoningLevel: .custom("none"))` on Core AI.
  - Times every backend at the same points: request start → first non-empty chunk → end.
- **`orion-agent model-bench`.**
  - Measures load, time to first token, prefill, decode and peak `phys_footprint`.
  - Prompts are real Starlette material at three sizes: short (725 tok), production (the actual
    `ContextBuilder` output, 4,927 tok) and long (18,026 tok).
  - Also measures a same-context-new-session case and a follow-up-turn case.
  - A unique first line per run defeats Core AI's cross-session prefix cache, so the prefill timing
    is cold. The first smoke run was timing cache hits (an "18K-token prefill in 0.48 s") until
    this fix.
- **`bench`** now preloads the local model when a local depth is forced, and reports
  `modelLoadMs` / `localModel` in its summary.
- **`teach bench`** now writes `teaching_calibration_run.json`: wall-clock time, judge calls, and
  **unparseable judge replies**, counted through the new public `LocalCriterionJudge.isParseable`.
- **`Agent Feasibility Study/results/coreai_backend/m3/`.**
  - `run_m3.sh` runs sequentially, one backend per process, with a fresh database copy per run,
    and skips any step that already has results.
  - `analyze_m3.py` builds the tables.
  - `hand_grades_d2.json` holds the depth-2 hand grades.

**Results so far.** See `Agent Feasibility Study/COREAI_BACKEND_EVAL.md` for the full tables.

- **Runtime.**
  - Core AI peaks at 10.9 GB versus MLX's 17.4 GB.
  - Prefill is at parity, and up to 18% faster on Core AI for long prompts.
  - Decode is at parity at 725 and 4.9K tokens, but **40% slower on Core AI at 18K**.
  - A follow-up turn costs Core AI a full re-prefill (6.2 s versus MLX's 0.16 s): Risk #2,
    confirmed. A repeated context in a new session costs Core AI 0.15 s versus MLX's 6.2 s.
- **Depth 2, 55 questions.**
  - Similar wall-clock (80 versus 81 min).
  - Core AI made a real tool call on only 30/55 questions versus 49/55. It returned the malformed
    action as the answer on 26 versus 7.
  - The failure is systematic: the first action is written as `"action": "<tool name>"`.
  - Hand-graded on the Phase 5 sample, Core AI scored 6.0/20 versus MLX's 4.5/20. When it
    answers, it's no worse; the gap is format adherence.
- **Not yet run.** Core AI depth 1, and both teaching-grader runs. Resume with `run_m3.sh`.

**Original plan for M3:**

- **New `orion-agent model-bench --local-backend`**
  - Measures load time, TTFT, prefill and decode tok/s, and peak `phys_footprint` (via `task_info`).
  - Runs at fixed real prompt sizes (~1K / 8K / 24K tokens, built from real `ContextBuilder` output on Starlette).
  - Uses `Response.usage` for Core AI token counts.
- **Fix `bench` so it doesn't reload Qwen3 per question** (`BenchCommand` builds a fresh `AgentSession` each time). Load once and report load separately. This means the MLX baseline is **re-measured under the new harness**, not compared against Phase 5's numbers, which include load time.
- **Runs, all local and free**
  - `bench --force-depth 1` and `--force-depth 2` on the 55 questions, per backend. Hand-grade the same 10-question sample Phase 5 used.
  - `teach bench` per backend: κ, verdict accuracy, parse-failure count, wall-clock.
  - One Foundation Models Instrument trace of a Core AI depth-2 answer. This checks whether cross-turn KV reuse happens; `CoreAIExecutor` reports `cachedTokenCount: 0`.
- **Gate:** Core AI passes only if all of these hold:
  - teach κ ≥ MLX − 0.03, and verdict accuracy is no worse;
  - the depth-1/2 hand-graded correctness is no worse;
  - peak memory ≤ MLX;
  - decode tok/s ≥ MLX;
  - TTFT at 24K is no worse than 1.2× MLX.
- **Write-up:** `Agent Feasibility Study/COREAI_BACKEND_EVAL.md`, with raw data under `results/coreai_backend/`.

### M3.5: Native tool calling on Core AI — replace the JSON-action workaround `[done]`

**Built.**
- **`Tooling/NativeToolLoop.swift`:**
  - `NativeToolLoop`: prose instructions, and one shared nudge for "answered without a tool" or
    an empty reply.
  - `ToolCallLedger`: records `ExecutedToolCall`s and enforces the budget. Calls past it get a
    "budget exhausted" result. After two refusals it throws `ToolBudgetExhausted`, and the loop
    turns that into one tool-free forced answer via `toolCallingMode = .disallowed`.
  - `AgentToolAdapter: Tool`: `Arguments = GeneratedContent`, with a `DynamicGenerationSchema`
    built from the new `AgentTool.parameters`.
- **`NativeToolCallingModel`**, implemented by `FoundationModelsAgent` through `FoundationModelsToolSession`.
- **`ToolCallProtocol`** (`json` | `native`), settable via `--tool-protocol` on `ask` / `bench`
  or `ORION_TOOL_PROTOCOL`. `native` on MLX is a validation error.
- **`AgentSession(nativeSessionFactory:)`** and `AgentSessionConfig.toolProtocol`.
- `bench` summaries record `toolProtocol`.
- **Tests:** 12 offline tests. `NativeToolLoopTests` drives a real `LanguageModelSession` through
  a scripted custom provider, emitting `.toolCalls` exactly as `CoreAILanguageModel` does. The
  rest are protocol parsing and defaults, plus an `AgentSession` native-path persistence test.
  There is also a gated live test, `CoreAINativeToolCallingLiveTests`.

**Results.** Full tables are in `COREAI_BACKEND_EVAL.md` §4b; raw data in `results/coreai_backend/m3_5/`.
- **Live CU-01**, a malformed action under json in M3: a real `lookup_symbol` call with a
  resolved anchor, 2/2 runs. The first call came after ~58 s of reasoning; total ~100 s.
- **55-question gate:**

  | criterion | result |
  |---|---|
  | tool call ≥ 49/55 | **pass**: 55/55 |
  | no usable answer ≤ 7 | **pass**: 0 (and 0 partial) |
  | hand-graded ≥ 6.0/20 | **pass**: 8.0/20 |
  | p50 ≤ 80 s | **fails as written**: 100.2 s |

- **The latency criterion was mis-specified.** The 80 s baseline includes 26 malformed questions
  that ended after one turn without an answer (p50 37.5 s). On the 29 questions Core AI json
  actually answered, native is faster: 101.9 vs 108.4 s.
- MLX remains ~15 s faster per question (84.7 vs 99.5 s on the questions it answered). That is
  M3's KV-reuse asymmetry, not the protocol.
- Outcomes: verified 32 / partially 21 / unverified 2, versus json's 20 / 9 / 26. Claims: 53 vs 29.

**Decision: native is Core AI's default.** `json` stays one flag away. MLX keeps `ActionLoop`, and
`ActionLoop` is removed with MLX in M6. M5's `@Generable AgentAction` is demoted to a fallback that
is no longer needed for depth 2. M5's judge and comparer guided-generation items stand.

**Latency, the stated priority, points elsewhere.** Qwen3's thinking dominates each question.
The next lever is `ContextOptions(reasoningLevel: .custom("none"))` for depth 2, measured on this
same bench. It is M4's reasoning axis, pulled forward if latency stays the priority.

Suites: `OrionMacOs` 490 non-live tests (342 + 148), `OrionApp` 148 tests, 0 failures.

**Original plan for M3.5:**

**Why now.** M3 is on hold by decision: latency is the priority, and Core AI already wins on
memory and matches on speed. Its one blocker at depth 2 is format adherence. The text-JSON
`ActionLoop` exists only because `mlx-swift-lm`'s native tool calling hung and crashed on Qwen3
(Docs/12 Risk #3). Core AI is a different runtime, so that finding doesn't transfer. M3.5 checks
whether Core AI can do tool calling directly, and if it can, switches the Core AI path over.

**Why it should work (from source, `coreai-models` @ `e7b24da`).**
- `CoreAILanguageModel` advertises `.toolCalling` whenever the tokenizer has `<tool_call>` /
  `</tool_call>`, which Qwen3's does.
- Tool definitions reach the model through **Qwen3's own chat template** (`applyChatTemplate(tools:)`).
  This is the format Qwen3 was trained on, not our hand-written JSON contract.
- The executor streams the output through `ToolCallParser`. Each
  `<tool_call>{"name": …, "arguments": …}</tool_call>` becomes a FoundationModels `.toolCalls`
  event. `LanguageModelSession` then runs our `Tool.call`, appends the `toolOutput` entry, and
  generates again.
- M3's systematic slip, `{"action": "<tool name>", "arguments": {…}}`, is the model reaching for
  exactly this native `{"name", "arguments"}` shape. The model knows the call it wants; the
  workaround's envelope is what it fumbles.

**Known limits (also from source).**
- Generation is **not grammar-constrained**. The call is parsed after the fact.
- A malformed `<tool_call>` body is **silently dropped**, leaving an empty response.
- `GenerationOptions.toolCallingMode` is **not read** by `CoreAIExecutor`, so `.required` isn't
  enforced. The "call at least one tool" rule stays our job.
- The session's own tool loop has no budget. The budget has to live in the tools.
- Prior reasoning isn't echoed back into the prompt. Each tool round re-tokenizes the transcript,
  so how much the engine-wide prefix cache saves per round is something to measure, not assume.

**Plan.**
1. **Adapter.** `AgentToolAdapter: FoundationModels.Tool` over the existing `AgentTool`s:
   - `Arguments = GeneratedContent`, and `parameters` built as a `DynamicGenerationSchema` from a
     new `AgentTool.parameters` list, so `QueryEngineTools` stay unchanged otherwise.
   - A shared `ToolCallLedger` enforces the depth-2 budget: past it, a call returns a "budget
     exhausted, answer now" result instead of running. It also records every executed call as an
     `ExecutedToolCall`, so evidence extraction, `agent_tool_calls` persistence and
     `SemanticImporter` are untouched.
2. **`NativeToolLoop`.**
   - Prose instructions, with no JSON contract.
   - One corrective re-prompt when the model answers with zero tool calls or an empty reply.
   - Returns the same `AgentAnswer` as `ActionLoop`.
3. **Selection.**
   - Add `ToolCallProtocol` (`json` | `native`), selectable with `--tool-protocol` or
     `ORION_TOOL_PROTOCOL`.
   - The default depends on the backend: MLX always uses `json` (Risk #3 stands for MLX), and
     Core AI's default is decided by step 5.
   - `model_used` / `investigations.tools_used` record which protocol ran.
4. **Smoke test.** Run `orion-agent ask --force-depth 2 --local-backend coreai --tool-protocol native`
   on Starlette. Check for real tool calls, resolved anchors, no hang, and per-round latency.
5. **Gate: `bench --force-depth 2 --local-backend coreai --tool-protocol native` over all 55 questions.**
   - Compare against M3's Core AI JSON baseline and MLX baseline, and hand-grade the Phase 5
     10-question sample.
   - **Adopt native as Core AI's default** if all of these hold:
     - questions with ≥ 1 real tool call ≥ MLX's 49/55;
     - malformed or empty answers ≤ MLX's 7;
     - p50 latency no worse than Core AI JSON's 80 s;
     - hand-graded score no worse than Core AI JSON's 6.0/20.
   - If it fails, record why, keep `json`, and fall back to M5's `@Generable AgentAction`.
6. **What "remove the workaround" means here.**
   - `ActionLoop` stays while MLX is supported, because it is MLX's only working tool path.
   - It is deleted with MLX in M6, once Core AI is the only local backend.

### M4: Per-role model selection `[done — short run; full run later]`

**Scope decision (2026-09-29): a short, informative run now; the full per-role benchmark later.**

**Built.**
- `Model/LocalModelRoles.swift`:
  - `LocalModelRole`: answering, drafting, judging, comparing.
  - `ReasoningMode`: on, off.
  - `LocalModelRoles`: the role → variant and reasoning table, read from `ORION_LOCAL_ROLES`
    (e.g. `*=qwen3-4b-4bit:off,answering=qwen3-8b-4bit`), falling back to `LocalModelRoles.recommended`.
    The CLI validates it.
  - `ResolvedLocalModel`, with identifiers like `coreai:qwen3-4b-4bit+nothink`.
- `LocalModelLoader.model(for:role:)` loads weights once per variant. A non-thinking role is the
  same weights wrapped with `ContextOptions(reasoningLevel: .custom("none"))`, via
  `FoundationModelsAgent.with(contextOptions:)`, which reaches the one-shot, multi-turn and
  native-tool paths.
- Every call site names its role:
  - `AgentSession` → answering, and `model_used` is per role;
  - `teach next` and the app drafter → drafting;
  - `teach answer`, `teach bench` and the app grader → judging, plus comparing for `--pairwise`.
    `teach bench`'s run info records both models.
- MLX ignores the table.

**Short run (`results/coreai_backend/m4/run_m4.sh`).** Bundles `qwen3-4b-4bit` (new, 2.1 GB,
284 s export) and `qwen3-8b-4bit_weights_8bit_kv_cache` (new) join `qwen3-8b-4bit`.

| role | measured on | configs |
|---|---|---|
| raw runtime | `model-bench`, 1 trial | 8B, 8B INT8-KV, 4B |
| answering | depth 2 with native tools, on the 10 hand-graded Phase 5 questions: p50, tool-call rate, hand grade | {8B, 8B INT8-KV, 4B} × {on, off}. 8B:on is reused from M3.5 |
| judging + comparing | `teach bench --pairwise`, k=3, on a 6-item gold subset: 2 strong answers where Phase 7's tripwire false-fired, and 4 weak or hedged answers where Phase 7's grader drifted lenient. Measures κ, verdict accuracy, unparseable replies, disputed items, wall-clock | {8B, 4B} × {on, off}. INT8-KV only matters for long contexts, and judge prompts are short |

- **Deferred to the full run: drafting.** Its metric, verifier-passed yield, is confounded
  by the vendored DB's 44% `CONTRADICTED` semantic layer (Docs/17 M7), which rejects nearly every
  question. It needs Phase 7 M8's clean re-investigation first. Drafting stays on 8B with thinking
  until then.

**Results.** Full tables are in `COREAI_BACKEND_EVAL.md` §4c; raw data in `results/coreai_backend/m4/`.
The run took ~2 h 05 m of benchmarking plus ~27 min of exports.
- **Runtime.**
  - 4B prefills and decodes ~1.8× faster than 8B: 1435 vs 807 tok/s prefill, 51 vs 29 tok/s decode.
  - 4B's peak footprint is only slightly lower (8.7 vs 9.5 GB), because the 40K-context KV cache
    dominates.
  - INT8-KV is slower and peaks at ~18 GB, so it is **rejected**.
- **Answering (10 questions, native tools).**
  - Hand grades are flat at 7.0–8.0/20 across all six configs, within noise.
  - p50 latency: 8B:on 99 s → 8B:off 50 s → **4B:off 45 s** (max 55 s).
- **Judging (6 items, k=3, pairwise).**
  - 8B:on scores κ 0.78 with verdict accuracy 0.83, in 30.6 min.
  - **Thinking off breaks the judge.** It calls ~95% of criteria "met", misconceptions included,
    giving κ 0.04 (8B) and 0.08 (4B).
  - 4B:on scores κ 0.80 but verdict accuracy 0.60, and one call produced no response, which failed
    that item's grade.
  - 0 unparseable judge replies in any config.
  - The pairwise tripwire fired on neither strong answer where it false-fired under MLX in Phase 7.
- **Choice (`LocalModelRoles.recommended`):**
  - answering = `qwen3-4b-4bit` with thinking off;
  - judging, comparing and drafting = 8B with thinking on (unchanged).
  - The table applies only to plain `coreai`. An explicit `coreai:<variant>` pins every role to
    that variant, and `ORION_LOCAL_ROLES` overrides both.
  - A live `ask --local-backend coreai` with no overrides answered in 33 s end to end and recorded
    `model_used = coreai:qwen3-4b-4bit+nothink`.
- **Hardening found (for M5 / Phase 7 M8).** A single judge call that throws fails the whole
  grade. It should instead become an unconfident vote.
- **For the full run later:**
  - all 55 questions and 15 gold items;
  - the comparer measured on its own;
  - drafting;
  - 4B:on as a judge after that hardening;
  - two-variant memory in the app process.

Suites: `OrionMacOs` 497 non-live tests (342 + 155), `OrionApp` 148 tests, 0 failures.

**Original plan for M4:**

- **Matrix:** {Qwen3-8B 4bit, 8B 4bit + INT8 KV, Qwen3-4B 4bit} × reasoning {default, `.custom("none")` through `ContextOptions`}.
- **Roles:**

  | Role | Measured on |
  |---|---|
  | depth-1/2 answering | the bench subset |
  | band-1/2 question drafting | verifier-passed yield over N concepts (M2's local anchor-hallucination problem) |
  | criterion judge | teach bench κ and time; today band-3 grading takes ~10.5 min on 8B |
  | answer comparer | the §7.4 tripwire false-positive rate |

- **Output:** a `LocalModelRoles` config (role → variant + reasoning level) that `LocalModelLoader` honours. Pick the smallest model that holds quality for each role.

### M5: Guided generation on the Core AI path `[done — short run; full run later]`

**Revised scope before starting.**
- M4 already had **0 unparseable judge replies in ~470 Core AI calls**, so the original goal
  ("parse failures → 0") is met.
- M3.5 already fixed depth 2's format adherence, so `@Generable AgentAction` isn't needed.
- The real question: can a guided judge match the thinking text judge at no-thinking speed?
- Plus the hardening M4 found.

**Built.**
- **`Teaching/GuidedGrading.swift`:**
  - `GuidedCriterionJudge` and `GuidedAnswerComparer`. Each runs **two guided turns in one
    session**: an analysis (`CriterionAnalysis {evidenceQuote, reasoning}`), then, with it in
    context, a decision (`CriterionDecision {answerStatesThisIdea, confidence}`). The comparer
    uses `AnswerComparisonAnalysis` and `…Decision`.
  - A kind-neutral prompt, and a quote-grounding check: a "stated" verdict whose quote isn't in
    the answer becomes an unconfident vote.
  - `JudgeOutput` (`text` | `guided`), selected by `--judge-output` on `teach answer` / `teach bench`
    or `ORION_JUDGE_OUTPUT`, default `text`. Guided on MLX is a validation error.
  - `LocalGrading.judge(agent:output:)` / `.comparer(...)` is now the single factory for the CLI
    and the app.
- **`GuidedGenerating` / `GuidedTurnGenerating`**, implemented by `FoundationModelsAgent` through
  `FoundationModelsGuidedSession`:
  - always `reasoningLevel .custom("none")`, because a grammar can't admit a `<think>` block;
  - a 512-token cap per turn, because an uncapped first smoke ran over 9 minutes on one item.
- **Hardening (`RubricGrader`, OrionCodeIntel).** A judge call that throws becomes one unconfident
  "not met" vote instead of failing the whole grade. A failed comparer leaves the tripwire unrun.
- **`teach bench` run info** records `judgeOutput` and `failedJudgeCalls` (via `CountingJudge`).
- **Tests:** 3 hardening tests in `RubricGraderTests`, and 8 in `GuidedGradingTests`, which drives
  a real `LanguageModelSession` schema decode through a custom provider. The gated live test
  `CoreAIGuidedJudgeLiveTests` gives ~3 s per two-turn verdict and judges a correct and a wrong
  answer correctly.

**Finding: on Core AI, `@Generable` field order is not declaration order.**
- FoundationModels encodes `properties` as an unordered dictionary, with declaration order only in
  `x-order`. xgrammar (via `coreai-models` @ `e7b24da`) follows the dictionary's order and ignores
  `x-order`.
- A live stream showed `met` generated before `reasoning` finished. "Reasoning first" in a single
  struct therefore holds only by chance.
- This is why the judge uses two turns. An upstream issue is drafted in
  `results/coreai_backend/m5/COREAI_MODELS_ISSUE_DRAFT.md` (not filed).

**Results.** The same 6-item subset as M4, k=3, pairwise. See `COREAI_BACKEND_EVAL.md` §4d.

| judge | κ | verdict accuracy | wall-clock |
|---|---|---|---|
| 8B text, thinking (default) | **0.780** | **0.83** | 30.6 min |
| 8B guided v1 (`met` + ANTI note) | 0.164 | 0.00 | 10.9 min |
| 4B guided v1 | 0.509 | 0.17 | 7.3 min |
| 8B guided v2 (neutral + grounding) | 0.526 | 0.33 | 12.3 min |
| 4B guided v2 | 0.469 | 0.33 | 7.4 min |

- v1 inverted polarity on anti-criteria. v2's neutral question and quote grounding roughly tripled
  8B's κ.
- 0 parse failures and 0 failed calls across all runs.

**Decision.**
- **Text with thinking stays the default judge and comparer.** Guided is an opt-in: 2.5× faster,
  but κ 0.53 is below the 0.60 bar and verdicts are right only a third of the time.
- The hardening ships.
- `@Generable AgentAction` is dropped as superseded by M3.5.

**For the full run later.**
- All 15 gold items.
- A guided single-struct judge, if `coreai-models` starts honouring `x-order`.
- "Think then decide": one thinking text turn followed by a guided decision turn. It should keep
  the thinking judge's quality while guaranteeing the format, though format is already not a
  problem on Core AI.

Suites: `OrionMacOs` 508 non-live tests (345 + 163), `OrionApp` 148 tests, 0 failures.

**Original plan for M5:**

These are the structural wins that MLX couldn't provide.

- **Criterion judge:** `@Generable CriterionVerdictOutput { evidenceQuote; note; met: Bool; @Guide(.anyOf([...])) confidence }` via `respond(generating:)`, in `Teaching/CriterionJudges.swift`.
  - Goal: parse failures go to 0. This is a direct fix for the Phase 7 M7 failure mode and a Phase 7 M8 hardening item.
  - Re-run teach bench.
- **Answer comparer:** `@Generable AnswerComparison { same: Bool }`.
- **ActionLoop:** `@Generable AgentAction` for each turn. Evaluate it against the text-JSON loop on the routing bench, and adopt it only if nothing regresses.
- ~~**Native FM `Tool` calling on `CoreAILanguageModel`:** a live experiment only.~~ Pulled forward into **M3.5**, gated by a full 55-question bench rather than a single live test. `@Generable AgentAction` remains M5's fallback if native calling fails that gate.

### M6: Cutover + MLX removal (only if M3's gate passed — passed by decision 2026-09-29) `[done]`

**Done.** Core AI is now the only local runtime.
- **Defaults.** `LocalModelBackend` has one case, `.coreAI(variant:)`, and defaults to
  `defaultCoreAI` (`qwen3-8b-4bit` with `LocalModelRoles.recommended`). Asking for `mlx` fails with
  "The MLX backend was removed (Docs/18 M6)".
- **Removed from `Package.swift`:** `mlx-swift-lm` and `swift-huggingface` as direct dependencies,
  plus `swift-transformers`. The latter two stay only as transitive dependencies of
  `coreai-models`. `mlx-swift` and `mlx-swift-lm` no longer resolve for either the package or the
  app.
- **Removed code:**
  - `Qwen3Agent`, `ToolCallCapture`, `ModelDownloadProgressReporter`, `ModelBackedDepthClassifier`;
  - `TurnGenerating`'s `ChatSession` conformance;
  - **the text-JSON `ActionLoop` workaround**, together with `ToolCallProtocol`, `--tool-protocol`
    and `ORION_TOOL_PROTOCOL`, as planned in M3.5.
- **Depth paths now.** Depth 2 is always `NativeToolLoop`. Depth 1 is a direct plain-chat answer,
  which is what `ActionLoop` did at budget 0.
- **Removed tests:** `Qwen3AgentTests`, `Qwen3NonThinkingToolCallingLiveTests`,
  `ModelBackedDepthClassifierLiveTests`, `ModelDownloadProgressReporterTests`, `ActionLoopTests`
  and `ActionLoopLiveTests`.
  - `AgentSessionTests`' depth-2 cases now script native tool calls.
  - The teaching live tests load through `LocalModelLoader`.
  - The CI `--skip` list drops the removed classes and adds `CoreAINativeToolCallingLiveTests` /
    `CoreAIGuidedJudgeLiveTests`.
- **No `xcodebuild` requirement.** Plain `swift run orion-agent ask <starlette> … --force-depth 2`
  answered in 40 s with native tool calls and recorded `model_used = coreai:qwen3-4b-4bit+nothink`,
  with no flags. `OrionMacOs/README.md` and `OrionApp/README.md` were rewritten accordingly.
- **App model-missing state.**
  - `CoreAIModelLocator.missingVariants(for:roles:)` and `exportCommand(variant:)`.
  - A new `LocalModelSetupNotice`, shown on Ask (answering role) and Teaching (drafting + judging).
    It lists each missing bundle's exact export command, with Copy and "Check again".
  - `LocatorError` is now `CustomStringConvertible`, so a failed ask or grade in the app shows the
    export command, not an enum case.
  - Stale "downloading weights / a few minutes" progress copy is updated.
  - The rebuilt app launches cleanly. A full Ask/Teaching click-through wasn't automated (the
    app's documented `System Events` limitation); the same `AgentSession` / grader paths are
    covered by the CLI live run and the suites.
- **Housekeeping.**
  - The rerunnable `results/coreai_backend/m4/run_m4.sh` drops `--tool-protocol`.
  - The M3 and M3.5 scripts are marked historical.
  - The untracked `OrionMacOs/mlxswift_check/` was left alone.
  - A pre-M6 snapshot of the uncommitted tree was saved outside the repo before any deletion.

Suites: `OrionMacOs` 487 non-live tests (345 + 142), `OrionApp` 148 tests, 0 failures.

**Original plan for M6:**


- **Defaults:** set the default backend to Core AI.
- **Remove:**
  - `mlx-swift-lm` and `swift-huggingface`;
  - `Qwen3Agent`, `ModelBackedDepthClassifier` and its live test, `Qwen3NonThinkingToolCallingLiveTests`, `ModelDownloadProgressReporter`;
  - the CI skip-list entries for those tests.
- **Remove the `xcodebuild` requirement:** verify that `swift run orion-agent ask` now works under plain SwiftPM, then drop the requirement from `OrionMacOs/README.md` and `OrionApp/README.md`.
- **App model-missing state:** the Core AI weights aren't auto-downloaded the way the Hugging Face ones were. Ask and Teaching need an actionable empty state that names the export command.
- **Memory update:** update the `orion-feasibility-study` memory and the Docs/18 banner.
- Leave the untracked `OrionMacOs/mlxswift_check/` alone. It's yours, so I'll ask before touching it.

## Reuse (don't rebuild)

- `TurnGenerating`, `AgentModel`, `TeachingQuestionDrafting`, `CriterionJudging`, `AnswerComparing`. These are already backend-agnostic seams.
- `ActionLoop`, `ContextBuilder`, `SemanticImporter.ingestAnswer`. These are unchanged.
- `BenchCommand` / `TeachBenchCommand` / `CalibrationStats`, extended with a backend flag.
- The Python harness's metric definitions (`harness/orion_eval/runner.py`: TTFT, `gen_tps`, peak memory). `model-bench` mirrors them so numbers are comparable with `LEADERBOARD.md`, where Qwen3-8B MLX is 22 tok/s, 10.58 s TTFT and 8.03 GB peak.

## Risks

1. **Exporting 8B needs the fp16 checkpoint (~16 GB) plus RAM on a 24 GB M5.** Try `--num-layers 1` and Qwen3-4B first.
2. **No cross-turn KV reuse in `CoreAIExecutor`.** Multi-turn depth-2 loops may re-prefill growing transcripts; M3 measures this explicitly.
3. **Export max context vs our prompt sizes.** Pinned by the `--dry-run` / `--max-context-length` step. Overflow now surfaces as `LanguageModelError.contextSizeExceeded`.
4. **`coreai-models` is days-old** ("not accepting PRs"). Pin the tag and verify the API against the checked-out source, as Docs/12 M0 and Docs/13 M0 did.
5. **The system classifier model changed with OS 27.** M0 re-validates the guardrail before anything else builds on it.
6. **CI may have no macOS 27 image.** Handle it honestly (M0).

## Verification

- **Every milestone:**
  - `cd OrionMacOs && swift build && swift test --skip <live classes>` is green.
  - `xcodebuild -project OrionApp/OrionApp.xcodeproj -scheme Orion -destination 'platform=macOS' test` succeeds (with `-skipPackagePluginValidation -skipMacroValidation`).
- **M0:** `ORION_AGENT_LIVE_MODEL_TEST=1 swift test --filter AppleFoundationDepthClassifierLiveTests`, then `orion-agent bench <starlette> --classify-only`.
- **M1:** `llm-runner --model <dir> --prompt "Hello"` answers, and `llm-benchmark` reports tok/s.
- **M2:** `orion-agent ask <starlette> "…" --force-depth 2 --local-backend coreai --explain` makes a real tool call with a resolved anchor. It does the same with `mlx`.
- **M3–M5:** the benchmark commands above, with the numbers written into `COREAI_BACKEND_EVAL.md` and Docs/18.
- **M6:** the app launches and Ask/Teaching work end to end on Core AI, on the Pulsed and Starlette repos. Plain `swift run orion-agent` works with no xcodebuild step.
