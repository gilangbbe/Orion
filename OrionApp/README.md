# Orion (macOS app)

Phase 4 of Orion: the Architecture UI. A SwiftUI app that links `OrionCodeIntel` (Phase 1) and
`OrionAgent` (Phase 3) directly as local Swift packages — no CLI subprocess for anything Orion
itself built. Open a repository, watch it get analyzed, explore its architecture as a diagram
with evidence and confidence attached to every claim, and ask it questions.

Design: [`../Docs/13_phase4_architecture_ui.md`](../Docs/13_phase4_architecture_ui.md).

## Layout

- `Orion/` — the app target's sources (SwiftUI views, the Model/ pure-logic layer, the
  Ingestion/ runners that drive `OrionCodeIntel`/`OrionAgent`).
- `Tests/OrionAppTests/` — unit + fixture-driven integration tests (no live network/API cost —
  every Claude CLI call in the suite is a stand-in shell script, and every local-model call is a
  fake `TurnGenerating`).
- `project.yml` — the [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; **this, not the
  generated `.xcodeproj`, is the source of truth.** Regenerate after any change:
  ```sh
  cd OrionApp && xcodegen generate
  ```
  `OrionApp.xcodeproj` is committed too, so a plain clone-and-open in Xcode works without
  `xcodegen` installed.

## Build & test

Building or testing this project needs `xcodebuild` (or Xcode's own Run/Test), **not** plain
`swift build`/`swift test` — `OrionAgent` links `mlx-swift-lm`, whose Metal shaders are compiled
as an Xcode build phase that plain SwiftPM's build system never runs (the same caveat
`OrionMacOs/README.md` documents for `orion-agent`). Building through this actual Xcode project
handles that correctly, including when launched from Xcode's own Run button — this was a real
gotcha for the *library's* CLI tools (Docs/12), not for this app.

```sh
cd OrionApp
xcodegen generate    # after any project.yml change
xcodebuild -project OrionApp.xcodeproj -scheme Orion -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation build
xcodebuild -project OrionApp.xcodeproj -scheme Orion -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation test
```

`-skipPackagePluginValidation -skipMacroValidation` avoid an interactive plugin-approval prompt
for `mlx-swift`'s (CUDA-only, no-op on macOS) build tool plugin — needed the first time a fresh
checkout builds this project.

The built app lands at `.build/xcodebuild/Build/Products/Debug/Orion.app` (or wherever Xcode's
own DerivedData puts it, if built from the Xcode GUI instead).

## Runtime requirements

- **First local-model question downloads real weights (~4.3GB).** "Ask" (Docs/13 M7) loads
  `mlx-community/Qwen3-8B-4bit` for depth 1/2 questions on first use — the app shows a generic
  "this can take a few minutes" notice, not a real progress bar (Docs/12 M6's own stderr-based
  progress reporter isn't visible from a GUI app). Every run after the first loads from the
  on-disk Hugging Face cache in seconds — see `OrionMacOs/README.md` for the exact cache location.
- **"Build Architecture Model" and depth-3 "Ask" answers need the real `claude` CLI installed.**
  `ClaudeBinaryLocator` resolves its absolute path itself (checking common install locations,
  then a login shell) specifically because a GUI app does *not* inherit an interactive shell's
  `PATH` the way a CLI tool run from Terminal does — found live as a real bug (Docs/13 Risk 13)
  after both features initially failed with "claude did not print a JSON wrapper on stdout" on a
  machine where `claude` was genuinely installed, just not somewhere a bare `env claude` could
  find it. If `claude` isn't installed at all, both features fail with an honest error rather
  than silently doing nothing.
- **Unsandboxed, signed for local execution only** (Docs/13 Decision 4) — no Apple Developer
  Team is assumed; `project.yml` sets ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`) so a fresh
  checkout builds without one. Switch to a real team + Developer ID in Xcode's Signing &
  Capabilities tab whenever distribution is actually needed.

## Status

**M0-M8 done** (Docs/13's full plan) — repository input (local path or a cloned GitHub URL),
live analysis progress, an optional cost-gated Claude Code semantic investigation, a Grape-
rendered architecture diagram (with a fully-accessible List fallback — Grape's own VoiceOver
support is unconfirmed), Component Exploration with a real evidence viewer, a shared
FACT/INTERPRETATION/INFERENCE/UNKNOWN/CONTRADICTED badge vocabulary used everywhere, and "Ask" —
an arbitrary question routed through the same local-model-or-Claude-delegation agent Phase 3
built, with its own clickable evidence. See Docs/13's own milestone-by-milestone log for what
was actually verified live at each step, including two real bugs found and fixed after M5 (a
repository-reopen crash, and the `claude`-`PATH` issue above).
