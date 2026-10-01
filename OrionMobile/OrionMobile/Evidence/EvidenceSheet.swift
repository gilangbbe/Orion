import SwiftUI

/// The code a claim or member cites (Docs/19 M8), as a sheet with a navigation bar: the symbol as
/// the title, its file and lines as the subtitle, and a Close button. Resizable between half and
/// full height with a grabber -- the HIG's "in an iPhone app, consider supporting medium".
struct EvidenceSheet: View {
    let evidence: EvidenceDetail
    let source: any EvidenceSourceProviding

    @Environment(\.dismiss) private var dismiss
    /// A per-reader preference: long lines scroll sideways, or wrap.
    @AppStorage("evidence.wrapLines") private var wrapLines = false
    @State private var snippet: EvidenceSnippet?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Couldn't Load the Code", systemImage: "doc.questionmark",
                        description: Text(loadError))
                } else if let snippet {
                    CodeLinesView(snippet: snippet, wrapLines: wrapLines)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(Self.title(evidence.anchor))
            .navigationSubtitle(Self.subtitle(evidence))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Wrap Lines", systemImage: "text.word.spacing", isOn: $wrapLines)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { load() }
    }

    private func load() {
        do {
            snippet = try source.snippet(for: evidence)
        } catch {
            loadError = String(describing: error)
        }
    }

    /// `pkg/app.py::Router.add_route` → `Router.add_route`; a bare file → its name.
    static func title(_ anchor: String) -> String {
        let parts = anchor.components(separatedBy: "::")
        if parts.count > 1, let symbol = parts.last, !symbol.isEmpty { return symbol }
        return (anchor as NSString).lastPathComponent
    }

    /// `pkg/app.py · lines 20–50`.
    static func subtitle(_ evidence: EvidenceDetail) -> String {
        let file = evidence.anchor.components(separatedBy: "::").first ?? evidence.anchor
        switch (evidence.startLine, evidence.endLine) {
        case let (start?, end?) where end > start: return "\(file) · lines \(start)–\(end)"
        case let (start?, _): return "\(file) · line \(start)"
        default: return file
        }
    }
}
