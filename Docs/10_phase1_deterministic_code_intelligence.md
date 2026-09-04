# 10 — Phase 1: Deterministic Code Intelligence (Development Plan)

> Status: **M0 done** (package skeleton builds, 9 tests green, CLI wired). This is the
> working plan for Phase 1 of [08_development_phases.md](08_development_phases.md). Edit
> freely as implementation proceeds.

## Context

Orion builds a persistent "Codebase Mental Model" of a repository. Phase 0 (MLX model
feasibility) is complete — `Qwen3-8B-4bit` is the leading local model. Phase 1 is the
deterministic foundation everything else stands on:

```
Repository -> AST -> Symbols -> References -> Dependencies -> Call graph -> Code Graph
```

It is **pure deterministic extraction — no LLM, no network model calls.** "No sophisticated
agent required" ([08_development_phases.md](08_development_phases.md)). The output is a
queryable Code Graph of structural facts that Phase 2 (Claude semantic analysis) and Phase 3
(MLX agent) consume.

Current repo state: `OrionMacOs/` is empty. The only code is the Python eval harness
(`Agent Feasibility Study/harness/orion_eval/`). Benchmark corpus: Starlette v1.6.0 vendored
at `Agent Feasibility Study/vendor/starlette/` (gitignored), pinned commit
`4f250d6b814587e20c5365f0a5f0c4d42bcb929f`; `Agent Feasibility Study/benchmark/benchmark.resolved.json`
has 55 questions with real `relevant_symbols` + `file`/`line` evidence anchors.

### Decisions (made with the user)

1. **Language: Swift**, native macOS, SwiftPM package rooted at `OrionMacOs/`. Start now.
   Library + CLI only — **no SwiftUI/app target** (that is Phase 4).
2. **Analyzer parses Python source only** for v1 (matches the Starlette corpus). Stays
   pluggable per language.
3. **Persistence: SQLite primary store + JSON/JSONL export** for the Phase 2 Python harness.

### Key alignment contract

The benchmark anchors symbols as `starlette/applications.py::Starlette.build_middleware_stack`
(repo-relative path + `::` + dot-joined in-file nesting). The analyzer must emit this exact
string as a join key (`symbols.anchor`), and each symbol's line range must contain the
benchmark's `evidence[i].line`. This is how Phase 1 output is validated against Phase 0 work.

---

## Project layout

`OrionMacOs/Package.swift`, `swift-tools-version:5.10`, `platforms: [.macOS(.v14)]`.
(Dev toolchain verified: Swift 6.3.3 / Xcode 26. Language mode stays 5 to avoid strict-concurrency churn on the shared pipeline context.)

| Target | Type | Purpose |
|---|---|---|
| `OrionCodeIntel` | library | All analysis + persistence + export. **No AppKit/SwiftUI, no `print`/`exit`** — communicates via return values + a `DiagnosticsSink`/`Logger`. This is what a Phase 4 Xcode app target will depend on. |
| `orion-index` | executable | Thin CLI over the library (swift-argument-parser). Integration point for the Phase 2/3 Python harness (shell out + read `export/`). |
| `OrionCodeIntelTests` | test | Unit + integration + snapshot. |

No vendored-C grammar target — resolved open question #1: keep the pure Swift Package Manager
grammar dependency, pin exact versions, and catch grammar drift with node-type assertion tests.

```
Sources/OrionCodeIntel/
  Model/         records + enums (SymbolKind, RelationshipType, ConfidenceTier, EpistemicType)
  Language/      LanguageSupport protocol, LanguageRegistry, PythonLanguage
  Ingest/        RepositoryScanner, GitRunner, LanguageDetector, RepoLayout
  Parsing/       TreeSitterParser, ParsedTree, LineIndex, ASTCache
  Symbols/       PythonSymbolExtractor, QualifiedNameBuilder, ReexportResolver, Queries/python-symbols.scm
  Scip/          ScipIndexer (runs scip-python), scip.proto + generated ScipProto.swift, ScipModel,
                 ScipSymbol (descriptor parser), SymbolJoiner (SCIP occurrence -> our anchor)
  Imports/       ImportExtractor, PyProjectParser, RequirementsParser, StdlibModules
  Relationships/ RelationshipBuilder (imports/depends_on + calls/reads/writes/extends/implements/references from SCIP)
  TestMapping/   TestDetector, TestMapper
  Graph/         CodeGraphAssembler, GraphSummary
  Persistence/   Database, Migrations, Store (DAO), DeterministicID
  Export/        JSONLExporter, CodeGraphExporter
  Pipeline/      AnalysisPipeline, PipelineStage, AnalysisContext, StageTimings
Sources/orion-index/  OrionIndex.swift + Commands/{Analyze,Stats,Export,Query}Command.swift
Tests/OrionCodeIntelTests/  Unit/  Integration/StarletteIntegrationTests.swift  Support/  Snapshots/
```

---

## Dependencies (SwiftPM)

| Package | URL | Pin | Why |
|---|---|---|---|
| swift-argument-parser | `github.com/apple/swift-argument-parser` | `from: 1.5.0` (→ 1.8.2) | CLI framework. |
| GRDB.swift | `github.com/groue/GRDB.swift` | `from: 7.6.0` (→ 7.11.1) | SQLite: named ordered migrations (`DatabaseMigrator`), fast batch writes in one transaction, `Codable` records, WAL + concurrent readers for the future app. Chosen over SQLite.swift (no migrations, slow batch) and raw SQLite3 C (boilerplate). |
| SwiftTreeSitter | `github.com/tree-sitter/swift-tree-sitter` | `from: 0.9.0` (→ 0.25.0) | Canonical tree-sitter Swift runtime binding (`Parser`, `Language`, `Tree`, `Node`, `Query`). |
| tree-sitter-python | `github.com/tree-sitter/tree-sitter-python` | **`exact: 0.23.6`** | Python grammar. `import TreeSitterPython; Language(tree_sitter_python())`. **Must be exactly 0.23.6:** 0.24+ ship a `Package.swift` whose `FileManager.fileExists("src/scanner.c")` guard evaluates against the wrong CWD, drops `scanner.c`, and the link fails with undefined `tree_sitter_python_external_scanner_*`. 0.23.6 lists both C sources unconditionally. ABI is fine against SwiftTreeSitter 0.25 (guarded by `GrammarTests`). |
| swift-collections | `github.com/apple/swift-collections` | `from: 1.1.0` (→ 1.6.0) | `OrderedSet`/`OrderedDictionary` for deterministic iteration. |
| swift-protobuf | `github.com/apple/swift-protobuf` | `from: 1.30.0` (→ 1.38.1) | Decode the SCIP index emitted by `scip-python`. `scip.proto` is vendored into `Sources/OrionCodeIntel/Scip/` and its generated `ScipProto.swift` is committed (no `protoc` at build time). |

We ship our **own** tree-sitter extraction queries (`Symbols/Queries/python-symbols.scm` via
`Bundle.module`), not the grammar's bundled highlight queries. Pin exact `SwiftTreeSitter` +
`tree-sitter-python` tags; a unit test asserts a handful of grammar node types
(`function_definition`, `class_definition`, `import_from_statement`, `decorated_definition`,
`aliased_import`) so a grammar bump that renames nodes fails loudly.

### External tools at analyze time

- **`scip-python`** (`@sourcegraph/scip-python`, Pyright-based) is the primary static
  resolver — resolved open question #2. `ScipIndexer` shells out to
  `npx --yes @sourcegraph/scip-python@<pinned> index --output <tmp>/index.scip
  --project-name <repo> --cwd <repoRoot>` (Node 25 + npx verified on the dev machine). It
  runs **once per analysis**; accuracy is prioritized over cost. Everything Pyright cannot
  confidently resolve stays `low` / `unresolved`. Jedi is only added later if benchmarks show
  a real coverage gap.
- **Graceful degradation:** if `npx`/`scip-python` is unavailable or exits non-zero, the
  pipeline still emits files + symbols + syntactic `imports`/`depends_on` edges, records a
  `SCIP_UNAVAILABLE` diagnostic, and sets `analysis_runs.resolver = "none"`; call/read/write/
  inheritance edges are then absent rather than wrong.
- `git` (already required) for ingestion.

No in-process LSP client, no hand-rolled name/scope resolver.

---

## Pipeline stages

`AnalysisPipeline.run(input:) -> AnalysisResult`. Each stage conforms to `PipelineStage` with
typed I/O and a shared `AnalysisContext` (DB handle, `runID`, `DiagnosticsSink`,
`StageTimings`, config). All collections sorted deterministically before persist/export
(files by path; symbols by `(file, startByte)`; relationships by
`(type, sourceAnchor, targetAnchor, siteStart)`).

1. **Ingestion** (`Ingest/`) — input: local path, optional `--commit`, `--source-url`.
   `GitRunner` (read-only `Process` wrapper) does `git ls-files -z` for tracked-file
   discovery + `git rev-parse HEAD`; `--commit` triggers the only state change (`git checkout`,
   reverted on exit). No `.git` -> filtered filesystem walk (skip `.git`, `.venv`,
   `node_modules`, `__pycache__`, `build`, `dist`). `LanguageDetector` (`.py`/`.pyi`).
   `RepoLayout` detects `src/` layout, PEP 420 namespace packages, `pyproject` `package-dir`
   -> the module-root set for dotted `module_path`. Outputs: one `Repository` row
   (`UNIQUE(local_path, commit_hash)`), one `AnalysisRun` (`status=running`), `files` rows
   (`path`, `language`, `module_path`, `sha256`, `line_count`, `is_package_init`).

2. **AST** (`Parsing/`) — one `Parser` per worker with `PythonLanguage`; parse bytes ->
   `ParsedTree` (+ `LineIndex` for byte<->1-based line/col). `ASTCache` holds trees for
   stages 3–7 then evicts (LRU). Walk for `ERROR`/`MISSING` -> `PARSE_ERROR` diagnostic,
   `files.parse_ok=false`, still extract from the partial tree. Bounded `TaskGroup` (`--jobs`).

3. **Symbol extraction** (`Symbols/`) — the authoritative symbol table, built from tree-sitter
   (not SCIP), so `anchor`/`qualified_name`/ranges are fully under our control. `.scm` queries
   capture class/function definitions (method vs function by parent), decorated defs,
   module/class-level assignments, imports. `PythonSymbolExtractor` -> `SymbolRecord`: `kind`
   (`module|class|function|method|property|variable|constant|parameter|import_alias|reexport`;
   `property` = `@property`, `constant` = UPPER_SNAKE module-level), `qualified_name`
   (`module_path` + dotted nesting), `anchor` (`path::dotted-nesting`, benchmark form),
   line/col + byte ranges (whole definition span), `signature`, `docstring` (first body
   string literal), `decorators` (JSON), `visibility` (name-based), `is_exported` (literal
   `__all__`, else public top-level = true; computed `__all__` -> `DYNAMIC_ALL` diagnostic).
   `ReexportResolver` (resolved open question #4): for static `__all__` entries and
   `from .x import y` in `__init__.py`, emit a **synthetic `reexport` symbol** on the exporting
   module (`anchor` = `<pkg>/__init__.py::y`) with `redirects_to` = the original definition's
   anchor; the original keeps its real location. Dynamic re-exports stay unresolved.

4. **SCIP index** (`Scip/`) — `ScipIndexer` runs `scip-python` over the repo checkout and
   `ScipModel` decodes `index.scip` (SwiftProtobuf). `ScipSymbol` parses SCIP descriptor
   strings (`module`/`type`/`method`/`term`/`parameter`) into a dotted path + kind.
   `SymbolJoiner` maps every SCIP definition occurrence to one of our tree-sitter symbols by
   `(file, range)` containment (exact range match preferred; enclosing-range fallback), giving
   a `scipSymbol <-> anchor` table. Unjoined SCIP defs (e.g. synthesized `__init__`) get a
   diagnostic. Output: the join table + the parsed SCIP documents/occurrences for stage 6.

5. **Imports & dependency graph** (`Imports/`) — `ImportExtractor` (tree-sitter) handles
   `import a.b.c`, `import a.b as x`, `from a.b import c, d as e`, `from . import x`,
   `from ..pkg import y` (relative level count); binds an `import_alias` symbol per local name.
   In-repo import targets come from the SCIP join where available (Pyright-accurate), falling
   back to path-based resolution against `RepoLayout` module roots. Unresolved in-repo ->
   **external**: classify via bundled `StdlibModules`, else `pyproject`/`requirements` for a
   `version_spec`, else `inferred`. Emits `imports` edges (in-repo) and `depends_on` edges
   (-> `external_dependencies` rows). This stage is what still works under SCIP degradation.

6. **Relationship building from SCIP** (`Relationships/`) — `RelationshipBuilder` walks the
   SCIP occurrences (joined to our anchors in stage 4) and emits typed edges:
   - `calls` — occurrence with `syntax_kind` in the function-identifier family, not a
     definition, whose enclosing SCIP symbol joins to a source anchor and whose referenced
     symbol joins to a callable target anchor. Keeps the call **site** (`site_file_id`,
     `site_start/end_line/col`).
   - `reads` / `writes` — occurrence `symbol_roles` `ReadAccess` / `WriteAccess` on
     module-global or class-attribute targets (locals ignored).
   - `extends` / `implements` — from `SymbolInformation.relationships` (`is_implementation`)
     and base-class occurrences; base resolves to `Protocol`/`abc.ABC` (directly or
     transitively) -> `implements`, else `extends`.
   - `references` — any remaining resolved occurrence that is not one of the above.
   - `provenance = "scip"`. `confidence` / `confidence_tier`: **high (0.9)** SCIP-resolved to
     a single in-repo definition; **medium (0.6)** SCIP-resolved but ambiguous / via a
     `reexport`; **unresolved (0.1, `resolved=false`)** SCIP left it external or unknown, or
     SCIP was unavailable. Edges whose source/target is external carry `target_ref` +
     `external_dependency_id` instead of a target anchor.

7. **Test mapping** (`TestMapping/`) — `TestDetector`: path `tests/**`, `**/test_*.py`,
   `**/*_test.py`; symbol = `test_*` function / `unittest.TestCase` method / `@pytest.*`.
   Back-fills `files.is_test`. `TestMapper`: test symbol's resolved outbound
   `calls`/`references`/`imports` into non-test in-repo symbols -> `tested_by` (medium for a
   call, low for import-only; boost to high when `test_applications.py` <-> `applications.py`).

8. **Assembly + persistence** (`Graph/`, `Persistence/`) — `CodeGraphAssembler` builds the
   in-memory `CodeGraph` + `GraphSummary` (counts, resolution rate, module import matrix,
   classes+bases, entrypoints, test map). `Store` writes one transaction per table with
   cached prepared statements; finalizes `AnalysisRun` (`status`, counts, `stage_timings`
   JSON, `orion_version`, `grammar_versions`). `DeterministicID`: file/symbol/relationship
   ids = truncated `sha256(repository_id + commit_hash + anchor + discriminator)` — stable
   across runs so JSONL diffs and snapshots mean something.

---

## SQLite schema (GRDB `DatabaseMigrator`, first migration `v1_phase1_schema`)

Tables: `repositories`, `analysis_runs`, `files`, `symbols`, `external_dependencies`,
`relationships`, `diagnostics`. Every fact table carries `repository_id` + `commit_hash` +
`run_id` so multiple repos/commits coexist; "current view" = latest succeeded `run_id` for a
`(repository_id, commit_hash)`. WAL on, foreign keys on. `eraseDatabaseOnSchemaChange` in
DEBUG only.

Field notes:
- `symbols`: `anchor` (UNIQUE per run, benchmark form), `qualified_name`, `kind`
  (`module|class|function|method|property|variable|constant|parameter|import_alias|reexport`),
  `start_line/col`, `end_line/col`, `start_byte`, `end_byte`, `signature`, `docstring`,
  `decorators` (JSON), `visibility`, `is_exported`, `parent_symbol_id`,
  `redirects_to` (anchor a `reexport`/`import_alias` points at, else NULL),
  `component_id` (Phase 2 placeholder, always NULL), `epistemic_type` (always `'FACT'` now).
- `relationships`: `relationship_type`
  (`calls|depends_on|imports|implements|extends|reads|writes|references|tested_by|part_of`),
  `source_symbol_id`, `target_symbol_id`, `external_dependency_id`, `source_ref`/`target_ref`
  (textual fallback when unresolved), `provenance`
  (`ast:import|scip|heuristic:test_reference`),
  `confidence` (REAL), `confidence_tier`, `resolved`, `site_file_id` + site line/col.
- `external_dependencies`: `name`, `distribution`, `source`
  (`pyproject|requirements|stdlib|inferred`), `version_spec`, `is_stdlib`, `import_count`.
- `analysis_runs`: `resolver` (`scip-python@<ver>` | `none`), `stage_timings` JSON,
  `grammar_versions` JSON, `tool_versions` JSON (scip-python, pyright), per-table counts, `error`.
- Indexes: `(repository_id, commit_hash)` on every fact table; plus
  `(run_id, qualified_name)` and `(file_id)` on symbols; `(run_id, source_symbol_id, type)`
  and `(run_id, target_symbol_id, type)` on relationships.

**Reserved for Phase 2 (do NOT create now):** `components`, `component_members`, `claims`,
`evidence`, `investigations`, `model_revisions`, `knowledge_states` — arrive as `v2_*`
migrations. `epistemic_type` columns already exist for `INTERPRETATION`/`INFERENCE` later.

Treat [07_data_models.md](07_data_models.md) as the **conceptual** contract: keep names that
map cleanly (`source_url`, `commit_hash`, `relationship_type`, `provenance`, `confidence`,
`part_of`); expand `Symbol.location` into explicit line/col/byte; add implementation fields
(`run_id`, `anchor`, `confidence_tier`, `resolved`, site ranges) freely.

---

## JSON/JSONL export (`<out>/export/`)

One object per line, keys sorted, deterministic ids, UTF-8. Emitted for the latest succeeded
run.

- `repository.json` — id, path, `commit_hash`, languages, `analyzed_at`, `orion_version`,
  `grammar_versions`, `counts{}`, `resolution{call_sites, calls_resolved, call_resolution_rate}`.
- `files.jsonl` — `{id, path, module_path, language, is_test, is_package_init, line_count,
  sha256, parse_ok, symbol_ids[]}`.
- `symbols.jsonl` — `{id, anchor, qualified_name, name, kind, file, module_path,
  parent_anchor, range{start_line,start_col,end_line,end_col}, signature, docstring,
  decorators[], visibility, is_exported, epistemic_type}`. `anchor` is byte-for-byte the
  benchmark `relevant_symbols` format.
- `relationships.jsonl` — `{id, type, confidence, confidence_tier, resolved, provenance,
  epistemic_type, source{anchor,kind}, target{anchor,kind} | target{ref,external},
  site{file,start_line,end_line}}`.
- `external_dependencies.jsonl`, `diagnostics.jsonl`.
- `code_graph.json` — compact whole-repo skeleton for LLM context: `repository`,
  `stats{symbols_by_kind, relationships_by_type, call_resolution_rate}`,
  `modules[]{module_path, file, symbols[], imports[], imported_by[], external_imports[]}`,
  `classes[]{anchor, bases[], methods[]}`, `entrypoints[]`, `test_map[]{test, targets[]}`.

**Phase 2 consumption (not built in Phase 1):** Phase 1 only guarantees the join contract —
`symbols.jsonl.anchor` == benchmark `relevant_symbols[i]` == `evidence[i].symbol`, and symbol
`range` contains `evidence[i].line`. Phase 2 later adds a `build_structured_context()` to
`Agent Feasibility Study/harness/orion_eval/context.py` that slices per-symbol source spans +
1-hop neighbors instead of concatenating whole files. **No harness files change in Phase 1.**

---

## CLI (`orion-index`)

- **`analyze <path>`** — `--commit <sha>` (checkout + revert), `--out <dir>` (default
  `<path>/.orion`, holds `orion.db` + `export/`), `--export/--no-export`,
  `--language python`, `--jobs <n>`, `--clean`, `--source-url <url>`,
  `--fail-on-parse-error`, `--max-file-bytes <n>` (default 2_000_000). Exit: `0` ok,
  `2` usage, `3` pipeline failure, `4` parse errors with `--fail-on-parse-error`.
- **`stats`** — `--db`/`--out`, `--commit`, `--json`. File count, symbols by kind,
  relationships by type, call-resolution rate, unresolved count, externals, parse errors,
  per-stage timings.
- **`export`** — re-serialize `export/` from an existing DB without re-analyzing.
- **`query`** (optional, debugging) — `--symbol <substr>`, `--callers/--callees <anchor>`,
  `--module <dotted>`, `--json`. Not a product surface.

---

## Testing & verification

`swift test` runs everything (XCTest).

**Unit — inline Python fixtures** (`PythonFixture` compiles a `String` or `{relpath: src}`
map through the real pipeline; SCIP-dependent cases run only when `npx` is available, else
`XCTSkip`).

- _Tree-sitter (no SCIP):_ nested-method anchor form; `x=1` -> variable, `UPPER=2` ->
  constant, `@property` -> property; decorator/docstring capture; literal `__all__` ->
  `is_exported`; `_x`/`__x` visibility; `__init__.py` -> package `module_path`;
  `from a.b import c as d` -> `import_alias` symbol; `from .x import y` in `__init__.py` ->
  synthetic `reexport` symbol with `redirects_to`; `import a.b.c` / `from . import x` /
  `from ..pkg import y` -> `imports` edges; unresolved import -> `external_dependencies` row
  (stdlib vs pyproject vs inferred); broken source -> one `PARSE_ERROR` + partial symbols;
  `src/pkg/mod.py` -> `module_path == "pkg.mod"`.
- _SCIP path:_ same-file call -> `calls` high; cross-file imported call -> `calls`;
  `self.method()` -> resolved to the class method; `Type()` -> `calls`/`references` on the
  class; `class C(Base)` -> `extends`, `class P(Protocol)` -> `implements`; `self.x = 1` ->
  `writes` on `C.x`, `return self.x` -> `reads`; call through a `reexport` -> tier `medium`;
  unknown external -> `resolved=false`.
- _Degradation:_ force `resolver="none"` -> symbols + `imports`/`depends_on` present, no
  `calls`/`reads`/`writes`/`extends`, one `SCIP_UNAVAILABLE` diagnostic.
- _Test mapping:_ `test_*` calling production -> `tested_by`.

**Integration — vendored Starlette** (`StarletteIntegrationTests`, locate vendor dir by
walking up from `#filePath`; `XCTSkip` if absent since it is gitignored; run pipeline once,
class-cached):
- Symbols by `qualified_name` **and** `anchor`: `starlette.applications.Starlette`,
  `...Starlette.build_middleware_stack`, `starlette.responses.JSONResponse`,
  `starlette.responses.Response`, `starlette.middleware.Middleware`
  (from `starlette/middleware/__init__.py`).
- Anchor strings verbatim in `symbols.jsonl`, incl.
  `starlette/middleware/__init__.py::Middleware`.
- Edges: `JSONResponse --extends--> Response` (resolved); `starlette.applications
  --imports--> starlette.middleware`; `ExceptionMiddleware`/`CORSMiddleware` have `extends`.
- External: `anyio` in `external_dependencies`, `source == "pyproject"`, `version_spec`
  non-null, a `depends_on` edge targets it.
- **Call-resolution-rate**: `calls_resolved / call_sites >= 0.55` initially (print actual;
  ratchet up per milestone).
- **Evidence-anchor cross-check**: load `benchmark.resolved.json`; for every `evidence` item
  (`type=="SOURCE"`, `.py` file, benchmark-anchor `symbol`), assert a symbol with that exact
  `anchor` whose `[start_line, end_line]` contains `evidence.line`. Require **>= 90%** of
  checkable items pass; print each failure with expected vs actual range.
- Every `starlette/**.py` has `parse_ok == true`.

**Golden snapshot** — serialize a stable subset of Starlette `code_graph.json`
(`symbols_by_kind`, `relationships_by_type`, sorted `classes[].bases`, module import matrix)
to `Tests/.../Snapshots/starlette_code_graph.json`; rewrite only when
`ORION_UPDATE_SNAPSHOTS=1`. No full symbol/relationship dump.

**Timing budget** — read `analysis_runs.stage_timings`; soft-warn if Starlette (~40 files)
> 5 s on a dev machine, hard-fail at 15 s (catch accidental O(n^2)).

**Manual end-to-end:**
```
cd OrionMacOs
swift run orion-index analyze "../Agent Feasibility Study/vendor/starlette" \
  --commit 4f250d6b814587e20c5365f0a5f0c4d42bcb929f --out /tmp/orion-starlette
swift run orion-index stats --out /tmp/orion-starlette --json
# inspect /tmp/orion-starlette/export/{symbols,relationships}.jsonl, code_graph.json
```

---

## Implementation order (each milestone builds, tests green, produces something runnable)

- **M0 — Skeleton. [done]** `Package.swift` with 3 targets + 6 deps; `PythonLanguageSupport`
  returns a usable `Language`; `SourceLanguage`/`LanguageRegistry`; Model enums locked to the
  Docs/04 epistemic vocabulary; `python-symbols.scm` bundled via `Bundle.module`;
  `GrammarTests` (grammar loads + ABI ok + required node types present + `.scm` compiles) +
  `ModelTests`; `orion-index --help`/`--version`/subcommand help; stubs throw
  `NotImplemented`. `swift build` + `swift test` (9) green.
- **M1 — Ingestion + DB.** `GitRunner`, `RepositoryScanner`, `LanguageDetector`,
  `RepoLayout`, `PyProjectParser`, migration `v1`, `Store` batch insert. `analyze` fills
  `repositories`/`analysis_runs`/`files`/`external_dependencies`; `stats` prints counts.
  Test: Starlette file count; `module_path` derivation; `__init__.py` detection; `anyio`
  from `pyproject`.
- **M2 — Parsing + diagnostics.** `TreeSitterParser`, `LineIndex`, `ASTCache`, parse-error
  diagnostics, `--jobs`. Test: broken fixture -> diagnostic; all Starlette `parse_ok`.
- **M3 — Symbols.** `python-symbols.scm`, `PythonSymbolExtractor`, `QualifiedNameBuilder`,
  `ReexportResolver`, signature/docstring/decorator/`__all__`/visibility. Persist `symbols`;
  export `symbols.jsonl` + partial `code_graph.json`. Test: full symbol matrix; synthetic
  `reexport` symbols; Starlette known-symbol + anchor format; first evidence-anchor cross-check.
- **M4 — Imports + dependency graph.** `ImportExtractor`, `PyProjectParser`,
  `RequirementsParser`, `StdlibModules`, path-based in-repo resolution. Emit `imports` +
  `depends_on`; export `external_dependencies.jsonl` + import matrix. Test: relative-import
  fixtures; Starlette `applications -> middleware`; `anyio` edge.
- **M5 — SCIP resolution + relationships.** `ScipIndexer` (npx `scip-python`), `ScipModel`
  (SwiftProtobuf + vendored `scip.proto`), `ScipSymbol`, `SymbolJoiner`, `RelationshipBuilder`
  (`calls`/`reads`/`writes`/`extends`/`implements`/`references`), confidence tiers, graceful
  degradation path. Reconcile M4 in-repo import targets with SCIP. Persist `relationships`;
  export `relationships.jsonl` + resolution stats. Test: `JSONResponse extends Response`;
  `Starlette.__call__` calls `build_middleware_stack`; resolution-rate threshold; full
  evidence cross-check >= 90%; `SCIP_UNAVAILABLE` degradation test.
- **M6 — Test mapping.** `TestDetector`, `TestMapper`, `tested_by`; back-fill `is_test`.
- **M7 — Assembly + full export + snapshot + timing.** `CodeGraphAssembler`, finalized
  `code_graph.json`, `export` command, deterministic ids, golden snapshot, `stage_timings`
  in `stats --json`. Deliverable: a complete `export/` the Python harness can load.
- **M8 — Hardening.** `query` subcommand, AST cache eviction tuning, `--clean`, exit-code
  paths, `OrionMacOs/README.md`, documented Phase 2 contract, optional GitHub Actions
  `swift test`.

---

## Risks / open questions

> **Resolved 2026-09-04** — the answers below (#1, #2, #4, #5) are now folded into the
> sections above: pure-SPM grammar + node-type assertions; `scip-python` (Pyright) as the
> primary resolver replacing the hand-rolled `Resolution/` package; synthetic `reexport`
> symbols; `EpistemicType` = the Docs/04 vocabulary. #3 and #6 stand as written.

1. **Grammar packaging.** Primary path uses `tree-sitter-python`'s `Package.swift` — needs
   network at `swift build`, and grammar node-type names can drift and silently break our
   `.scm`. Mitigation: pin exact grammar + `SwiftTreeSitter` versions; unit-assert a few
   known node types so drift fails loudly; keep vendored-C fallback staged from M0.
   *Open: vendor from day one for hermetic offline builds?*
   Answer: No. Keep the simpler Swift Package Manager approach, pin exact dependency versions, and add node-type assertions to catch grammar drift
2. **Resolution ceiling.** Name-based resolution cannot follow instance-attribute types,
   `getattr`, dynamic dispatch, decorator rebinding, conditional imports, `import *`. These
   stay `low`/`unresolved`. *Open: acceptable call-resolution floor for Starlette (proposed
   0.55, ratcheting)? Is an opt-in Jedi/pyright bridge a later Phase 1.5?*
   answer: Use Pyright as the primary static analyzer during this process rather than building a lightweight name-based resolver first. Since this process runs only once, prioritize resolution accuracy over computational cost. Cases that Pyright cannot confidently resolve remain low/unresolved. Start with Pyright alone and add Jedi only if benchmarks demonstrate a meaningful coverage gap.
3. **Namespace / src-layout detection** will misfire on editable installs, monorepos, PEP
   420 packages spanning roots. Starlette is the easy case. Emit a diagnostic when
   `module_path` can't be computed.
4. **`__all__` / re-exports.** Only literal `__all__` and simple `+=` honored; `from .x
   import y` in `__init__.py` gets an `imports` edge. *Open: emit synthetic re-export
   symbols so `starlette.Foo` resolves, or just edges?*
   answer: Emit synthetic re-export symbols. For supported __all__ and from .x import y patterns, create a synthetic symbol on the exporting module that points to the original definition. This allows references such as starlette.Foo to resolve directly while preserving the actual definition location. Continue to support only statically determinable __all__ values; leave dynamic re-exports unresolved.
5. **Epistemic vocabulary mismatch to reconcile before Phase 2.**
   [04_codebase_mental_model.md](04_codebase_mental_model.md) uses
   `FACT | INTERPRETATION | INFERENCE | UNKNOWN | CONTRADICTED`; the existing harness
   `schema.py` uses `VERIFIED | INFERRED | UNKNOWN | CONTRADICTED`. Phase 1 emits only
   `FACT`. *Open: which vocabulary wins?*
   answer: the 04_codebase_mental_model.md vocabulary wins
6. **Byte vs line offsets.** tree-sitter is byte-oriented; benchmark uses 1-based lines.
   Store bytes, derive line/col via `LineIndex`. Assume UTF-8 (`errors=replace`), diagnostic
   on decode fallback; handle CRLF in line counts.
