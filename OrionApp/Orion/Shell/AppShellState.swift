import Foundation

/// Where you are in a repository window (Docs/14 §8 M1): the destination, Architecture's view mode
/// and inspector. Separate from `RepositorySession` (whether a repository is open) and
/// `SemanticInvestigationSession` (the Build Architecture Model action). Recreated for every
/// repository opened, so one repository's selection never leaks into the next.
@MainActor
@Observable
final class AppShellState {
    private var _destination: Destination = .overview

    /// Docs/14 §8 M3: switching destinations closes the inspector. Its content is Architecture's
    /// alone, so it would be stale anywhere else. Done here, once, rather than at every call site.
    var destination: Destination {
        get { _destination }
        set {
            if newValue != _destination {
                inspectorContent = nil
            }
            _destination = newValue
        }
    }

    /// Setting content opens the inspector (Docs/20 R3); clearing it closes it.
    var inspectorContent: InspectorContent? {
        didSet { isInspectorPresented = inspectorContent != nil }
    }

    /// Bound to Architecture's native inspector, its toolbar toggle and View > Show Inspector.
    /// Opening it with nothing selected shows a "No Selection" placeholder.
    var isInspectorPresented = false

    /// Not reset by `destination`: remembered for the next visit to Architecture.
    var viewMode: ArchitectureViewMode = .diagram

    /// Docs/16 §8 M5: which `model_revisions` row Model Changes selects on arrival, set by a
    /// `CONTRADICTED` claim's "Superseded — see Model Changes" link. Read once when that screen
    /// appears, so a stale value is harmless.
    var focusedModelChangeRevisionId: String?
}
