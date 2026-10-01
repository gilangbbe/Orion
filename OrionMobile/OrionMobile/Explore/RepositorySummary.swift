import OrionCore
import SwiftUI

/// What this repository is, as analyzed, and which view of it Explore shows: the Mac's semantic
/// model, or only the structural one. Plain secondary text -- none of it is tappable, so none of it
/// takes the accent colour (HIG Color: "avoid using the same color to mean different things").
struct RepositorySummary: View {
    let manifest: KnowledgeSnapshotManifest
    let layer: ArchitectureLayer

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("\(LibraryView.commitLabel(manifest.commitHash).capitalizedFirst) · analyzed \(LibraryView.dateLabel(manifest.analyzedAt))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            AdaptiveStack {
                layerLabel
                badge
            }
            Text(LibraryView.contentsLabel(manifest.counts))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var layerLabel: some View {
        Label(Self.layerText(layer), systemImage: Self.layerSymbol(layer))
            .font(.subheadline.weight(.medium))
    }

    private var badge: some View {
        EpistemicBadge(Self.layerTag(layer))
    }

    static func layerText(_ layer: ArchitectureLayer) -> String {
        switch layer {
        case .semantic(_, let count, _): "Architecture model · \(count) components"
        case .structural(let count): "Structure only · \(count) modules"
        }
    }

    static func layerSymbol(_ layer: ArchitectureLayer) -> String {
        if case .semantic = layer { return "sparkles" }
        return "cube"
    }

    static func layerTag(_ layer: ArchitectureLayer) -> EpistemicTag {
        if case .semantic = layer { return .interpretation }
        return .fact
    }
}

extension String {
    /// "commit 4f250d6b" → "Commit 4f250d6b".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
