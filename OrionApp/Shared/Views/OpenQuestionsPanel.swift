import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §4.4/§8 M3: the inspector's other case besides component
/// detail -- every investigation-wide uncertainty (Docs/13 M6's "Open questions" list) shown in
/// full. Moved off `ArchitectureOverviewView`'s own always-expanded banner, which didn't scale to
/// a real investigation's actual shape: production data has around 6 of these, some 150-220 words
/// each -- inlined above the diagram, that's over a thousand words sitting on top of the graph
/// it's supposed to summarize (see this doc's revision note). Reached through a slim, always-visible
/// summary strip instead (`ArchitectureOverviewView.openQuestionsStrip(_:)`), full text lives here.
struct OpenQuestionsPanel: View {
    let uncertainties: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(uncertainties.enumerated()), id: \.offset) { index, statement in
                    VStack(alignment: .leading, spacing: 6) {
                        EpistemicBadge(.unknown)
                        Text(statement)
                            .font(.callout)
                    }
                    if index < uncertainties.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    OpenQuestionsPanel(uncertainties: [
        "Is Persistence still read by any component now that session writes route through SessionStore?",
        "UserCache has no visible eviction policy.",
    ])
    .frame(width: 320, height: 400)
}
