# 14 — Phase 4.5: UI/UX Redesign

**Status: SwiftUI implementation complete — M0 through M9 all done** (M7 landed before M8 by
explicit request; M8.5/M8.6/M8.7/M8.8 are four rounds of real, live-reproduced UX bug fixes found
during acceptance testing, all inserted ahead of the original M9; M9 itself is the final light/dark
+ accessibility + regression pass). See §8 for the full milestone-by-milestone record. This phase
produced a clickable high-fidelity prototype and this companion doc; §8 is the real build plan
against `OrionApp/`, executed the same milestone-at-a-time way Docs/13 was, with every milestone
verified against the actual running app, not just the prototype. Nothing in this phase has been
committed to git.

Prototype: **[Orion Phase 4.5 UI Redesign](https://claude.ai/code/artifact/7c0c3403-b913-4ee8-8754-f8a40cddbd0d)**
— open it and click through. Source lives at `Docs/phase4_5_design/` (`Main.dc.html` is the
interactive shell, `Legend.dc.html` is the token/component reference sheet, `canvas.json` lays
them out). Edit those files and re-read this doc's "How to revise this" section when you want to
change something yourself.

**Revision note:** the first pass of this prototype inlined every Open Questions entry directly
above the diagram and modeled Ask as one flat scrolling transcript; a second pass replaced Ask's
transcript with a list filtered by a row of pill buttons. All three were wrong against real usage —
see 4.4 and 4.6, which now describe (and the prototype now implements) the corrected designs: Open
Questions as a collapsed strip opening a dedicated inspector panel, and Ask as a master-detail list
grouped into collapsible per-component sections (not filter pills, which don't scale to many
components or a long component name).

## 1. Why this phase exists

Phase 4 (Docs/13) built a *correct* UI: every screen in Docs/05's flow works, every claim carries
its epistemic tag and confidence, nothing is presented as more certain than it is. But it was
built by wiring views directly to the data layer as each milestone landed — sheet-per-feature,
default system chrome, no considered navigation structure. Concretely, the shipped app has these
UX problems this phase set out to fix:

1. **No persistent navigation.** `ContentView` is a single state machine with three modal sheets
   (`OpenRepositoryView`, `BuildArchitectureModelSheet`, `AskView`) stacked on top of it. Asking a
   question about a component you're looking at means leaving the diagram entirely for a
   disconnected full-screen sheet — Docs/05 Stage 4→5's continuity ("the developer can ask
   questions about the selected component") isn't actually possible in the shipped app.
2. **Component exploration is a sheet, not an inspector.** Clicking a node interrupts the diagram
   instead of sitting alongside it the way Xcode's or Finder's inspector does.
3. **Two stages of Docs/05 have no UI at all.** Stage 6 (Continuous model update — "Understanding
   updated / Previously / Now / Reason") and Stage 7 (Teaching mode) were never built. The shipped
   app silently drops both.
4. **The analysis progress screen doesn't show Docs/05's own 4 named phases** ("Mapping repository
   structure," "Identifying components," "Verifying dependencies," "Building architecture") — it
   shows a generic linear bar plus raw internal pipeline-stage identifiers behind a disclosure.
5. **Color is overloaded.** `ConfidenceBadge` and `EpistemicBadge` both render as filled capsules
   with only color distinguishing the two independent axes ("what kind of knowledge" vs. "how
   sure"); `EpistemicTag.unknown` and `ConfidenceTier.unresolved` are both plain gray, so an
   `UNKNOWN`-tagged claim with `unresolved` confidence — a common, meaningful combination — shows
   two visually identical greyish pills next to each other.
6. **The "front door" (Open Repository) and the empty state undersell the product.** Generic SF
   Symbol + text, no articulation of what Orion actually does or why evidence-and-confidence
   matters, in a fixed-size default `.sheet`.
7. **The cost-gated "Build Architecture Model" action is a plain form**, undersold for what it
   actually is (Docs/06 §6's real accounted-for spend of $0.17–$1.77 and several minutes).

This phase doesn't change what the app *knows how to do* (no new backend capability) — it changes
how that capability is organized, navigated, and explained. Docs/13's `Model/` and `Ingestion/`
layers (loaders, runners, `AgentSession`) are untouched by this redesign; only the `Views/` layer
and `ContentView`'s shell are in scope for the eventual implementation.

## 2. What this redesign is grounded in

### Apple Human Interface Guidelines — macOS 26 "Liquid Glass"

`OrionApp/project.yml` already targets macOS 26 (Tahoe), the release that shipped Apple's Liquid
Glass material system across every platform. Three HIG points from that release drive this
redesign specifically:

- **Sidebar and toolbar are a distinct floating glass layer that sits above the content**, not
  flush chrome — "establish a clear visual hierarchy where controls and interface elements
  elevate and distinguish the content beneath them." Concretely: the sidebar and toolbar in the
  prototype are translucent (`backdrop-filter: blur(24px) saturate(180%)`) over the content
  scrolling underneath them, exactly like Finder/Xcode on Tahoe — never opaque chrome.
- **Concentric corner radii.** A window's corner radius, its sidebar's top-left corner, its
  toolbar's top-right corner, and the controls nested inside all step down together rather than
  each picking their own arbitrary radius. The prototype uses one radius scale throughout (window
  16 / panel 12 / control 9 / badge pill — see the Legend artboard) instead of the shipped app's
  ad-hoc `.clipShape(RoundedRectangle(cornerRadius: 8))` scattered per-view.
- **Content runs edge-to-edge under the glass**, not boxed in by margins that duplicate the
  window's own edge. The diagram, list, and Ask transcript in the prototype fill the content
  column completely; only floating panels (inspector, sheets) get their own inset padding.

Sources: [Apple — "Apple introduces a delightful and elegant new software design"](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/),
[Liquid Glass: Redefining design through Hierarchy, Harmony and Consistency](https://www.createwithswift.com/liquid-glass-redefining-design-through-hierarchy-harmony-and-consistency/),
[Build an AppKit app with the new design — WWDC25](https://developer.apple.com/videos/play/wwdc2025/310/).

### Human-Centered AI — Microsoft HAX Toolkit / Google PAIR

Orion's entire premise (Docs/04) is that an AI-assisted tool must never let its output be mistaken
for more certain than it is. That's a human-AI interaction design problem with an existing
literature, not something to improvise per-screen. Microsoft Research's 18 "Guidelines for
Human-AI Interaction" and Google PAIR's People + AI Guidebook patterns map directly onto specific
redesign decisions:

| Guideline | Where it shows up in this redesign |
|---|---|
| **G2** — make clear how well the system can do what it can do | Confidence badges on every node/claim; the sidebar's "6 components verified · $0.63 · 3m 40s" cost/quality receipt after a Build Architecture Model run |
| **G10** — scope services when in doubt | Depth-1 Ask answers are labeled "Not independently checked," never given the same green-seal treatment as a verified answer (this is Docs/12 Risk #5, carried forward and made visually explicit) |
| **G11** — make clear why the system did what it did | The "Explain" disclosure on every Ask answer; the whole Diagnostics destination |
| **G16** — convey the consequences of user actions | The Build Architecture Model sheet states the real cost/time tradeoff before the button is pressed, not after |
| **G18** — notify users about changes | Stage 6's Model Changes timeline, now a first-class sidebar destination with an unread-count badge, not something the user has to notice on their own |
| PAIR — mental models | The persistent "Structural / Semantic" layer banner, so the user always knows which of the two knowledge layers (Docs/04 §2) they're looking at |
| PAIR — errors & graceful failure | `CONTRADICTED` claims are shown inline with a "Superseded — see Model Changes" cross-reference, not hidden or silently dropped |

Sources: [Microsoft Research — Guidelines for Human-AI Interaction](https://www.microsoft.com/en-us/research/blog/guidelines-for-human-ai-interaction-design/),
[Microsoft HAX Toolkit](https://www.microsoft.com/en-us/haxtoolkit/ai-guidelines/).

## 3. Design system (see the Legend artboard for live swatches)

All values below are CSS custom properties in the prototype (`Docs/phase4_5_design/Main.dc.html`
and `Legend.dc.html`, each file's own `:root`-equivalent `.orion`/`.orion-legend` token block —
the two files don't share state, so both carry the same values twice by design).

**Type** — system font (SF Pro on macOS): Large Title 34/700, Title 2 20/650, Headline 16/650,
Body 13/400, Caption 11/600 uppercase-tracked, Mono (evidence anchors, code, routing traces)
11.5/400 `ui-monospace`.

**Epistemic color** (Docs/04 §3's five types) — unchanged hues from the shipped
`EpistemicTag.color` (green/purple/indigo/gray/red), re-expressed in OKLCH with matched light/dark
pairs, rendered as a **filled capsule + icon**:

| Type | Hue | Icon |
|---|---|---|
| Fact | green | seal/checkmark |
| Interpretation | purple | speech bubble |
| Inference | indigo | branch |
| Unknown | gray | question mark |
| Contradicted | red | warning triangle |

**Confidence color** (`ConfidenceTier`, a *separate* axis from epistemic type — deliberately never
reusing an epistemic hue, so a viewer never conflates "how sure" with "what kind") — rendered as an
**outlined capsule + a 3-bar signal meter** (3/3 bars lit = high, 2/3 = medium, 1/3 = low, 0/3 =
unresolved) instead of the shipped app's plain colored-text capsule. This is the one real visual
vocabulary change from the shipped app, and it's deliberate: filled-vs-outlined plus a bar count
means the two axes are distinguishable by *shape*, not only by hue — the current app relies on
color and a text label alone, which is more fragile for a colorblind viewer or a quick glance
across a diagram full of dots.

**Spacing scale:** 4 · 8 · 12 · 16 · 20 · 24 · 32px. **Radius scale:** window 16 / panel 12 /
control 9 / badge pill (999px). **Materials:** sidebar/toolbar/inspector are glass
(`blur(24px) saturate(180%)` over translucent fill); cards, sheets, and the inspector's content
are opaque — glass is reserved for *navigation* chrome, never for content you're trying to read
closely (matches Apple's own Liquid Glass guidance not to layer glass on glass).

## 4. Screen-by-screen

Each section names the prototype state to click into, what changed vs. the shipped app, and the
concrete SwiftUI mapping for whoever implements this next.

### 4.1 Shell (sidebar + toolbar) — replaces `ContentView`'s toolbar + ad-hoc sheets

The single biggest structural change: a persistent sidebar with five destinations
(**Architecture Overview, Ask, Model Changes, Teaching Mode**, and **Diagnostics** set apart below
a divider labeled "Advanced") replaces the current toolbar-button-opens-a-sheet pattern. Ask and
Model Changes are promoted from "a sheet you open" to "a place you go," which is what makes
Stage 5/6 actually feel like part of the exploration flow instead of a bolted-on chat window.

- **SwiftUI mapping:** `NavigationSplitView(sidebar:content:)` with a `List(selection:)` bound to a
  `Destination` enum (`.overview, .ask, .changes, .teaching, .diagnostics`); the "Advanced" divider
  is a second `Section` in the same list. The repo identity block above the list is a plain
  `VStack` in the sidebar's `safeAreaInset(edge: .top)`. The Build Architecture Model
  button/status card pinned at the sidebar bottom is a `safeAreaInset(edge: .bottom)` — this is
  what makes it persist across every destination instead of only showing on Overview
  (`ContentView.swift`'s current `readyHeader`-only placement).
- Toolbar becomes a real `.toolbar { ToolbarItem }` group: destination title (from
  `navigationTitle`), the Diagram/List segmented control (only added when `destination == .overview`,
  via `if` inside the `ToolbarItemGroup`), and a light/dark toggle (macOS already gives you this for
  free via `.preferredColorScheme` / system appearance — the prototype's manual toggle exists only
  because a static mockup can't read the real system setting; **don't build a real in-app
  light/dark switch**, just verify both appearances against the token table above).
- Traffic lights are real window chrome on macOS — nothing to build, they're a mockup convention
  only.

### 4.2 Welcome / Open Repository — replaces `OpenRepositoryView`'s sheet + `ContentView`'s empty state

Merges Docs/05 Stage 1's entry point and the current empty state into one screen: a real headline
stating the product's thesis ("See what your code actually does") next to the same Local
Folder/GitHub URL/Recents card the shipped app already has, just restyled and no longer a
fixed-420×360 `.sheet`. The *same* card markup is reused, unchanged, when "Open Another
Repository" is invoked from inside a ready session — there it becomes a floating modal over a
blurred backdrop instead of the initial screen's embedded panel.

- **SwiftUI mapping:** this is directly `OpenRepositoryView.swift`'s existing content, restyled —
  no new state or logic. Keep `RepositorySession`, `RepositoryCloner`, `RecentRepositories` exactly
  as they are (Docs/13 M1); only the container view changes, from a `.sheet` to (a) the full window
  content when `session.state == .idle`, and (b) a custom-presented overlay (`.overlay` +
  `.transition`, or keep it a `.sheet` — a real sheet is fine here since it's a deliberate
  interrupt, unlike Ask/Build Model which are now destinations) when reopening from `.ready`.

### 4.3 Analysis Progress — replaces `AnalysisProgressView`

Docs/05 Stage 2 lists four *named, meaningful* phases. The shipped view showed a generic
`ProgressView(progress.currentStage?.rawValue)`, which surfaces the internal `PipelineStageID`
raw value directly (`clone_repository`, `resolve_symbols`, …) as the primary UI text. The redesign
shows the four Docs/05 phases as a real stepper (pending outline → active spinner → done
checkmark), with the internal per-stage log moved fully into a closed-by-default "Advanced"
disclosure — same information, correctly layered per Docs/05 §8.

- **SwiftUI mapping:** `AnalysisProgressTracker` already exposes `stageHistory`; add one pure
  function `AnalysisProgressStage.uiPhaseIndex` (0–3) next to the existing
  `AnalysisProgressStage.uiStage(for:)` in `Ingestion/AnalysisProgressTracker.swift` mapping each
  of the 8 real `PipelineStageID`s to one of the 4 Docs/05 phases, and drive the stepper's
  done/active state off that index — no new tracking infrastructure needed.

### 4.4 Architecture Overview — replaces `ArchitectureOverviewView`'s diagram/list + banner

Kept: the structural-vs-semantic layer banner, the Diagram/List toggle, Grape-style force-directed
node layout. Changed: node selection opens an **inspector** in the same window (see 4.5) instead
of a `.sheet`; confidence dots on nodes/edges now use the shared `confMeta` bar-and-color mapping
(edges too — the shipped app only did a binary solid/dashed split, the redesign carries the full
high/medium/low/unresolved distinction onto edge color as well, reusing one function for both
nodes and edges instead of two separate mappings).

**Open Questions is now a collapsed, clickable summary strip, not inline text.** The shipped app
(and this doc's first draft) rendered every uncertainty's full text directly in a banner above the
diagram. Real production data broke that: a real investigation surfaces around 6 open questions,
several 150–220 words each — inlined, that's over a thousand words sitting on top of the graph it's
supposed to summarize. The redesign keeps the strip itself always visible (never buried behind a
disclosure — Docs/13 M6's reasoning still holds: an honest "here's what we don't know" deserves the
same visibility as the components) but reduces it to one line: an icon, "Open Questions (6)," a
truncated preview of the first one, and a chevron. Clicking it doesn't expand the strip in place —
it opens a full list in the **same inspector panel** node detail already uses (see 4.5), each
question shown in full with its `UNKNOWN` badge, scrollable, with the panel's existing close
button. Selecting a node while the questions panel is open replaces it with that node's detail, and
vice versa — the two are mutually exclusive uses of one panel, never stacked.

- **SwiftUI mapping:** `ArchitectureOverviewView` keeps `ArchitectureModelLoader`,
  `ArchitectureModel`, `ArchitectureNode/Edge` untouched. The Grape `ForceDirectedGraph` stays;
  what changes is (a) `LinkMark.stroke(...)` gets its color from the same `ConfidenceBadge.color(forTier:)`
  used for nodes and confidence badges (today it's a special-cased binary
  `edge.confidenceTier == "high" ? .secondary : .orange`), and (b) `.graphOverlay`'s tap handler
  and the new Open Questions strip both drive one `@State var inspectorContent: InspectorContent?`
  (an enum: `.node(ArchitectureNode)` / `.openQuestions`) instead of a bare `selectedNode` — that
  single piece of state is what makes the two mutually exclusive, and it's what `.inspector(item:)`
  (4.5) switches on.

### 4.5 Component Exploration — replaces `ComponentDetailView`'s sheet

Same content as the shipped `ComponentDetailView` (Purpose / Members / Dependencies / Claims &
Evidence, all epistemic-tagged) — the change is entirely about *placement and dismissal*: a
persistent right-hand panel with a close (×) button, not a modal that covers the diagram you were
just looking at. This is the concrete fix for Docs/05 Stage 3→4's implied continuity.

**New: an "Ask about {name}" button in every node's detail.** This is the other half of that same
continuity fix — Docs/05 Stage 4 says "the developer can ask questions about the selected
component," but the shipped app never gave that sentence a button. Clicking it jumps to the Ask
destination (4.6) and immediately asks "Tell me more about {name}," so the Overview → Ask path is
one click, not "remember the component's name, then go type it yourself."

- **SwiftUI mapping:** macOS's native `.inspector(isPresented:)` modifier (there is no `item:`
  overload — corrected in §8 M1 against the real SDK), attached at the `ArchitectureOverviewView`
  level (same place `.sheet(item: $selectedNode)` lives today) with `isPresented` computed from
  whether the shared `InspectorContent?` enum from §4.4 is non-`nil`. Reuse
  `ComponentDetailLoader`/`ComponentDetail` exactly
  as-is — only the presentation modifier changes. Evidence chips still open `EvidenceView`, which
  can stay a real `.sheet` (a genuine short-lived interrupt, unlike the component detail itself).
  The "Ask about" button needs one new piece of plumbing: a way for `ArchitectureOverviewView` to
  hand a prefilled question to whatever owns Ask's state (a shared `@Observable AskSession` object,
  or a binding passed down) and switch the sidebar selection to `.ask` — there's no such hand-off
  today because Ask and Overview don't currently share any state.

### 4.6 Ask — replaces `AskView`'s sheet

Promoted to a sidebar destination (4.1) so asking a question no longer means leaving the app's
main content area — but this section changed shape entirely from the first draft of this doc, not
just placement.

**Why the first draft was wrong.** The initial redesign kept `AskView`'s single flowing transcript
— every question and answer in one scrolling column, ChatGPT-style. That's the wrong model for
this app specifically: Orion's whole premise is that a developer returns to a specific answer as
reference material (Docs/04 §6, "the Codebase Model should be queryable independently of any
individual conversation"), not that they're having one continuous conversation. Finding what you
asked about `SessionStore` two days ago meant scrolling past every unrelated question in between,
reading each one's full answer body to identify it — the opposite of what a reference tool should
feel like, and a real regression from how the rest of this app already works (a scannable list,
click through to detail).

**The fix: master-detail, matching the rest of the app instead of a chat app.** Ask is now two
columns, not one flowing feed:

- **Left — a question list grouped by component**, not filtered by a row of pill buttons (an
  earlier pass tried pills here and it doesn't scale: a horizontal row either wraps or scrolls
  sideways once there are more than a handful of components, and one long component name can blow
  out a pill's width on its own — a real failure mode, not a hypothetical one). Grouping instead of
  filtering means the same information organizes the list *by construction*: each component gets a
  collapsible section header (name, count, chevron — click to collapse/expand), and a long name
  just truncates with an ellipsis in its own row instead of breaking anything, because a section
  header is a single block-level row, not an item competing for horizontal space with others. A
  search field above the groups filters question text within them (auto-expanding every group while
  a search is active, so a match is never hidden behind a collapsed section). Each row underneath a
  group header is just the question text (2-line clamp) plus a small outcome dot and a relative
  time — the component name is no longer repeated per-row since the group header already says it.
  This is the actual fix for "hard to find a specific answer": scan short titles under the group you
  care about, instead of scrolling past long answer bodies or a sideways-scrolling filter bar.
- **Right — the selected question's full answer**, exactly the content the old transcript entry
  had: outcome label (including the Docs/12 Risk #5 "Not independently checked" treatment for
  ungrounded depth-1 answers), the answer text, claims with clickable evidence, and routing detail
  behind "Explain."
- **The input bar stays full-width at the bottom**, spanning both columns. Asking a new question
  still shows the thinking→resolved transition immediately in the right pane (hiding that latency
  behind a spinner, Docs/05 §5's "the user should not need to understand the routing mechanism," is
  still the point) — it also adds a new row to the top of the left list, so the question is
  simultaneously answered *and* filed for later, not one or the other.

This is also what makes the "Ask about {name}" button (4.5) meaningful rather than just a shortcut
to typing: the question it asks lands in the list tagged with that component, so a developer
exploring several components ends up with an organized, searchable set of answers about each one —
closer to building a personal reference of the codebase than to chat history.

- **SwiftUI mapping:** `AskRunner`, `AskResultSummary`, `AskOutcome` all stay exactly as Docs/13 M7
  built them — no backend change. The left column is a `List` with `Section(header:)` per component
  (native `List` sections already collapse/expand and already truncate a too-long header with an
  ellipsis for free — this is one of the few places the redesign gets a real SwiftUI feature for
  free that the prototype had to hand-build in HTML/CSS); the right side is the detail pane, laid
  out as `NavigationSplitView` (or a plain `HStack` of the `List` + detail, given this is already
  nested inside the app's outer `NavigationSplitView`). Both are bound to an array of past
  `AskResultSummary`/question pairs kept in a new small `@Observable AskHistory` object
  (`AskView.swift`'s current `[AskTranscriptEntry]` array is almost this already — it mainly needs a
  `selectedID` and, per question, which component it was about, which has to come from somewhere:
  either the "Ask about {name}" call site passes it explicitly, or it's left `nil`/"General" for
  questions typed directly into the input bar, same as the prototype's sample data does).

### 4.7 Model Changes — new, implements Docs/05 Stage 6 (currently unbuilt)

A timeline of "Understanding updated" entries, each collapsed to a one-line summary with an
unread-style badge count in the sidebar, expanding to the exact Docs/05 shape: **Previously / Now
/ Reason**. This did not exist anywhere in the shipped Phase 4 app — Stage 6 was a real gap.

- **What has to be built, not just restyled:** there is currently no persisted record of model
  revisions to render here. The minimum backing this needs is a new small table (or a derived
  view over existing tables) recording, per investigation, which claims/relationships were added,
  superseded, or reversed since the previous investigation on the same repository — this is new
  scope for `OrionCodeIntel`/`CodebaseModelStore`, not something `Model/ArchitectureModel.swift`
  already has. Treat this as its own milestone before wiring the view; the prototype's two
  timeline entries are illustrative sample data, not derived from anything real yet.
- **SwiftUI mapping (once the data exists):** a `List` of a new `ModelChangeSummary` struct
  (title, when, before, after, reason), each row a `DisclosureGroup`.

### 4.8 Teaching Mode — new, implements Docs/05 Stage 7 (currently unbuilt)

Docs/05's loop (Explain → Question → Developer answer → Evaluation → Correction → Transfer
problem) rendered as one scrolling column with each stage labeled by a small eyebrow, so the
pedagogical structure is visible rather than implied: a short **Explain** primer, then the
**Question**, a text-area **Your Answer**, and — after submitting — an **Evaluation** (verdict +
why), a **Correction**, and a **Transfer Problem** to try next.

- **What has to be built, not just restyled:** entirely new backend scope. "The system evaluates
  conceptual understanding, not wording similarity" (Docs/05 §7) is itself a real agent-design
  problem — almost certainly a new prompt/schema for the Claude-Code or local-model path, plus new
  persistence for a developer's per-component learning history if this is meant to improve over
  time. This phase only designed the *shape* of the conversation; the evaluation logic is
  unscoped and should get its own planning doc before implementation (likely a Phase 6, given the
  size of "design an LLM-graded teaching loop" versus the rest of this UI pass).
- **SwiftUI mapping (shape only):** a small local state machine (`.explaining → .answering →
  .evaluated`) very similar to `SemanticInvestigationSession`'s pattern; the real work is what
  populates `Evaluation`/`Correction`/`TransferProblem`, which doesn't exist yet.

### 4.9 Diagnostics — new, implements Docs/05 §8's "advanced diagnostic view"

Docs/05 explicitly reserves this: "an advanced diagnostic view may later expose deeper traces for
expert users." This phase gives it a real home — a sidebar destination visually set apart
("Advanced" section) rather than a per-screen disclosure, showing the routing decision + full tool
trace for the last Ask call and the raw pipeline stage log with timestamps.

- **SwiftUI mapping:** this is almost entirely already-computed data with nowhere to live.
  `AskResultSummary` already carries `routingMethod`, `routingConfidence`, `rationale`,
  `toolCalls` (currently only shown per-answer behind AskView's own "Explain"); `AnalysisProgressTracker.stageHistory`
  already has full stage+timestamp data (currently only shown behind `AnalysisProgressView`'s
  disclosure, and only during analysis, not after). Making Diagnostics a persistent destination
  means holding onto the *last* Ask result's trace and the completed run's stage history in
  `RepositorySession`/a small new `DiagnosticsSession` object, rather than only ever rendering them
  inline and losing them once their originating view disappears.

### 4.10 Build Architecture Model sheet — restyle of `BuildArchitectureModelSheet`

Same cost-ceiling stepper and Start/Cancel actions, restyled with an icon-led header and clearer
visual separation between the explanatory copy and the cost control (Docs/06 §6 / HAX G16 —
"convey the consequences of user actions" before the action, not after). Stays a real `.sheet`
(this is a deliberate interrupt with a financial/time cost, unlike Ask/Model Changes).

- **SwiftUI mapping:** no logic changes — `SemanticInvestigationRunner.run(...)` is called exactly
  as today; only the sheet's internal layout changes.

### 4.11 Evidence viewer — restyle of `EvidenceView`

Same monospace source snippet with the cited range highlighted; kept as a `.sheet` for the same
reason as 4.10 (a short, deliberate look-away, not a destination).

## 5. What did *not* change

- Every existing `Model/` and `Ingestion/` type (`RepositorySession`, `ArchitectureModelLoader`,
  `ComponentDetailLoader`, `AskRunner`, `SemanticInvestigationRunner`, `ClaudeBinaryLocator`,
  `AnalysisProgressTracker`) — this phase is a `Views/`-and-navigation-layer redesign only.
- The two live bug fixes from Phase 4 (the SQLite reopen-crash guard in `AnalysisRunner`, and
  `ClaudeBinaryLocator`'s PATH resolution) — untouched, still load-bearing.
- The epistemic and confidence *hues* themselves (Docs/04 §3's FACT=green through
  CONTRADICTED=red, and confidence's blue/amber/orange/gray) — only their OKLCH re-expression and
  the badge *shape* changed, not the underlying color-to-meaning mapping the shipped app already
  committed to.

## 6. How to revise this

The prototype is a Claude Design canvas — open the link, and if your account has saving enabled
you can click any element to select it, edit text and colors inline, and hit Save to publish a new
version at the same link. If you'd rather edit the source directly: `Docs/phase4_5_design/Main.dc.html`
is the interactive shell (all state and copy live in the `class Component extends DCLogic` block
near the bottom — `NODES`/`EDGES_RAW`/`DETAILS`/`ASK_SEED`/`TIMELINE_SEED` are the sample data,
`renderVals()` is where every color/label mapping happens), `Legend.dc.html` is the static
token sheet (plain HTML, no logic, safe to hand-edit). Ask me to re-seed and republish after any
source edit — that's a couple of one-line commands, not a rebuild.

## 7. Decisions

The three open questions from the earlier draft are resolved:

1. **Inspector width** — constrained, not free-floating: `.inspectorColumnWidth(min: 308, ideal: 308)`.
   The prototype's fixed 308px already reads correctly, so `min`/`ideal` both lock to it; leaving
   `max` unconstrained still lets someone drag it wider without ever letting it collapse to
   something narrower than what the design was actually proven at.
2. **Diagnostics' data lifetime** — only the *last* Ask result and the *last* completed analysis
   run, never a rolling history. `DiagnosticsSession` (M8) is two overwritable optionals, not a log.
3. **Model Changes' backing data (4.7) and Teaching Mode's evaluation logic (4.8) stay unimplemented
   on purpose.** This phase deliberately designed the frontend before either backend, because
   neither backend's real behavior is understood yet — the UI here isn't meant to establish that
   domain model, it's meant to pin down what UX the eventual backend design has to support. M6 and
   M7 below build both screens for real in SwiftUI, backed by the same fixed sample data the
   prototype uses, not a real data source — wiring either to something real waits for its own
   backend design pass (Docs/13-style), most likely a Phase 6.

## 8. Implementation plan — SwiftUI milestones

Executed the same way Docs/13 was: one milestone at a time, each landing real working code and
tests against `OrionApp/`, with this doc updated with a `[done]` marker and real findings before
the next one starts. Say "proceed to M\<n\>" to begin one. Every milestone that touches an existing
file keeps that file's current public API stable unless a section below says otherwise, so a
milestone landing early never blocks the ones after it from compiling.

### M0 — Design tokens & shared components `[done]`

**Goal:** the new visual vocabulary exists before any screen changes shape, so every later
milestone builds with it instead of inventing its own colors again.

- **New `OrionApp/Orion/Views/Shared/DesignTokens.swift`.** Real finding, not the vague "convert by
  eye" this milestone assumed: SwiftUI has no OKLCH initializer, but the OKLCH→sRGB conversion is a
  well-defined, standard formula (Oklab → linear sRGB → gamma-corrected sRGB), so every token was
  converted *computationally* from `Main.dc.html`'s own `:root`/`.dark` values, not eyeballed —
  precise, reproducible, and re-derivable if a token's OKLCH value ever changes. `DesignTokens`
  deliberately only holds the palette that carries meaning specific to Orion: `accent`/`accentStrong`,
  the 5 epistemic hues, and the 4 confidence hues — nothing for backgrounds, borders, or text, all
  of which map to existing macOS semantic colors/materials instead (see below). Light/dark switching
  is a single `NSColor(name: nil) { appearance in ... }` dynamic-provider closure per token, wrapped
  as `Color(nsColor:)` — the code-only equivalent of an Asset Catalog color set's Any/Dark pair,
  without 20 `.colorset` folders.
- **Confirmed against the real macOS 26.5 SDK, not assumed:** `SwiftUICore`'s `glassEffect(_:in:)`,
  `Glass` (`.regular`/`.clear`/`.tint(_:)`/`.interactive(_:)`), and `GlassEffectContainer`, plus
  `SwiftUI`'s `.glass`/`.glassProminent` button styles, all genuinely exist and all require exactly
  `macOS 26.0+` — matching `project.yml`'s deployment target precisely, so no availability guarding
  is needed anywhere this gets used. These are for *custom* views that want to explicitly opt into
  the glass material. Standard `NavigationSplitView`/`.toolbar`/`.inspector` chrome (which is what
  M1's sidebar/toolbar/inspector actually are) already renders as Liquid Glass automatically on
  macOS 26 — Apple's own point that Tahoe applies it to Toolbar/Sidebar/Menu Bar/Dock without any
  app code. So M1 needs **no** manual glass code for the shell itself; `.glassEffect()`/`.glass`/
  `.glassProminent` are reserved for later milestones' custom controls (e.g. primary buttons in the
  Welcome/Build Model/Ask screens, M2/M4/M5) that should visually match the system's own glass
  controls rather than looking like a pre-Tahoe bordered button.
- `DesignTokens.Radius`/`DesignTokens.Spacing` hold §3's radius/spacing scale, replacing the ad-hoc
  literals scattered per-view — not yet applied to any existing view (that happens as each screen
  is touched in M2+, not retroactively in M0).
- Rewrote `ConfidenceBadge`'s body to the outlined-capsule + 3-bar signal-meter shape from §3, using
  `DesignTokens`'s confidence hues. `EpistemicTag.color` now returns `DesignTokens`'s epistemic hues
  too (same green/purple/indigo/gray/red hue families as before, tuned per-appearance) — `EpistemicBadge`
  itself needed no code change, since it already just renders whatever `tag.color` returns.
- **Verification:** full `OrionAppTests` suite (88 tests) green, including `EpistemicTagTests`'
  `testAllFiveTagsHaveDistinctColorsFromEachOther` — a real risk worth calling out: that test
  compares `Color` values with `XCTAssertNotEqual`, and it wasn't obvious in advance whether two
  `Color(nsColor:)` values built from different `NSColor(name: nil, dynamicProvider:)` closures
  would compare as unequal correctly rather than by some appearance-dependent runtime quirk. They
  do — confirmed by the test passing, not assumed. `ComponentDetailView`/`AskView`/
  `ArchitectureOverviewView` (the existing call sites) needed zero changes since `ConfidenceBadge`'s
  and `EpistemicBadge`'s public API didn't move, only their bodies did.

### M1 — App shell: sidebar, toolbar, inspector plumbing `[done]`

**Goal:** the navigation skeleton from §4.1 exists, with every current screen dropped into it
largely unchanged in content — this milestone is structure only, not any one screen's redesign.

- **New `Model/AppShellState.swift`:** `Destination` (`.overview, .ask, .changes, .teaching,
  .diagnostics`, with `.primary`/`.advanced` groupings for the sidebar's two sections) and
  `InspectorContent` (`.node(ArchitectureNode)`/`.openQuestions`), both owned by a small
  `@Observable AppShellState` recreated on every fresh repository open (same place
  `SemanticInvestigationSession` already gets reset in `ContentView`'s `.task(id:)`).
- **`ContentView`'s `.ready` branch rebuilt as `NavigationSplitView`:** sidebar (repo identity via
  `safeAreaInset(edge: .top)`, the destination `List(selection:)` with its "Advanced" section, Build
  Architecture Model status + "Open Another Repository" via `safeAreaInset(edge: .bottom)`) and a
  detail column switching on `shellState.destination`. `.overview` and `.ask` render the existing
  `ArchitectureOverviewView`/`AskView` completely unchanged — Ask just moved from a `.sheet` to
  inline destination content. `.changes`/`.teaching`/`.diagnostics` show a small
  `ContentUnavailableView` placeholder naming the real milestone that builds them (M6/M7/M8), so the
  sidebar's final 5-destination shape is real now instead of hidden until each screen exists.
- **Real correction to this doc's own plan, caught against the SDK, not assumed:** §4.5 and this
  milestone's own first draft said `.inspector(item:)` — that overload doesn't exist. The real
  macOS 26 SDK only has `.inspector(isPresented: Binding<Bool>) { content }` plus
  `.inspectorColumnWidth(min:ideal:max:)`/`.inspectorColumnWidth(_:)`. Implemented as a computed
  `Binding<Bool>` derived from `shellState.inspectorContent != nil`, clearing it back to `nil` when
  the system sets `isPresented` to `false`. `.inspectorColumnWidth(min: 308, ideal: 308)` per
  Decision 1. The inspector's actual content is still `EmptyView()` for every case — Docs/14 §8 M3
  is what makes `ArchitectureOverviewView` populate `inspectorContent` and moves
  `ComponentDetailView`'s content into it; M1 only had to prove the modifier's shape compiles and
  holds the right width.
- One small, justified content change while relocating: `semanticInvestigationSection`'s three
  non-idle cases used `.trailing` `VStack` alignment, which only made sense beside the identity
  block in the old horizontal header. Now that it's alone in a vertical sidebar footer, that's
  `.leading` — the only edit to that view's actual content; everything else about it (states,
  labels, button actions) is untouched.
- **Verification:** full `OrionAppTests` suite (88 tests) green. Manual click-through was only
  partly possible through UI scripting — `System Events`/AXPress-driven clicks on the sidebar's
  `List` rows were unreliable for actually changing selection (a documented limitation from Docs/13
  M2-M4: this app's custom SwiftUI controls don't reliably respond to synthetic AX clicks), even
  with a coordinate-accurate click confirmed to hit the right element. Rather than accept that as
  "probably fine," verified the routing for real by temporarily swapping `AppShellState`'s default
  `destination` to `.ask` and then to `.changes`, rebuilding, and screenshotting a real repository
  reopen (starlette, reusing its existing analysis via the Docs/13 M5 SQLite-reopen-crash fix) each
  time — confirmed the sidebar highlights the right row, the toolbar title updates, `AskView`
  renders its real empty state inline, and the `.changes` placeholder shows the correct milestone
  name, before reverting the default back to `.overview`. The Open Repository sheet's Recent-list
  click-to-reopen flow (used to drive this check) also confirmed working unchanged through the new
  shell. Also visible in the same screenshots: the real `starlette` investigation's Open Questions
  banner at its actual production shape — 6 items, one over 150 words — independently confirming
  the M3/§4.4 scaling problem this doc's §4.4 already redesigned around was a real, not
  hypothetical, concern.

### M2 — Welcome, Open Repository, Analysis Progress `[done]`

- **Split `OpenRepositoryView` into a shared `OpenRepositoryForm`** (the actual Local Folder/GitHub
  URL/Recents content, unchanged logic, `.buttonStyle(.glassProminent)` on its primary actions
  since M0 confirmed that's real macOS 26 API) **plus a thin `OpenRepositoryView` wrapper** that's
  now only the "Open Another Repository" sheet — exactly the reuse §4.2 called for.
- **New `WelcomeView`** replaces `ContentView.emptyState`: the product-thesis headline next to the
  same `OpenRepositoryForm`, embedded directly instead of hidden behind a button.
  `linkedLibrariesFooter` moved here verbatim from `ContentView`.
- **A real bug, caught visually and fixed, not shipped:** embedding `OpenRepositoryForm` inside
  `WelcomeView`'s `ScrollView` made its Recent list silently disappear — a `List` nested inside a
  `ScrollView` with no explicit height collapses instead of showing rows, a genuine SwiftUI layout
  gotcha, not something a compiler or the test suite would ever catch. Fixed by giving the `List` a
  bounded `.frame(minHeight: 120, maxHeight: 240)` and dropping the redundant outer `ScrollView` in
  `WelcomeView` (the form doesn't need one now that its own list is height-bounded). Caught only
  because this milestone's own screenshots were compared against what the code was supposed to
  render, not just "did it build."
- **`AnalysisProgressView` rebuilt as the 4-phase stepper** (pending outline → active spinner →
  done checkmark) from §4.3, reading `AnalysisProgressStage.allCases` directly against
  `progress.currentStage`; the internal per-stage log moved into a closed-by-default "Advanced"
  disclosure. Added `AnalysisProgressStage.uiPhaseIndex(for:)` next to the existing `uiStage(for:)`.
  Since `.idle` now shows `WelcomeView`'s embedded form directly, `ContentView`'s top-level toolbar
  button and the now-redundant `isPresentingOpenSheet = true` in `errorState`'s "Try Again" both
  came out — nothing left needed them.
- **Verification:** full `OrionAppTests` suite (90 tests: 88 + 2 new `uiPhaseIndex` cases) green.
  Live end-to-end check, not just a build: opened a genuinely fresh (never-before-analyzed) local
  folder through the real `WelcomeView` → `OpenRepositoryForm` → NSOpenPanel flow and watched it
  reach `.ready` — confirming the Welcome screen's Recent list (after the fix above), the Local
  Folder picker, and the merged idle/analyzing/ready flow all work together for real, not just
  independently. Separately, pointed the same flow at a ~12,700-file directory (this repo's own
  `.venv`) specifically to slow analysis down enough to screenshot the stepper mid-run — captured
  "Mapping repository structure" done, "Verifying dependencies" active with its spinner, and the
  other two phases correctly still pending, exactly matching the redesign. That run also happened
  to confirm a pre-existing edge case still holds: analyzing a directory that resolves to zero
  source files reaches `.ready` with a graceful "No architecture data yet" empty state rather than
  failing or crashing. Test-only recent-repository entries and their `.orion` output directories
  were removed afterward rather than left behind.

### M3 — Architecture Overview, Component Inspector, Open Questions panel `[done]`

- **`InspectorContent` grew payloads**: `.node(ArchitectureNode, ArchitectureLayer)` and
  `.openQuestions([String])`, not bare `.node(ArchitectureNode)`/`.openQuestions`. `ContentView`'s
  inspector needed `ArchitectureLayer` (for `ComponentDetailView`'s structural-vs-semantic
  treatment) and the uncertainties list, and `ArchitectureOverviewView` already has both the moment
  a node or the strip is tapped — riding them along on the enum avoided lifting the loaded
  `ArchitectureModel` up to `ContentView` just to duplicate what Overview already loaded.
- **`AppShellState.destination` became a computed property** whose setter clears
  `inspectorContent` whenever the destination actually changes (a no-op reselect doesn't touch it).
  This is what makes the inspector correctly Overview-only without duplicating that rule at every
  call site — the sidebar's selection binding, and `ComponentDetailView`'s new "Ask about" button,
  both just set `shellState.destination` and get the clearing for free.
- **`ArchitectureOverviewView`**: the old always-expanded Open Questions section is now
  `openQuestionsStrip(_:)` — one line (icon, count, first question truncated, chevron), tapping it
  sets `.openQuestions`. Node taps (both the diagram's tap gesture and the accessible List's
  buttons) set `.node(node, model.layer)`. Its own `.sheet(item:)` is gone entirely.
- **`ComponentDetailView`**: dropped its own `header(_:)` (name is now the inspector's shared
  title, drawn once by `ContentView`, not duplicated); gained the "Ask about {name}" button right
  under the confidence badge. For now that button only does `shellState.destination = .ask` — a
  real, working jump to the Ask destination (which also closes the inspector, via the
  `AppShellState` setter above) — not yet a prefilled/auto-asked/tagged question, since `AskView`
  has nowhere to put one until its own §8 M4 redesign.
- **New `OpenQuestionsPanel`**: the `.openQuestions` case's content — every uncertainty in full,
  each with its `EpistemicBadge(.unknown)`, scrollable.
- **Verification:** full `OrionAppTests` suite (95 tests: 90 + 5 new `AppShellStateTests` covering
  mutual exclusivity and the destination-change clearing rule, both directions).
  `ArchitectureModelLoaderTests`/`ComponentDetailLoaderTests` untouched, as expected — pure loader
  logic, no changes. Live end-to-end check against the real `starlette` investigation (not just the
  unit tests): opened the Open Questions strip and confirmed the real 6-question panel renders with
  the shared close button; switched to List mode and opened "Authentication & Sessions," confirming
  the inspector shows its real Purpose/Members/confidence content with the new "Ask about" button
  in place; clicked that button and confirmed it lands on the Ask destination with the inspector
  correctly closed — the full Overview → inspector → Ask hand-off working end-to-end, not just each
  piece in isolation.

### M4 — Ask redesign + Overview→Ask hand-off `[done]`

- **New `Model/AskHistory.swift`** — an `@Observable` class holding `[AskHistoryEntry]`
  (question/component-tag/timestamp/outcome) plus the selected id, owned by `ContentView` like
  `AppShellState`/`SemanticInvestigationSession`. This isn't a style choice: `destinationContent(_:)`'s
  `switch` gives `.ask` its own view identity, so a plain `@State` transcript array *inside*
  `AskView` would reset every time the destination switches away from `.ask` and back — silently
  reproducing the exact "Ask forgets everything" problem this whole redesign exists to fix (Docs/04
  §6). Caught by reasoning about SwiftUI's identity rules before writing the view, not after
  finding it empty. `AskHistory.groups(matching:)` (component-grouped, "General" last, filtered by
  a case-insensitive substring match) and `AskHistory.handoffQuestion(forComponentNamed:)` are pure
  functions on this class specifically so M4's grouping/search/hand-off logic is unit-testable
  without driving `AskView`/`ComponentDetailView` themselves.
- **`AskView` rebuilt as master-detail**: a `List` of `Section(_:isExpanded:)` per component (a
  real, verified-against-the-SDK collapsible section API, not assumed — confirmed at
  `SwiftUI.Section.init(_:isExpanded:content:)`) on the left, a search field above it, the selected
  entry's full answer (unchanged `AskEntryView` content: outcome label, claims, "Explain") on the
  right, one full-width input bar underneath both. `.listStyle(.sidebar)` is what actually makes
  the section disclosure triangles render — a small, deliberate visual trade (this list picks up
  a bit of the app's real sidebar's vibrancy/selection styling) for a genuinely native collapse
  behavior instead of hand-rolling one.
- **`ComponentDetailView`'s "Ask about {name}" button does the real thing now**: builds the
  hand-off question via `AskHistory.handoffQuestion(forComponentNamed:)`, switches to `.ask`,
  files a component-tagged entry, and kicks off the actual `AskRunner.ask(...)` call — landing
  exactly where M3 left a `shellState.destination = .ask`-only stub.
- **Verification:** full `OrionAppTests` suite (105 tests: 95 + 10 new `AskHistoryTests` covering
  insertion order/selection, resolving by id, grouping/sorting/filtering, and the hand-off producing
  a correctly-tagged entry) — existing `AskRunnerTests` untouched, no change to `AskRunner`/`AgentSession`.
  Live end-to-end check, and a demanding one: from a real component's inspector, clicked "Ask about
  Authentication & Sessions" and watched it land on the Ask destination with a real
  "Authentication & Sessions" section already containing "Tell me more about Authentication &
  Sessions." selected and showing the real "Thinking…" state — i.e. this actually invoked the
  production `AskRunner`/`AgentSession`/local-model path, not a fixture. Waited it out: it resolved
  to a real "Partially Verified" answer a couple of minutes later, with a genuine `CONTRADICTED`/
  Medium-confidence claim and real clickable evidence anchors into `starlette/middleware/sessions.py`
  — confirming not just that the hand-off reaches `AskRunner`, but that the whole result (outcome
  label, claims, epistemic badges, evidence) renders correctly in the new detail pane exactly as
  the unchanged `AskEntryView` always did, and that the list row itself updated from a spinner to a
  green checkmark with the timestamp advancing, live.

### M5 — Build Architecture Model sheet & Evidence viewer restyle `[done]`

- **`BuildArchitectureModelSheet`**: icon-led header (a sparkles glyph tinted
  `DesignTokens.interpretation` — the same hue the "Semantic view" banner renders in once this
  investigation completes, since that's exactly the knowledge tier it produces), the cost-ceiling
  `Stepper` set apart in its own card so the real consequence (a paid API call, several minutes)
  reads clearly before the button, not after (Docs/06 §6 / HAX G16). "Start Investigation"/"Cancel"
  now use `.glassProminent`/`.glass` — real macOS 26 button styles, confirmed to exist in M0, used
  for the first time here.
- **`EvidenceView`**: the highlighted cited range now uses `DesignTokens.accent` instead of a plain
  yellow (matching every other "this is what's being pointed at" treatment in the redesign rather
  than reading as an unrelated editor-warning color), plus an explicit close button — the sheet
  previously had no visible way to dismiss it beyond Escape, a real if minor gap. Neither
  `SemanticInvestigationRunner` nor `EvidenceSourceLoader` changed at all, as planned.
- **An unplanned but real bug, found live while manually verifying this milestone's own sheets, not
  part of M5's scope — fixed anyway rather than left for later**: reopening `starlette` to check
  the restyled Build Architecture Model sheet showed the Architecture Overview had silently
  regressed to "Structural view — no architecture investigation yet," even though a real semantic
  investigation from M1-M4's own testing still existed. Root cause: `investigations` is one shared
  SQL table for both a whole-architecture "Build Architecture Model" pass and every one-off Ask
  question answered at depth 3, with no `kind` column distinguishing them —
  `ArchitectureModelLoader.load()` called `CodebaseModelStore.latestInvestigation(runId:)`, which
  just grabs the single newest row of *either* kind. M4's own live verification had asked several
  real depth-3 questions against `starlette` after its architecture investigation, so the "latest
  investigation" became an Ask investigation with zero components, and the loader fell back to
  structural — silently, with the real components still sitting untouched in the database the
  whole time. Confirmed by reading `investigations` directly (`sqlite3 orion.db`) before touching
  any code, not guessed at. Fixed by filtering to the one stable, pre-existing discriminator that
  already happens to exist: `SemanticImporter`'s architecture-investigation rows always carry the
  literal marker `question = "phase2_semantic_grouping"` (the column's own SQL default in
  `Migrations.swift`), which an Ask investigation's real question text never collides with. New
  `ArchitectureModelLoader.latestArchitectureInvestigation(store:runId:)` filters to that marker
  before taking the newest row — a one-function fix, no schema migration.
- **Verification:** full `OrionAppTests` suite (106 tests: 105 + 1 new regression test —
  `testLoadStaysOnTheSemanticModelAfterALaterAskInvestigation` — that inserts a later, real-shaped
  Ask investigation row after a real architecture investigation and asserts the loader still
  returns `.semantic`, reproducing the exact live sequence that broke). Then confirmed against the
  actual `starlette` database that exposed the bug in the first place: reopened it and watched
  Overview correctly show "Semantic view — 11 components" again instead of the regressed
  structural fallback.

### M6 — Model Changes (UI only, sample-backed — Decision 3) `[done]`

- **New `Model/ModelChangeSummary.swift`**: the `Previously`/`Now`/`Reason` shape plus
  `ModelChangeSample.entries` — Docs/05 Stage 6's own worked example (Authentication,
  Persistence) verbatim, not invented content, so the screen's shape is validated against a real
  spec even though the data behind it is fixed.
- **New `Views/ModelChangesView.swift`**: each entry a `DisclosureGroup` (title + relative time
  collapsed, Previously/Now/Reason expanded), the first entry starting expanded so the screen never
  opens to a wall of collapsed rows.
- **This is the first real sidebar badge** — `sidebarRow(_:)`/`sidebarBadgeCount(for:)` in
  `ContentView` are new, generic infrastructure (not Model-Changes-specific), so Diagnostics or any
  future destination can add a count the same way later without inventing its own mechanism.
- **Verification:** full `OrionAppTests` suite (106 tests, unchanged — this milestone's own plan
  called for no new tests, since there's no backend logic yet to test, only a view over fixed
  data). Live check: reopened `starlette`, confirmed the "2" badge renders next to Model Changes in
  the sidebar, and — since sidebar-row clicks are the same unreliable AX-automation path noted in
  M1 — used the same temporary-default-swap technique to confirm the screen itself: first entry
  expanded showing the exact Docs/05 Stage 6 content (`AuthService → Persistence` /
  `AuthService → SessionManager → SessionStore → Keychain` / the reason text), second entry
  correctly still collapsed.

### M7 — Teaching Mode (UI only, sample-backed — Decision 3) `[done]`

(Implemented after M6, skipping ahead of M8 per direction mid-session — M8/Diagnostics remains
not-started, picked up next.)

- **New `Model/TeachingSample.swift`**: the Explain/Question/Evaluation/Correction/Transfer content
  — the prototype's own "TokenManager vs. SessionManager" scenario verbatim, not invented content.
- **New `Views/TeachingView.swift`**: a two-state machine (`.answering`/`.evaluated`), each stage
  labeled by a small accent-colored eyebrow so Docs/05 Stage 7's pedagogical structure
  (Explain → Question → Answer → Evaluation → Correction → Transfer) is visible, not implied. The
  "Evaluation" verdict reuses `DesignTokens.confidenceMedium` — the same amber "Partially Correct"
  reads as, and literally is, a confidence-shaped judgment, so it borrows that vocabulary rather
  than inventing a fourth color scale. "Try Another"/"Done for Now" both call the same `reset()`,
  clearing both the step and the typed answer.
- **Verification:** full `OrionAppTests` suite (106 tests, unchanged — no backend logic yet to
  test, as planned). Live click-through, and a real automation limitation worth recording
  honestly: driving text into the "Your Answer" `TextEditor` via `System Events`/AX synthetic
  clicks + `keystroke` never actually focused the field (several approaches tried — plain click,
  focus-then-click, double-click via the exact AX element path — all left the field empty), a new
  instance of the same class of custom-SwiftUI-control automation unreliability Docs/13 already
  documented for this app's List rows. Rather than leave the post-submit half unverified, used the
  same temporary-default technique as M1/M6: hardcoded `step = .evaluated` with a sample answer,
  confirmed the Evaluation/Correction/Transfer Problem card renders exactly as designed, clicked
  "Try Another" (a plain `Button`, which *does* respond reliably to synthetic clicks, unlike the
  `TextEditor`) and confirmed `reset()` correctly clears back to a fresh, disabled "Submit Answer"
  state — then reverted the temporary default. One real slip caught by the test suite itself, not
  missed: forgetting to also revert `AppShellState`'s temporary default destination broke
  `AppShellStateTests.testInitialInspectorContentIsNil` on the very next full test run, exactly
  the kind of mistake this milestone's own "always run the full suite before calling it done"
  discipline exists to catch.

### M8 — Diagnostics (last-only — Decision 2) `[done]`

- **New `Model/DiagnosticsSession.swift`**: `@Observable final class DiagnosticsSession` with two
  overwritable optionals — `lastAskTrace: DiagnosticsAskTrace?` and
  `lastAnalysisStages: [DiagnosticsStageEntry]?` — plus `recordAsk(question:outcome:)` and
  `recordAnalysis(stageHistory:)`. `DiagnosticsStageEntry` is a small `Identifiable`/`Equatable`
  wrapper around `AnalysisProgressTracker.stageHistory`'s own `(stage:startedAt:)` tuple (tuples
  can't conform to either protocol, which both the view's `ForEach` and this milestone's test
  need); `DiagnosticsAskTrace` pairs a question with the `AskResultSummary` that already carries
  `routingMethod`/`routingConfidence`/`rationale`/`toolCalls` — exactly §4.9's own "almost entirely
  already-computed data with nowhere to live" observation, confirmed true: no new backend logic,
  just a place to keep the last of each. `recordAsk` deliberately no-ops on a `.failed` outcome
  (nothing to show, and the previous successful trace staying visible is more useful than blanking
  it) rather than overwriting with nothing.
- **New `Views/DiagnosticsView.swift`**: two labeled sections, each with its own honest empty
  state ("No Ask call yet this session." / "No analysis run yet this session.") rather than
  showing nothing.
- **Wired into `ContentView`**: a new `@State diagnosticsSession = DiagnosticsSession()`, reset
  alongside `shellState`/`askHistory` in `.opening`; `recordAnalysis` called right after
  `AnalysisRunner.run` returns in the `.analyzing` case; `diagnosticsSession` threaded into
  `AskView` and `ComponentDetailView` (both call sites that run `AskRunner.ask`), each calling
  `recordAsk` immediately after resolving its own `AskHistory`/entry. The `.diagnostics` case in
  `destinationContent(_:)` now renders `DiagnosticsView` instead of the placeholder —
  `destinationPlaceholder(_:)` itself came out, since nothing else used it.
- **Small, justified addition to `AskRunner.swift`'s stable API**: `AskResultSummary` gained a
  second, explicit memberwise `init` alongside `init(_ result: AgentSessionResult, claims:)`.
  Real finding, not assumed: `AgentSessionResult` (in `OrionAgent`) has no initializer reachable
  outside that module (confirmed during M5), and defining any custom `init` on a struct suppresses
  Swift's synthesized memberwise one — so without this addition, `DiagnosticsSessionTests` would
  have had no way to construct a synthetic `AskResultSummary` at all. Purely additive; the existing
  `init(_:claims:)` and every current call site are untouched.
- **Verification:** full `OrionAppTests` suite (110 tests: 106 + 4 new `DiagnosticsSessionTests`)
  green, including the regression test §8 itself asked for — a second `recordAsk`/`recordAnalysis`
  overwrites rather than accumulates, and a failed Ask leaves the previous trace in place. Live
  verification went further than a build check: opened the real, already-analyzed `starlette`
  checkout (reused from M5's own testing) through the actual Recent-repositories list — a real AX
  finding worth recording, since it contradicts this doc's own running assumption: unlike the
  sidebar's `List`, Recent is an `outline`/row-button AX hierarchy, and `click button 1 of UI
  element 1 of row N of outline 1 ...` selected it reliably on the first try, no coordinate click or
  temporary-default workaround needed. Sidebar `List` row selection (trying to reach Ask directly to
  drive a real end-to-end Ask call into Diagnostics) hit the same pre-existing unreliability as
  always and wasn't worth forcing — the temporary-default technique already covered rendering
  correctness. What that live run confirmed, unplanned: with `AppShellState`'s default temporarily
  pointed at `.diagnostics` and `DiagnosticsSession` temporarily seeded with sample data (the usual
  M1/M6/M7 technique, reverted after), opening starlette actually *exercised the real
  `recordAnalysis` call* — since starlette was already analyzed, `AnalysisRunner` took the
  cache-reuse path (empty `stageHistory`), and that real, empty call correctly overwrote the
  hardcoded 7-stage sample, leaving "No analysis run yet this session." on screen — the exact
  overwrite behavior `DiagnosticsSessionTests` asserts in isolation, now also seen happening for
  real. The hardcoded `lastAskTrace` sample (question/routing/tool-call rows) rendered exactly as
  designed and was correctly left alone, since no real Ask ran that session to overwrite it.
  Confirmed the true empty state (both sections, no seeding) separately. `starlette`'s
  `recent-repositories.json` entry and `.orion/orion.db` content were both left untouched (only the
  SQLite `-shm` sidecar's mtime moved, an ordinary WAL-mode read artifact, not a content change).

### M8.5 — Post-M8 UX bug fixes (user-reported) `[done]`

Six bugs the user found live-testing after M8, not part of §8's original plan. Grounded here by
actually reproducing each one (or, for #4, finding its root cause independently) before writing
this plan — the same discipline every other milestone in this doc uses, applied to a bug report
instead of a fresh screen. One (#1) turned out more serious than its one-line description suggests;
one (#4) isn't in the user's list at all but is the actual mechanism behind their #4 as originally
numbered below, so it's folded into that item rather than kept separate.

1. **Remove the sidebar's stale repo-stats disclosure — reproduced live, serious.** The "135 files
   · 3,225 symbols · 815 relationships" line in `ContentView.sidebarHeader(_:)` is a
   `DisclosureGroup`, carried over verbatim from Docs/13's pre-4.5 header (its own doc comment
   says so: "relocated unchanged from the old `readyHeader`"). Clicking it to expand does not just
   show the Repository/Languages/Resolver detail underneath — it collapses the *entire* sidebar
   (destination list, Build Architecture Model status, Open Another Repository) and the detail
   column to a blank state, reproduced twice via direct AX click, independent of which destination
   or component was showing. Root cause not yet isolated to a single line (candidates: the
   `DisclosureGroup` expanding inside a `List`'s `.safeAreaInset(edge: .top)` fighting the
   `NavigationSplitView` sidebar's own layout pass) — worth a real "why," not just cutting it, since
   the same shape (`DisclosureGroup` inside a `safeAreaInset`) could recur elsewhere.
   - **Fix:** remove the `DisclosureGroup` wrapper; keep the summary counts as plain static text
     (no longer expandable from the sidebar at all). The detail it used to reveal on expand
     (Repository path, Languages, Resolver, the `resolver == "none"` failure-transparency caption
     from Docs/06 §7, parse errors, diagnostics, analysis time) doesn't just disappear — move it
     into Diagnostics (M8) as a new "Repository" section, since Diagnostics is already this app's
     real home for exactly this kind of advanced/rarely-needed detail. This quietly grows M8's
     scope after the fact, which is why it's called out explicitly here instead of silently
     amending M8's own `[done]` entry.
   - **Verification:** confirm the collapse no longer reproduces (click the summary line
     repeatedly, in every destination); screenshot the relocated Repository section in Diagnostics.

2. **Mental model graph: more spacious layout + distinct per-node color.** Currently
   `ArchitectureOverviewView.diagram(_:)` runs Grape's `.manyBody().link().center()` with every
   parameter at its library default (`manyBody(strength: -30)`, `link(originalLength: 30)`), and no
   collision force at all — confirmed against the vendored `Grape` package source
   (`ForceDescriptor.swift`), which is exactly the cramped, overlapping cluster in the user's
   screenshot. Node fill color currently comes from `ConfidenceBadge.color(forTier:)` — a
   4-value confidence palette, not a per-node identity.
   - **Fix — spacing:** increase `manyBody`'s repulsion (more negative `strength`) and `link`'s
     `originalLength`, and add Grape's `.collide(strength:radius:)` force (confirmed real in
     `ForceDescriptor.swift`, not currently used anywhere in this codebase) sized from each node's
     own `radius(for:)` plus a fixed padding, so nodes structurally cannot overlap regardless of how
     the repulsion/link tuning is adjusted later.
   - **Fix — color:** replace `color(for:)`'s confidence-tier mapping with a color derived
     deterministically from `node.id` (hash into a fixed hue palette) — "randomly assigned" in the
     sense the user means (arbitrary, unrelated to confidence, visually distinct component-to-
     component), not literally `Int.random`, which would reshuffle colors on every reload/re-render
     and make "the blue one" meaningless from one session to the next.
   - **Trade-off to flag, not silently decide:** this removes confidence-tier signal from the
     diagram's node fill — previously the one place confidence was visible without opening a node.
     Confidence stays visible in `ConfidenceBadge` inside the inspector and (once #5 below lands)
     the list view's row badge, so no information is actually lost, only relocated — but this is a
     real, deliberate change to what the diagram communicates at a glance, worth surfacing at
     hand-off rather than assuming it's fine.
   - **Verification:** before/after screenshot of the same starlette graph; confirm no visually
     overlapping nodes at default zoom; confirm colors are visually distinct at starlette's actual
     node count (~11 semantic components) and stable across two consecutive reloads of the same
     repo (same node → same color both times).

3. **Move the View Mode control into the destination's title bar.** Currently the Diagram/List
   `Picker` lives inline in `ArchitectureOverviewView.banner(for:)`, competing for space with the
   layer-status line. The user wants it beside the "Architecture Overview" title instead — which is
   `ContentView`'s own `.navigationTitle(shellState.destination.rawValue)`, i.e. the window's
   toolbar/title strip, not a view `ArchitectureOverviewView` renders itself.
   - **Fix:** move the `Picker` out of `banner(for:)` into a `.toolbar { ToolbarItem(placement:
     .primaryAction) { ... } }` attached alongside `.navigationTitle` in
     `ContentView.readyState(_:)`, shown only when `shellState.destination == .overview` (it's
     meaningless on every other destination). `viewMode` itself has to move out of
     `ArchitectureOverviewView`'s local `@State` so `ContentView`'s toolbar closure can read/write
     it — the natural fit is `AppShellState` (it's shell-navigation-shaped state, same category as
     `destination`/`inspectorContent`, not per-load data), following the same "shell-level state,
     not a local `@State` that resets on destination-switch" rule this doc has used since M1.
   - **Verification:** screenshot confirming the control renders next to "Architecture Overview" in
     the title bar, still switches Diagram↔List correctly, and is absent (or inert) on every other
     destination.

4. **Fix stale inspector content when switching components without closing the inspector —
   root-caused independently, not from the user's screenshots.** Reproduced live while grounding
   this plan: opened "Routing & Endpoint Dispatch" in the inspector, then clicked "Authentication
   Framework" without closing it first — the inspector's shared title updated correctly (it reads
   `shellState.inspectorContent` directly in `ContentView.inspectorTitle`), but every other line of
   content (Purpose, Members, Dependencies, Claims, and the "Ask about {name}" button's own name)
   kept showing the *previous* component. Root cause: `ComponentDetailView`'s `@State private var
   detail: ComponentDetail?` is populated by a plain `.task { await load() }`, and
   `ContentView.inspectorBody(_:)` constructs `ComponentDetailView` fresh on every node change but
   gives it no explicit SwiftUI identity — so SwiftUI treats consecutive selections as updates to
   the *same* view instance and never re-runs `.task` at all. This is exactly the user's bug #4
   ("the sheet should update dynamically... without requiring the user to close the sheet first"),
   just with its real mechanism identified rather than only its symptom.
   - **Fix:** give `ComponentDetailView` explicit per-node identity at its call site —
     `.id(node.id)` on the `ComponentDetailView(...)` construction in
     `ContentView.inspectorBody(_:)` — so SwiftUI tears the view down and recreates it (and so every
     `@State` on it: `detail`, `loadError`, `selectedEvidence`) on every node change, rather than
     patching `.task` alone (which would still flash one stale frame before reloading).
   - **Verification:** manual — this is a SwiftUI view-identity bug with no ViewInspector-style unit
     test in this codebase's toolkit; repeat the exact repro above (open one component, click a
     second without closing) and confirm every field updates immediately, no stale frame.

5. **List view: title only by default, description on demand.** `ArchitectureOverviewView.nodeList(_:)`
   currently shows `node.subtitle` under every row's name unconditionally.
   - **Fix:** drop the eager `node.subtitle` `Text` from each row — show only `node.name` (+
     `ConfidenceBadge` if present). Tapping a row already opens the full inspector (Purpose/
     Members/Dependencies/Claims, including the subtitle-equivalent "Purpose" section) via the
     existing `shellState.inspectorContent = .node(...)`, so hiding it in the list loses no
     information — it stops appearing twice (once cluttering the list, once properly in the
     inspector).
   - **Verification:** screenshot of list view showing name-only rows; confirm tapping still opens
     unchanged full detail.

6. **Component-scoped Ask hand-off: empty session, not an auto-question — plus a real general-
   question entry point.** Currently `ComponentDetailView.askAbout(_:)` immediately builds
   `AskHistory.handoffQuestion(forComponentNamed:)` ("Tell me more about {name}.") and fires it
   through `AskRunner.ask` right away — the developer never phrases their own question.
   `AskHistory` also has no notion of "a session scoped to a component with nothing asked yet" —
   every `AskHistoryEntry` is created already carrying real question text, so there's no clean
   place to hang "empty, but scoped" state today.
   - **Fix, conceptually:**
     - `AskHistory` gains a `pendingScope: String?` — "the next question typed in `AskView`'s input
       bar is about this component." `ComponentDetailView.askAbout(_:)` changes to: switch to
       `.ask`, set `history.pendingScope = name`, and stop there — no `AskRunner` call, no entry
       created, until the user actually submits something.
     - `AskView`'s `submit()` reads `history.pendingScope` when filing the entry (`history.ask(question,
       component: history.pendingScope)`), and the input area shows a small, removable "Asking
       about {name}" chip while a scope is pending (clearing it falls through to a general
       question). `pendingScope` clears once the entry is filed.
     - **Separate general-question entry point**, per the user's explicit ask: a plain "Ask a
       general question" affordance (e.g. in `AskView`'s empty state, or always visible above the
       input bar) that explicitly sets `history.pendingScope = nil` — makes "not about any specific
       component" a deliberate, visible choice rather than just whatever's left over when nothing
       else was clicked.
   - **Verification:** new `AskHistoryTests` covering `pendingScope` set by the component hand-off
     and cleared both by filing an entry and by explicitly choosing "general question"; live
     click-through confirming the input field is genuinely empty immediately after clicking "Ask
     about {name}" — not pre-filled, not auto-submitted.

**Ordering note:** M9 (below) is the final full light/dark + accessibility + regression pass across
*every* screen this phase built — it should run after M8.5, not before, so it also covers what M8.5
touches (the relocated Diagnostics Repository section, the retuned diagram, the moved View Mode
control, the reworked Ask hand-off) instead of needing a second pass.

**Implementation notes, all six landed as planned:**

- **Item 1 (disclosure removal):** implemented exactly as planned -- `ContentView.sidebarHeader(_:)`'s
  `DisclosureGroup` replaced with plain static text; its detail moved into `DiagnosticsView`'s new
  `repositorySection(_:)`, which takes `summary: RepositorySummary` (now a required `DiagnosticsView`
  param, threaded from `ContentView`). Root cause was never fully isolated (still worth someone's time
  later if a similar `DisclosureGroup`-in-`safeAreaInset` shape shows up again), but that didn't block
  fixing it. **Live-reproduced fix, not assumed:** repeated the exact repro from this milestone's own
  planning pass (clicking the summary line) against the built app -- no collapse, sidebar and content
  column both stayed intact.
- **Item 2 (graph spacing/color):** implemented as planned -- `.manyBody(strength: -220)`,
  `.link(originalLength: 90.0)`, and a new `.collide(radius: .varied { ... })` sized from each node's
  own `radius(for:)` + 12pt padding. **Two real Grape API mismatches caught by the compiler, not
  guessed correctly on the first try:** `.link(originalLength:)` needs a `Double` (`90.0`, not the
  `Int` literal `90` this plan's own draft used -- `LinkLength` conforms to `ExpressibleByFloatLiteral`
  only); `.collide(radius: .varied { id in ... })`'s closure parameter type couldn't be inferred and
  needed an explicit `(id: String)` annotation. `color(for:)` replaced with a small hand-rolled FNV-1a
  hash over `node.id` into a 12-color palette -- deliberately not `node.id.hashValue` (Swift's
  `Hasher` is seeded per-process for hash-flooding protection, so that would've been stable only
  within one launch, not across relaunches, undermining the "same node, same color" goal this item
  itself set). **Live-confirmed:** starlette's 11-component graph rendered with visibly distinct
  colors and zero overlapping nodes at default zoom -- a dramatic difference from the cramped cluster
  this item's own planning screenshot showed.
- **Item 3 (View Mode relocation):** implemented as planned -- `ArchitectureViewMode` (renamed from
  `ArchitectureOverviewView`'s old private `ViewMode`) now lives on `AppShellState`;
  `ContentView.readyState(_:)` hosts the `Picker` in a `.toolbar { ToolbarItem(placement:
  .primaryAction) { ... } }`, shown only when `shellState.destination == .overview`.
  `ArchitectureOverviewView` reads/writes `shellState.viewMode` directly (a reference type, so no
  `Binding` plumbing needed) instead of owning it locally. **Live-confirmed:** the control now
  renders as a real toolbar element next to "Architecture Overview" (confirmed via the accessibility
  tree, not just a screenshot -- it reports as `radio group 1 of group 1 of toolbar 1`, structurally
  outside the content view now), still switches Diagram↔List correctly.
- **Item 4 (stale inspector content):** implemented exactly as planned -- `.id(node.id)` on the
  `ComponentDetailView(...)` construction in `ContentView.inspectorBody(_:)`. Also removed
  `ComponentDetailView`'s now-unused `diagnosticsSession` param (its only use, the `AskRunner` call
  inside the old `askAbout(_:)`, moved to `AskView` as part of item 6) -- a small cleanup found while
  making this fix, not scope creep. **Live-reproduced fix, not assumed:** repeated the exact original
  repro (open "Routing & Endpoint Dispatch," click "Authentication Framework" without closing) --
  title, Purpose, Members, and the "Ask about" button's name all updated correctly and immediately,
  no stale frame.
- **Item 5 (list view description hiding):** implemented as planned -- dropped `node.subtitle` from
  `nodeList(_:)`'s row content. **Live-confirmed:** list view now shows name + confidence badge only.
- **Item 6 (Ask hand-off redesign):** implemented as planned -- `AskHistory.pendingScope: String?`;
  `ComponentDetailView.askAbout(_:)` now only sets `shellState.destination = .ask` and
  `askHistory.pendingScope = name`, no `AskRunner` call; `AskView` reads `history.pendingScope` in
  `submit()` and shows a removable "Asking about {name}" chip (its × clears the scope -- doubling as
  the "ask a general question instead" affordance this item asked for, without a redundant always-
  visible button for the case where nothing needs clearing). `AskHistory.handoffQuestion(forComponentNamed:)`
  removed entirely (no longer called anywhere) along with the two tests that exercised only it;
  replaced with tests covering `pendingScope`'s own lifecycle. **Live-confirmed, the most important
  check in this milestone:** clicking "Ask about Authentication Framework" switched to Ask with a
  genuinely empty input field (placeholder text, not a canned question), the scope chip showing
  correctly, and the "Ask" button correctly disabled until something is typed -- the exact bug
  behavior this item exists to fix, confirmed gone. Clicking the chip's × correctly reverted to the
  plain general-question empty state.
- **Verification overall:** full `OrionAppTests` suite, 112 tests (112 = 110 after M8, minus 2 removed
  hand-off tests, plus 4 new `AskHistoryTests.pendingScope` tests, unchanged elsewhere) green after
  every fix, including after reverting the temporary-default technique's changes (used twice here --
  once to reach the sidebar's collapse bug reliably via the Recent-repositories list rather than the
  still-unreliable sidebar destination `List`, once to view Diagnostics's new Repository section the
  same way, since sidebar row `List` selection remains the same pre-existing automation limitation
  documented throughout this doc since Docs/13). Every fix in this milestone was confirmed against
  the real, running app, not just read back from the diff.

### M8.6 — Evidence-link layout + LLM answer formatting (user-reported) `[done]`

Two more real bugs found live-testing after M8.5, both about how this app presents text it didn't
author itself (evidence paths, LLM answers) rather than anything it computes.

1. **Evidence-link columns unreadable, gets worse the longer the anchor.** A claim's evidence
   anchors (`starlette/routing.py::Router.lifespan` -- a full repo-relative path plus `::symbol`)
   were laid out in an `HStack`, in both `AskEntryView.claimsSection` (Ask) and
   `ComponentDetailView.claimsList` (the inspector). With more than one anchor and not enough
   width for all of them side by side, each anchor's own `Text` wrapped inside its own narrow
   column instead of using the row's real width -- three anchors became three squeezed, broken-up
   columns of 2-3 characters per line, exactly the failure mode that gets *worse*, not better, as
   symbol names get longer.
   - **Fix:** both `HStack`s became `VStack(alignment: .leading, spacing: 4)` -- one evidence link
     per full-width line. Simple over clever: a custom flow/wrap `Layout` would pack links more
     densely, but one-per-line is unconditionally readable regardless of anchor length, which is
     the actual bug being fixed, and needs no new code beyond changing one container type.
   - **Live-confirmed:** starlette's real "Routing & Endpoint Dispatch" claims (5 evidence anchors
     on one claim, 3 on another) both render as clean, fully-readable one-per-line lists now --
     reached by setting the inspector's AX scroll bar value directly (`1.0`) via `System Events`,
     since neither Page Down nor a synthetic scroll wheel event reached this `ScrollView` and no
     `cliclick`/`Quartz` was available in this environment for a real wheel event -- a new, minor
     automation-environment finding, not an app bug.

2. **`**bold**` shown as literal asterisks in LLM-authored text.** `AskEntryView`'s answer text,
   routing rationale, and claim statements, plus `ComponentDetailView`'s Purpose text (all either
   directly LLM-generated or written by the semantic investigation) were rendered with plain
   `Text(_:)`, which does not parse markdown when given a `String` variable (only a `Text` built
   from a string *literal* gets SwiftUI's automatic `LocalizedStringKey` markdown parsing) -- so a
   model that wrote `**bold**` for emphasis showed literal asterisks.
   - **Fix:** new `Views/Shared/MarkdownText.swift` -- no third-party dependency, built on
     Foundation's own `AttributedString(markdown:options:)` (macOS 12+), parsed with
     `.inlineOnlyPreservingWhitespace` specifically so paragraph breaks and line breaks survive
     exactly as written (the alternative, `.full`, treats blank-line-separated text as separate
     block elements that `Text` has no way to re-render with the original spacing -- wrong for
     this app's plain chat-style paragraphs). Swapped in at every render site named above.
   - **Verification:** `MarkdownTextTests` (4 tests) on the pure `MarkdownText.attributed(_:)`
     function -- bold markers produce a `.stronglyEmphasized` run with the asterisks stripped from
     the string content, blank lines between paragraphs survive, plain text and empty input both
     pass through unchanged/without throwing. Live-confirmed beyond the unit tests, since this is
     exactly the kind of "does it actually render" question a pure-function test can't answer by
     itself: temporarily swapped `WelcomeView`'s subtitle for a `MarkdownText` sample containing
     `**bold**`, `*italic*`, and `` `code` `` (the same temporary-swap-then-revert technique this
     doc has used since M1) -- all three rendered correctly (bold weight, italic slant, monospaced
     code), confirming the fix works in the actual app, not just against `AttributedString`
     directly. Reverted afterward.
   - **Scope note:** applied everywhere real agent/semantic-investigation text is rendered as
     plain `Text` (Ask's answer/rationale/claims, the inspector's Purpose/claims) -- deliberately
     not touched: `ModelChangesView`/`TeachingView`'s sample copy (Docs/14 §7 Decision 3: both are
     explicitly UI-only/sample-backed, not real model output, so this fix's premise doesn't apply
     there yet).
- **Verification overall:** full `OrionAppTests` suite, 116 tests (112 after M8.5, plus 4 new
  `MarkdownTextTests`) green.

### M8.7 — Inspector resize (user-reported) `[done]`

The user's ask: the inspector's current 308px should be the *minimum*, not a fixed width -- make
it resizable wider, with a real maximum.

- **`.inspectorColumnWidth`'s `max` alone doesn't work on this SDK -- confirmed with a real
  trackpad, not just automation.** First attempt was the obvious one: keep `.inspector()`, add
  `.inspectorColumnWidth(min: 308, ideal: 308, max: 480)` (Decision 1 had shipped with no `max` at
  all). Live drag-testing -- `cliclick` (installed via Homebrew for this milestone, since neither
  `osascript`/System Events, `Quartz`, nor `pyautogui` could simulate a real mouse drag) confirmed
  the native inspector column narrows down to `min` (and collapses below it) correctly, but simply
  will not grow past `ideal` no matter what `max` is set to. **Asked the user to try dragging it
  themselves before concluding anything from automation alone** -- they confirmed the same result
  with a real trackpad. That ruled out "this is just a synthetic-input quirk" and confirmed a real,
  reportable limitation of `.inspector()`'s resize on macOS 26.5.
- **First fix attempt -- a hand-rolled `DragGesture` -- worked, but was the wrong tool.** Replaced
  `.inspector()` entirely with a plain `HStack` (`destinationContent` + a manual resize handle +
  the inspector panel), driving width via `@State` and a `DragGesture`. This did work once actually
  hit precisely (confirmed by temporarily widening the invisible hit-target to 40pt to find its
  real screen position first) -- but reinvents, by hand, exactly what a real split-view control
  already does natively: hit-testing, cursor feedback, drag tracking. Reverted before finishing
  tuning it, on the user's own explicit direction to "search and read the proper SwiftUI component
  for this" instead of shipping a hand-rolled substitute.
- **The real fix: `HSplitView`.** Confirmed real in the macOS 26.5 SDK
  (`SwiftUI.swiftinterface`) -- `public struct HSplitView<Content>`, macOS-only (unavailable on
  every other platform), available since macOS 10.15. It wraps `NSSplitView` directly -- the same
  mature, real AppKit divider-drag mechanism that was already confirmed working correctly for
  `NavigationSplitView`'s own sidebar column (live-tested during this same investigation). Replaced
  `.inspector()`/`.inspectorColumnWidth` with `HSplitView { destinationContent(...); if
  shellState.inspectorContent != nil { inspectorBody(...) } }`, using ordinary
  `.frame(minWidth:idealWidth:maxWidth:)` on the inspector pane (308/308/480) instead of a
  SwiftUI-specific modifier -- `HSplitView` reads per-pane sizing the same way any AppKit-backed
  split view does. `.background(.regularMaterial)` on the inspector pane stands in for the Liquid
  Glass chrome `.inspector()` gave for free (Docs/14 §2's own point) -- an approximation, not a
  perfect match, but the resizing actually working matters more here than the exact material.
  `inspectorIsPresented` (the now-unused `.inspector()`-only binding) removed with it.
- **Live-verified, precisely, after learning from an earlier miss:** the first attempt's own
  screen-coordinate math for the hand-rolled handle turned out consistently wrong in a way debug
  instrumentation (temporarily widening the hit-target and coloring it) resolved but never fully
  explained -- so this time, verification read `HSplitView`'s real `AXSplitter` element's position
  directly (via `System Events`) rather than computing an expected coordinate from window/frame
  arithmetic. Confirmed all three behaviors precisely against the live app: dragging left grows the
  panel (splitter moved 997→850, a real ~147px widen); dragging further left stops exactly at
  825 -- `1305 - 825 = 480`, the real max; dragging back right stops exactly at 997 -- `1305 - 997 =
  308`, the real min, **without collapsing** (unlike `.inspector()`'s own min-adjacent behavior).
  The close button (×) still closes the panel entirely, reopening restores cleanly.
- **Verification:** full `OrionAppTests` suite, 116 tests (no logic changed, so an unchanged
  count) green.

### M8.8 — List row hit-area, sidebar header overflow, banner truncation (user-reported) `[done]`

Three more real bugs, live-reproduced from the user's own screenshots before fixing.

1. **List view rows only clickable on the text itself.** `ArchitectureOverviewView.nodeList(_:)`
   wrapped each row in a `Button` whose label was `HStack { Text(node.name); Spacer(); badge }` --
   a `Button`'s hit area is exactly its label's laid-out content, and a `Spacer()` lays out to zero
   *content*, so clicking the empty stretch between the name and the confidence badge did nothing.
   **Fix:** replaced the `Button`-per-row with `List(selection:)` + `.tag(node.id)` -- the same real
   pattern `ContentView.sidebar(_:)` already uses for its own destination rows, not a nested
   tappable control. A `Binding<String?>` (`nodeSelection(_:)`) reads/writes `shellState
   .inspectorContent` by node id, mirroring `sidebarSelection`'s own shape. **Live-confirmed:**
   clicking dead center in the empty space of a row (not on the name, not on the badge) now
   correctly selects it (real `List` selection highlight) and opens the inspector.
2. **Sidebar header text protruding past the sidebar's own width.** `sidebarHeader(_:)`'s two
   `Text`s had no width constraint of their own, so their intrinsic (unwrapped) size could exceed
   the actual sidebar column width instead of wrapping or truncating within it. **Fix:**
   `.frame(maxWidth: .infinity, alignment: .leading)` on the containing `VStack` so both `Text`s
   size against the sidebar's real width; the repository name truncates (`.lineLimit(1)`,
   `.truncationMode(.middle)` -- a long name keeps its meaningful ends visible) and the file/symbol/
   relationship counts wrap instead (`.fixedSize(horizontal: false, vertical: true)`, the same
   technique `WelcomeView`'s own subtitle already uses for this exact shape, since truncating a
   count line would hide real information a developer might want in full). **Live-confirmed:** the
   header now wraps cleanly within the sidebar's bounds instead of extending past it.
3. **Banner text + "Interpretation" badge not filling their row properly once the inspector is
   open.** With the inspector open, `ArchitectureOverviewView.banner(for:)`'s own column narrows a
   lot; its `Label` had no `.lineLimit`, so it wrapped to a second line under pressure instead of
   truncating, throwing off the row's vertical centering against the badge next to it. **Fix:**
   `.lineLimit(1)` + `.truncationMode(.tail)` on the `Label`, `.fixedSize()` on the `EpistemicBadge`
   so it keeps its own compact size instead of being squeezed, `Spacer(minLength: 0)` so the spacer
   collapses fully rather than forcing extra width. **Live-confirmed, under real stress:** widened
   the inspector to its full 480px max (M8.7) specifically to squeeze the banner as hard as
   possible -- the label truncated gracefully on one line ("Semantic view — 11 components,
   investigated 2026-0…") with the badge staying properly aligned and full-sized next to it.
- **Verification:** full `OrionAppTests` suite, 116 tests (no logic changed, so an unchanged count)
  green. All three fixes confirmed against the real running app, not just read back from the diff --
  item 1 by clicking empty row space, item 2 by inspection, item 3 under the specific narrow-column
  stress condition it was reported in.

### M9 — Full pass `[done]`

- **Light/dark check, done live, not by inspection.** Discovered right away that this whole build
  (M0 through M8.8) had only ever been looked at in Dark -- `defaults read -g AppleInterfaceStyle`
  showed the machine's own appearance is Dark, so every prior milestone's screenshots were
  incidentally all one appearance, never confirmed against Light at all until now. Switched the
  system to Light (`osascript ... appearance preferences ... dark mode false`), rebuilt, and went
  screen by screen against the real running app: Welcome, Architecture Overview (diagram, list,
  banner, inspector, Claims & Evidence with its M8.6 one-per-line evidence links and `MarkdownText`
  rendering), Ask's empty state, Model Changes, Teaching Mode, Diagnostics (including its M8.5
  Repository section), the Build Architecture Model sheet, and the Evidence viewer. All clean --
  every `DesignTokens` color, every `.regularMaterial`/`.controlBackgroundColor` panel, every
  hardcoded system color (`.orange`/`.green`/`.blue` captions) read correctly and legibly in Light,
  matching the Legend's own light/dark OKLCH pairs this phase was built from (M0). One genuinely
  nice confirmation along the way: switching the system appearance updated the already-running app
  live, no relaunch needed -- direct proof `DesignTokens.dynamicColor`'s `NSColor(name: nil) {
  appearance in ... }` closures are real dynamic providers, not just resolved once at launch.
  Switched back to Dark afterward and re-checked the same screens plus the specific M8.8 banner
  fix under its own worst-case stress (inspector dragged to its full 480px max) -- identical,
  correct behavior in both appearances.
- **Docs/13 M8 accessible List fallback, re-confirmed.** `ArchitectureOverviewView.nodeList(_:)`
  is still not a sheet (M3 already moved that to the shared inspector) and, after M8.8, is a real
  `List(selection:)` rather than a `Button`-per-row -- if anything a stronger accessible fallback
  than before, since `List` selection is native VoiceOver-navigable behavior the previous
  `Button`-wrapping-`HStack` pattern only partially had (and, per M8.8's own finding, didn't even
  make fully mouse-clickable). Every row still carries its own `.accessibilityHint`.
- **Verification:** full `OrionAppTests` suite, 116 tests, green (no logic changed by this
  milestone -- it's a verification pass, not a code change one). This doc's status line and every
  milestone above already carry `[done]` and real findings as each landed, following Docs/13's own
  convention throughout -- this entry is the final confirmation that held true end to end.

This closes Phase 4.5. Every milestone from M0 through M9 is real, working code in `OrionApp/`,
verified live against the running app at each step -- not just against the prototype it started
from. (This phase's own work has since been committed to `main`, alongside unrelated work in other
areas of the app.)

### Post-completion fix: empty-state placement in Architecture Overview

A real bug reported after M9: with zero modules/components (a genuinely empty or not-yet-analyzed
repository), `ContentUnavailableView("No architecture data yet", ...)` defaulted to centering
itself in the *entire* remaining height of the pane below the banner -- on a normal-sized window,
that put a large, empty dark gap directly under the banner+divider before the message appeared,
reading as if the banner's own backdrop stretched unnaturally far down the screen before anything
else showed up ("the bar with the text 'Structural View' protrudes downward").

Root-caused by live reproduction, not guessed: matched the reporting window's size almost exactly
(computed ~1213×658pt from the reported screenshot's pixel dimensions vs. this session's own
1200×653pt test window) and the exact repository (`pdf-merge`, 0 files), and reproduced the
identical layout on the first try -- confirming this wasn't a stale-build or environment-specific
issue. **Fix:** `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)` +
`.padding(.top, 48)` on the `ContentUnavailableView`, anchoring it just below the banner instead of
true-centering it in the whole pane -- any leftover space now sits at the bottom, not split evenly
above and below the message. Verified against the same `pdf-merge` repository afterward: the empty
state now sits immediately under the banner, matching the fix's intent. Full `OrionAppTests` suite
(132 tests -- grown since M9 from other sessions' own test additions) green throughout.
