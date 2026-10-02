import SwiftUI

/// A component in Architecture's inspector (Docs/13 M5, Docs/05 Stage 4, Docs/20 R3): its name
/// and how far to trust it, Ask About This, then Purpose, Members, Dependencies and Claims with
/// evidence. A structural (Phase 1 only) node says so plainly. Mac only since Docs/19 M8 gave the
/// iPhone its own component screen.
struct ComponentDetailView: View {
    let outputDirectory: URL
    let node: ArchitectureNode
    let layer: ArchitectureLayer
    let evidenceSource: any EvidenceSourceProviding
    /// "Ask About This": the window switches to Ask and resumes or scopes a session.
    let onAskAbout: (ComponentDetail) -> Void
    /// "Superseded — see Model Changes": opens the revision that reversed a claim.
    let onShowRevision: (String) -> Void

    @State private var detail: ComponentDetail?
    @State private var loadError: String?
    @State private var selectedEvidence: EvidenceDetail?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Couldn't Load Component", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                        ComponentHeader(detail: detail, askAbout: { onAskAbout(detail) })
                        ComponentSections(detail: detail, showEvidence: showEvidence, showRevision: onShowRevision)
                    }
                    .padding(DesignTokens.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
        .sheet(item: $selectedEvidence) { evidence in
            EvidenceView(evidence: evidence, source: evidenceSource)
        }
    }

    private func showEvidence(_ evidence: EvidenceDetail) {
        selectedEvidence = evidence
    }

    private func load() async {
        let outputDirectory = outputDirectory
        let node = node
        let layer = layer
        do {
            detail = try await Task.detached(priority: .userInitiated) {
                try ComponentDetailLoader.load(outputDirectory: outputDirectory, node: node, layer: layer)
            }.value
        } catch {
            loadError = String(describing: error)
        }
    }
}
