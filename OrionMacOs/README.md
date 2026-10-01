# OrionCodeIntel

Phase 1 of Orion: **deterministic code intelligence**. Takes a Python repository checkout and
produces a structural Code Graph (files → symbols → references → dependencies → call graph),
persisted to SQLite with a JSON/JSONL export. No LLM is involved.

Design: [`../Docs/10_phase1_deterministic_code_intelligence.md`](../Docs/10_phase1_deterministic_code_intelligence.md).

## Layout

- `Sources/OrionCore/` — the portable Codebase Model: records, `Store`, migrations, queries, the
  semantic/revision layer and teaching logic. GRDB only; builds for macOS and iOS (Docs/19 M1).
- `Sources/OrionCodeIntel/` — the analysis library (no AppKit/SwiftUI; no stdout/`exit`). Mac only
  in practice (it shells out to git/npx); re-exports `OrionCore`.
- `Sources/OrionAgent/` — the local agent and teaching model calls, over `OrionCore`. Builds for iOS
  too: Core AI and the Claude/`Process` paths are Mac-only, and `--local-backend system` (the
  on-device Apple model) works on both.
- `Sources/orion-index/` — the CLI (`analyze`, `stats`, `export`, `query`, … and `snapshot`, which
  packs a knowledge snapshot for the iOS companion, Docs/19 M2).
- `Tests/OrionCodeIntelTests/` — unit + integration + snapshot tests.
- `EXPORT.md` — the `export/` schema and the Phase 2 join contract.

## Build & test

```sh
swift build
swift test
swift run orion-index --help
```

## External tools (analyze-time, not build-time)

- **`git`** — repository ingestion.
- **`npx` + `@sourcegraph/scip-python`** — the Pyright-based static resolver used for
  reference resolution, the call graph, and inheritance edges (Milestone M5). If it is
  unavailable the pipeline still emits files, symbols, and syntactic import edges, and records
  a `SCIP_UNAVAILABLE` diagnostic.

## OrionAgent — local model setup (Core AI, Docs/18)

`Sources/OrionAgent/` and its `orion-agent` CLI (design:
[`../Docs/12_phase3_mlx_agent.md`](../Docs/12_phase3_mlx_agent.md), runtime:
[`../Docs/18_os27_foundation_models_coreai.md`](../Docs/18_os27_foundation_models_coreai.md)) run
Qwen3 locally on **Core AI** for depth 1/2 answers and teaching mode. Since Docs/18 M6 this is the
only local runtime: MLX, its Hugging Face download and its `xcodebuild` requirement are gone, so
plain `swift build`, `swift test` and `swift run orion-agent` work.

**First run: export the model bundles.** Nothing is downloaded automatically. A bundle is a folder
with `<name>.aimodel`, a `tokenizer/` and `metadata.json`, which `CoreAILanguageModel(resourcesAt:)`
loads. The default setup needs two:

```sh
scripts/coreai/export-qwen3.sh                         # qwen3-8b-4bit: judging, comparing, drafting
scripts/coreai/export-qwen3.sh --model qwen3-4b         # qwen3-4b-4bit: depth-1/2 answering
scripts/coreai/export-qwen3.sh --dry-run                # print the resolved config only
```

A missing bundle fails with the exact export command, and the app's Ask and Teaching pages show
it up front.

**What the script does:**
- Clones `apple/coreai-models` at a pinned commit into `~/Library/Caches/Orion/coreai-models`.
- Runs its `coreai.llm.export` in its own `uv` environment.
- Downloads the fp16 Hugging Face checkpoint into the normal HF cache (Qwen3-8B is ~16GB).
- Writes the bundle to `<root>/<model>-<compression>/`. Exports take ~5 min (4B) to ~8 min (8B)
  and peak at ~15 GB of memory.

**Where bundles live.** `<root>` is `ORION_COREAI_MODEL_DIR` if set, otherwise
`~/Library/Application Support/Orion/CoreAIModels`. `CoreAIModelLocator` resolves the same path.

**Optional `--aot`.** This also compiles the bundle ahead of time for this Mac
(`xcrun coreai-build compile`) and points `metadata.json` at the compiled asset. Docs/18 M1
measured it slower, so it is off by default.

**Choosing the bundle.** Pass `--local-backend coreai|coreai:<variant>` to `ask`, `bench`,
`teach next`, `teach answer`, `teach bench` and `model-bench`, or set `ORION_LOCAL_BACKEND` (the
app reads that variable). The default is `coreai`.

**Choosing a model per role (Docs/18 M4).**
- Plain `coreai` uses the measured table:
  - depth-1/2 answering on `qwen3-4b-4bit` with thinking off;
  - rubric judging, the pairwise comparer and question drafting on `qwen3-8b-4bit` with thinking on.
- `coreai:<variant>` runs every role on that one bundle.
- `ORION_LOCAL_ROLES` overrides both. It takes comma-separated `role=setting` pairs:
  - roles are `answering`, `drafting`, `judging`, `comparing`, or `*` for the rest;
  - a setting is a variant, `on|off`, or `variant:on|off`;
  - for example `*=qwen3-4b-4bit:off,judging=qwen3-8b-4bit:on`.

**Depth-2 tool calling (Docs/18 M3.5).** Depth 2 uses FoundationModels' native tool calling
(`NativeToolLoop`). The model calls the query tools in Qwen3's own `<tool_call>` format. The old
text-JSON `ActionLoop` workaround, and its `--tool-protocol` / `ORION_TOOL_PROTOCOL` switch, were
removed with MLX in M6.

**Teaching grader output (Docs/18 M5).** `teach answer` and `teach bench` take
`--judge-output text|guided`, or `ORION_JUDGE_OUTPUT`.
- `text` (the default) lets the model think, then parses its JSON verdict.
- `guided` uses Core AI guided generation: it is 2.5× faster, but agrees less with the expert
  labels (κ 0.53 vs 0.78 on the short M5 run).

**Smoke-test a bundle** with the package's own runner:

```sh
cd ~/Library/Caches/Orion/coreai-models
swift run -c release llm-runner --model "$HOME/Library/Application Support/Orion/CoreAIModels/qwen3-8b-4bit" --prompt "Hello"
```

## Status

**Phase 1 complete — M0–M8, `swift test` (127) green.**

- **M0** — package skeleton, `PythonLanguageSupport`, model enums, grammar guard tests.
- **M1** — `analyze` ingests a repo into SQLite: `repositories`, `analysis_runs`, `files`
  (dotted `module_path`, `is_package_init`, `is_test`, sha256/loc), and
  `external_dependencies` (from `pyproject.toml` / `requirements*.txt`). `stats` / `stats --json`.
- **M2** — tree-sitter parsing (UTF-8 byte offsets), `LineIndex`, parallel parse pass
  (`--jobs`), real `files.parse_ok`, `parse`-stage `ERROR`/`MISSING` diagnostics.
  `--fail-on-parse-error` exits 4.
- **M3** — `symbols` table: module/class/function/method/property/variable/constant/
  import_alias/`reexport`, benchmark-form anchors, parent links, signatures/docstrings/
  decorators, `__all__`→`is_exported`. Validated against `benchmark.resolved.json`
  (Starlette: 3.2k symbols, anchors 96.5% present, evidence lines 99% in-range).
- **M4** — `relationships` table: module→module `imports` and module→external `depends_on`
  edges (path-based `ModuleResolver`, no re-parse), `StdlibModules` classification, minted
  `external_dependencies` for undeclared imports, `import_count`. Starlette: 635 edges.
- **M5** — SCIP resolution via `scip-python` (Pyright): `calls` / `extends` / `implements` /
  `references` edges, joined back to M3 anchors. `--no-resolve` + `SCIP_UNAVAILABLE`
  graceful degradation; `analysis_runs.resolver`. Starlette: 7515 edges total (3716
  `calls`, 111 `extends`).
- **M6** — `tested_by` edges from test functions to the production symbols they exercise
  (call/reference/import based, tiered by name-match). Starlette: 1847 edges.
- **M7** — Code Graph export. `analyze --export` (and `orion-index export`) write
  `<out>/export/`: `repository.json`, `{files,symbols,relationships,external_dependencies,
  diagnostics}.jsonl`, `code_graph.json` (skeleton: module import matrix, class hierarchy,
  entrypoints, test map). Snake_case, sorted keys, byte-deterministic. `symbols.jsonl`
  `anchor` is the Phase 2 join key against `benchmark.resolved.json`. See `EXPORT.md`.
- **M8** — `orion-index query` (`--symbol` / `--callers` / `--callees` / `--module`, `--json`);
  `analyze` failure → exit 3; `stats` shows `resolver`; `.github/workflows/ci.yml`.

### SCIP notes

- Regenerating `Sources/OrionCodeIntel/Scip/ScipProto.generated.swift` needs `protoc` +
  `protoc-gen-swift` (`brew install protobuf swift-protobuf`) — see `Protos/README.md`. Not
  needed for a normal build.
- `ScipIndexer` passes `--environment` with an empty package list so `scip-python` skips its
  `pip3 show` enumeration of the ambient Python install (which otherwise ENOBUFS-crashes on
  machines with many packages installed). In-repo edges don't need third-party type info.

> Note: `tree-sitter-python` is pinned to **exactly 0.23.6** — 0.24+ ship a `Package.swift`
> that drops `scanner.c` and fails to link. `GrammarTests` guards the grammar ABI + node
> types against future bumps.
