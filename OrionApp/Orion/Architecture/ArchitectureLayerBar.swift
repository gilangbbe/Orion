import SwiftUI

/// Which layer is on screen, so its epistemic status is never ambiguous (Docs/04), and the
/// investigation's open questions one click away (Docs/13 M6, Docs/14 §8 M3).
struct ArchitectureLayerBar: View {
    let model: ArchitectureModel
    let shell: AppShellState

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            switch model.layer {
            case .structural(let moduleCount):
                Label("Structural view: \(moduleCount) modules, no architecture investigation yet", systemImage: "cube")
                    .lineLimit(1)
                EpistemicBadge(.fact)
            case .semantic(_, let componentCount, let investigatedAt):
                Label(Self.semanticTitle(componentCount: componentCount, investigatedAt: investigatedAt), systemImage: "sparkles")
                    .lineLimit(1)
                EpistemicBadge(.interpretation)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            if !model.uncertainties.isEmpty {
                Button(Self.openQuestionsTitle(model.uncertainties.count), systemImage: "questionmark.circle", action: showOpenQuestions)
                    .buttonStyle(.borderless)
                    .help("Things the investigation couldn't settle")
            }
        }
        .font(.callout)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private func showOpenQuestions() {
        shell.inspectorContent = .openQuestions(model.uncertainties)
    }

    static func semanticTitle(componentCount: Int, investigatedAt: String?) -> String {
        var title = "Semantic view: \(componentCount) components"
        if let iso = investigatedAt, let date = try? Date(iso, strategy: .iso8601) {
            title += ", investigated \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return title
    }

    static func openQuestionsTitle(_ count: Int) -> String {
        count == 1 ? "1 Open Question" : "\(count) Open Questions"
    }
}
