import Foundation

/// Docs/14_phase4_5_ui_ux_redesign.md §4.7/§8 M6: one "Understanding updated" entry -- Docs/05
/// Stage 6's exact shape (Previously / Now / Reason).
struct ModelChangeSummary: Identifiable {
    let id: String
    let title: String
    let when: String
    let before: String
    let after: String
    let reason: String
}

/// Docs/14 §7 Decision 3: this phase deliberately designed the frontend before the backend for
/// Model Changes, because the backend behavior isn't understood yet -- there is no persisted
/// record of model revisions to derive this from (that's real, unscoped work: recording, per
/// investigation, which claims/relationships were added, superseded, or reversed since the
/// previous one on the same repository). `ModelChangesView` renders this fixed sample instead of
/// anything from `CodebaseModelStore`, using Docs/05 Stage 6's own worked example verbatim so the
/// screen's shape is validated against a real spec, not invented content.
enum ModelChangeSample {
    static let entries: [ModelChangeSummary] = [
        ModelChangeSummary(
            id: "sample-authentication", title: "Authentication", when: "2 days ago",
            before: "AuthService → Persistence",
            after: "AuthService → SessionManager → SessionStore → Keychain",
            reason: "New source evidence identified an intermediate session layer."),
        ModelChangeSummary(
            id: "sample-persistence", title: "Persistence", when: "2 days ago",
            before: "Primary session persistence layer",
            after: "Legacy fallback — no longer written to directly by Authentication",
            reason: "AuthService's session writes now route through SessionStore instead."),
    ]
}
