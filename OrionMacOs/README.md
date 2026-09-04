# OrionCodeIntel

Phase 1 of Orion: **deterministic code intelligence**. Takes a Python repository checkout and
produces a structural Code Graph (files → symbols → references → dependencies → call graph),
persisted to SQLite with a JSON/JSONL export. No LLM is involved.

Design: [`../Docs/10_phase1_deterministic_code_intelligence.md`](../Docs/10_phase1_deterministic_code_intelligence.md).

## Layout

- `Sources/OrionCodeIntel/` — the analysis library (no AppKit/SwiftUI; no stdout/`exit`).
- `Sources/orion-index/` — the CLI (`analyze`, `stats`, `export`).
- `Tests/OrionCodeIntelTests/` — unit + integration + snapshot tests.

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

## Status

**M0 (package skeleton) — done.** `swift build` + `swift test` (9) green; CLI wired with
not-yet-implemented subcommand stubs. Next: M1 (ingestion + SQLite). See the milestone list
in the design doc.

> Note: `tree-sitter-python` is pinned to **exactly 0.23.6** — 0.24+ ship a `Package.swift`
> that drops `scanner.c` and fails to link. `GrammarTests` guards the grammar ABI + node
> types against future bumps.
