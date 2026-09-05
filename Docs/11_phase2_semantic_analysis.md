# 11 — Phase 2: Semantic Analysis Prototype (Development Plan)

> Status: **M0-M6 done — all planned milestones complete.** Full details in each milestone's
> entry below; full research write-up in `Agent Feasibility Study/PHASE2_EVAL.md`. Headline
> results, from **4 independent live investigations** of vendored Starlette: a single run
> scores well against a hand-authored gold set (10/11 components matched, macro F1 = 0.926,
> evidence accuracy 1.000), but across 4 runs only **2/4 came back fully `verified`** (2/4
> `partially_verified` — real, structurally-caught instability, not a self-report) and
> pairwise component-decomposition stability between runs was **mean F1 = 0.723** — lower
> than any single run's agreement with gold, as expected for three independently-plausible
> decompositions compared to each other rather than to one fixed target. Two genuine schema/
> logic bugs were found and fixed only because real repeated output was run through the
> pipeline, not synthetic fixtures alone (M2: a structural-connectivity check was one
> symbol-level too narrow; M6: a `components` uniqueness constraint was scoped to the wrong
> table, breaking the exact multi-investigation scenario M6 exists to test) — see each
> milestone's own entry for the story. Depends on Phase 1
> (`orion-index analyze`/`export`, complete — see
> [10_phase1_deterministic_code_intelligence.md](10_phase1_deterministic_code_intelligence.md)).
> Corpus stays Starlette (vendored, pinned `4f250d6b814587e20c5365f0a5f0c4d42bcb929f`) for
> continuity with Phase 0/1.

## Context

Phase 1 produced a deterministic Code Graph: files, symbols, relationships, all `FACT`-tier,
zero LLM involvement. Phase 2 is the first semantic step —
[08_development_phases.md](08_development_phases.md):

```
Code Graph -> Claude Code -> Semantic Components -> Codebase Model
```

Goal: **determine whether structured semantic knowledge can be reliably reconstructed** from
the Code Graph — i.e. produce empirical evidence for H2 (persistent model), H6 (delegated
reasoning can be ingested/verified without making Claude the permanent orchestrator), and a
first data point for H4/H5 (does Claude-level reasoning earn its cost here, and can that need
be recognized). There is no MLX Agent yet (Phase 3) and no UI (Phase 4) — Phase 2 is Claude
investigation + a **verification and persistence pipeline** the Phase 3 agent will later drive
itself.

### Decisions (made with the user)

1. **Full-stack: Swift + Python.** Phase 1 already reserved `components`, `component_members`,
   `claims`, `evidence`, `investigations`, `model_revisions` as Phase-2 `v2_*` migrations and a
   `symbols.component_id` placeholder column
   ([10_phase1_deterministic_code_intelligence.md](10_phase1_deterministic_code_intelligence.md#L238-L241)).
   Phase 2 builds those migrations, a `Store` DAO, and a validation/ingestion pipeline in
   `OrionCodeIntel`, so the output is a real persisted, exported Codebase Model — not a
   throwaway JSON blob — for Phase 3 to build on.
2. **Invocation: an agentic Claude Code CLI session with real repo tool-access**, not a single
   scripted Anthropic API call. This is what [06_claude_code_integration.md](06_claude_code_integration.md)
   literally describes ("Claude investigates repository") and what the eventual product does.
   It is a materially different (and more expensive/variable) hypothesis test than a one-shot
   API call over pasted context, so Phase 2 explicitly measures cost, turns, latency, and
   run-to-run stability (M6).
3. **Evaluation: hand-author a small gold component decomposition for Starlette** and score
   precision/recall/evidence-accuracy against it — objective, matches the
   `benchmark.resolved.json` precedent from Phase 0/1, rather than relying solely on an
   LLM-judge's subjective coherence rating.

### What Phase 2 is not

- Not the MLX Agent (no routing, no local-model involvement, no depth model). Phase 3.
- Not a UI. Phase 4.
- Not re-running the 55-question Task 3/4 benchmark — that already answers "can a model answer
  questions given context." Phase 2 answers a different question: "can whole-repo semantic
  *structure* (components, their responsibilities, their relationships) be reconstructed and
  verified." The Starlette corpus and its `benchmark.resolved.json` anchors are reused only as
  a source of realistic architectural vocabulary and as an anchor-format precedent, not as the
  eval set itself (see the new gold file, M5).

---

## Claude Code CLI investigation contract

`ClaudeInvestigator` (Python, `harness/orion_eval/semantic/investigate.py`) shells out to the
`claude` CLI in non-interactive mode, standing in for the "MLX Agent invokes Claude Code"
step of [06_claude_code_integration.md](06_claude_code_integration.md) §2 — the agent doesn't
exist yet, so Phase 2's Python script performs that step by hand and hands its output to the
same Swift ingestion path Phase 3 will later call itself.

- **Working directory**: the vendored Starlette checkout (`Agent Feasibility Study/vendor/starlette/`).
- **Context priming**: before/alongside free exploration, the prompt points Claude at
  `<out>/export/code_graph.json` (and, if it wants more detail, `symbols.jsonl`/
  `relationships.jsonl`) as **ground-truth structural facts already extracted** — its map, not
  something to re-derive. Every evidence citation in its output must use the exact
  `<path>::<Dotted.Name>` anchor form from `symbols.jsonl` (the same benchmark-anchor
  contract Phase 1 established) so Swift-side evidence validation can resolve it without fuzzy
  matching.
- **Tool access**: read-only. Restrict to `Read`/`Grep`/`Glob` — no `Bash`, no `Edit`/`Write`.
  Investigation must not be able to mutate the checkout or run arbitrary commands.
- **Output**: `--print`/`-p` with `--output-format json` for a single structured wrapper result
  (final message + `session_id`, `total_cost_usd`, `num_turns`, `duration_ms` — capture all of
  these as `investigations` row fields). The prompt requires the final message to be a single
  JSON object matching `SEMANTIC_SCHEMA` (below) and nothing else.
- **Budget**: a soft wall-clock timeout, so a stuck investigation fails as
  `outcome = "incomplete"` rather than hanging or running away on cost
  ([06_claude_code_integration.md](06_claude_code_integration.md) §7).
- **Confirmed flags** (`claude` 2.1.260, checked M1 — CLI flags are not treated as stable API
  here; re-check `claude --help` if invocation starts failing): `-p` + `--output-format json`
  for a single structured result; `--model claude-sonnet-5` pinned explicitly; `--tools
  Read,Grep,Glob` hard-restricts the whole session's available tools (stronger than an
  allowlist — the session has no `Bash`/`Edit`/`Write` tool to even be granted); `--add-dir
  <export_dir>` grants read access to the sibling `.orion/export/` directory outside the repo
  checkout; `--permission-mode bypassPermissions` so headless execution doesn't hang waiting on
  an approval no human can answer (safe specifically because `--tools` already forbids
  mutation); `--max-budget-usd <amount>` is a real cost ceiling the CLI enforces itself; `
  --json-schema <SEMANTIC_SCHEMA>` asks the CLI to constrain its final answer to the contract
  directly. This CLI version has **no turn-cap flag** — budget is enforced via
  `--max-budget-usd` plus a Python-side `subprocess` wall-clock `timeout`, not a turn count.
- **Determinism**: none assumed. Unlike Phase 1 (byte-deterministic) or the Task 3 harness
  (`temperature=0.0` single-shot API calls), an agentic multi-turn session is not expected to
  reproduce identical output run to run. M6 measures that variance directly instead of
  assuming it away.

### Structured output contract (`SEMANTIC_SCHEMA`, version `phase2.v1`)

Extends [06_claude_code_integration.md](06_claude_code_integration.md) §4's example with a
`schema_version` tag, explicit `claim_type`, and evidence as anchors (not free-text
`"file:line"`):

```json
{
  "schema_version": "phase2.v1",
  "components": [
    {
      "name": "Routing",
      "description": "Matches incoming requests to endpoint handlers by path/method.",
      "architectural_role": "core",
      "members": ["starlette/routing.py::Route", "starlette/routing.py::Router"]
    }
  ],
  "component_relationships": [
    {"source": "Middleware", "target": "Routing", "type": "depends_on"}
  ],
  "claims": [
    {
      "claim_type": "INTERPRETATION",
      "statement": "Router.app dispatches to the first matching Route in declaration order.",
      "evidence": ["starlette/routing.py::Router.app"],
      "confidence": "high"
    }
  ],
  "uncertainties": [
    "Whether route matching short-circuits on the first partial match or evaluates all routes."
  ]
}
```

`claim_type` is one of the [04_codebase_mental_model.md](04_codebase_mental_model.md)
vocabulary values Claude may assert: `INTERPRETATION` | `INFERENCE` | `UNKNOWN`. (`FACT` is
reserved for Phase 1 output; Claude never gets to self-tag `FACT`. `CONTRADICTED` is a
Swift-side verdict, never Claude's own tag — see below.) Each `uncertainties[]` entry becomes a
`claims` row with `claim_type = UNKNOWN` and no evidence.

`Agent Feasibility Study/harness/orion_eval/semantic/schema.py` mirrors the existing
`schema.py` pattern: a JSON Schema (draft 2020-12) for `jsonschema` validation, plus a tolerant
`extract_json()` (clean / fenced / brace-scan recovery) reused from the existing module rather
than duplicated.

This is a **first-pass filter only** — real validation (anchors actually resolve, ranges
actually contain what's claimed, no duplicate/contradictory claims) happens in Swift, which is
the only side with the real Code Graph in a queryable form. A Python-side schema pass just
avoids handing Swift obviously-malformed JSON.

---

## SQLite v2 schema (GRDB `DatabaseMigrator`, migration `v2_phase2_schema`)

Additive only — no Phase 1 table is altered, so Phase 1's tests, golden snapshot, and
`resolved_relationship_rate` contract are untouched.

- **`components`** — `id`, `repository_id`, `run_id`, `name`, `description`,
  `architectural_role`, `confidence` (REAL), `confidence_tier`, `status`, `epistemic_type`
  (`INTERPRETATION` for the description/role, never `FACT`), `provenance` (`claude_code`),
  `investigation_id`. **`confidence`/`confidence_tier` are derived by `SemanticImporter`, not
  asserted by Claude** — `SEMANTIC_SCHEMA` (M1) never asks for a per-component confidence, so
  the tier reflects our own verification instead: `high` iff every cited member resolved,
  `medium` if some were dropped.
- **`component_members`** — `id`, `component_id`, `symbol_id`, `confidence`, `role`
  (`core`|`supporting`, currently always `core` — Claude's output has no per-member role).
  Many-to-many: a shared symbol (e.g. a small utility) can belong to more than one component at
  different confidences. `symbols.component_id` is denormalized by the importer to each
  symbol's single highest-confidence membership, for cheap joins/UI later —
  `component_members` stays the source of truth.
- **`component_relationships`** — `id`, `source_component_id`, `target_component_id`,
  `relationship_type` (reuses the Phase 1 `relationship_type` vocabulary: `depends_on` etc.),
  `confidence`, `confidence_tier`, `provenance`, `investigation_id`. Kept as its own table
  rather than widening Phase 1's symbol-scoped `relationships` table — additive, zero risk to
  Phase 1's frozen schema/snapshot. **`confidence_tier` is likewise derived, not asserted**:
  `high` iff `Store.relationshipExists` confirms a real Phase 1 edge between the two
  components' member symbols (or their parents — see M2's real-data finding), else
  `unresolved` — never dropped either way, an unconfirmed relationship stays visible.
- **`claims`** — `id`, `repository_id`, `run_id`, `subject_ref` (nullable — the claim's first
  resolved evidence anchor, or null for an `uncertainties`-derived claim; relaxed from the
  original `NOT NULL` design once M2 confirmed Claude's claims carry no separate subject),
  `predicate`, `object_ref` (both currently always null — Claude's candidate JSON has no
  subject/predicate/object triple, only statement+evidence; kept for a future investigation
  type that might supply one), `statement`, `claim_type`
  (`INTERPRETATION`|`INFERENCE`|`UNKNOWN`|`CONTRADICTED` — the last is a verdict *assigned by
  Swift-side consistency checking*, never emitted by Claude directly), `confidence`, `status`,
  `created_by` (`claude_code`), `investigation_id`.
- **`evidence`** — `id`, `claim_id`, `file_id`, `start_line`, `end_line`, `evidence_type`, plus
  a resolved `symbol_id`. In practice always non-null: an unresolved anchor never becomes an
  `evidence` row at all — the whole claim is dropped (with a diagnostic) if it has no
  resolvable evidence left, so nothing unverified is ever inserted as if it were.
- **`investigations`** — `id`, `repository_id`, `run_id`, `question` (fixed:
  `"phase2_semantic_grouping"` for now — free-form questions are Phase 3), `complexity`
  (`high`), `schema_version` (the candidate's own, even a wrong one — useful on a rejected row),
  `model_used`, `tools_used` (JSON), `session_id`, `num_turns`, `total_cost_usd`,
  `duration_ms`, `outcome` (`verified`|`partially_verified`|`unverified`|`incomplete`|
  `rejected` — Swift's own verdict from what actually survived validation, never a copy of
  Python's own guess), `created_at`. Always written, even for a decode failure or
  `schema_version` mismatch (Docs/07: an attempt is itself useful) — only a hard throw with a
  bare invalid JSON parse skips it, and even that path still records `outcome = "rejected"`.
- **`model_revisions`** — `id`, `repository_id`, `previous_revision`, `change_summary`,
  `triggering_investigation_id`, `created_at`. Phase 2 writes exactly one revision per
  successful ingestion (a coarse "semantic layer v0 -> v1" log) — full diff/contradiction UX is
  Phase 6.
- `symbols.component_id` (already present, NULL in Phase 1) — backfilled by the importer.
- `diagnostics` (existing table, no migration needed) — `stage = "semantic_ingest"`, codes
  actually emitted: `SCHEMA_INVALID` (step 1), `ANCHOR_UNRESOLVED`/`COMPONENT_DROPPED`/
  `CLAIM_DROPPED`/`COMPONENT_RELATIONSHIP_DROPPED` (step 2), `DUPLICATE_COMPONENT`/
  `COMPONENT_RELATIONSHIP_UNCONFIRMED`/`CLAIM_CONTRADICTED` (step 3). `RANGE_MISMATCH` and
  `BUDGET_EXCEEDED` from the original plan aren't implemented — line-range containment isn't
  checked beyond anchor resolution, and there's no Swift-side cost/duration ceiling (M1's
  Python side already enforces `--max-budget-usd` + a wall-clock timeout before Swift ever
  sees the candidate).

`knowledge_states` stays reserved and unbuilt — that's Phase 7 (Teaching).

---

## Validation pipeline (`Sources/OrionCodeIntel/Semantic/`)

Implements [03_agent_and_model_routing.md](03_agent_and_model_routing.md) §5's required path
concretely, as a library entry point Phase 3's MLX Agent will call directly instead of
shelling out to Python:

```
semantic_findings.json (Python-produced candidate)
  |
  v
1. Schema validation      -- Decodable structs, schema_version match, required fields.
  |                           Failure -> outcome="rejected", investigation row still written,
  |                           schema errors persisted as SCHEMA_INVALID diagnostics, nothing
  |                           else touched.
  v
2. Evidence validation    -- every evidence/member anchor resolves to a real symbols.anchor
  |                           in the current run (exact string match, `UNIQUE(run_id, anchor)`
  |                           so at most one hit -- no separate range-containment check, the
  |                           anchor match already implies the right symbol); unresolved ->
  |                           dropped + ANCHOR_UNRESOLVED diagnostic, not inserted; an item
  |                           left with zero resolved anchors is dropped entirely.
  v
3. Consistency check       -- de-duplicate component names (first wins, later ones dropped +
  |                           DUPLICATE_COMPONENT); confirm every component_relationship and
  |                           every multi-evidence claim structurally against the real Phase 1
  |                           relationship graph (Store.relationshipExists /
  |                           relationshipExistsAmongAnyPair, checking each cited symbol's
  |                           parent too -- see M2's real-data finding) -- unconfirmed is kept
  |                           at .unresolved confidence, not dropped; an unconfirmed claim is
  |                           reclassified CONTRADICTED and stays queryable, never silently
  |                           dropped, per Docs/04 (contradictions stay visible).
  v
4. Codebase Model update    -- one investigations row is always written first (even for a
  |                           step 1 failure); on success: Store.insertComponents/
  |                           insertComponentMembers/insertComponentRelationships/
  |                           insertClaims/insertEvidence/insertDiagnostics,
  |                           symbols.component_id backfill (highest-confidence membership),
  |                           one model_revisions row.
  v
5. Export (M3, done)        -- components.jsonl, claims.jsonl, evidence.jsonl,
                                investigations.jsonl, semantic_model.json
```

Never insert an unverified claim as if it were fact-tier, and never silently drop a
contradiction — both are explicit failure/soft-failure modes in
[06_claude_code_integration.md](06_claude_code_integration.md) §7. `investigations.outcome` is
computed from what actually survived steps 2-3 (`verified`/`partially_verified`/`unverified`/
`rejected`), never copied from Python's own (unverified) guess about its own output.

`Component`/`ComponentMember`/`ComponentRelationship`/`Claim`/`Evidence`/`Investigation`/
`ModelRevision` rows all get a random UUID (`DeterministicID.newUUID()`), *not* a content
hash — unlike Phase 1, they're genuinely not expected to be stable across reruns (a rerun is a
new `investigation_id` and, in general, a new set of findings; M6 measures that instability
directly rather than an ID scheme presupposing stability that isn't there). `diagnostics` rows
are the one exception: those *do* use `DeterministicID.diagnostic` (a real content hash,
scoped by investigation id + ordinal), matching Phase 1's own pattern for that table.

---

## Export additions (`<out>/export/`)

Added directly to [EXPORT.md](../OrionMacOs/EXPORT.md) (M3 decision: additive to the existing
doc, not a separate `SEMANTIC_EXPORT.md` — five more files in the same directory didn't
warrant a second document):

- `components.jsonl` — `{id, name, description, architectural_role, confidence,
  confidence_tier, epistemic_type, member_anchors[]}`.
- `claims.jsonl` — `{id, subject_ref, predicate, object_ref, statement, claim_type,
  confidence, evidence_ids[]}`.
- `evidence.jsonl` — `{id, claim_id, anchor, range{start_line,end_line}, evidence_type}`.
- `investigations.jsonl` — `{id, question, model_used, num_turns, total_cost_usd,
  duration_ms, outcome}` — the run's **full** investigation history, not just the latest.
- `semantic_model.json` — compact skeleton mirroring `code_graph.json`'s role for the
  structural layer, scoped to the run's **latest** investigation: `investigation_id`,
  `components[]{name, architectural_role, member_count, confidence}`,
  `component_relationships[]{source, target, type, confidence_tier}` (by component **name**,
  not id — matches `code_graph.json`'s own anchor-not-id convention), `uncertainty_count`,
  `contradiction_count`. This is the artifact Phase 4's Architecture UI will eventually render
  directly.

Phase 1's `code_graph.json` is **not** modified — no risk to its golden snapshot test.

---

## CLI (`orion-index`)

- **`ingest-semantic <path/to/semantic_findings.json>`** (new, M2) — `--out <dir>` / `--db`
  (same as `export`/`stats`; resolves the latest run via `store.latestRun`), `--commit`,
  `--meta <path>` (optional `investigation_meta.json` sidecar for cost/session/turn metadata).
  Always prints accepted/dropped/duplicate/unconfirmed/contradicted counts and the
  investigation id. Exit `0` for `verified`/`partially_verified` (a partial result is still a
  successful ingest — the DB row is the record of what didn't fully check out), exit `1` for
  `rejected`/`unverified`, standard ArgumentParser usage-error exit (64) for a bad invocation.
  *Not built: `--export`/`--no-export`* — export is M3, not part of `ingest-semantic`.
- *Deferred to M3 or later*: a `stats --semantic` extension (component/claim/contradiction
  counts) — not built in M2; `sqlite3 <db> "select ..."` or the manual end-to-end query below
  covers it for now.

Python side (`harness/orion_eval/` — extends the existing `orion_eval` package rather than a
new top-level directory, to reuse `requirements.txt`, `mlflow_log.py`, and the existing
Anthropic-call conventions):

- `semantic/investigate.py` — `ClaudeInvestigator`, the CLI bridge described above.
- `semantic/schema.py` — `SEMANTIC_SCHEMA` + tolerant JSON extraction + `cli_json_schema()`.
- `semantic/score.py` — the gold-set scorer (M5, not built yet).
- `cli.py investigate` (built, M1) writes three files under `--out`: `semantic_findings.json`
  (the candidate), `semantic_findings.raw.json` (the full CLI wrapper, for debugging), and
  `investigation_meta.json` (the small Swift-owned sidecar — model/session/turns/cost/
  duration/tools — `ingest-semantic --meta` reads this, not the raw wrapper). `--write`/
  `--raw-write`/`--meta-write` override the three filenames.
  `cli.py score-semantic` (M5, done — see below).
  *Not built: MLflow logging.* The original plan wanted `investigate` runs logged the way
  Task 3's `grade` is (`mlflow_log.py`, comparable cost/turns/duration across repeated
  investigations) — deferred; not needed until M6's repeatability runs actually happen, and
  `investigation_meta.json` + the DB's own `investigations` table already capture the same
  numbers per-run in the meantime.

---

## Gold evaluation set + scorer [M5 done]

`Agent Feasibility Study/benchmark/starlette_components.gold.json` — hand-authored, 11
top-level components at module + class + top-level-function granularity (no methods), 150
member anchors total, every one confirmed to exist in the real exported `symbols.jsonl` (zero
typos, zero duplicates across components — checked programmatically before use). Each entry:
`name`, `description`, `architectural_role`, `member_anchors[]` (benchmark-anchor form).
**Disclosed limitation**: authored with prior awareness of this specific investigation's own
component breakdown (inspected during M1/M2 development), not a fully blind gold set — see
`PHASE2_EVAL.md` §2 for what that does and doesn't undermine.

`semantic/score.py`:

- **Anchor normalization** (`normalize_anchor`) — rolls every anchor up to its top-level
  defining symbol (`path::Class.method` → `path::Class`) *before* comparing. Needed because the
  gold set stops at class granularity while real predictions routinely cite individual methods
  — without this, the Jaccard score would penalize a prediction for being more specific than
  gold rather than measuring whether the grouping is right.
- **Component alignment** — greedy best-match gold<->predicted by normalized-anchor Jaccard
  overlap, `>= 0.3` to count as a match, then per-match precision/recall/F1. Unmatched gold ->
  **missed**; unmatched predicted -> **spurious** (over-fragmentation or a hallucinated
  grouping) — reported separately, not folded into one number.
- **Evidence accuracy** — reuses the Swift-side verdict already recorded per claim at ingestion
  (`claim_type == "CONTRADICTED"` or not), read straight from the export's `claims.jsonl`
  rather than re-derived in Python; `UNKNOWN` (uncertainty-derived) claims are excluded — never
  a checkable assertion to begin with.
- **Not built: the optional judge axis** (stretch, explicitly deferred in the original plan —
  costs a real API call per run and wasn't needed to get the gold-set path working).
- `cli.py score-semantic --out <dir> --gold <path> [--threshold] [--write <report.json>]`.
- 14 new Python tests (`test_semantic_score.py`, 37 total in `harness/tests/`): normalization,
  Jaccard edge cases, a synthetic perfect/partial/spurious alignment with hand-checked
  precision/recall/F1, evidence-accuracy counting, and a full `score()` round trip through
  temp gold/export files.

**Real result** (`Agent Feasibility Study/PHASE2_EVAL.md`, full write-up): scored against the
same real Starlette investigation from M1/M2/M4 — **10/11 gold components matched (F1 ≥ 0.77),
0 spurious, macro F1 = 0.926, evidence accuracy 1.000 (10/10)**. The one miss
(`Form & Multipart Parsing`) and the weakest match (`Middleware Stack`, R=0.64) were both
checked by hand against the real `components.jsonl`, not just read off the score: in both
cases the underlying content is present, just filed under a different (defensible) component
boundary — exactly the "legitimate judgment call" scenario Risk #4 below anticipated, now with
one concrete instance of it actually observed rather than hypothesized.

---

## Testing & verification

**Swift (`swift test`)**

- Migration test: `v2_phase2_schema` applies cleanly on top of `v1_phase1_schema`; all new
  tables/columns present; Phase 1 tests still green (no regression). **Done — `SemanticSchemaTests`.**
  Note: `eraseDatabaseOnSchemaChange = true` (DEBUG) means an existing on-disk `.orion/orion.db`
  from before a schema edit gets silently wiped on next open, not migrated — hit this firsthand
  mid-M2 (see M2's entry); re-`analyze` after any schema change, don't assume old runs survive.
- Fixture-driven `SemanticImporter` tests, done as `SemanticImporterTests` (19 tests, a real
  analyzed 3-file repo for realistic anchors + a real Phase 1 relationship graph, no network/CLI
  call): valid minimal case round-trips through all 4 implemented pipeline steps (export, step
  5, is M3); an unresolvable anchor is dropped + diagnosed, not inserted; a duplicate component
  name has its later occurrence *dropped* (not the whole batch rejected) with a diagnostic; a
  claim whose evidence symbols share no Phase 1 relationship is reclassified `CONTRADICTED` and
  stays queryable; a `schema_version` mismatch is rejected outright (`outcome = "rejected"`,
  investigation row still persisted); `symbols.component_id` backfill picks the
  highest-confidence membership when a symbol has two; diagnostics land in the DB `diagnostics`
  table, not just the in-memory outcome.
- Export test: M3, not built yet.

**Python (`unittest`, stdlib — no pytest dependency; `harness/tests/`, run via
`python -m unittest discover -s tests -t .` from `harness/`)**

- `schema.py` unit tests: clean/fenced/brace-scan extraction, `jsonschema` validation against
  hand-written valid/invalid payloads, `cli_json_schema()` strips `$schema` correctly.
  **Done — `test_semantic_schema.py`, 9 tests.**
- `investigate.py` unit tests: prompt/command construction (read-only tools, `--json-schema`
  has no `$schema`, prompt is the final positional), wrapper-parsing for all four outcomes with
  `subprocess.run` mocked, `structured_output` preferred over re-parsing `result`, `model_used`
  derived from `modelUsage`'s highest-cost entry. **Done — `test_semantic_investigate.py`,
  14 tests.** 23 total.
- `score.py` unit tests against a tiny synthetic gold file + synthetic predicted output with
  known precision/recall (sanity-check the alignment/scoring math itself, independent of any
  real Claude output).

**Manual end-to-end** (not CI — costs real API/CLI usage). Run and confirmed working
2026-09-04 (10 components / 17 relationships / 17 claims, `outcome = verified`, 0
diagnostics, on the real Starlette candidate — see M2's entry above):

```
cd OrionMacOs
swift run orion-index analyze "../Agent Feasibility Study/vendor/starlette" \
  --commit 4f250d6b814587e20c5365f0a5f0c4d42bcb929f --out /tmp/orion-starlette

cd "../Agent Feasibility Study/harness"
python -m orion_eval.cli investigate --out /tmp/orion-starlette --repo ../vendor/starlette
# writes /tmp/orion-starlette/{semantic_findings.json, semantic_findings.raw.json,
# investigation_meta.json}

cd ../../OrionMacOs
swift run orion-index ingest-semantic /tmp/orion-starlette/semantic_findings.json \
  --meta /tmp/orion-starlette/investigation_meta.json --out /tmp/orion-starlette
# re-running `analyze` into the SAME --out for the same commit needs --clean first
# (Phase 1's file/component ids are content-addressed per (repo, commit), not per-run)

sqlite3 /tmp/orion-starlette/orion.db \
  "select name, architectural_role, confidence_tier from components;"

cd "../Agent Feasibility Study/harness"
python -m orion_eval.cli score-semantic --out /tmp/orion-starlette \
  --gold ../benchmark/starlette_components.gold.json   # M5, not built yet
```

CI stays Swift-only and network-free, same as Phase 1 — the Claude Code CLI investigation is
inherently a paid, non-hermetic step and is exercised manually / on demand, not per-commit.

---

## Implementation order

- **M0 — Schema skeleton. [done]** `v2_phase2_schema` migration: `investigations`,
  `components`, `component_members`, `component_relationships`, `claims`, `evidence`,
  `model_revisions` (additive only, all FKs `ON DELETE CASCADE` off `investigations`/
  `components`/`claims`; `UNIQUE(run_id, name)` on components), typed `OrionRecord`s for all
  six (`Model/SemanticRecords.swift`). Decodable input DTOs for the candidate JSON
  (`Semantic/SemanticFindings.swift`): `SemanticFindings`, `SemanticComponentInput`,
  `SemanticComponentRelationshipInput`, `SemanticClaimInput`, `SemanticClaimType` (Claude may
  only self-tag `INTERPRETATION`/`INFERENCE`/`UNKNOWN` — `FACT` doesn't decode, `CONTRADICTED`
  is a Swift-side verdict). `SemanticImporter` (`Semantic/SemanticImporter.swift`): step 1
  `validateSchema` (schema_version match + required-field/confidence-vocabulary checks), step 2
  `validateEvidence` (resolves every component-member/claim-evidence anchor against
  `Store.symbol(runId:anchor:)`; an item with zero resolved anchors is dropped + diagnosed, not
  kept; `uncertainties[]` become `UNKNOWN` claims needing no evidence); `ingest(candidateURL:
  runId:)` throws `SemanticImportError.notImplemented(_, partial:)` carrying the real step-1/2
  outcome once steps 3-5 are reached, or `.schemaInvalid` if step 1 fails outright. `orion-index
  ingest-semantic <path> --out <dir>` wires it up, prints accepted/dropped counts, and exits via
  `NotImplemented("M2")`. 16 new tests (`SemanticSchemaTests`, `SemanticImporterTests`); full
  suite 143/143 green. Manually verified end-to-end against a throwaway repo: a 3-anchor
  component with one bogus member correctly persists 2 members + drops 1 with a diagnostic.
- **M1 — Claude Code CLI bridge. [done]** `harness/orion_eval/semantic/`:
  `schema.py` (`SEMANTIC_SCHEMA` draft-2020-12 + `SCHEMA_HINT`, `extract_semantic_json`
  reusing the existing `orion_eval.schema.extract_json` clean/fenced/braces recovery,
  `validate_semantic` via `jsonschema`); `investigate.py`'s `ClaudeInvestigator` — builds the
  investigation prompt (points at `<out>/export/`, states the anchor-verbatim rule and the
  INTERPRETATION/INFERENCE-only claim-type rule), builds the `claude -p` command (read-only
  `--tools`, `--json-schema`, `--max-budget-usd`, `bypassPermissions`), runs it with a
  `subprocess` wall-clock timeout, and parses the `--output-format json` wrapper into an
  `InvestigationResult` (`outcome` one of verified/unverified/incomplete/rejected,
  `session_id`/`num_turns`/`total_cost_usd`/`duration_ms` captured for the future
  `investigations` row). `cli.py investigate --out <dir> [--repo] [--model] [--max-budget-usd]
  [--timeout] [--dry-run]` wires it up and prints the next command to run
  (`ingest-semantic`). 18 new tests (`harness/tests/`, stdlib `unittest`, no live `claude`
  call — subprocess is mocked): schema validation/extraction, prompt/command construction,
  and wrapper-parsing for all four outcomes. Dry-run verified end to end against a real
  Starlette Code Graph export (prompt + full command printed correctly).

  **First live attempt (2026-09-04) failed before calling the model**: `claude`'s own
  `--json-schema` validator doesn't have the 2020-12 meta-schema registered offline and
  rejected our `$schema` dialect URI outright (`not a valid JSON Schema: no schema with key or
  ref ...draft/2020-12/schema`, exit 1, no cost incurred). Fixed by `cli_json_schema()` in
  `schema.py` — the exact same schema minus the `$schema` key (every keyword actually used is
  unchanged across drafts, so nothing about what's accepted changed); `investigate.py` now
  passes that to `--json-schema` while `validate_semantic()` still uses the full
  `SEMANTIC_SCHEMA` with `Draft202012Validator` for our own Python-side check. 2 new tests
  cover it.

  **Second live attempt (user-run, 2026-09-04) succeeded**: 24 turns, $1.38, ~315s, 100%
  schema-valid on the first try. 10 components (Application Assembly, Routing & URL
  Convertors, HTTP & WebSocket Connections, Responses & Background Tasks, Middleware Stack,
  Error & Exception Handling, Data Structures & Form Parsing, Endpoints/Static
  Files/Templating, Async Concurrency & Internal Utilities, Optional Services), 17
  `component_relationships` (all `depends_on`), 10 evidenced claims (8 `INTERPRETATION` / 2
  `INFERENCE`, 8 high / 2 medium confidence) + 7 `uncertainties`, 189 member anchors with zero
  overlap between components. A genuinely coherent, plausible architectural read of Starlette
  — first real evidence for H2. Inspecting the raw wrapper also found `structured_output`
  (already the parsed `--json-schema`-conformant object) alongside `result` (the same content
  as a JSON string) and no top-level `model` field (only a per-model `modelUsage` cost
  breakdown, since a `claude-haiku-4-5` sub-call happened alongside the main
  `claude-sonnet-5` investigation). `investigate.py` was updated accordingly: prefer
  `structured_output` over re-parsing `result` text (falling back to the tolerant extractor
  only if it's absent — `validate_semantic` still runs unconditionally either way), and derive
  `model_used` from `modelUsage`'s highest-cost entry rather than a nonexistent field. `cli.py
  investigate` now also writes `investigation_meta.json` — a small, Swift-owned sidecar
  (model/session/turns/cost/duration/tools) — next to the candidate, decoupling Swift from
  the CLI's own internal wrapper shape. 4 new tests (23 total in `harness/tests/`).
- **M2 — Full Swift ingestion pipeline. [done]** `Sources/OrionCodeIntel/Semantic/SemanticImporter.swift`
  steps 3-4 (export, step 5, is M3):
  - **Step 3 (consistency check)**: de-duplicates component names (first occurrence wins,
    later ones dropped + `duplicateComponent` diagnostic — the DB's `UNIQUE(run_id, name)` is
    defense-in-depth, not the primary mechanism); drops self-referential or
    already-invalidated `component_relationships`; **confirms every component relationship
    and every multi-evidence claim structurally** against the real Phase 1 relationship graph
    (`Store.relationshipExists`/`relationshipExistsAmongAnyPair`, both new) rather than
    trusting Claude's assertion — a relationship/claim with no connecting Phase 1 edge is
    **kept, not dropped** (Docs/04: uncertainty stays visible), but a component relationship
    lands at `.unresolved` confidence and a claim is reclassified `CONTRADICTED`.
  - **Confidence/schema gap found against real output, resolved here**: `SEMANTIC_SCHEMA`
    (M1) gives components and `component_relationships` no confidence field at all — Claude
    was never asked to self-report one. Resolved by *deriving* it from our own verification
    signal instead of inventing a default: a component's tier is `high` iff zero of its cited
    members were unresolvable, else `medium`; a component relationship's tier is `high` iff
    the connectivity check confirms it, else `unresolved`. `claims.subject_ref` was `NOT NULL`
    in the M0 migration but Claude's claims are statement+evidence, not a subject/predicate/
    object triple — relaxed to nullable (still pre-release, safe to amend directly rather than
    add a `v3` migration) and set to the claim's first evidence anchor, or left null for an
    `uncertainties`-derived claim.
  - **Step 4 (persistence)**: an `investigations` row is written *first* and unconditionally
    (even a JSON-decode failure or `schema_version` mismatch still gets one, `outcome =
    "rejected"` — Docs/07: an attempt is itself useful); on success, `components` /
    `component_members` / `component_relationships` / `claims` / `evidence` are inserted,
    `symbols.component_id` is backfilled to each symbol's *highest-confidence* membership
    (a symbol can belong to more than one component), and one `model_revisions` row logs the
    update. `investigations.outcome` is Swift's own verdict (`verified` / `partially_verified`
    / `unverified` / `rejected`) computed from what actually survived steps 2-3 — never a
    copy of Python's own (unverified) guess.
  - `InvestigationMeta` (Decodable, `Semantic/SemanticFindings.swift`) decodes the M1 sidecar;
    `ingest-semantic` gained `--meta <path>`.
  - 18 new Swift tests (150 total): duplicate-name handling, confirmed/unconfirmed component
    relationships against a real `imports` edge, contradicted/confirmed multi-evidence claims,
    decode-failure and schema-mismatch both still persisting an investigation row, a full
    clean round-trip (DB row counts + `investigations`/`model_revisions` asserted directly),
    and the `component_id` backfill picking the higher-confidence of two memberships.

  **Real-data validation caught a real bug.** Re-running `ingest-semantic` against the actual
  Starlette candidate from M1 initially came back `outcome = "partially_verified"`: 1 of 17
  component relationships `unresolved`, 3 of 10 evidenced claims reclassified `CONTRADICTED`.
  Inspecting them (e.g. the "Mount and Host subclass BaseRoute" claim, evidenced by
  `Mount.matches`/`Mount.handle`/`Host.matches`/`BaseRoute`) showed the underlying edge
  genuinely exists (`Mount --extends--> BaseRoute`, confirmed by direct query) — Claude just
  cited *method*-level anchors while Phase 1 records `extends` *class*-to-class, so the
  pairwise check among only the cited symbol ids missed it. Fixed by having
  `relationshipExists`/`relationshipExistsAmongAnyPair` check each cited symbol's **parent**
  too (`ResolvedMember`/`ResolvedEvidence` now carry `parentSymbolId`), not just the symbol
  itself. Re-ingesting the same real candidate after the fix: `0 unconfirmed, 0 contradicted,
  outcome = "verified"`. The synthetic no-connection fixtures (`testComponentRelationship
  UnconfirmedWhenNoRealEdgeExists`, `testMultiEvidenceClaimReclassifiedContradicted...`) still
  pass, so the check still catches genuinely unrelated pairs — it just no longer false-positives
  on evidence cited one level below where Phase 1 recorded the edge. This is exactly the kind
  of gap M1's "check the real output before designing M2 further" was meant to surface (see
  Risks below for the check's remaining known limitation).
- **M3 — Export. [done]** `Sources/OrionCodeIntel/Semantic/SemanticModel.swift` (DTOs, mirrors
  `CodeGraphModel`'s pattern) + `SemanticExporter.swift` (the writer, mirrors
  `CodeGraphExporter`'s snake_case/sorted-keys `JSONEncoder` conventions exactly, same
  `write`/`writeJSONL` helpers). Scopes to the run's **latest** investigation for
  `components`/`claims`/`evidence`/`semantic_model.json` (M6 will re-ingest the same run under
  new investigations; "the" current semantic model is the newest one), but
  `investigations.jsonl` exports the *full* history for the run, like Phase 1's
  `diagnostics.jsonl` does — every attempt stays auditable, not just the latest.
  `semantic_model.json`'s `component_relationships[]` reference components **by name**, not id
  (readable, matches `code_graph.json`'s own anchor-not-id convention).
  Two new `Store` read-method groups (investigations/components/component_members/
  component_relationships/claims/evidence, all scoped by `run_id`/`investigation_id`/
  `component_id` set). Wired into **both** surfaces: `ingest-semantic` gained `--export/
  --no-export` (default on, matches `analyze`'s convention) and exports even a rejected
  attempt's `investigations.jsonl` entry; the existing `orion-index export` command now also
  calls `SemanticExporter` after `CodeGraphExporter`, no-op (returns `nil`, Phase 1's files
  untouched) when the run has no investigation yet. 4 new tests
  (`SemanticExportTests`): all 5 files present with the right shape (`member_anchors`,
  `evidence_ids`, `range{start_line,end_line}`, relationships by name not id,
  `uncertainty_count`/`contradiction_count` correct); re-exporting without re-ingesting is
  byte-identical; the no-investigation-yet case returns `nil`, not an error; the combined
  `export`-command call path writes both layers into the same `export/` directory. 155 tests
  total. Manually confirmed against the real, already-ingested Starlette DB: `orion-index
  export --out /tmp/orion-starlette` wrote all 5 semantic files alongside Phase 1's, and
  `semantic_model.json`'s 17 `component_relationships` all show `confidence_tier: "high"` —
  consistent with M2's fully-`verified` real result.
  `EXPORT.md` gained a "Semantic export" section (additive, not a separate document — decided
  once the shape turned out to be five files in the same table, not enough to warrant its own
  doc). *Not done: a golden snapshot test.* The shape is covered by `SemanticExportTests`'
  assertions instead — worth a real snapshot once the shape has had at least one more real
  investigation's output to snapshot against (M4/M6), per the original plan's own reasoning for
  deferring it past a single sample.
- **M4 — Starlette end-to-end run. [done]** The full manual pipeline (analyze → investigate →
  ingest-semantic → export) already ran for real as validation work during M1-M3 — M4 is
  substantively that same run, formally recorded here with numbers pulled directly from the
  live DB/export rather than from memory:

  | | |
  |---|---|
  | model / turns / cost / duration | `claude-sonnet-5`, 24 turns, **$1.38**, ~315s |
  | Phase 1 baseline (context) | 135 files, 3225 symbols, 9362 relationships, 65 ext. deps |
  | components | **10 persisted, 0 dropped, 0 duplicate** |
  | component members | 189 anchors (5.9% of all 3225 symbols — components cover the
    notable architectural surface, not every constant/parameter/import_alias) |
  | component_relationships | **17 persisted, 0 dropped, 0 unconfirmed** (all `confidence_tier
    = high` — every one structurally confirmed against a real Phase 1 edge) |
  | claims | **17 persisted** (10 evidenced: 8 `INTERPRETATION` / 2 `INFERENCE`, backed by 41
    evidence rows across them; + 7 `uncertainties` as `UNKNOWN`), **0 dropped, 0 `CONTRADICTED`** |
  | `semantic_ingest` diagnostics | **0** |
  | investigation outcome | **`verified`** |

  Every number here is post-fix (the parent-symbol connectivity correction from M2) — the
  *first* attempt at this same run scored 1 unconfirmed relationship + 3 contradicted claims,
  which is exactly the real bug M2's entry documents, not a second independent run.

  **What this is real evidence for, and what it isn't yet.** This is a genuine, first data
  point for **H2** (structured semantic knowledge *can* be reconstructed from the Code Graph —
  a coherent 10-component decomposition, evidence-backed, zero fabricated anchors across 230
  total citations) and **H6** (the findings were ingested and verified by code that is not
  Claude itself, without making Claude the permanent orchestrator — every one of the 17
  relationships and 10 evidenced claims was independently confirmed against Phase 1's
  deterministic graph, not taken on Claude's word). It is **one run** — H5 (can the *routing*
  decision to escalate be made reliably) isn't tested at all yet (no MLX Agent exists to make
  that call, Phase 3), and a single clean run says nothing about consistency across repeated
  investigations, which is specifically M6's job, not this one's. Read this as "the pipeline
  works end-to-end on real output," not "Claude reliably does this."
- **M5 — Gold set + scorer. [done]** `starlette_components.gold.json` authored and validated
  (11 components, 150 anchors, zero typos/duplicates); `semantic/score.py` (anchor
  normalization + Jaccard alignment + evidence accuracy, no judge axis — see "Gold evaluation
  set + scorer" above for the full breakdown); `cli.py score-semantic`; 37 Python tests total.
  `PHASE2_EVAL.md` written with the real result from M4's run: **10/11 matched, 0 spurious,
  macro F1 = 0.926, evidence accuracy 1.000** — both the one miss and the weakest match
  checked by hand, not just read off the number.
- **M6 — Repeatability. [done]** Re-ran the investigation 3 more times (`run3`/`run4`/`run5`;
  2 earlier attempts, `run1`/`run2`, hit a transient Anthropic `529 Overloaded` before
  producing output) against the same commit — 4 independent investigations total including
  the original from M4. This is the actual answer to "can structured semantic knowledge be
  *reliably* reconstructed," not just "was it reconstructed once" (M4), and it's a more mixed
  answer than M4 alone suggested. Full numbers and reading: `PHASE2_EVAL.md` §6.

  **Deliberately one investigation per command invocation, never a loop over N** — the same
  sandbox constraint from M1 (this session can't invoke `claude` recursively) means a human
  has to run each investigation anyway, so the tooling is built around that instead of working
  around it:
  - `investigate --repeatability --out <dir>` runs **exactly one** investigation and writes it
    to an auto-numbered `<out>/repeatability/runN/` (`N` picked from what's already on disk,
    not an in-memory counter — safe to invoke from a fresh process each time). Everything else
    about the command is unchanged; `--write`/`--raw-write`/`--meta-write` are rejected
    alongside `--repeatability` since it picks its own filenames.
  - Run it as many separate times as wanted (by hand, one at a time — the whole point). Each
    call is independent; nothing here batches or schedules multiple investigations.
  - `repeatability-report --out <dir> [--threshold] [--write <report.json>]` reads back
    whatever `runN/` directories exist (2 is enough for one comparison; the command doesn't
    care whether that's 2, 3, or more) and reports, per pair of runs: component-alignment
    macro F1 (via the *same* `score_components`/`normalize_anchor` machinery M5 built, reused
    here as a symmetric "compare two decompositions to each other" rather than
    "compare gold to predicted" — no ground truth needed, just internal agreement) — plus
    cost/duration/turn min/max/mean across all runs found. Runs no investigation itself; safe
    to call after 1 run (prints per-run stats only) or partway through collecting N.
  - `harness/orion_eval/semantic/repeatability.py`: `discover_runs`, `discover_failed_runs`
    (surfaces a failed attempt — like `run1`/`run2`'s API overload — with its reason instead
    of silently excluding it), `summarize_run`, `pairwise_stability`, `build_report`. 16 new
    tests (`test_semantic_repeatability.py`, 53 total in `harness/tests/`) against synthetic
    multi-run fixtures, including one built directly from `run1`'s real failure shape.

  **Real result** (4 investigations: the original from M4 + `run3`/`run4`/`run5`, all
  ingested into the same Swift DB as separate `investigations` rows against the same Phase 1
  run): **2/4 came back fully `verified`, 2/4 `partially_verified`** (one unconfirmed
  component relationship; 3 contradicted claims) — real instability, not just in component
  *count* (9/10/10/14) but in whether independent structural verification comes back clean.
  Pairwise component-set stability across `run3`/`run4`/`run5`: **mean macro F1 = 0.723**
  (range 0.650-0.779) — notably lower than the 0.926 each individual run scored against the
  fixed gold set in M5, which makes sense: three independent decompositions naturally agree
  with each other less than any one of them agrees with a stable external reference. Turns
  ranged 24-67, cost $1.32-$1.77. Full breakdown, per-run table, and reading:
  `PHASE2_EVAL.md` §6.

  **A second real schema bug, found the same way as M2's**: `components` was
  `UNIQUE(run_id, name)` — scoped to the Phase 1 analysis run, not the investigation. Ingesting
  `run3` and `run4` both failed on a raw SQLite constraint violation because both
  independently produced a component literally named "Middleware Stack" against the same
  run — exactly the scenario M6 exists to exercise, broken by a schema constraint that was
  scoped one level too broad. Fixed to `UNIQUE(investigation_id, name)`: within-one-
  investigation duplicates are still caught (that was the constraint's actual intent), the
  same name across independent investigations of the same run is now allowed. 2 new Swift
  tests (`SemanticSchemaTests`, one per direction), 156 Swift tests total. Same lesson as
  M2's parent-symbol fix: fixtures alone wouldn't have found this — it took real, independent
  repeated output to hit it.

  Reproduce:
  ```
  cd "Agent Feasibility Study/harness"
  python -m orion_eval.cli investigate --out /tmp/orion-starlette --repeatability   # one at a time,
  # ... run again whenever ready, as many times as wanted ...                       # by hand

  python -m orion_eval.cli repeatability-report --out /tmp/orion-starlette \
    --write /tmp/orion-starlette/repeatability_report.json
  ```

---

## Risks / open questions

1. **Cost and turn budget.** An agentic multi-turn session over a ~70-file repo could run long
   or expensive if not bounded. Mitigation: `--max-budget-usd` (a real cost ceiling `claude`
   itself enforces) + a Python-side wall-clock `subprocess` timeout from M1 — this CLI version
   has no turn-cap flag, so there's no independent turn ceiling beyond those two; `outcome =
   "incomplete"` is a legitimate, expected result of the timeout firing, not a bug to work
   around. The real Starlette run used 24 turns / $1.38 / ~315s — comfortably under both.
2. **Non-determinism makes "correctness" fuzzier than Phase 1.** A single bad run must not be
   read as "the hypothesis failed" — M6 exists specifically so the plan doesn't over-index on
   one sample. *Open: minimum N for a credible stability claim — 3 is a starting budget-driven
   guess, revisit once M4's per-run cost is known.*
3. **Anchor discipline.** Nothing stops Claude from citing a plausible-looking but wrong anchor
   (e.g. right file, wrong dotted path) despite being told to use `symbols.jsonl` verbatim.
   Evidence validation (pipeline step 2) is the only backstop — track the
   resolved/unresolved rate from M4 onward the way Phase 1 tracked call-resolution-rate, and
   treat a low rate as a prompt-design problem to fix, not something to relax the validator for.
4. **Component-granularity ambiguity.** "Routing" vs. "Routing + Applications" as one component
   is a legitimate judgment call with no single right answer. The Jaccard-overlap alignment in
   `score.py` (M5) is deliberately threshold-based and forgiving of boundary disagreement while
   still penalizing genuinely missed or spurious groupings. **Observed for real in M5**: gold's
   `Form & Multipart Parsing` had no match because the real prediction folded it into
   `Data Structures & Form Parsing` instead, and gold's `Middleware Stack` only got R=0.64
   because the prediction filed `ServerErrorMiddleware`/`ExceptionMiddleware` under its own
   `Error & Exception Handling` component — both checked by hand against `components.jsonl`
   and confirmed as boundary calls, not missing/fabricated content (`PHASE2_EVAL.md` §4). The
   0.3 threshold held up fine on this one comparison; still worth re-checking once a second
   real gold-vs-predicted comparison exists (M6) rather than trusting one data point.
5. **`component_relationships` vs. reusing Phase 1's `relationships` table.** Decided above
   (separate table) to protect Phase 1's frozen schema/snapshot; revisit only if Phase 3/4
   turns out to need symbol-level and component-level edges queried through one unified path —
   a view can bridge the two later without a schema change.
6. **The claim-contradiction check is a structural proxy, not real contradiction detection —
   and even after M2's fix, only reaches one level up.** It asks "does any pair of this
   claim's evidence symbols (or their immediate enclosing symbol) have *any* Phase 1
   relationship at all" — not "is this specific statement true." First pass on real Starlette
   output false-positived on 3/10 claims because Phase 1 records `extends` class-to-class while
   the evidence cited methods; including each symbol's immediate parent in the check (not a
   full ancestor walk) fixed that specific case and re-validated clean, but a claim whose
   evidence sits two levels down (e.g. a nested function, or a relationship that only exists
   between *grandparent* symbols) would still false-positive the same way. Same caveat applies
   to `component_relationships`' confirmation check, though components' much larger member
   sets make it far less likely to matter there in practice. If M4/M6 keep seeing spurious
   `CONTRADICTED`/`unresolved` verdicts on real runs, extend `idsWithParents` to walk the full
   `parent_symbol_id` chain rather than one level, before concluding the underlying claims are
   actually wrong.
