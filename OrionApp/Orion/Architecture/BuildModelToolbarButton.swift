import SwiftUI

/// Build Architecture Model (Docs/13 M3): the explicit, cost-gated Claude Code investigation. Opens
/// the confirmation sheet; shows progress while one runs, since it takes minutes.
struct BuildModelToolbarButton: View {
    let window: RepositoryWindow

    var body: some View {
        if window.semantic.state == .investigating {
            Label {
                Text("Building Architecture Model…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .labelStyle(.titleAndIcon)
            .help("Claude Code is investigating this repository. This takes a few minutes.")
        } else {
            Button("Build Architecture Model…", systemImage: "sparkles", action: build)
                .help("Group the code into components and evidence-backed claims with Claude Code")
        }
    }

    private func build() {
        window.isBuildingModel = true
    }
}
