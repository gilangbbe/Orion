# OrionCodeIntel

Phase 1 of Orion: **deterministic code intelligence**. Takes a Python repository checkout and
produces a structural Code Graph (files → symbols → references → dependencies → call graph),
persisted to SQLite with a JSON/JSONL export. No LLM is involved.

Design: [`../Docs/10_phase1_deterministic_code_intelligence.md`](../Docs/10_phase1_deterministic_code_intelligence.md).

## Layout

- `Sources/OrionCodeIntel/` — the analysis library (no AppKit/SwiftUI; no stdout/`exit`).
- `Sources/orion-index/` — the CLI (`analyze`, `stats`, `export`, `query`).
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

## OrionAgent (Phase 3) — first-run model download

`Sources/OrionAgent/` and its `orion-agent ask` CLI (design:
[`../Docs/12_phase3_mlx_agent.md`](../Docs/12_phase3_mlx_agent.md)) load a local
`mlx-community/Qwen3-8B-4bit` checkpoint for depth 1/2 questions. **The first `ask` on a fresh
machine downloads the real weights (~4.3GB) from the Hugging Face Hub** — `orion-agent` prints
download progress to stderr while this happens (a silent multi-minute wait otherwise looks like
a hung process, not a slow one); every run after that loads from the on-disk cache in seconds.

That cache lives wherever `swift-huggingface`'s `HubClient` puts it — same resolution order the
Python `huggingface_hub` library uses, so a cache is shareable between the two:

1. `HF_HUB_CACHE` environment variable, if set.
2. `HF_HOME` environment variable + `/hub`, if set.
3. Otherwise `~/.cache/huggingface/hub` (confirmed on this machine: a real `orion-agent` run
   landed the checkpoint at `~/.cache/huggingface/hub/models--mlx-community--Qwen3-8B-4bit`,
   ~4.3GB on disk).

Deleting that directory (or the one model's subdirectory within it) forces a re-download next
run; nothing else in this repo depends on its contents.

Building/running an MLX-touching binary (`orion-agent`, or any `OrionAgentTests` gated behind
`ORION_AGENT_LIVE_MODEL_TEST=1`) needs `xcodebuild`, not plain `swift build`/`swift test` —
`mlx-swift`'s Metal shaders are compiled as an Xcode build phase that plain SwiftPM's build
system never runs, so a plain `swift build` links fine but fails at runtime with "Failed to load
the default metallib" the moment a model actually loads:

```sh
xcodebuild -scheme orion-agent -destination 'platform=macOS' -derivedDataPath .build/xcodebuild \
  -skipPackagePluginValidation -skipMacroValidation build
.build/xcodebuild/Build/Products/Debug/orion-agent ask <repo> "<question>"
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
