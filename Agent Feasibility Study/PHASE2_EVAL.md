# PHASE2_EVAL.md

Docs/11_phase2_semantic_analysis.md M5: gold-set evaluation of one real Claude Code semantic
investigation over vendored Starlette. Companion to `TASK3_BASELINE_EVAL.md` (which asks "can a
model answer questions given context") — this asks a different question: "can a model
reconstruct a repository's *architecture* as a set of coherent components, and does the
resulting knowledge survive independent structural verification."

## 1. What this answers

First empirical read on **H2** (structured semantic knowledge can be reconstructed from the
Code Graph) and **H6** (Claude's findings can be ingested and verified by code that is not
Claude itself, without making Claude the permanent orchestrator) from
`09_research_hypotheses.md`. One run, one repository — not a statistical claim. M6
(repeatability, N runs) is the milestone that turns "it worked once" into "it works reliably."

## 2. Method

**The investigation.** `claude-sonnet-5`, headless (`claude -p`), read-only tools
(`Read`/`Grep`/`Glob`), pointed at vendored Starlette (`4f250d6b814587e20c5365f0a5f0c4d42bcb929f`)
plus its Phase 1 Code Graph export as a starting map. 24 turns, $1.38, ~315s. Full details:
Docs/11 M1/M4.

**Validation.** Every finding passed through `SemanticImporter` (Swift) — schema validation,
then every cited anchor resolved against the real `symbols` table, then every
component-to-component relationship and every multi-evidence claim structurally confirmed
against the real Phase 1 relationship graph (not taken on Claude's word). Full details:
Docs/11 M2.

**The gold set** (`benchmark/starlette_components.gold.json`, 11 components, 150 anchors) was
hand-authored from the vendored source and cross-checked against the real exported
`symbols.jsonl` (every anchor confirmed to exist — no typos in the ground truth itself), at
module + class + top-level-function granularity only (no individual methods).

**Known limitation on independence**: the gold set was authored with prior awareness of this
specific investigation's own component breakdown (inspected during earlier development) — not
a fully blind gold set. The groupings deliberately differ from the prediction's in several
places based on independent judgment (Data Structures kept apart from Form Parsing; Concurrency
Utilities split out on its own), but this is a real limitation on how independent this
particular evaluation is. A blind second author, or a gold set authored before ever running the
investigation, would make M5's numbers more trustworthy — worth doing before drawing strong
conclusions from a single comparison like this one.

**Scoring** (`harness/orion_eval/semantic/score.py`):
- *Component alignment*: every anchor on both sides is normalized to its top-level defining
  symbol (`path::Class.method` → `path::Class`) before comparing — the gold set only goes to
  class granularity, predictions routinely cite methods, and without normalizing, that
  granularity mismatch alone would tank the score regardless of whether the grouping was right.
  Gold and predicted components are then greedy-matched by Jaccard overlap of their normalized
  anchor sets (≥ 0.3 to count as the same component), and each matched pair gets
  precision/recall/F1. A gold component with no match above threshold is **missed**; a
  predicted component with no match is **spurious**.
- *Evidence accuracy*: read directly off the export's `claims.jsonl` — the fraction of
  evidence-bearing claims (excludes `UNKNOWN`/uncertainty-derived ones, which were never a
  checkable assertion) that were **not** reclassified `CONTRADICTED` by Swift's own structural
  check. Not re-derived in Python; Swift is the side with the real Code Graph.

## 3. How to run

```
cd "Agent Feasibility Study/harness"
python -m orion_eval.cli score-semantic \
  --out /tmp/orion-starlette \
  --gold ../benchmark/starlette_components.gold.json \
  --write /tmp/orion-starlette/score_report.json
```

(Requires a `.orion` dir with both Phase 1's and Phase 2's export already written — see Docs/11
"Manual end-to-end.")

## 4. Results (2026-09-04, one run)

```
component alignment (10 matched, 1 missed, 0 spurious):
  'Application Assembly'                <-> 'Application Assembly'                                    J=1.00 P=1.00 R=1.00 F1=1.00
  'HTTP & WebSocket Connections'         <-> 'HTTP & WebSocket Connections'                             J=1.00 P=1.00 R=1.00 F1=1.00
  'Responses & Background Tasks'         <-> 'Responses & Background Tasks'                             J=1.00 P=1.00 R=1.00 F1=1.00
  'Endpoints, Static Files & Templating' <-> 'Endpoints, Static Files & Templating'                     J=1.00 P=1.00 R=1.00 F1=1.00
  'Routing'                              <-> 'Routing & URL Convertors'                                 J=0.96 P=0.96 R=1.00 F1=0.98
  'Async Concurrency Utilities'          <-> 'Async Concurrency & Internal Utilities'                   J=0.83 P=0.83 R=1.00 F1=0.91
  'Optional Services'                    <-> 'Optional Services: Config, Auth, Schemas & Test Client'   J=0.83 P=0.83 R=1.00 F1=0.90
  'Error & Exception Handling'           <-> 'Error & Exception Handling'                                J=0.82 P=1.00 R=0.82 F1=0.90
  'Data Structures'                      <-> 'Data Structures & Form Parsing'                            J=0.67 P=0.67 R=1.00 F1=0.80
  'Middleware Stack'                     <-> 'Middleware Stack'                                          J=0.62 P=0.95 R=0.64 F1=0.77
  missed: ['Form & Multipart Parsing']
  spurious: []

macro precision=0.923  macro recall=0.946  macro F1=0.926
evidence accuracy: 1.000 (10/10 evidenced claims confirmed, 0 contradicted)
```

10 of 11 gold components matched at F1 ≥ 0.77; **zero spurious** predicted components (nothing
hallucinated as a standalone architectural area); **zero contradicted** evidence-bearing claims
(all 10 confirmed against the real Phase 1 relationship graph, including the 3 that were false
positives before M2's parent-symbol fix — see Docs/11 M2's own entry for that story).

### The one miss, checked by hand

`Form & Multipart Parsing` (gold) has no match ≥ 0.3. Checking the prediction directly: all 7 of
`formparsers.py`'s symbols are present — folded into `Data Structures & Form Parsing` instead of
kept as their own component. That's exactly why that pairing's own precision/recall aren't
perfect (P=0.67, R=1.00 — the prediction contains real content beyond what gold's narrower
`Data Structures` component defines). Read as a genuine boundary/granularity disagreement, not a
dropped architectural area — "should form parsing be its own component or grouped with the data
types it produces" is a legitimate judgment call (Docs/11 Risk #4), and this is one concrete
instance of it actually happening.

### Middleware Stack's lower recall (R=0.64)

The weakest real match. `Middleware Stack` (predicted) doesn't include
`starlette/middleware/errors.py`/`ServerErrorMiddleware` or
`starlette/middleware/exceptions.py`/`ExceptionMiddleware` — the prediction filed those under
its own `Error & Exception Handling` component instead (which *does* match gold's
`Error & Exception Handling` reasonably, at R=0.82). Gold's `Middleware Stack` bundled all
middleware together including the error-handling ones; the prediction split error-handling
middleware out. Another boundary disagreement in the same family as the form-parsing one above,
not a fabrication or an omission of real content — cross-checked directly against
`components.jsonl`, same as the miss above.

## 5. Reading these numbers

- **Every predicted component corresponds to something real.** Zero spurious components across
  10 predictions is the strongest single signal here for H2 — nothing was invented out of
  whole cloth.
- **Every evidence-bearing claim held up under independent structural checking.** 10/10, not
  self-reported — Swift confirmed each one against Phase 1's deterministic relationship graph.
  This is the concrete form H6 takes: verification, not trust.
- **The disagreements that exist are boundary calls, not errors** — checked by hand above for
  both cases below the top F1 tier. That distinction matters: a scorer number alone can't tell
  "wrong" from "differently-but-defensibly grouped," which is exactly why Docs/11 M5 planned a
  by-hand check alongside the numeric score rather than the number standing alone.
- **This is one run.** A macro F1 of 0.926 here says the pipeline *can* produce a
  high-quality decomposition — it does not yet say it *reliably* does. M6 (repeatability) is
  where that claim would actually get made or broken.

## 6. Repeatability (M6, 2026-09-05)

Three additional independent investigations (`run3`/`run4`/`run5`, same commit, same
`--repeatability` command run separately by hand) plus the original one from §4 — 4 total.
Two earlier attempts (`run1`/`run2`) hit Anthropic API `529 Overloaded` before producing any
output; `repeatability-report` now surfaces failed attempts with their reason instead of
silently excluding them.

### Per-run numbers (Swift-verified, not self-reported)

| run | components | relationships | unconfirmed | claims | contradicted | outcome |
|---|---|---|---|---|---|---|
| M1 (original, §4) | 10 | 17 | 0 | 17 | 0 | `verified` |
| run3 | 9 | 12 | 1 | 14 | 0 | `partially_verified` |
| run4 | 10 | 17 | 0 | 16 | 0 | `verified` |
| run5 | 14 | 16 | 0 | 12 | 3 | `partially_verified` |

**2/4 runs came back fully `verified`; 2/4 `partially_verified`** — one investigation
(run3) asserted a component relationship the structural check couldn't confirm; another
(run5) asserted 3 claims whose evidence symbols didn't structurally connect. Zero components
or claims were *dropped* in any run (every cited anchor always resolved) — the instability is
in what gets asserted and whether it holds up, not in basic anchor discipline.

### Component-set stability (pairwise, `run3`/`run4`/`run5`)

```
run3 <-> run4   matched=7 missed=2 spurious=3 macro_f1=0.650
run3 <-> run5   matched=9 missed=0 spurious=5 macro_f1=0.779
run4 <-> run5   matched=8 missed=2 spurious=6 macro_f1=0.740

mean_pairwise_f1=0.723 (min=0.650 max=0.779)
```

Notably **lower** than the 0.926 macro F1 against the hand-authored gold set in §4 — the
investigation agrees with a good independent decomposition more than it agrees with *itself*
across reruns. That's a real, interpretable finding, not a contradiction: gold is one
specific, stable target; three independent runs are three different (each individually
plausible) ways of carving the same repository, so their pairwise agreement is naturally
lower than any one of them matching a fixed reference.

### Cost / turns / duration variance

| | min | max | mean |
|---|---|---|---|
| cost (USD) | $1.32 | $1.77 | $1.54 |
| duration | 179s | 325s | 230s |
| turns | 24 | 67 | 40 |

Turns varied nearly 3x (24 to 67) for investigations of the *same* repository at the *same*
commit — the agentic investigation's own exploration path is not fixed, which is expected for
a multi-turn tool-using session but worth having a real number for rather than assuming.

### A real schema bug this run surfaced

`components` was originally `UNIQUE(run_id, name)` (Docs/11 M0) — scoped to the Phase 1
analysis run, not the investigation. Ingesting `run3` and `run4` initially failed with a raw
SQLite constraint violation: both investigations independently produced a component named
"Middleware Stack" against the same analysis run, which the schema treated as a duplicate
insert rather than two investigations legitimately agreeing on a name. Fixed to
`UNIQUE(investigation_id, name)` — within-one-investigation duplicates are still caught
(that's what the constraint was actually meant to guard), but the same name across
independent investigations of the same run is exactly the case M6 exists to exercise. 2 new
Swift tests cover both directions. This is exactly the kind of gap that only running the
pipeline against real, independent repeated output — not synthetic fixtures — was ever going
to surface.

### Reading this

- **H2 gets a more honest answer than §4 alone gave it.** A single high-quality run (0.926
  vs. gold) is a real data point, but 4 runs show real variance in both content (9-14
  components) and in how much of that content survives independent structural verification
  (2/4 fully clean, 2/4 with at least one unconfirmed/contradicted item). "Can Claude
  reconstruct a plausible architecture" and "does it reconstruct the *same* one reliably" are
  different questions with different answers here.
- **H6 held up under repetition, not just once.** Every run's output — including the two that
  weren't fully `verified` — was caught, marked, and left queryable rather than silently
  trusted. The consistency check doing its job on `run3`/`run5` (not the fact that 2/4 were
  clean) is the actual point of H6.
- **N=4 is still small.** These numbers characterize *a* level of instability, not *the*
  level — more runs would tighten the confidence interval on 0.723 mean pairwise F1 and on the
  50% `partially_verified` rate, both of which are single small-sample estimates right now.

## 7. Limitations

- **Gold-set independence** (§2) is the biggest one — read these numbers as "the scoring
  machinery works and produced a plausible-looking result," not as a fully independent
  benchmark score, until a blind gold set exists.
- **One repository throughout.** §6 covers repeatability across runs of *this* repository —
  nothing here says whether Starlette's ~0.72 mean pairwise stability and 50% partial-verify
  rate would hold on a larger, messier, or differently-shaped codebase.
- **N=4 for repeatability is still a small sample** (§6's own reading already says this) —
  enough to show real variance exists, not enough to pin down its distribution.
- **The optional LLM-judge axis from the original Docs/11 plan is not built.** `score.py`
  only implements the gold-set path; a judge-based plausibility rating (mirroring `grade.py`'s
  pattern) remains a documented stretch item.
- **Jaccard-with-normalization is a coarse metric.** It rewards "contains the right symbols,"
  not "explains their relationship correctly" — the by-hand checks in §4 exist because the
  number alone under-distinguishes a genuine miss from a reasonable alternative grouping.
