import Foundation

/// Docs/14_phase4_5_ui_ux_redesign.md §4.6/§8 M4: one asked question, its outcome once resolved,
/// and (optionally) which component it was about.
struct AskHistoryEntry: Identifiable {
    let id: UUID
    let question: String
    let component: String?
    let askedAt: Date
    var outcome: AskOutcome?
}

/// Docs/14 §8 M4: the question history Ask's master-detail list is built from, and what
/// `ComponentDetailView`'s "Ask about {name}" hand-off writes into -- owned by `ContentView`
/// (same lifetime as `AppShellState`/`SemanticInvestigationSession`, reset on every fresh
/// repository open) rather than kept as `AskView`'s own local `@State`. That's not a style
/// preference: `destinationContent(_:)`'s `switch` gives each case its own view identity, so a
/// plain `@State` array inside `AskView` would reset every time the destination switches away
/// from `.ask` and back -- exactly the "Ask forgets everything the moment you look away" problem
/// this redesign exists to fix (Docs/04 §6: "the Codebase Model should be queryable independently
/// of any individual conversation").
@Observable
final class AskHistory {
    private(set) var entries: [AskHistoryEntry] = []
    var selectedID: UUID?

    /// Docs/14_phase4_5_ui_ux_redesign.md §8 M8.5 item 6: which component (if any) the *next*
    /// question typed into `AskView`'s input bar is about -- set by `ComponentDetailView`'s "Ask
    /// about {name}" hand-off instead of that hand-off asking a canned question outright, so the
    /// developer still phrases their own question (Docs/05 Stage 4/5's "the developer can ask
    /// questions about the selected component," not "the app asks a generic one for them"). Also
    /// what makes "a general question" a real, visible choice rather than just whatever's left
    /// over when nothing else was clicked: `AskView` shows a removable "Asking about {name}" chip
    /// while this is set, and clearing it (or filing the question) falls through to general.
    var pendingScope: String?

    /// Starts a new question (pending, no outcome yet), files it at the front of the list, and
    /// selects it. The caller is responsible for actually resolving it (via `AskRunner.ask`) and
    /// calling `resolve(_:outcome:)` once that completes. Clears `pendingScope` unconditionally --
    /// filing any question, scoped or general, ends that scope; asking another one about the same
    /// component again requires clicking "Ask about {name}" again, a deliberate choice per
    /// question rather than a scope that silently stays sticky.
    @discardableResult
    func ask(_ question: String, component: String? = nil) -> UUID {
        let entry = AskHistoryEntry(
            id: UUID(), question: question, component: component, askedAt: Date())
        entries.insert(entry, at: 0)
        selectedID = entry.id
        pendingScope = nil
        return entry.id
    }

    func resolve(_ id: UUID, outcome: AskOutcome) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].outcome = outcome
    }

    struct Group: Identifiable {
        let name: String
        let entries: [AskHistoryEntry]
        var id: String { name }
    }

    /// Docs/14 §8 M4's own testing plan: grouped by component (`nil` -> "General", sorted
    /// alphabetically with "General" always last -- matching the prototype's fix for a filter
    /// mechanism that didn't scale, see §4.6's revision note), filtered by a case-insensitive
    /// substring match on the question text. Pure and independent of any SwiftUI state, so it's
    /// testable directly rather than only through `AskView` itself.
    func groups(matching search: String) -> [Group] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = entries.filter { query.isEmpty || $0.question.lowercased().contains(query) }
        let names = Set(filtered.map { $0.component ?? "General" })
        let sortedNames = names.sorted { lhs, rhs in
            if lhs == "General" { return false }
            if rhs == "General" { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return sortedNames.map { name in
            Group(name: name, entries: filtered.filter { ($0.component ?? "General") == name })
        }
    }
}
