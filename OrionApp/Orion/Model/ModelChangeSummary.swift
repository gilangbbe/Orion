import Foundation

/// Docs/14_phase4_5_ui_ux_redesign.md §4.7/§8 M6: one "Understanding updated" entry -- Docs/05
/// Stage 6's exact shape (Previously / Now / Reason). Docs/14 §7 Decision 3 deliberately designed
/// this screen's frontend before its backend existed, rendering a fixed sample
/// (`ModelChangeSample`, now removed) instead of real data; Docs/16_phase6_continuous_model_updates.md
/// §4/§8 (M5) built that backend (`RevisionDiffer` + `model_revisions`/`model_revision_entries`)
/// and `ModelChangeLoader` now produces real instances of this same shape from it.
struct ModelChangeSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let when: String
    let before: String
    let after: String
    let reason: String
}
