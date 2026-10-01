import SwiftUI

/// One component (Docs/19 M8): its purpose, members, relationships and the claims about it, as an
/// inset-grouped list. "Ask About This" is a toolbar action -- the HIG's "a toolbar acts on
/// content" -- rather than a button inside the content.
struct ComponentScreen: View {
    let outputDirectory: URL
    let node: ArchitectureNode
    let model: ArchitectureModel
    let onAskAbout: ((ComponentDetail) -> Void)?
    let open: (ExploreRoute) -> Void

    @State private var detail: ComponentDetail?
    @State private var loadError: String?
    @State private var selectedEvidence: EvidenceDetail?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Couldn't Load This Component", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else if let detail {
                ComponentDetailList(detail: detail, model: model, open: open) { selectedEvidence = $0 }
            } else {
                ProgressView()
            }
        }
        // The name heads the content, in full; the bar's title is for the back button and
        // VoiceOver, so it isn't drawn truncated above it (HIG Toolbars: a title "can be omitted
        // when content supplies context").
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.accessibilityHidden(true)
            }
            if let onAskAbout, let detail {
                ToolbarItem(placement: .primaryAction) {
                    Button("Ask About This", systemImage: "bubble.left.and.text.bubble.right") {
                        onAskAbout(detail)
                    }
                }
            }
        }
        .sheet(item: $selectedEvidence) { evidence in
            EvidenceSheet(evidence: evidence, source: SnapshotEvidenceSource(outputDirectory: outputDirectory))
        }
        .task { await load() }
    }

    private func load() async {
        let outputDirectory = outputDirectory
        let node = node
        let layer = model.layer
        do {
            detail = try await Task.detached(priority: .userInitiated) {
                try ComponentDetailLoader.load(outputDirectory: outputDirectory, node: node, layer: layer)
            }.value
        } catch {
            loadError = String(describing: error)
        }
    }
}
