# Code Graph export (`<out>/export/`)

Written by `orion-index analyze` (unless `--no-export`) and regenerable at any time with
`orion-index export --out <dir>`. All files are UTF-8, keys are `snake_case` and sorted, and
output is **byte-deterministic** for a given `(repository, commit)` — ids are content hashes,
so JSONL diffs are meaningful.

| file | one row / object per | key fields |
|---|---|---|
| `repository.json` | the run | `commit_hash`, `orion_version`, `grammar_versions`, `resolver`, `counts{}`, `resolution{total_relationships, resolved_relationships, calls, resolved_relationship_rate}` |
| `files.jsonl` | source file | `id`, `path`, `module_path`, `language`, `is_test`, `is_package_init`, `parse_ok`, `line_count`, `sha256`, `symbol_ids[]` |
| `symbols.jsonl` | symbol | `id`, **`anchor`**, `qualified_name`, `name`, `kind`, `file`, `module_path`, `parent_anchor`, `redirects_to`, `range{start_line,start_col,end_line,end_col}`, `signature`, `docstring`, `decorators[]`, `visibility`, `is_exported`, `epistemic_type` |
| `relationships.jsonl` | edge | `id`, `type`, `confidence`, `confidence_tier`, `resolved`, `provenance`, `epistemic_type`, `source{anchor,kind}`, `target{anchor,kind}` **or** `target{ref,external:true}`, `site{file,start_line,end_line}` |
| `external_dependencies.jsonl` | third-party / stdlib dep | `id`, `name`, `distribution`, `source` (`pyproject`\|`requirements`\|`stdlib`\|`inferred`), `version_spec`, `is_stdlib`, `import_count` |
| `diagnostics.jsonl` | analysis note | `stage`, `severity`, `code`, `message`, `file`, `start_line`, `end_line` |
| `code_graph.json` | whole repo (skeleton for LLM context) | `repository`, `stats{symbols_by_kind, relationships_by_type}`, `modules[]{module_path, file, symbols[], imports[], imported_by[], external_imports[]}`, `classes[]{anchor, bases[], methods[]}`, `entrypoints[]`, `test_map[]{test, targets[]}` |

## `kind` values

`module`, `package`, `class`, `function`, `method`, `property`, `variable`, `constant`,
`parameter`, `import_alias`, `reexport`.

## `type` values

`calls`, `depends_on`, `imports`, `implements`, `extends`, `reads`, `writes`, `references`,
`tested_by`, `part_of`. (`reads`/`writes` and `part_of` are not emitted in Phase 1.)

`provenance`: `ast:import` (M4 import edges), `scip` (M5 call/inheritance edges),
`heuristic:test_reference` (M6 `tested_by`).

## The Phase 2 join contract

`symbols.jsonl[].anchor` is `<repo-relative path>::<dotted in-file nesting>` — **byte-for-byte
the form the Phase 0 benchmark uses** in `relevant_symbols` and `evidence[].symbol`
(`starlette/applications.py::Starlette.build_middleware_stack`). A module symbol's anchor is
the bare path (`starlette/applications.py`).

Guarantees, checked in `StarletteExportTests`:

- every benchmark `relevant_symbols` anchor (≥ 95 %) appears verbatim as a `symbols.jsonl`
  `anchor`;
- a symbol's `range` covers the source lines the benchmark cites for it (modulo the
  benchmark occasionally anchoring `Sub.method` to the inherited `Base.method` — same leaf
  name, same file).

Phase 2's `build_structured_context(question, export_dir)` can therefore, for each
`relevant_symbol`: slice that symbol's source span from `range`, pull its 1-hop neighbours
(`calls` / `extends` / `tested_by`) from `relationships.jsonl`, and prepend the relevant
`modules[]` slice from `code_graph.json` — a structure-first context in place of whole-file
concatenation. No harness file changes were made in Phase 1.

## Semantic export (Phase 2, M3)

Written by `ingest-semantic` (unless `--no-export`) and regenerable with `orion-index export`
— the same command as above; it writes both layers when the run has a semantic ingestion,
Phase-1-only files otherwise. See
[../Docs/11_phase2_semantic_analysis.md](../Docs/11_phase2_semantic_analysis.md) for how these
rows are produced (Claude Code CLI investigation → validation → consistency check).

| file | one row / object per | key fields |
|---|---|---|
| `components.jsonl` | semantically-grouped component | `id`, `name`, `description`, `architectural_role`, `confidence`, `confidence_tier`, `epistemic_type`, `member_anchors[]` |
| `claims.jsonl` | claim | `id`, `subject_ref`, `predicate`, `object_ref`, `statement`, `claim_type`, `confidence`, `evidence_ids[]` |
| `evidence.jsonl` | evidence for one claim | `id`, `claim_id`, `anchor`, `range{start_line,end_line}`, `evidence_type` |
| `investigations.jsonl` | one Claude Code investigation attempt (**full history for the run**, not just the latest) | `id`, `question`, `model_used`, `num_turns`, `total_cost_usd`, `duration_ms`, `outcome` |
| `semantic_model.json` | the run's **latest** investigation (skeleton) | `investigation_id`, `components[]{name, architectural_role, member_count, confidence}`, `component_relationships[]{source, target, type, confidence_tier}` (by component **name**, not id), `uncertainty_count`, `contradiction_count` |

Unlike the Phase 1 files above, semantic-export ids are **not** content-addressed — a
component/claim/evidence/investigation row gets a random UUID, because re-ingesting the same
run under a new investigation is expected to (and, across repeated Claude Code runs, likely
will) produce a different set of findings. `investigations.jsonl` and `semantic_model.json`
scope differently on purpose: the former is every attempt ever ingested for the run (an audit
trail, like `diagnostics.jsonl`); the latter is "the" current semantic model, i.e. only the
most recent investigation's components/relationships.

`claim_type` values: `INTERPRETATION`, `INFERENCE`, `UNKNOWN` (Claude may assert any of these),
plus `CONTRADICTED` — a verdict the Swift-side consistency check assigns when a claim's
evidence symbols share no confirmable Phase 1 relationship; Claude never asserts it itself.
`confidence`/`confidence_tier` on `components.jsonl`/`semantic_model.json` are likewise
**derived** by the importer (how much of what Claude cited actually resolved/confirmed
against the Code Graph), not self-reported by Claude — its structured-output contract has no
per-component or per-relationship confidence field.

No file here is written if the run has no investigation yet — `orion-index export` silently
skips this section rather than erroring, and Phase 1's files are unaffected either way.
