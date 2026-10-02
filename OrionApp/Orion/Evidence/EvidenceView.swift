import SwiftUI

/// The code a claim or member cites (Docs/13 M5), as a sheet: the symbol and its file and lines
/// at the top, the lines with the cited range highlighted, and Done (HIG, Sheets). Plain
/// monospace with line numbers -- an evidence view, not an editor (Docs/08). Lines come from the
/// analyzed checkout.
struct EvidenceView: View {
    let evidence: EvidenceDetail
    let source: any EvidenceSourceProviding

    @Environment(\.dismiss) private var dismiss
    @State private var snippet: EvidenceSnippet?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(evidence.anchor))
                    .font(.headline.monospaced())
                Text(Self.subtitle(evidence))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(DesignTokens.Spacing.lg)
            Divider()
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Couldn't Load the Code", systemImage: "doc.questionmark",
                        description: Text(loadError))
                } else if let snippet {
                    EvidenceLinesView(snippet: snippet)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DesignTokens.Spacing.md)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 440, idealHeight: 560)
        .task { load() }
    }

    private func close() {
        dismiss()
    }

    private func load() {
        do {
            snippet = try source.snippet(for: evidence)
        } catch {
            loadError = String(describing: error)
        }
    }

    /// `pkg/app.py::Router.add_route` → `Router.add_route`; a bare path → its file name.
    static func title(_ anchor: String) -> String {
        if let range = anchor.range(of: "::") {
            return String(anchor[range.upperBound...])
        }
        return (anchor as NSString).lastPathComponent
    }

    /// `pkg/app.py · lines 20–50`.
    static func subtitle(_ evidence: EvidenceDetail) -> String {
        let path = evidence.anchor.components(separatedBy: "::").first ?? evidence.anchor
        switch (evidence.startLine, evidence.endLine) {
        case let (start?, end?) where start != end: return "\(path) · lines \(start)–\(end)"
        case let (start?, _): return "\(path) · line \(start)"
        default: return path
        }
    }
}
