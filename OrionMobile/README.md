# OrionMobile

The iOS companion to Orion ([Docs/19](../Docs/19_ios_companion.md)): explore and learn a codebase
on the iPhone from knowledge analyzed on the Mac, with every AI interaction on the on-device
Foundation Models system model.

**Status: M8.** Library, Explore, **Ask** and **Learn** work on knowledge snapshots synced from
the Mac through iCloud (or imported by hand). Ask and Learn run on Apple's on-device system model.
M8 redesigned the app to Apple's HIG: split views on iPad, a repository title menu, Dynamic Type
up to AX5, and Xcode's accessibility audit.
Learn offers questions shipped from the Mac first, drafts bands 1–2 on the device (always through
the verifier), and grades with a single-call guided judge; grades are a self-check until the
calibration gate is cleared (Docs/19 M7).

On-device benchmarks (Library ⋯ menu, or at launch with `devicectl … --environment-variables`):

- **Ask:** `{"ORION_ASK_BENCH":"all"}` (or a comma-separated id list, plus
  `"ORION_ASK_BENCH_DEPTH":"2"`) → `Documents/ask-bench-latest.json`.
- **Learn:** `{"ORION_LEARN_BENCH":"all|calibration|drafting","ORION_LEARN_BENCH_K":"1,3","ORION_LEARN_BENCH_DRAFTS":"10"}`
  → `Documents/learn-bench-latest.json` (grader calibration against
  `starlette_teaching_grader.gold.json`, then drafts for the top concepts).

Pull results with `devicectl device copy from`. Keep the phone unlocked: the system model only
serves the foreground app. See `Agent Feasibility Study/IOS_COMPANION_EVAL.md`.

## Layout

| Path | What |
|---|---|
| `project.yml` | xcodegen spec — the source of truth. Regenerate with `xcodegen generate`. |
| `OrionMobile/` | The iOS 27 app (`com.gilangbbe.orion.mobile`, team `S3AP74B5TH`): `Shell/` (tabs, repository title menu), `Explore/`, `Evidence/`, `Ask/`, `Learn/`, `Library/`, `Sync/`, `Design/` (small shared views and modifiers). One view per file. |
| `../OrionApp/Shared/` | Loaders, models and views shared with the Mac app (compiled by both projects). |
| `OrionMobileTests/` | Unit tests (iOS simulator); `SnapshotFixture` builds a minimal snapshot with `OrionCore` alone. |
| `OrionMobileUITests/` | On demand, scheme `OrionMobileWalkthrough`: screenshot walkthroughs of Explore, Ask and Learn, an iPad layout pass (`IPadLayoutUITests`, run on an iPad simulator) and Xcode's accessibility audit on each main screen (`AccessibilityAuditUITests`). |
| `Probe/` | `FMProbe` (Docs/19 M0), shared by the app (Library ⋯ → On-Device Model) and `fm-probe`. |
| `fm-probe/` | macOS command-line twin of the probe. |
| `scripts/make-sample-context.sh` | Regenerates `Probe/SampleContext.swift` from the vendored Starlette analysis. |

## Getting knowledge onto the device

**iCloud (the normal way, Docs/19 M5):** in Orion on the Mac, open the repository and switch on
**Sync to iPhone** in the sidebar footer. The iPhone (same Apple ID) installs it at launch, when the
app comes to the foreground, or on pull-to-refresh in Library. Container `iCloud.com.gilangbbe.orion`,
private database, zone `OrionKnowledge` (`OrionMacOs/Sources/OrionSync`). Before a TestFlight/App
Store build, deploy the CloudKit schema to Production in CloudKit Dashboard.

**By hand** (no iCloud, or for the simulator): on the Mac, build a snapshot:

```sh
cd OrionMacOs && swift run orion-index snapshot <repo> [--commit <hash>]   # → <repo>/.orion/snapshot/
```

Then put `<name>.orionsnap` (and its `<name>.manifest.json`, which lets the app verify it) into the
app's Documents folder — the app imports it at launch / when it becomes active:

```sh
# Simulator
DOCS="$(xcrun simctl get_app_container booted com.gilangbbe.orion.mobile data)/Documents"
cp <name>.orionsnap <name>.manifest.json "$DOCS"/
# iPhone (or drag into Orion in Finder's file sharing, or use Library ⋯ → Import Snapshot…)
xcrun devicectl device copy to --device <udid> --domain-type appDataContainer \
  --domain-identifier com.gilangbbe.orion.mobile --source <name>.orionsnap --destination Documents/<name>.orionsnap
```

## Build & test

```sh
xcodegen generate
xcodebuild -project OrionMobile.xcodeproj -scheme OrionMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
# Visual walkthrough (needs a repository imported into the simulator first):
xcodebuild -project OrionMobile.xcodeproj -scheme OrionMobileWalkthrough \
  -destination 'platform=iOS Simulator,name=iPhone 17' -resultBundlePath walk.xcresult test
xcrun xcresulttool export attachments --path walk.xcresult --output-path walk-shots
```

Large-snapshot timing (Docs/19 M8), skipped unless pointed at a snapshot:
`TEST_RUNNER_ORION_LARGE_SNAPSHOT=<path>.orionsnap xcodebuild … -only-testing:OrionMobileTests/LargeSnapshotTests test`.
For Dynamic Type passes, `xcrun simctl ui <device> content_size accessibility-extra-extra-extra-large`
before a walkthrough (and `large` after).

On a device: `-destination 'id=<udid>' -allowProvisioningUpdates`, then
`xcrun devicectl device install app --device <udid> <…>/Debug-iphoneos/Orion.app`.

## Running the M0 probe

On the Mac:

```sh
xcodebuild -project OrionMobile.xcodeproj -scheme fm-probe -configuration Release \
  -derivedDataPath .build/xcodebuild build
FM_PROBE_OUT=results/mac-probe.json .build/xcodebuild/Build/Products/Release/fm-probe
```

On an iPhone (unlocked; the system model only serves foreground apps), launch with
`--environment-variables '{"FM_PROBE_AUTORUN":"1"}'`; ~30 s later pull
`Documents/fm-probe-latest.json` with `devicectl device copy from --domain-type appDataContainer`.
Kept results live in `Agent Feasibility Study/results/ios_companion/`.
