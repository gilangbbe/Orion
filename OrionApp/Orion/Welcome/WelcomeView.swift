import OrionAgent
import OrionCodeIntel
import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §4.2/§8 M2: Docs/05 Stage 1's entry point and the old empty
/// state (`ContentView.emptyState`) merged into one screen -- a real headline stating the
/// product's thesis next to the same `OpenRepositoryForm` the "Open Another Repository" sheet
/// uses (`OpenRepositoryView.swift`), embedded directly instead of hidden behind a button.
struct WelcomeView: View {
    let session: RepositorySession

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Spacer()
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 34))
                    .foregroundStyle(DesignTokens.accent)
                    .accessibilityHidden(true)  // decorative; the headline already says this
                Text("See what your code actually does.")
                    .font(.largeTitle.bold())
                Text(
                    "Orion reconstructs a repository's architecture with evidence and confidence "
                        + "attached to every claim — not another dependency graph you have to "
                        + "take on faith."
                )
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(linkedLibrariesFooter)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
                Spacer()
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Divider()

            OpenRepositoryForm(session: session)
                .padding(28)
                .frame(width: 360, alignment: .top)
        }
    }

    /// A real, side-effect-free reference into each linked library -- proof this target actually
    /// links `OrionCodeIntel` and `OrionAgent` (not just resolves the packages), without loading
    /// the MLX model or touching the network (moved here unchanged from `ContentView`, Docs/13's
    /// own comment preserved -- still dropped once a later milestone gives the app a more organic
    /// reason to import both directly).
    private var linkedLibrariesFooter: String {
        let sample = DepthHeuristics.classify("What does AuthService do?")
        return
            "OrionCodeIntel \(OrionCodeIntel.version) · OrionAgent linked (sample depth: \(sample?.depth.description ?? "nil"))"
    }
}

#Preview {
    WelcomeView(session: RepositorySession())
        .frame(width: 900, height: 500)
}
