import Foundation

/// Docs/14_phase4_5_ui_ux_redesign.md §4.1 / §8 M1: which of the five sidebar destinations is
/// currently showing. `.changes`/`.teaching`/`.diagnostics` don't have real content yet (M6/M7/M8
/// build them) -- they still appear in the sidebar now, per the plan's own M1 scope, showing a
/// plain "not built yet" placeholder until their milestone lands.
enum Destination: String, CaseIterable, Identifiable {
    case overview = "Architecture Overview"
    case ask = "Ask"
    case changes = "Model Changes"
    case teaching = "Teaching Mode"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: return "point.3.connected.trianglepath.dotted"
        case .ask: return "bubble.left.and.bubble.right"
        case .changes: return "clock.arrow.circlepath"
        case .teaching: return "graduationcap"
        case .diagnostics: return "gearshape"
        }
    }

    /// Docs/14 §4.1's sidebar layout: the first four are primary destinations; Diagnostics sits
    /// alone below an "Advanced" section divider (Docs/05 §8 -- hidden-by-default detail, not
    /// undiscoverable).
    static let primary: [Destination] = [.overview, .ask, .changes, .teaching]
    static let advanced: [Destination] = [.diagnostics]
}

/// Docs/14_phase4_5_ui_ux_redesign.md §8 M8.5 item 3: Architecture Overview's Diagram/List toggle.
/// Was `ArchitectureOverviewView`'s own local `@State` (M1); moved here so `ContentView` can host
/// the actual control in the window's toolbar, beside the "Architecture Overview" title, instead
/// of inline in that view's own banner -- the same "shell-level state, not a local `@State` that
/// resets on destination-switch" rule `destination`/`inspectorContent` below already follow.
enum ArchitectureViewMode: String, CaseIterable, Identifiable {
    case diagram = "Diagram"
    case list = "List"
    var id: String { rawValue }
}

/// Docs/14 §4.4's mutually-exclusive inspector content -- a selected node's detail, or the
/// investigation-wide Open Questions list; `nil` means the inspector is closed. Only the
/// Architecture Overview destination populates this (Docs/14 §8 M3). Each case carries what
/// `ContentView`'s shared inspector needs to render without re-loading anything:
/// `ArchitectureOverviewView` already has the current `ArchitectureModel` (and so its `layer` and
/// `uncertainties`) at the moment a node or the Open Questions strip is tapped, so that data rides
/// along instead of `ContentView` needing its own separate copy of the loaded model.
enum InspectorContent: Equatable {
    case node(ArchitectureNode, ArchitectureLayer)
    case openQuestions([String])
}

/// Docs/14 §8 M1: the shell-level navigation state `ContentView`'s `NavigationSplitView` is built
/// around. Deliberately separate from `RepositorySession` (which owns *whether* a repository is
/// open, not *where you are* once it is) and from `SemanticInvestigationSession` (which owns the
/// Build Architecture Model action's own state, not navigation) -- each of the three has exactly
/// one reason to change. Recreated on every fresh repository open, same as `SemanticInvestigationSession`
/// already is in `ContentView`, so a previous repository's destination/inspector selection never
/// leaks into the next one.
@Observable
final class AppShellState {
    private var _destination: Destination = .overview

    /// Docs/14 §8 M3: switching destinations always closes the inspector -- its content
    /// (`InspectorContent`) is Overview-specific, so leaving Overview with a node's detail still
    /// open would show stale component detail over, say, the Ask destination. Centralized here as
    /// the setter's own side effect rather than duplicated at every call site (the sidebar's
    /// selection binding, `ComponentDetailView`'s "Ask about" button, and any future one) --
    /// there's exactly one place this rule can be forgotten now, not N.
    var destination: Destination {
        get { _destination }
        set {
            if newValue != _destination {
                inspectorContent = nil
            }
            _destination = newValue
        }
    }

    var inspectorContent: InspectorContent?

    /// Docs/14 §8 M8.5 item 3 -- see `ArchitectureViewMode`'s own doc comment. Deliberately not
    /// reset by `destination`'s setter (unlike `inspectorContent`): it's meaningless outside
    /// Architecture Overview, but harmless to remember for next time you're there, same as this
    /// object as a whole persists per-repository, not per-visit.
    var viewMode: ArchitectureViewMode = .diagram

    /// Docs/16_phase6_continuous_model_updates.md §8, M5: which `model_revisions` row to
    /// auto-expand when landing on `.changes` -- set by the `CONTRADICTED`-claim cross-reference
    /// (Docs/14 §2's "Superseded — see Model Changes"). Deliberately not reset by `destination`'s
    /// setter (unlike `inspectorContent`), the same "harmless to leave stale" reasoning
    /// `viewMode` above already uses -- `ModelChangesView` only ever reads it once, right when it
    /// appears, to decide what to expand; a stale value sitting around between visits changes
    /// nothing about how any other destination behaves.
    var focusedModelChangeRevisionId: String?
}
