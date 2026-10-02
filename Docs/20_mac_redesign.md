# 20 — Mac app redesign: Apple HIG + SwiftUI Pro

> Status: **R1–R7 done (2026-10-02).** The whole Mac app is redesigned and verified on the real
> app, in dark and light, on the Pulsed repository.
>
> - **Sync to iPhone is a toolbar button** on every repository window, with a popover holding the
>   switch, the status, Sync Now and what gets uploaded. It's also Repository > Sync to iPhone,
>   and Settings (⌘,) lists every repository that syncs. Verified: the popover's switch is
>   enabled for Pulsed, which means the sync key lookup that Docs/19 M5 never ran now runs.
> - **A second bug found on the way:** opening a repository failed with "database is locked" on
>   `PRAGMA journal_mode = WAL` whenever another connection was busy (here, the user's other Orion).
>   `OrionDatabase` set no busy timeout; it now waits up to 5 s.
> - Suites: 166 Mac app tests (+17, `MacRedesignTests`), 30 iOS tests, and the package suites, all
>   passing.
>
> Results and what wasn't done are under "Results" at the end.

## Why

Docs/19 M5 put a "Sync to iPhone" switch in the Mac app's sidebar footer. On the user's Mac it
never appeared:

- The switch sat in a `Group` that was empty until a `.task` on that same `Group` had looked up
  the repository's library key. A modifier on a `Group` applies to each child, so an empty group
  has nothing to run the task on. The key was never looked up, and the switch never drew, for
  any repository.
- M5's end-to-end check drove sync through `ORION_SYNC_PUBLISH` at launch, so it never exercised
  the switch.
- Even working, it was a mini switch in caption type at the bottom of the sidebar. The HIG says
  to keep critical actions away from there: "Keep critical information/actions away from the
  bottom, which may be offscreen" (Sidebars, macOS).

The user asked for a redesign of the whole Mac app with the `apple-hig` and `swiftui-pro` skills,
as Docs/19 M8 did for the iPhone.

## What the audit found

The app's shape (Docs/14) is sound: a sidebar of destinations, and master/detail inside them. What
doesn't follow the platform:

1. **Actions live in the window body instead of the window frame and menu bar.** Open Another
   Repository, Build Architecture Model and Sync to iPhone are all in the sidebar footer. There is
   no File > Open, no Open Recent, no repository menu, no keyboard shortcut for any of them. HIG:
   "Use the menu bar for easy access to all app commands" and "Every toolbar item must also be a
   menu-bar command" (macOS).
2. **One repository per app.** The window group shares one `RepositorySession`, so File > New
   Window shows the same repository twice. HIG: "Multiple apps and windows are the default".
3. **Liquid Glass in the content layer.** Welcome, Teaching and the Build sheet use `.glass` and
   `.glassProminent` buttons in the window body. HIG: "Don't use Liquid Glass in the content
   layer."
4. **Hand-built lists.** Ask, Teaching and Model Changes draw `ScrollView` + `Button` rows with a
   manual selection tint. They have no keyboard navigation, no native selection colour, and no
   type-select. Docs/14 chose this to dodge `Section(isExpanded:)` bugs in sidebar lists, but plain
   sections in a `List(selection:)` don't have them.
5. **The window says little about where you are.** The title is the destination ("Architecture
   Overview", 21 characters; the HIG asks for under 15), and the repository name sits in a
   sidebar header.
6. **List mode is a list, not a table.** Components have a name, a purpose, a size and a
   confidence. The HIG for macOS tables says to let people sort by a column.
7. **Small things:** `caption2` in many places, `foregroundStyle(.blue)` for links, a debug
   "OrionCodeIntel x · OrionAgent linked" footer on the welcome screen, `String(format:)`,
   `@Observable` classes without `@MainActor`, and several files with more than one type.

## Design

Each change cites the HIG rule it applies.

### The window frame

- **One repository per window.** Each window owns its own session (a `RepositoryWindow` model).
  File > New Window opens a welcome screen next to the open repository.
- **Title and subtitle.** Title is the repository name: "Give each window a useful title to
  confirm location and distinguish windows". Subtitle is the destination. The title has a menu
  (Open Recent, Show in Finder).
- **Sidebar.** Destinations only: Architecture, Ask, Learn, Model Changes, then Diagnostics under
  Advanced. Same names as the iPhone where the two apps share a concept (Learn). Counts use the
  native `.badge`. Nothing at the bottom.
- **Toolbar.** Acts on content: "a toolbar acts on content".
  - Always: **Sync to iPhone**, a toolbar button whose symbol shows the state. It opens a
    popover with the switch, the status, Sync Now, and what gets uploaded. Popovers suit "a
    little information or functionality". The switch lives in the popover, not the toolbar: "Use
    switches, checkboxes, and radio buttons in the window body, not the window frame".
  - Architecture: **Build Architecture Model** (with progress while it runs), the Diagram/List
    segmented control ("consider a segmented control for view switching in a toolbar"), and the
    inspector toggle at the trailing edge ("nearby inspectors").
  - Ask: **New Session**, and search for sessions.
  - Learn: **Practise Next**, and search for concepts.
- **Menu bar.** Every toolbar item has a menu command:
  - File: Open Repository… (⌘O), Clone from GitHub…, Open Recent.
  - View: the five destinations (⌘1–⌘5), as Diagram / as List, plus the system's sidebar and
    inspector commands.
  - **Repository** (app-specific, between View and Window): Build Architecture Model…, Sync to
    iPhone (checkmark), Sync Now, Show in Finder.
- **Settings (⌘,).** One pane, iPhone Sync: the iCloud account state and every repository that
  syncs, each with Stop Syncing. Without it, a repository that isn't open can't be stopped.
  "Handle iCloud being unavailable … unobtrusively noting that changes won't reach other devices."

### The screens

- **Welcome.** Like Xcode's welcome window: the app's name and purpose with Open Folder… and
  Clone from GitHub… on the left, recent repositories in a native list on the right. Double-click
  or Return opens one. No debug footer.
- **Analysis progress.** Kept. Small fixes only.
- **Architecture.** The layer banner with an Open Questions button. Diagram, or a sortable
  `Table` (Component, Purpose, Members, Confidence). The component inspector becomes the native
  `.inspector` if macOS 27 has fixed the resize bug Docs/14 M8.7 hit on 26.5; otherwise the
  existing `HSplitView`. The component detail gets a real header, link-style evidence buttons and
  the system link colour.
- **Ask.** A native `List(selection:)` of sessions in plain sections (General, then per
  component), with Rename and Delete in the context menu. The conversation, with the composer at
  the bottom of the conversation pane (a growing text field and a prominent Ask button).
- **Learn.** A native `List(selection:)` of concepts with mastery meters. The practice pane keeps
  its Explain → Question → Answer → Evaluation → Correction → Transfer flow. Standard bordered
  buttons replace glass, and a growing text field replaces `TextEditor`.
- **Model Changes.** A native list of changes and the shared detail view.
- **Diagnostics.** A grouped `Form`: Repository, Architecture Model (moved out of the sidebar
  footer, with its cost), Last Ask, Last Analysis Run.
- **Sheets.** Clone from GitHub, Build Architecture Model (a form with the cost limit), Rename
  Session. Each has Cancel and a default button.

### Kept on purpose

- `HSplitView` for list | detail inside a destination. Docs/14 M8.7 replaced
  `NavigationSplitView` there because its column could be collapsed with no way back. The
  macOS 27 crash rule stays too: no animated `scrollTo` while a split pane is being inserted.
- The iPhone app is untouched. Shared views change only where the Mac alone uses them.

## Milestones

- **R1 — Window frame.** `RepositoryWindow`, sidebar, title, toolbar, Sync popover (fixes the
  bug), menu commands, Settings.
- **R2 — Welcome, analysis, sheets.**
- **R3 — Architecture.** Table, banner, inspector, component detail.
- **R4 — Ask.**
- **R5 — Learn.**
- **R6 — Model Changes and Diagnostics.**
- **R7 — Verification.** Mac tests, iOS tests (shared code), the package tests, and a screenshot
  walkthrough of every screen in light and dark.

## Verification

- `xcodebuild -scheme Orion test` and the OrionMobile tests stay green.
- New unit tests: the window model (state reset when a new repository opens, the Model Changes
  badge baseline, the sync key lookup), destination titles and shortcuts, table sorting.
- Screenshots of the real app: launched in the background with `ORION_OPEN_REPO` and
  `ORION_DESTINATION` (DEBUG only), then captured with `screencapture -l <window>`.
- Sync to iPhone switched on from the new toolbar popover for Pulsed, then received on the
  iPhone.

## Results

Built as planned, with these specifics and changes of plan:

- **Native inspector.** macOS 27's `.inspector` resizes both ways, so Architecture uses it,
  with View > Show Inspector from `InspectorCommands`. Docs/14 M8.7's `HSplitView` workaround
  for the inspector is gone; list | detail inside Ask, Learn and Model Changes keeps `HSplitView`.
- **One type per file.** The Mac target went from 29 Swift files to 114, in feature folders
  (`Shell`, `Welcome`, `Architecture`, `Ask`, `Learn`, `Changes`, `Diagnostics`, `Sync`,
  `Settings`, `Evidence`). The shell's logic left `ContentView` for `RepositoryWindow`, and Ask's
  submit logic moved into `AskHistory.submit`.
- **Mac-only views left `Shared/`.** `ComponentDetailView`, `EvidenceView` and
  `OpenQuestionsPanel` moved into the Mac target, and the unused `ArchitectureLayerBanner` and
  `ModelChangeRowLabel` were removed. The iPhone app has had its own versions since Docs/19 M8.
- **`@MainActor`** on `AppShellState`, `AskHistory`, `TeachingSession`, `DiagnosticsSession` and
  the new models (SwiftUI Pro); four test classes are now `@MainActor` too.
- **Fixed while checking screenshots:**
  - the Ask composer floated mid-window;
  - member links in the inspector were centred;
  - a claim's full sentence became a huge title on Learn's concept card;
  - SwiftUI turned the Clone sheet's example URL into a link.
- **Launch hooks (DEBUG):** `ORION_OPEN_REPO`, `ORION_DESTINATION`, `ORION_VIEW_MODE`,
  `ORION_INSPECT`, `ORION_SELECT`, `ORION_SHOW` (`Support/LaunchEnvironment.swift`). Screenshots
  came from copies launched in the background and captured with `screencapture -l`. Light mode
  used `-NSRequiresAquaSystemAppearance YES` on the copy, so the system appearance never changed.

**Not done:**

- **Switching sync on for Pulsed and receiving it on the iPhone.** It uploads private code, so
  it's the user's switch to flip.
- **The Settings window's appearance.** It builds and its logic is tested, but it wasn't
  screenshotted: opening Settings needs the app in front.
- **The accessibility audit of the Mac screens.** An XCUITest audit drives the real mouse.
