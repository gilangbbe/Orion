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
