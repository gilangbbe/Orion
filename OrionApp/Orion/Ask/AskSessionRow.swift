import Foundation

/// One conversational session, as shown in Ask's session-grouped list.
/// Docs/15_phase5_adaptive_exploration.md M6 promotes this list's unit from "one question"
/// (Docs/14_phase4_5_ui_ux_redesign.md §4.6) to "one session" -- a session's own turn-by-turn
/// history is what used to be this list's entire row set.
struct AskSessionRow: Identifiable, Equatable {
    let id: String
    let title: String
    /// `nil` for a repository-wide session; the resolved component *name* (not just its id) for
    /// a component-scoped one -- resolved once when the session list loads, not re-looked-up per
    /// render.
    let componentName: String?
    /// The real `components` row id backing `componentName`, `nil` for a repository-wide session.
    /// Carried alongside the name (not just derived from it) so a "+" on an existing component
    /// group, or a resumed session, can hand the real id straight to a new sibling session
    /// instead of re-deriving it -- see the fix note on `startSession(forGroupNamed:componentId:)`.
    let componentId: String?
    let turnCount: Int
    let lastActiveAt: Date
}
