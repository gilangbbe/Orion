# 16 — Phase 6: Continuous Model Updates (Development Plan)

> Status: **M0 done.** `v5_phase6_schema` migration (`model_revisions.revision_number`,
> `model_revision_entries`), typed `ModelRevisionEntryRecord` (+ `ModelRevisionRecord
> .revisionNumber`), `ModelRevisionEntityType`/`ModelRevisionChangeType` enums, bare `Store` CRUD
> (`modelRevisions`/`insertModelRevisionEntries`/`modelRevisionEntries`) — no behavior change yet,
> `RevisionDiffer` (§4) is M2's job. **One real, small correction against this doc's own draft
> schema, made during implementation, not silently done**: neither `model_revisions` nor
> `model_revision_entries` carries a `commit_hash` column, unlike §2's original sketch of
> `(repository_id, commit_hash)` scoping — `repositories` rows are already one-per-commit via
> their own `UNIQUE(local_path, commit_hash)` (Phase 1), so `repository_id` alone is enough and a
> redundant column was dropped before it was ever added. 8 new tests
> (`ModelRevisionSchemaTests`), full suite green (318 tests, 0 failures) under the exact CI
> invocation; `OrionApp.xcodeproj` still builds clean (no app-side reference to touch yet — Model
> Changes stays sample-backed until M5).
>
> **M1 done.** `AnchorAlignment` (`Sources/OrionCodeIntel/Semantic/AnchorAlignment.swift`) —
> `normalize`/`jaccard` ported verbatim from `score.py`, `align(lhs:rhs:threshold:)` ported from
> `score_components`'s own greedy-match algorithm. **One real, deliberate enrichment over this
> doc's own §3 sketch**: `align` returns a `Match<T>` (`jaccard`/`precision`/`recall`/`f1`/
> `intersection`/`lhsOnly`/`rhsOnly`) per pair, not a bare `[(T, T)]` of matched ids — the
> `lhsOnly`/`rhsOnly` anchor sets are exactly what `RevisionDiffer`'s deterministic reason
> templating (§4.2/§4.3, M2) needs to say *what* changed, not just *that* two things matched;
> computing them once here means M2 never has to re-derive them per caller. 12 new tests
> (`AnchorAlignmentTests`), every case ported directly from `test_semantic_score.py`'s own
> fixtures — this port is checked against Python's known-correct numbers (e.g. the 0.5/⅔/⅔
> partial-match case), not newly invented ones. Full suite green (330 tests, 0 failures) under the
> exact CI invocation.
>
> **M2 done.** `RevisionDiffer` (`Sources/OrionCodeIntel/Semantic/RevisionDiffer.swift`) —
> `diff(store:repositoryId:newInvestigationId:)`, `diffComponents`/`diffComponentRelationships`
> (§4.2, architecture investigations only), `diffClaims` (§4.3, any investigation kind, matched
> via `AnchorAlignment`). **Two real, deliberate refinements against this doc's own draft, both
> recorded rather than silently done**: (1) there is no separate `InvestigationKind` parameter —
> `diff` determines architecture-vs-question by reading the new investigation's own `question`
> column against `InvestigationRecord.architectureQuestionMarker` (a new shared constant,
> consolidating a string literal that was independently hardcoded three separate times across
> `SemanticImporter`/`OrionApp`'s `ArchitectureModelLoader`), the same marker-based check
> `ArchitectureModelLoader.latestArchitectureInvestigation` already uses — self-determined from
> what was actually persisted, not a caller-supplied flag that could disagree with it. (2) claim
> matching does **not** reuse `AnchorAlignment.align`'s bipartite greedy algorithm — that assigns
> each historical claim to at most one new claim, which is right for components (a stable
> decomposition) but wrong for claims accumulating across many investigations over time: each new
> claim is scored independently against the *entire* historical pool and takes its own best match
> (ties/multiple-above-threshold logged as `CLAIM_DIFF_AMBIGUOUS`, per §4.3 point 4), so two
> unrelated new claims can legitimately both match the same old one without either being blocked
> from it. Component-relationship reasons were also written to cite what a `component_relationships`
> row actually carries (confidence tier) rather than an evidence-anchor count that entity type
> doesn't have — a small, more honest adjustment against Decision #2's own illustrative example
> text, not a deviation from the deterministic-template decision itself. 12 new tests
> (`RevisionDifferTests`), including one that reproduces the exact Docs/05 Stage 6 worked example
> (`AuthService -> Persistence` removed, replaced by a 3-hop chain through `SessionManager`/
> `SessionStore`/`Keychain`) and a genuine Jaccard-tie ambiguous-match case verified to pick the
> earliest-created investigation's claim deterministically. Not yet wired into
> `SemanticImporter.ingest()`/`.ingestAnswer()` (M4) or given uncertainty tracking (M3). Full suite
> green (342 tests, 0 failures) under the exact CI invocation.
>
> **M3 done.** `RevisionDiffer.diffUncertainties` (§5) — token-Jaccard over lowercased,
> stopword-stripped word sets (reusing `AnchorAlignment.jaccard` directly, since it's a plain
> `Set<String>` overlap function with nothing anchor-specific about it), compared only against the
> immediately preceding investigation *of the same kind*; `.carriedOver` (`>= 0.6`), `.addressed`
> (`>= 0.4` against a newly `.added` claim from this same diff pass, hedged, never asserted as a
> confirmed resolution), `.noLongerRaised` (equally hedged), `.added` for a brand-new one. **One
> real, deliberate exception to §9 Risk #5's own claim, found while implementing this milestone
> and recorded there directly (see the amended Risk #5 below)**: a brand-new uncertainty becomes
> `.added` even on a repository's very first investigation ever — unlike components/relationships/
> claims, there is nothing to meaningfully compare a *newly raised* open question against in the
> first place, so "nothing to diff against" correctly yields nothing for those three, but not for
> an uncertainty's own first appearance. **A second, real bug found and fixed while reasoning
> through this milestone, not caught by any M2 fixture**: `diffClaims` had an early `return`
> whenever the historical-claims pool ended up empty, which silently skipped `.added` entries for a
> *second* investigation's genuinely new claims whenever the *first* investigation happened to have
> none of its own (a real gap in M2, not something M3 introduced) — removed; the main per-claim
> loop already handles an empty historical pool correctly on its own (every candidate list is
> trivially empty, so every claim becomes `.added`), so no replacement logic was needed, only the
> premature guard's removal. 7 new tests plus one existing M2 test updated to reflect the
> now-complete behavior (an `UNKNOWN` claim was previously asserted to produce *no* entries at all;
> it now correctly produces one `.added` uncertainty entry, which is exactly §5's own job — the
> original test's own comment had already said as much). Full suite green (349 tests, 0 failures)
> under the exact CI invocation.
>
> **M4 done.** `SemanticImporter.ingest()`/`.ingestAnswer()` both now call a new shared
> `writeModelRevision(run:investigation:now:)` helper (the same "extend the shared pipeline"
> precedent `resolveClaimEvidence`/`checkClaimConsistency`/`buildClaimRecords` already set,
> Docs/12 M3) — §4.1's write-cardinality change lands for real here. `RevisionDiffer.Diagnostic`s
> persist as real `diagnostics` rows, `stage = "model_revision"`, regardless of whether
> `diff.entries` itself ended up empty (an ambiguous match can occur on a claim that turned out
> unchanged). Export: `model_revisions.jsonl`/`model_revision_entries.jsonl`, additive to
> `EXPORT.md` exactly as Phase 2 M3 did for its own five files — `previous_state`/`new_state`
> carry the underlying JSON columns verbatim, not further decoded (documented explicitly, not
> silently under-specified). CLI: `orion-index revisions [--db|--out] [--commit] [--since] [--json]`.
> **One real, deliberate correction against this doc's own §7 sketch, found by checking the actual
> codebase rather than guessing**: no positional `<path>` — `revisions` is a pure `Store` read
> exactly like `stats`/`query`/`export`, all three of which use `--db`/`--out`; only `analyze`
> takes a repo checkout path, since it's the one command that actually needs one. **A second real,
> deliberate simplification**: both callers' old "did this ingestion actually insert anything"
> guard before ever touching `model_revisions` is gone — `RevisionDiffer` decides
> revision-worthiness for real now, and that guard would have silently hidden a real case (a new
> architecture investigation that dropped every previous component is a meaningful "all removed"
> revision, not nothing). 5 new `RevisionDifferWiringTests` (real `ingest()`/`ingestAnswer()` calls
> through a real analyzed fixture repo, not hand-built `Store` rows — confirming the revision chain
> (`revision_number`/`previous_revision`), a real ambiguous-match diagnostic landing with
> `stage = "model_revision"`, and the true "nothing to diff against" case now that the manual guard
> is gone) + 1 new `SemanticExportTests` case. **Manually verified end to end against a real tiny
> repo, not just the test suite**: `orion-index analyze` → two `ingest-semantic` calls → `orion-index
> revisions` (both text and `--json`) produced exactly the expected single revision with a
> `component`/`added` and a `component_relationship`/`added` entry, readable reason text, and
> correctly-embedded JSON snapshots. Full suite green (355 tests, 0 failures) under the exact CI
> invocation; `OrionApp.xcodeproj` still builds clean (no app-side code touches the new tables yet
> — that's M5).

>
> **M5 done.** `ModelChangeLoader` (real `model_revisions`/`model_revision_entries` reads,
> grouped by shared "source" component per §8's own instruction) replaces `ModelChangeSample`
> (deleted) in `ModelChangesView`, which now self-loads via `outputDirectory` the same
> `@State`+`.task` way `ArchitectureOverviewView`/`ComponentDetailView` already do. A real sidebar
> unread-badge count and the `CONTRADICTED`-claim -> Model Changes cross-reference (Docs/14 §2,
> previously unbuilt) both now work, in both `ComponentDetailView` and `AskEntryView`.
>
> **Four real findings, all recorded rather than silently absorbed:**
> 1. **A retroactive correction to M2's own `relatedClaimId` semantics.** Building the
>    cross-reference surfaced that a `.reversed`/`.modified` entry's `relatedClaimId` pointed at
>    `previous.id` (the *superseded* claim) — useless for "which entry explains *this*
>    currently-displayed claim." Changed to `new.id` (the current, still-persisted claim) on both
>    branches, matching `.addressed`'s own existing convention; `previous`'s statement/type/anchors
>    stay fully preserved in `previousStateJson`. Three M2 test assertions updated accordingly.
> 2. **A real, pre-existing timing bug in `ArchitectureModelLoader.latestArchitectureInvestigation`
>    (Docs/13/14, not this phase's own code), found live while writing this milestone's own
>    fixture tests, not hypothesized.** Its `.max { $0.createdAt < $1.createdAt }` tie-break isn't
>    guaranteed to pick the second of two investigations ingested within the same
>    second-resolution `Timestamp.now()` tick — a real test (two rapid `ingest()` calls) reproduced
>    exactly that, silently reading back the *first* investigation's stale claim instead of the
>    second's real `CONTRADICTED` one. Not fixed at the source this milestone (out of scope — a
>    pre-existing app-layer helper, not part of Docs/16's own surface) but worked around in every
>    affected test by passing explicit, strictly-increasing `now` values, and called out here so
>    it isn't lost: worth a real fix (e.g. an explicit ordinal/sequence column, or just running
>    `ArchitectureModelLoader`'s tie-break through `RevisionDiffer`'s own array-order convention
>    instead of a second `.max(by:)`) whenever `ArchitectureModelLoader` is next touched.
> 3. **Component-relationship grouping is by *source* component only, not full transitive-chain
>    grouping.** A genuine multi-hop replacement (Docs/05 Stage 6's own 3-hop example) still
>    produces one card per distinct source node, not one unified "this whole path changed" card —
>    a real, documented scope limit (full chain-tracing would need a small union-find over the
>    revision's edges), not silently claimed as more than it is. Confirmed directly by a test
>    asserting 3 cards, not 1, for that exact shape.
> 4. **The sidebar badge count is session-local, not persisted across relaunches.** A deliberate,
>    honestly-scoped v1 — a new per-repo local-JSON file just for one integer (mirroring
>    `RecentRepositories`'s own pattern) was judged not worth it yet; revisit if that gap proves to
>    matter in real use.
>
> A supporting `Store.modelRevisionEntries(relatedClaimId:)` reverse lookup (+
> `idx_model_revision_entries_related_claim`, added directly to the still-unreleased `v5`
> migration rather than a new `v6`) was needed and added along the way.
> `ComponentDetailQuery.Claim`/`ComponentClaimDetail`/`AskClaimSummary` all gained a
> `reversedByRevisionId: String?` field to carry it through to the UI. 8 new tests (3
> `ModelChangeLoaderTests`, 1 `ComponentDetailLoaderTests` — all in `OrionApp`, real
> `ingest()`-through-`ArchitectureModelLoader` fixtures, not hand-built rows) — `OrionApp` suite
> now 136 tests, 0 failures; `OrionCodeIntel` suite unchanged at 355 (a relocation/plumbing
> milestone at that layer, no new library-level logic beyond the one reverse-lookup method). Both
> `xcodebuild build` and `xcodebuild test` succeed with zero Orion-authored warnings.
>
> **M6 done — this closes Phase 6's full implementation order.** Real end-to-end verification
> against the actual vendored-Starlette research database from Phase 2 M6's repeatability runs
> (`/tmp/orion-starlette`, 4 real independent investigations, real API cost already spent —
> worked on an isolated copy throughout, original confirmed byte-identical afterward). A new
> capability was needed and built first: **`orion-index revisions --backfill`**
> (`SemanticImporter.backfillModelRevisions(investigations:run:)`, §7) — real Phase 2/3
> investigation history predates `RevisionDiffer` ever being wired into `ingest()`/`ingestAnswer()`
> (M4), so a repository investigated before Phase 6 shipped has real investigations with no
> revision at all; `--backfill` computes and persists them retroactively, dated to each
> investigation's own `createdAt` rather than "now."
>
> **Backfilling the real database found three real, load-bearing bugs — exactly what this
> milestone exists for — none of them visible in ~360 tests built against live, in-order
> ingestion alone, because every one of them is specifically about processing investigations
> *out of* live-insertion order, which only a backfill over real history ever does:**
>
> 1. **The backfill's own "already covered" check couldn't tell a real structured revision from
>    Phase 2/3's old coarse one.** The real database already had one entry-less legacy
>    `model_revisions` row per investigation (Phase 2/3's own unconditional-write behavior,
>    predating M4's change); a naive `Set(modelRevisions.compactMap(\.triggeringInvestigationId))`
>    coverage check read every one of those as "already backfilled" and silently no-op'd on the
>    exact database `--backfill` exists to help. Fixed to require at least one real
>    `model_revision_entries` row, not just any `model_revisions` row.
> 2. **`writeModelRevision`'s revision-chaining broke under out-of-order writes.** It asked "what's
>    the single most-recently-*created*-by-timestamp row in `model_revisions`" to find the
>    predecessor to chain onto — correct only when rows are written in true chronological order
>    (always true for live ingestion), wrong the moment a backfill inserts a revision dated
>    *earlier* than rows already sitting in the table. Live symptom: backfilling all 4 real
>    investigations produced four sibling revisions that all chained onto the same (wrong,
>    chronologically-*later*) predecessor and all landed on the identical `revision_number`.
>    Fixed with a new `previousRevision(before:repositoryId:)` that walks the repository's real
>    investigation history instead of the revisions table's own insertion order — a pure
>    generalization for the live path (there, the two happen to always agree). The exact same
>    timestamp-based "latest" assumption also broke `backfillModelRevisions`'s own "did this
>    actually create something" detection (`store.latestModelRevision` unchanged ≠ "nothing was
>    inserted," once more for the same out-of-order reason) — fixed by comparing row counts instead.
> 3. **The most significant of the three: `RevisionDiffer.diffClaims` could diff a claim against
>    claims from investigations that happened *after* it.** `priorInvestigationIds` was computed
>    as "every *other* investigation" (`!= newInvestigationId`), not "every investigation *earlier*
>    than this one" — every prior test (M2-M5) always diffed the most-recently-created
>    investigation, where those two sets are identical by construction, so this was never once
>    exercised differently until a real backfill processed the repository's genuine first
>    investigation while three *later* ones already existed in the table. Live symptom: that first
>    investigation's own claims came back reported as `.modified` against claims from
>    investigations that hadn't happened yet at the time. Fixed to match `diffComponents`/
>    `diffUncertainties`'s own existing index-based "strictly earlier in the ordered investigation
>    list" pattern, which they'd had correctly all along — this was the one place claim-diffing had
>    quietly invented a second, wrong convention.
>
> All three fixed, each with its own regression test built directly from the real failure shape
> (`testLegacyEntrylessRevisionIsNotTreatedAsCoverage`,
> `testBackfillProducesAProperlyChainedSequenceEvenWithOutOfOrderLegacyRevisions`,
> `testClaimDiffingNeverMatchesAgainstALaterInvestigation`).
>
> **After the fixes, the real backfill produced a clean, correctly-chained sequence** (revision
> numbers 1→2→3→4, each pointing at its true predecessor) with substantial, genuinely interesting
> real content: 218 total structured entries across the 4 new revisions, 12 real
> `CLAIM_DIFF_AMBIGUOUS` diagnostics (expected and correct — independent investigations describing
> overlapping evidence in different words, exactly Docs/11 M6's own "independently-plausible
> decompositions" finding), and one real `claim/reversed` entry. **That reversed claim was hand-
> checked against the actual Starlette source (§9's own standing discipline) and traced to a
> concrete, first-ever empirical confirmation of Docs/11 Risk #6's already-documented limitation**:
> the earlier investigation cited `_CachedRequest`'s constructing *method*
> (`BaseHTTPMiddleware.__call__`) as evidence, the later one cited only the *class*
> (`BaseHTTPMiddleware`) — since the real Phase 1 relationship connects the method to
> `_CachedRequest`, not the bare class, and the structural check only walks one level of
> `parent_symbol_id`, the later investigation's shallower citation structurally fails a check the
> earlier one passed, producing a `reversed` verdict despite the underlying claim being
> substantively the same. Recorded in §9's own risk list below as real, not hypothetical.
> Idempotency and export both confirmed against the real backfilled data too: a second
> `--backfill` run correctly finds nothing left to do, and `orion-index export` writes all 218
> entries cleanly alongside the pre-existing 8 `model_revisions` rows (4 legacy + 4 new).
>
> 5 new tests (4 `RevisionDifferWiringTests`, 1 `RevisionDifferTests`) — `OrionCodeIntel` suite now
> 360 tests, 0 failures; `OrionApp` suite reconfirmed unchanged at 136, 0 failures (M6 touched only
> `OrionCodeIntel`). Both `xcodebuild build` and `xcodebuild test` still succeed. This closes
> Phase 6's full implementation order (M0-M6). Depends on Phase 1
> ([10_phase1_deterministic_code_intelligence.md](10_phase1_deterministic_code_intelligence.md)),
> Phase 2 ([11_phase2_semantic_analysis.md](11_phase2_semantic_analysis.md)), Phase 3
> ([12_phase3_mlx_agent.md](12_phase3_mlx_agent.md)), Phase 4
> ([13_phase4_architecture_ui.md](13_phase4_architecture_ui.md)), Phase 4.5
> ([14_phase4_5_ui_ux_redesign.md](14_phase4_5_ui_ux_redesign.md)), and Phase 5
> ([15_phase5_adaptive_exploration.md](15_phase5_adaptive_exploration.md)) — all complete.

## 1. Context

Phases 1-5 built, in order: a deterministic Code Graph (Phase 1); semantic components/claims/
evidence reconstructed via a delegated Claude Code investigation and verified against that graph
(Phase 2); an MLX agent that routes an arbitrary question through local/tool-augmented/delegated
reasoning (Phase 3); an Architecture UI (Phase 4), redesigned for real navigation and epistemic
clarity (Phase 4.5); and guardrails, persisted conversational sessions, and a routing benchmark
(Phase 5). None of them close the loop [08_development_phases.md](08_development_phases.md)
assigns to Phase 6:

```
Implement:
- evidence-linked updates;
- model revisions;
- contradiction handling;
- uncertainty tracking.
```

or the UX [05_user_flow_and_ux.md](05_user_flow_and_ux.md) Stage 6 describes:

```
Understanding updated

Previously:
AuthService -> Persistence

Now:
AuthService -> SessionManager -> SessionStore -> Keychain

Reason:
New source evidence identified an intermediate session layer.
```

Phase 4.5 §4.7 already built this screen's real **shape** — `ModelChangesView`, a
`DisclosureGroup` per entry (title/time collapsed, Previously/Now/Reason expanded), a sidebar
unread-count badge — but explicitly left it **sample-backed**, naming the gap outright: "there is
currently no persisted record of model revisions to render here... this is new scope for
`OrionCodeIntel`/`CodebaseModelStore`... most likely a Phase 6." Phase 6 is that backend, wired
into the screen Phase 4.5 already drew.

This is also the first phase to seriously exercise **H2** (persistent model) as a genuinely
*evolving* artifact rather than a series of independent snapshots, and to give **H7** (epistemic
transparency) its Docs/04 §5 counterpart: "every meaningful update should retain: previous state;
new claim; evidence; source of update; confidence; timestamp/version" — a rule every prior phase
deferred, not one any of them violated.

### What already exists to build on

- **`model_revisions`** (Phase 2 M0): `id`, `repository_id`, `previous_revision`,
  `change_summary`, `triggering_investigation_id`, `created_at`. Written exactly once per
  successful ingestion by both `SemanticImporter.ingest()` and `.ingestAnswer()` — but as one
  coarse, unstructured log line (Phase 2's own example: "semantic layer v0 -> v1"), never a real
  diff. Nothing in the shipped app reads this table today (Phase 4.5's `ModelChangesView` renders
  fixed sample data instead) — safe to change its write behavior with no live consumer to break.
- **`claims.claim_type == CONTRADICTED`**: already a real, Swift-assigned verdict — but it is a
  purely *within-investigation* structural check (Docs/11 M2: does any pair of a claim's evidence
  symbols, or their parents, have a real Phase 1 relationship at all). It has never been compared
  against what an *earlier* investigation claimed about the same evidence. Docs/11 Risk #6 already
  flags this check's shallowness; this phase adds a second, genuinely new axis (cross-investigation
  reversal) rather than deepening that one.
- **`investigations`**: real free-form `question` since Phase 3, `answer_text` since Phase 5 M3,
  `outcome`, `session_id` (Claude's own). Every depth (1/2/3) and every entry point (`orion-index
  ingest-semantic`, `orion-agent ask`, the app's `SemanticInvestigationRunner`/`AskRunner`) already
  funnels through `SemanticImporter`'s validation pipeline before anything is persisted.
- **`ArchitectureModelLoader.latestArchitectureInvestigation`** (Phase 4.5 M5): filters
  `investigations` to the literal `question == "phase2_semantic_grouping"` marker to distinguish a
  whole-repo architecture investigation from a single-question Ask investigation sharing the same
  table — built to fix a real bug (the "latest investigation" silently becoming a zero-component Ask
  row). This phase reuses that exact filter rather than re-deriving it.
- **Phase 2 M5's `score.py`** (`Agent Feasibility Study/harness/orion_eval/semantic/score.py`):
  `normalize_anchor` (roll an anchor up to its top-level defining symbol) + greedy Jaccard-overlap
  alignment (`>= 0.3` to count as a match) — built to compare a *predicted* component decomposition
  against a *gold* one without exact-string identity. This phase needs the identical shape of
  comparison (two independently-produced sets, no stable cross-investigation id, "close enough"
  must count as a match) for components, relationships, and claims across investigations — a Swift
  port, not a re-derivation (§3).
- **`ModelChangesView`/`ModelChangeSummary`** (Phase 4.5 M6): already renders exactly the
  Previously/Now/Reason shape, sample-backed. Phase 6's UI work (§7) should need to change as
  little of this view as possible — swap its data source, not its shape.

### Decisions (made with the user)

1. **A model revision can be triggered by any successful investigation** — a whole-repo
   architecture run (`ingest()`) or a single-question Ask/delegated answer at any depth
   (`ingestAnswer()`) — not architecture runs only. This matches Docs/04 §5's own diagram literally
   ("User question -> Investigation -> New evidence -> Model revision"), not just the Docs/05 Stage
   6 worked example's architecture-flavored wording. In practice this costs little: most depth-1
   answers assert zero claims (Docs/12 M5's own finding) and so have nothing to diff; a revision
   only ever gets written when the differ (§4) actually finds a diff-worthy change (§4's
   `RevisionDiffer` returning `nil`/empty skips the write entirely — see the explicit behavior
   change called out in §4.1). A guardrail decline (Phase 5 §3.3) never reaches ingestion at all, so
   it never participates.
2. **The human-readable "Reason" sentence is generated by a deterministic template over the
   structured diff facts, not a model call.** E.g. *"New relationship `Router -> Middleware`
   confirmed via 3 evidence anchors"* / *"Claim about `SessionManager.save` superseded: new
   evidence adds an intermediate `SessionStore` hop."* Zero added latency or cost (no new prompt, no
   new model dependency, nothing to validate for schema conformance), fully unit-testable, and
   consistent with how confidence tiers are already *derived* rather than asked for (Docs/11 M2). A
   local-model paraphrase pass was considered and explicitly deferred — a real future enhancement if
   the templated sentences read too mechanically once there's real revision history to look at, not
   built now.
3. **Matching strategy across investigations** (components/claims/relationships have no stable
   cross-investigation identity — Docs/11's own design, each row is scoped to one
   `investigation_id`):
   - **Components**: exact case-insensitive name match, between the two most recent architecture
     investigations (via `latestArchitectureInvestigation`'s marker filter) — the same convention
     Docs/15 M5's `session create --component` already established for resolving a component by
     name.
   - **`component_relationships`**: match by `(source component name, target component name,
     relationship_type)` tuple, same two investigations.
   - **Claims**: match by normalized-evidence-anchor Jaccard overlap `>= 0.3` (§3) — scoped to
     **all** prior investigations for this `(repository_id, commit_hash)`, not just the immediately
     preceding one, since a depth-3 Ask claim about `Router.app` should diff against whatever any
     earlier investigation (architecture run or Ask) already said about that same evidence, not only
     the literal previous row in insertion order.
4. **A new shared `AnchorAlignment` utility** (`Sources/OrionCodeIntel/Semantic/AnchorAlignment.swift`)
   ports Phase 2 M5's normalization + Jaccard-alignment logic to Swift, rather than re-deriving it
   or duplicating it inline inside the new differ. `Agent Feasibility Study/harness/orion_eval/
   semantic/score.py` stays exactly as-is for Phase 2's own reproducibility — the same "port,
   don't extend the Python side further" precedent Phase 3 already set when it ported
   `investigate.py`'s CLI contract into Swift (Docs/12 Decision 3).
5. **Contradiction handling adds a new *revision-level* concept — "reversed" — rather than a sixth
   epistemic type.** [04_codebase_mental_model.md](04_codebase_mental_model.md) §3's vocabulary
   (`FACT|INTERPRETATION|INFERENCE|UNKNOWN|CONTRADICTED`) is closed; Phase 6 does not add to it.
   "Reversed" is a `model_revision_entries.change_type` value describing a *relationship between two
   claims across investigations* (their evidence overlaps, but their structural verdicts disagree),
   not a new label on a `claims` row itself.
6. **Uncertainty tracking is scoped honestly, not solved.** `uncertainties[]` claims have no evidence
   anchors (Docs/11's own design), so they cannot be matched the way components/relationships/claims
   are (§3). §5 below tracks whether the *same or near-duplicate wording* persists, disappears, or is
   plausibly addressed by a later evidenced claim — the last of these is always surfaced as a hedged
   candidate link, never asserted as a confirmed resolution. This is the most speculative mechanism
   in this phase and is flagged again in Risks (§9).

### What Phase 6 is not

- Not a change to `DepthModel`, `ActionLoop`, guardrails, or session continuity — Phase 5's routing
  and session mechanisms are untouched. Phase 6 adds a step *after* an investigation already
  succeeded, the same way Phase 3's claim persistence sits after routing, not inside it.
- Not a UI redesign. Phase 4.5 already designed and built `ModelChangesView`'s shape; Phase 6 wires
  real data into it and, where genuinely needed (§7), makes small, additive changes — it does not
  re-litigate navigation, layout, or the design system.
- Not Teaching Mode (Docs/05 Stage 7, Docs/14 §4.8) — still unscoped, still explicitly deferred past
  this phase too.
- Not a new epistemic vocabulary, and not a rewrite of the existing within-investigation
  `CONTRADICTED` check (Docs/11 M2's parent-symbol-aware structural check stays exactly as shipped).
- Not semantic/NLP contradiction detection ("does claim A's statement actually logically contradict
  claim B's statement"). Every comparison in this phase is structural (shared evidence anchors,
  matched names, matched relationship tuples) or, for uncertainties only, a hedged lexical-overlap
  heuristic (§5) — consistent with this project's standing discipline of deterministic-first,
  LLM-only-where-verified.
- Not a benchmark of revision quality — Phase 5 already built the routing/latency/cost benchmark
  machinery; if Phase 6's diff quality needs a systematic evaluation later, that is its own follow-up,
  not folded in here.

---

## 2. Schema (`v5_phase6_schema`, GRDB `DatabaseMigrator`)

Additive only — no Phase 1-5 table is altered except one new column on the existing
`model_revisions` table (a widening `ALTER TABLE ... ADD COLUMN`, the same kind of safe, in-place
amendment Docs/11 M2 already made to `claims.subject_ref` pre-release).

```sql
ALTER TABLE model_revisions ADD COLUMN revision_number INTEGER NOT NULL DEFAULT 1;
-- Monotonic per (repository_id, commit_hash) -- Docs/04 §5's "versioned knowledge state" gets a
-- literal, displayable version number ("Revision 12"), not just a linked list via
-- previous_revision. Backfilled to a per-repo running count at write time, not computed lazily.

CREATE TABLE model_revision_entries (
    id                  TEXT PRIMARY KEY,
    model_revision_id   TEXT NOT NULL REFERENCES model_revisions(id) ON DELETE CASCADE,
    entity_type         TEXT NOT NULL,   -- 'component' | 'component_relationship' | 'claim' | 'uncertainty'
    change_type         TEXT NOT NULL,   -- 'added' | 'removed' | 'modified' | 'reversed' |
                                          -- 'carried_over' | 'addressed' | 'no_longer_raised'
    subject_label       TEXT NOT NULL,   -- "Authentication", "AuthService -> SessionManager", or a
                                          -- claim/uncertainty statement excerpt (first ~120 chars)
    previous_state_json TEXT,            -- nullable JSON snapshot (null for 'added')
    new_state_json      TEXT,            -- nullable JSON snapshot (null for 'removed', 'no_longer_raised')
    reason              TEXT NOT NULL,   -- the deterministic templated sentence (Decision #2)
    confidence_tier     TEXT,            -- carried from the underlying claim/component/relationship
                                          -- where one exists; NULL for a bare uncertainty
    related_claim_id    TEXT REFERENCES claims(id) ON DELETE SET NULL,  -- the hedge link for
                                          -- 'addressed' (§5) -- nullable, never a certain assertion
    created_at          TEXT NOT NULL
);
CREATE INDEX idx_model_revision_entries_revision ON model_revision_entries(model_revision_id);
CREATE INDEX idx_model_revision_entries_type ON model_revision_entries(entity_type, change_type);
```

**No new snapshot table.** The diff is computed by re-querying the already-persisted rows of the
relevant prior investigation(s) at diff time — matching Docs/15 §4.1's own "a session is a thin,
ordered pointer... not a duplicate transcript store" discipline. `previous_state_json`/
`new_state_json` on each entry are small, denormalized snapshots (name/description/members for a
component; statement/confidence/evidence-anchor-list for a claim) captured *once*, at the moment
the entry is written, purely so the UI never has to re-join back through a possibly-deleted or
superseded investigation to render "Previously" — not a general-purpose history mechanism.

`Model/ModelRevisionRecords.swift` gains typed `ModelRevisionRecord` (existing table, `+
revisionNumber`) and `ModelRevisionEntryRecord`. `Store` gains `insertModelRevision`/
`insertModelRevisionEntries`/`modelRevisions(repositoryId:commitHash:)`/
`modelRevisionEntries(modelRevisionId:)`/`latestRevisionNumber(repositoryId:commitHash:)` — bare
CRUD, matching the precedent Docs/12 M1 set for `routing_decisions` and Docs/15 M0 set for
`ask_sessions`.

---

## 3. `AnchorAlignment` (ported comparison utility)

`Sources/OrionCodeIntel/Semantic/AnchorAlignment.swift` — a direct Swift port of Phase 2 M5's
`score.py`, kept deliberately small and general so `RevisionDiffer` (§4) is its only caller today
but nothing about it is differ-specific. **`[done]` — see §11 M1 for a real, deliberate enrichment
over this sketch's own `align` return shape** (a typed `Match<T>` carrying `precision`/`recall`/
`f1`/`lhsOnly`/`rhsOnly` per pair, not a bare `[(T, T)]`):

```swift
public enum AnchorAlignment {
    /// Rolls an anchor up to its top-level defining symbol: "path::Class.method" -> "path::Class".
    /// Ported verbatim from score.py's normalize_anchor -- needed because a later investigation
    /// routinely cites a more (or less) specific anchor than an earlier one for the same subject.
    public static func normalize(_ anchor: String) -> String

    /// Jaccard overlap of two normalized-anchor sets.
    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double

    public struct Match<T> {
        public let lhsId: T
        public let rhsId: T
        public let jaccard: Double
        public let precision: Double
        public let recall: Double
        public let f1: Double
        public let intersection: Set<String>
        public let lhsOnly: Set<String>   // normalized anchors lhs has that rhs doesn't
        public let rhsOnly: Set<String>   // normalized anchors rhs has that lhs doesn't
    }
    public struct AlignmentResult<T> {
        public let matches: [Match<T>]
        public let unmatchedLhs: [T]
        public let unmatchedRhs: [T]
    }

    /// Greedy best-match alignment between two labeled anchor-sets (a component's members, or a
    /// claim's evidence anchors), returning matched pairs at or above `threshold` plus each side's
    /// unmatched remainder -- the same shape score.py's own component-alignment step returns.
    public static func align<T: Hashable>(
        lhs: [(id: T, anchors: Set<String>)],
        rhs: [(id: T, anchors: Set<String>)],
        threshold: Double = defaultThreshold
    ) -> AlignmentResult<T>
}
```

**Testing**: `AnchorAlignmentTests` ports `score.py`'s own unit fixtures (`test_semantic_score.py`)
as Swift test cases — normalization edge cases (already-top-level anchor, deeply nested anchor,
malformed anchor with no `::`), a synthetic perfect/partial/spurious alignment with the exact
precomputed Jaccard values `test_semantic_score.py` already hand-checked, so this port is verified
against known-correct numbers rather than newly invented ones.

---

## 4. `RevisionDiffer`

`Sources/OrionCodeIntel/Semantic/RevisionDiffer.swift` — pure logic over `Store`, no model call, no
network. Invoked from **both** `SemanticImporter.ingest()` and `.ingestAnswer()`, appended as a new
step after their existing step 4 (Codebase Model update) and before step 5 (export) — so every
current call site (`orion-index ingest-semantic`, `orion-agent ask` at any depth,
`SemanticInvestigationRunner`, `AskRunner`) gets revision diffing for free with no change to its own
code, the same "extend the shared pipeline, don't touch its callers" shape Docs/12 M3 already used
when it added `ingestAnswer()` itself.

```
SemanticImporter.ingest() / .ingestAnswer()
  ... existing steps 1-4 (schema/evidence/consistency/persistence), unchanged ...
  v
4.5. RevisionDiffer.diff(store:, repositoryId:, newInvestigationId:)  -- [done], M2
       -- self-determines architecture-vs-question by reading the new investigation's own
       -- `question` column against InvestigationRecord.architectureQuestionMarker, rather than a
       -- caller-supplied kind flag that could disagree with what was actually persisted (a real
       -- refinement found during M2 -- see the status banner above)
       |
       +-- if this investigation's own question == architectureQuestionMarker:
       |     diffComponents(latest two architecture investigations)      -- §4.2
       |     diffComponentRelationships(same two investigations)          -- §4.2
       |
       +-- diffClaims(this investigation's claims vs. every prior investigation's claims,
       |               same repository_id)                    -- §4.3, [done] M2 (per-claim
       |               independent best-match scoring against the whole historical pool, not
       |               AnchorAlignment.align's bipartite matching -- see status banner)
       |
       +-- diffUncertainties(this investigation's UNKNOWN claims vs. the immediately preceding
       |                      investigation of the same kind)              -- §5, M3, not built yet
       v
     entries: [ModelRevisionEntryDraft]
       |
       +-- entries.isEmpty? -> write nothing, return nil (Decision #1's explicit behavior change --
       |                        see §4.1)
       +-- else -> one model_revisions row (revision_number = latestRevisionNumber + 1,
                    previous_revision = the prior row's id, change_summary = a short rollup like
                    "3 changes: 1 relationship added, 1 claim reversed, 1 uncertainty addressed"),
                    then insertModelRevisionEntries
```

### 4.1 Explicit behavior change to existing tables

Phase 2/3 wrote exactly one `model_revisions` row per successful ingestion, unconditionally
("`model_revisions` writes exactly one revision per successful ingestion... a coarse
'semantic layer v0 -> v1' log", Docs/11 M2). **This phase changes that to: write one row only when
`RevisionDiffer` actually finds at least one entry.** Called out explicitly because it changes
established Phase 2/3 write behavior on an existing table, even though nothing currently reads
`model_revisions` in the shipped app (§1) — the same "call out behavior changes to existing
mechanisms" discipline this project has followed since Docs/11's own claims.subject_ref relaxation.
The very first investigation for a repository can never produce a revision (there is nothing prior
to diff against) — expected, not a bug, and worth a direct unit test rather than an assumption.

### 4.2 Component & component-relationship diffing (architecture investigations only)

Using `AnchorAlignment` is unnecessary here — components/relationships match by name/tuple
(Decision #3), not anchor overlap:

- **Added component**: name present in the new investigation, absent from the previous one.
  `change_type = "added"`, `previous_state_json = nil`. Reason:
  *"New component '{name}' identified, {n} members, {confidence_tier} confidence."*
- **Removed component**: name present previously, absent now. `change_type = "removed"`,
  `new_state_json = nil`. Reason: *"Component '{name}' no longer appears in the latest
  architecture investigation."*
- **Modified component**: same name, but its member-anchor set changed (added/dropped members via
  a plain set comparison, not Jaccard — an exact-name match already establishes identity) or its
  `description`/`architectural_role` text differs. `change_type = "modified"`. Reason:
  *"'{name}''s membership changed: +{added} / -{removed} symbols."* or
  *"'{name}''s described role changed."*
- **`component_relationships`**: added/removed by the `(source, target, type)` tuple key, same
  `added`/`removed` shape. This is the mechanism that produces Docs/05 Stage 6's own worked example
  directly: if `AuthService -> Persistence` (`depends_on`) is absent from the new investigation but
  `AuthService -> SessionManager`, `SessionManager -> SessionStore`, and `SessionStore -> Keychain`
  are all newly present, that renders as one `removed` entry plus three `added` entries — the
  "Previously: AuthService -> Persistence / Now: AuthService -> SessionManager -> SessionStore ->
  Keychain" framing in `ModelChangeSummary` (§7) groups these by shared component into one visual
  timeline entry rather than four separate rows, but the underlying `model_revision_entries` stay
  one row per actual change, matching Docs/04's per-claim evidence-linking discipline.

### 4.3 Claim diffing (any investigation kind, cross-investigation)

For each claim in the new investigation with `claim_type != UNKNOWN` (uncertainties are §5's job):

1. `AnchorAlignment.align` the new claim's evidence-anchor set against every prior investigation's
   claims' evidence-anchor sets (same `repository_id`/`commit_hash`), threshold `0.3`.
2. **No match above threshold** -> `change_type = "added"`. Reason: *"New claim about {subject}:
   \"{statement excerpt}\"."*
3. **Matched to exactly one prior claim**:
   - Both claims' own structural verdict (`CONTRADICTED` or not, from Docs/11 M2's existing
     within-investigation check) **agree** -> `change_type = "modified"` only if the statement text
     or evidence set actually differs (an unchanged re-assertion writes no entry at all — not every
     re-confirmation is diff-worthy); reason: *"Claim about {subject} refined: evidence now includes
     {new anchors}."*
   - The verdicts **disagree** (previously clean, now `CONTRADICTED`, or vice versa) ->
     `change_type = "reversed"` (Decision #5) — the new, cross-investigation concept this phase adds.
     Reason: *"Claim about {subject} reversed: previously {prior verdict label}, now
     {new verdict label} against the current Code Graph."*
4. **Matched to more than one prior claim** above threshold (a genuine possibility once several
   investigations exist) — take the highest-Jaccard match only, log the rest as a
   `CLAIM_DIFF_AMBIGUOUS` diagnostic (new code, `stage = "model_revision"`, alongside the existing
   `semantic_ingest` diagnostics) rather than silently picking arbitrarily or fanning out one entry
   per candidate.

---

## 5. Uncertainty tracking

**`[done]` — see §11 M3.** Scoped per Decision #6 — honest about what a lexical heuristic can and cannot establish. Compares
this investigation's `uncertainties[]` (each a `claim_type == UNKNOWN` row, no evidence) against
the **immediately preceding investigation of the same kind** (architecture-vs-architecture,
question-vs-question — comparing an Ask investigation's uncertainties against an unrelated
architecture investigation's would conflate two different questions' open items):

- **Token-Jaccard over lowercased, stopword-stripped words** (a simple, inspectable, dependency-free
  measure — not embeddings, not a model call) between the new uncertainty's text and each prior
  uncertainty's text.
- `>= 0.6` (deliberately higher than the `0.3` structural threshold in §4 — prose similarity is a
  much noisier signal than shared evidence anchors, so this phase sets a conservative bar and
  accepts under-matching over false "same question" claims) -> `change_type = "carried_over"`.
  Reason: *"Still open: \"{text excerpt}\"."*
- **No match** for a previously-open uncertainty in the new investigation -> check every **evidenced**
  claim newly added in *this* investigation (from §4.3's `"added"` entries) for token-Jaccard
  `>= 0.4` against the old uncertainty's text:
  - A hit -> `change_type = "addressed"`, `related_claim_id` set to that claim, confidence_tier
    carried from the claim. Reason (explicitly hedged, never asserted as fact): *"Possibly addressed
    by a new claim: \"{claim statement excerpt}\" — not a confirmed resolution, worth a manual
    check."*
  - No hit -> `change_type = "no_longer_raised"`, `related_claim_id = nil`. Reason (equally
    honest): *"No longer raised in the latest investigation — this may mean it was resolved, or
    simply not revisited; not confirmed either way."*
- **A brand-new uncertainty** with no `carried_over` match -> `change_type = "added"` under
  `entity_type = "uncertainty"`, same shape as §4.3.

This is, by design, the softest mechanism in this phase — see Risk §9.2.

---

## 6. Export additions (`<out>/export/`)

Additive to [EXPORT.md](../OrionMacOs/EXPORT.md), matching Phase 2 M3's "additive to the existing
doc" decision:

- `model_revisions.jsonl` — `{id, revision_number, previous_revision, change_summary,
  triggering_investigation_id, created_at}`.
- `model_revision_entries.jsonl` — `{id, model_revision_id, entity_type, change_type,
  subject_label, previous_state, new_state, reason, confidence_tier, related_claim_id}`.

`orion-index export` gains this as a third exporter call (after `CodeGraphExporter`,
`SemanticExporter`), no-op when the repository has zero revisions yet — same "no-op, don't error"
convention Phase 2 M3 already established for a not-yet-investigated repository.

---

## 7. CLI (`orion-index`)

**`[done]` — see §11 M4** for one real correction against the sketch below: no positional
`<path>`, since this is a pure `Store` read exactly like `stats`/`query`/`export` (all three use
`--db`/`--out`, checked directly against the real commands rather than assumed) — only `analyze`
takes a repo checkout path.

- **`revisions [--db <orion.db> | --out <dir>] [--commit <sha>] [--since <revision-number>]
  [--backfill] [--json]`** — prints revision history newest-first: revision number, timestamp,
  triggering investigation's question, and each entry's
  `entity_type`/`change_type`/`subject_label`/`reason`. `--since` filters to revisions after a
  given number (for "what changed since I last looked," the CLI-level analog of the app's
  unread-badge count, §8). Lands on `orion-index` (not `orion-agent`) since this is a pure `Store`
  read with no agent/model involvement, matching `query`'s own precedent as a debugging/inspection
  surface rather than a product-facing command with its own tests beyond what `RevisionDiffer`/
  `Store` already cover.
- **`--backfill`** (M6, `[done]`) — computes and persists a revision for every past investigation
  that doesn't have a real, structured one yet (`SemanticImporter.backfillModelRevisions`), dated
  to each investigation's own `createdAt` rather than "now," then falls through to the normal
  listing. Exists because real Phase 2/3 investigation history predates `RevisionDiffer` ever
  being wired into `ingest()`/`ingestAnswer()` — any repository investigated before Phase 6 shipped
  has real investigations with no revision at all until this runs once. Idempotent: a second run
  finds nothing left to do (verified live against the real vendored-Starlette research database,
  §11 M6).

---

## 8. App UI wiring (`OrionApp/`)

Minimal, additive changes to Phase 4.5's already-built screen:

- **New `Model/ModelChangeLoader.swift`** — reads `model_revisions`/`model_revision_entries` via
  `CodebaseModelStore` and maps them onto the **existing** `ModelChangeSummary` shape (Docs/14 §8
  M6) grouped so that, per §4.2's own callout, a removed relationship and its replacement chain
  render as one visual entry when they share a component, not four disconnected rows. `Model
  ChangeSample.entries` (the fixed sample data) is removed once this loader is wired in — the view
  itself (`ModelChangesView`) needs no structural change, only its data source.
- **Real sidebar unread-count badge**: today's `sidebarBadgeCount(for:)` returns the sample's fixed
  count. Replace with a small, local (not DB) "last-viewed revision number" per repository —
  matching `RecentRepositories`' own precedent of small per-repo state living in a local JSON file
  under Application Support, not the SQLite DB (this is view-state, not model state) — badge count
  = revisions newer than that number; clears to the latest number when the Model Changes destination
  is actually opened.
- **`CONTRADICTED`-claim cross-reference** (Docs/14 §2's own named, previously-unbuilt PAIR pattern:
  "`CONTRADICTED` claims are shown inline with a 'Superseded — see Model Changes' cross-reference,
  not hidden or silently dropped"): `ComponentDetailView`'s and `AskEntryView`'s claim rows gain a
  small link, shown only when a `model_revision_entries` row of `change_type == "reversed"`
  references that claim's evidence, jumping to the Model Changes destination with that revision
  pre-selected/expanded.

No change to `RepositorySession`, `AnalysisRunner`, `SemanticInvestigationRunner`, `AskRunner`, or
`AgentSession` — this phase's app-side surface is entirely new read paths plus one small addition to
two existing claim-rendering views.

---

## 9. Risks / open questions

1. **Name/tuple matching for components and relationships is a heuristic identity, not a certain
   one** — a component renamed between two investigations (same underlying grouping, different
   label) reads as a remove-plus-add rather than a modification, the cross-investigation echo of
   Docs/11 Risk #4's own "component-granularity ambiguity is a legitimate judgment call." Not fixed
   here; worth revisiting only if real multi-investigation usage shows this misfiring often enough
   to matter (an anchor-overlap-based component match, similar to §3's claim matching, is the
   natural next step if so).
2. **Uncertainty resolution tracking (§5) is the most speculative mechanism in this phase, by
   design, not oversight.** A token-Jaccard heuristic over free text can both under-match (missing a
   genuinely-resolved uncertainty phrased differently the second time) and over-match (linking an
   unrelated new claim that happens to share vocabulary). Every "addressed" entry is written as an
   explicit hedge (§5's own reason wording), never presented as a confirmed resolution — if this
   proves too noisy or too timid in practice, the fix is tuning the two thresholds (`0.6`/`0.4`), not
   a redesign.
3. **Diffing every successful investigation (Decision #1), not just architecture runs, can surface
   many low-signal revisions if a repository is asked many similar-but-not-quite-identical
   questions.** Accepted deliberately, matching Docs/04's own literal loop over the Docs/05 Stage 6
   example's narrower architecture framing — revisit only if real usage shows the Model Changes list
   getting noisy; a minimum-entries-to-write threshold (e.g. suppress a revision consisting of a
   single low-confidence `modified` claim) is a cheap, backward-compatible fix if so, not a schema
   change.
4. **`model_revisions`' write cardinality changes from Phase 2/3's "always write one" to "write one
   only when a real diff exists" (§4.1).** Safe today (nothing reads the table live), called out
   explicitly per this project's own standing discipline for behavior changes to existing
   mechanisms, not because any current consumer would actually break.
5. **The differ only ever compares against investigations already committed to the DB at diff time**
   — the first investigation for any `(repository_id, commit_hash)` can never produce a
   *component/relationship/claim* revision. Expected, not a bug; a direct unit test confirms it
   (§10). **Amended in M3**: uncertainty diffing (§5) is a deliberate exception — a brand-new open
   question becomes `.added` even on a repository's very first investigation, since there is
   nothing to meaningfully compare a *newly raised* question against in the first place (unlike a
   component/relationship/claim, whose "added" status is only meaningful relative to some prior
   state that didn't have it). Confirmed directly by
   `testBrandNewUncertaintyOnRepositorysFirstEverInvestigationIsAddedNotEmpty`, not left as an
   untested edge case.
6. **Component `component_id` staleness** (Docs/15 Risk #2: a session can outlive the component it
   points to) means old architecture investigations' `components` rows persist in the DB forever.
   `latestArchitectureInvestigation`'s exact marker-filtering logic (reused directly, Decision #3)
   is what keeps §4.2's "two most recent architecture investigations" query from ever accidentally
   diffing against a stale one — the same class of bug Phase 4.5 M5 hit and fixed for the
   Architecture Overview itself, guarded against here by construction rather than re-discovered live.
7. **CONFIRMED, at M6 — Docs/11 Risk #6's "one level of `parent_symbol_id` only" limitation
   produces real, false cross-investigation `reversed` verdicts, not just false within-investigation
   `CONTRADICTED` ones.** Backfilling the real vendored-Starlette research database surfaced one
   concrete instance: an earlier investigation cited `BaseHTTPMiddleware.__call__` (the *method*
   that actually constructs `_CachedRequest`) as evidence; a later, independent investigation of
   the same underlying fact cited only `BaseHTTPMiddleware` (the *class*). The real Phase 1
   relationship connects the method to `_CachedRequest`, not the bare class — since the structural
   consistency check only walks one level of `parent_symbol_id` up from a cited symbol (never down
   into a class to find the specific method that actually does the work), the later, shallower
   citation fails a connectivity check the earlier, more specific one passed, and
   `RevisionDiffer` correctly-per-its-own-logic reports this as `reversed` even though the
   underlying claim is substantively unchanged. Not a Phase 6 bug — Docs/11 M2's own risk list
   named this limitation before Phase 6 existed — but this is the first concrete, hand-verified
   case of it manifesting as a *revision-level* false positive rather than an isolated
   within-investigation tag, worth real attention (extending `idsWithParents` to walk the full
   ancestor chain, per Docs/11's own suggested next step) before `reversed` entries are surfaced to
   a user as confidently as `.added`/`.removed` ones.
8. **CONFIRMED, at M6 — every real bug this milestone found was specific to processing
   investigations out of live-insertion order, and none of them were visible in ~360 tests built
   against live, in-order ingestion alone.** A coverage-check gap (legacy rows counted as
   "covered"), a revision-chaining bug, and `diffClaims` diffing against chronologically-*later*
   investigations were all invisible until a real backfill over real historical data exercised the
   one code path every prior milestone's own tests never happened to: diffing an investigation
   that is *not* the most-recently-created row in the table. Recorded here as a general lesson
   about this phase's own test coverage, not just three isolated bugs — any *future* change to
   `RevisionDiffer`/`SemanticImporter`'s revision logic should be checked against an out-of-order
   scenario specifically, not assumed safe because live-ingestion tests pass.

---

## 10. Testing & verification `[done]`

**Unit (`OrionCodeIntelTests`, no model load, no network)**

- `v5_phase6_schema` migration applies cleanly on top of `v4_phase5_schema`; all Phase 1-5 tests
  stay green (no regression) — the bar every prior additive migration has been held to.
- `AnchorAlignmentTests`: ported `score.py` fixtures (§3) — normalization edge cases, hand-checked
  Jaccard values, a synthetic perfect/partial/spurious alignment matching Python's own known-correct
  numbers.
- `RevisionDifferTests`, fixture-driven (two synthetic investigations against a small analyzed
  repo, no `claude` CLI call): added/removed/modified component; added/removed
  `component_relationship` producing the exact Docs/05 Stage 6 multi-hop shape (§4.2); a new claim
  with no prior match; a refined claim (same evidence, extra anchors); a reversed claim (matched
  evidence, disagreeing verdicts); an ambiguous multi-match claim correctly logging
  `CLAIM_DIFF_AMBIGUOUS` and picking the best match, not fanning out; a carried-over uncertainty; an
  addressed uncertainty with its hedge wording intact; a no-longer-raised uncertainty; the
  **first-ever investigation for a repo produces zero entries and no `model_revisions` row**
  (Risk #5, tested directly); an investigation that only re-confirms existing claims/components
  verbatim also writes nothing (the "not every re-confirmation is diff-worthy" rule, §4.3).
- `Store` CRUD for `model_revisions`/`model_revision_entries`: insert, read back, `revision_number`
  monotonically increasing per `(repository_id, commit_hash)`, cascade-delete from
  `model_revisions` to its entries.
- `SemanticImporter.ingest()`/`.ingestAnswer()` integration: a fixture repo investigated twice with
  a deliberately changed candidate JSON between calls produces the expected `model_revisions` row
  and entries as a side effect of the normal ingestion call, with no change needed at any existing
  call site.

**Integration — real prior data, no new live cost `[done]` (§11 M6)**

- Ran `orion-index revisions --backfill` against a working copy of the real vendored-Starlette
  research database (Phase 2 M6's 4 real repeatability investigations, already ingested — no new
  `claude` CLI spend) and hand-checked the results — the same "real data catches real bugs"
  discipline every phase since Phase 1 has followed, at zero marginal cost since the data already
  existed. Found and fixed three real bugs (all specific to processing investigations out of
  live-insertion order, §9 Risk #8) and hand-verified one genuine `reversed` claim against the
  actual Starlette source, tracing it to Docs/11 Risk #6 (§9 Risk #7) — full account in the §1
  status banner. The original research database was worked on only via an isolated copy and
  confirmed byte-identical afterward, never touched directly.

**App (`OrionAppTests`)**

- `ModelChangeLoaderTests` against a fixture DB with real `model_revisions`/`model_revision_entries`
  rows: correct grouping of a removed-relationship-plus-replacement-chain into one visual entry;
  empty state when zero revisions exist.
- Sidebar badge count: correct against a known "last-viewed" number and a known revision count;
  clears on opening the destination.
- `CONTRADICTED`-claim cross-reference link appears only when a matching `reversed` entry exists,
  absent otherwise.

**Manual, not CI**

- Open the real, already-multiply-investigated Starlette repository in the app; confirm Model
  Changes renders real Previously/Now/Reason entries (not sample data) matching what `orion-index
  revisions` prints for the same DB; click a `CONTRADICTED` claim's new cross-reference link and
  confirm it lands on the right revision.

**CI**: stays network-free exactly as every prior phase — schema/differ/loader tests run in CI; no
new live-model or live-`claude` test tier is needed, since this phase adds no new model call at all
(Decision #2).

---

## 11. Implementation order

- **M0 — Schema. [done]** `v5_phase6_schema` migration (`model_revisions.revision_number`,
  `model_revision_entries`), typed records, bare `Store` CRUD. No behavior change yet. See the
  status banner above for the one real schema correction found while implementing it (no
  `commit_hash` column, unlike this doc's own original draft).
- **M1 — `AnchorAlignment`. [done]** Swift port of `score.py`'s normalization + Jaccard alignment
  (§3), tested against ported known-correct fixtures. See the status banner above for the one
  real, deliberate enrichment over this doc's own original sketch (`Match<T>`, not a bare tuple).
- **M2 — `RevisionDiffer` core. [done]** Component/`component_relationship` diffing (§4.2) + claim
  diffing including `reversed` (§4.3) + deterministic reason templating (Decision #2).
  Fixture-driven tests, no wiring into `SemanticImporter` yet. See the status banner above for two
  real refinements found during implementation (self-determined investigation kind via the shared
  `architectureQuestionMarker`; per-claim independent best-match scoring instead of reusing
  `AnchorAlignment.align`'s bipartite matching).
- **M3 — Uncertainty tracking. [done]** `diffUncertainties` (§5), its own milestone given its
  distinct, more speculative logic and Docs/08's own explicit "uncertainty tracking" bullet. See
  the status banner above for the one deliberate exception to Risk #5 this milestone introduced,
  and a real M2-era bug found and fixed along the way.
- **M4 — Wire into ingestion + export + CLI. [done]** `SemanticImporter.ingest()`/
  `.ingestAnswer()` call `RevisionDiffer` (§4.1's write-cardinality change lands here);
  `model_revisions.jsonl`/`model_revision_entries.jsonl` export; `orion-index revisions` CLI. See
  the status banner above for two real corrections found during implementation (no positional
  `<path>` — matches `stats`/`query`/`export`'s own `--db`/`--out` convention; the old
  "did this insert anything" guard removed in favor of letting the differ decide).
- **M5 — App UI. [done]** `ModelChangeLoader` replacing Phase 4.5's sample data; real sidebar
  unread-badge count; `CONTRADICTED`-claim cross-reference link. See the status banner above for
  four real findings, including a retroactive `relatedClaimId` semantics correction to M2 and a
  pre-existing `ArchitectureModelLoader` timing bug found live while testing this milestone.
- **M6 — Hardening. [done]** Real end-to-end verification against Starlette's existing real
  multi-investigation history (Phase 2 M6's repeatability runs) — diff real data, hand-check the
  entries, fix whatever real diffing bugs surface, matching every prior phase's own closing
  milestone shape. Built `orion-index revisions --backfill` first (a genuinely new, permanent
  capability every pre-Phase-6 repository needs); found and fixed three real bugs specific to
  processing investigations out of live-insertion order (a coverage-check gap, a revision-chaining
  bug, and — the most significant — `diffClaims` diffing against investigations that happened
  *after* the one being diffed). See the status banner above for the full account, including a
  hand-verified real `reversed` claim traced to Docs/11 Risk #6's already-documented limitation
  (now added to §9 below). This closes Phase 6's full implementation order.

---

## 12. Post-completion fixes

Two real bugs the user found live-testing after M0-M6 landed, on their own real, long-lived
Starlette repository (86 investigations, 20 analysis runs — real usage across the whole project's
development, not a fresh fixture) — the same "reproduce against the real thing before fixing"
discipline every milestone above already used.

### 12.1 Sidebar badge showed the entire historical count, every time the app was reopened

**Symptom** (user's own report): "the model change side panel shows around 50 badges every time I
open the app, even though there are no model updates."

**Root-caused, not guessed**: the real Starlette database had never been backfilled (§11 M4
shipped in code, but nothing had run `orion-index revisions --backfill` against this *particular*,
long-lived repository yet) — it had exactly 50 real `model_revisions` rows, every one a coarse,
entry-less Phase 2/3 legacy row (0 total `model_revision_entries`), confirmed by direct inspection
before touching any code. Two compounding bugs, both real:

1. **`ContentView`'s badge baseline reset to `0` on every fresh repository open**
   (`viewedModelChangeCount = 0` in the `.opening` case), making the *entire* historical revision
   count read as "unread" every single time the app launched, not just genuinely new activity —
   the literal mechanism behind "every time I open the app."
2. **`ModelChangeLoader.revisionCount` counted bare `model_revisions` rows**, including
   entry-less legacy ones that `load()` itself correctly renders as *zero* cards — so the badge
   number didn't even match what clicking through to Model Changes actually showed ("No model
   changes yet" alongside a badge reading "50").

**Fixed**: `revisionCount` now counts only revisions with >= 1 `model_revision_entries` row (a
"does this actually produce a visible card" count, matching `load()`'s own criterion exactly, not
a second driftable one). `ContentView` gained `modelChangeBaselineSet`: the *first* time a
freshly-opened repository's count is read this session, that count becomes the baseline
(`viewedModelChangeCount` starts equal to it, not `0`) — only revisions created *after* that
baseline, within the same session, ever show as unread. 2 new tests
(`testRevisionCountExcludesLegacyEntrylessRevisions`, plus regression coverage already in place
for the loader's own grouping) — `OrionApp` suite now 137 tests, 0 failures.

### 12.2 The user's own real repository, actually populated

While diagnosing the above, the user separately asked for the real Starlette repository's Model
Changes data to be populated so the UI could actually be seen. Ran the exact real-data workflow
§11 M6 already built and validated, this time against the user's own live, app-facing database
(`Agent Feasibility Study/vendor/starlette/.orion/orion.db`, not a research copy) — backed up
first (`cp` to a scratch location), then `orion-index revisions --backfill`:

- **86 investigations checked, 51 real revisions created** (chained 2→51, each pointing at its
  true predecessor — the exact chaining logic §11 M6 fixed, now exercised at 10x the scale of that
  milestone's own 4-investigation verification).
- **229 total structured entries**: 32 claims added, 34 modified, 13 reversed; 16 components
  added, 5 modified, 17 removed; 41 relationships added, 36 removed; 20 uncertainties added, 15 no
  longer raised.
- **24 real `CLAIM_DIFF_AMBIGUOUS` diagnostics** — expected, at a scale consistent with §11 M6's
  own smaller finding (independent investigations describing overlapping evidence differently).
- All pre-existing data (86 investigations, 33 components, 108 claims, 20 analysis runs)
  reconfirmed byte-identical in row count after the backfill; the backup was not needed but was
  taken anyway, per this project's own standing discipline before touching real, hard-to-reproduce
  data.

This is exactly the same operation §11 M6 already validated against a research copy — no new code
was needed, only running the shipped `--backfill` command for real against the repository the user
actually opens in the app.

### 12.3 Model Changes page rebuilt on the right native component

**Symptom** (user, after seeing the page populated with 51 real revisions): the disclosure rows
only toggle when the ~12pt chevron glyph itself is clicked — the title text isn't in the hit
target — and the Previously/Now/Reason block sits at an inconsistent, content-dependent
indentation relative to the title.

**Root cause — a wrong component, not a styling bug.** The old `ModelChangesView` was a
`ScrollView { VStack { ForEach { DisclosureGroup } } }` with each card setting its own
`.padding(12)` + background + `clipShape`. A freestanding `DisclosureGroup` (one not inside a
`List`) only makes its own triangle interactive — its label is inert; and its content gets an
independent indent under that label that never lines up with a manually-padded card edge, and
shifts with content.

**Redesigned on `List` + collapsible `Section`** (`Section(isExpanded:content:header:)` +
`.listStyle(.sidebar)`) — the same API Docs/14 M4 already verified against the real SDK and ships
in `AskView`, and the pattern Apple's own HIG points at for this ("Disclosure controls": a
disclosure control and its label are one unit; "Lists and tables": use `List`, don't hand-roll row
chrome). Both reported problems are fixed *by construction*, not patched:

- The **entire section header row** is the disclosure toggle — icon, title, timestamp, trailing
  space, all of it.
- `List` owns row insets and the single header→content indent step with one consistent set of
  platform metrics; no manual `.padding`, no manual card background, nothing left to disagree.

Supporting polish, in the same pass (both visible in the user's screenshot, both making the
redesign land properly): (1) `ModelChangeLoader` now shows the *full* claim statement in the
Previously/Now fields (decoded from the state snapshot's `statement`) instead of the 120-char
`subject_label` excerpt that trailed off mid-word; (2) standalone-entry row titles now carry the
change type ("Claim reversed", "Open question no longer raised") instead of a bare "Claim" /
"Open question" that read identically down a list of dozens; (3) prose fields dropped monospace
(kept for the old arrow-string values, wrong for full sentences) and are `.textSelection`-enabled
and wrap rather than truncate; (4) an `.added` entry's empty "Previously" field is omitted rather
than shown as "—".

1 existing `ModelChangeLoaderTests` case updated for the new titles; full `OrionApp` suite green
at 137, `OrionCodeIntel` at 360. The component is proven in this same app already; a live visual
click-through of the new layout specifically was left to the user (the same `System Events`
custom-control automation limits Docs/13/14 hit repeatedly), who reported the original issue from
their own screenshot and is best placed to confirm the feel.

### 12.4 §12.3's `Section(isExpanded:)` list was itself the wrong shape — rebuilt as master/detail

**Symptom** (user, after §12.3 shipped): *still* have to click the disclosure glyph — the row
doesn't toggle — and now each expanded row's Previously/Now/Reason text is clamped to a single
truncated line with no way to read the rest.

**Root cause.** §12.3 traded a freestanding `DisclosureGroup` for
`List { ForEach { Section(_:isExpanded:) } }.listStyle(.sidebar)`. That API is a known
AppKit-bridging trouble spot on macOS — `AskView` hit the identical wall (its "Left: the session
list" comment cites Apple Developer Forums threads 820006 / 739118 / 778432, where a
`Section`/`DisclosureGroup` inside a sidebar `List` renders or animates incorrectly, especially
when its rows populate *after* the list's first layout pass, which is exactly what
`ModelChangesView`'s `.task`-driven load does). The two symptoms the user reported are that
failure mode: the header row's tap-to-toggle doesn't register (only the chevron does) and the
expandable `Section` content is height-clamped so `.fixedSize(...vertical: true)` can't win.
`AskView` had already abandoned this same construct for this same reason; §12.3 walked back into
it.

**The deeper point is HIG, not a workaround.** Apple's "Disclosure controls" guidance frames a
disclosure triangle as revealing *secondary information within the same view* — short, structured,
glanceable. Previously / Now / Reason are multi-paragraph LLM-authored prose. Long-form reading
content belongs behind *navigation to a detail area*, and the standard macOS shape for "a list of
items, each with substantial detail" is master/detail in a split view (HIG "Lists and tables";
Mail, Notes, News, System Settings, Xcode's navigators all do it). `AskView` already made exactly
this choice for exactly these reasons.

**Rebuilt as master/detail**, structurally mirroring `AskView`:

- `HSplitView { list; detail }`. The list pane is pinned `minWidth == idealWidth == maxWidth`
  (260pt) so `NSSplitView` has no divider to drag and the pane can't be collapsed away (this
  screen has no toolbar sidebar-toggle to bring it back — `AskView`'s documented reasoning).
- The list is a plain `ScrollView` + `LazyVStack` of `Button` rows (icon, title, "Updated …", a
  one-line teaser of where the model landed). **The whole row is the button** — no glyph to aim
  at. Selection tint is this view's own `@State selectedID`, not any `List`/`Section` machinery.
  Truncating the teaser here is correct: the full text is one click away.
- The detail pane is a `ScrollView` of the selected change's Previously / Now / Reason, each a
  labelled block rendered with `MarkdownText` (so inline `` `code` `` spans in a statement render
  instead of showing backticks), `.textSelection(.enabled)`, wrapping freely — **nothing
  truncated**. The colour cue moved from the paragraph body (the pre-redesign screenshot rendered
  whole paragraphs in monospaced green) to the field *label* + a thin leading rule on "Now"; body
  text stays `.primary` for legibility.
- `focusedRevisionId` (the "Superseded — see Model Changes" hand-off) now selects and scrolls to
  that revision's first row; a normal visit selects the most recent change so the detail pane is
  never blank on arrival.

`ModelChangeLoader` and its tests are unchanged from §12.3 (the truncation was purely a rendering
constraint of the abandoned sidebar `List` row; the loader was already producing full statement
text). `OrionApp` suite green at 137, `OrionCodeIntel` at 360, both build clean. Live visual
confirmation again left to the user, who is best placed to judge the feel.
