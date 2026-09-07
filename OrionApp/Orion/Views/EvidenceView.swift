import SwiftUI

/// Docs/13_phase4_architecture_ui.md M5's source-snippet panel. Reads the real file from the
/// analyzed checkout at `repoRoot` and shows the cited range highlighted -- plain monospace +
/// line numbers (Docs/08 asks for an "evidence view," not a code editor).
struct EvidenceView: View {
    let repoRoot: URL
    let evidence: EvidenceDetail

    @State private var snippet: EvidenceSnippet?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(evidence.anchor)
                    .font(.headline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            Divider()
            if let loadError {
                ContentUnavailableView(
                    "Couldn't load source", systemImage: "doc.questionmark",
                    description: Text(loadError))
            } else if let snippet {
                sourceView(snippet)
            } else {
                ProgressView()
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .task { load() }
    }

    private func load() {
        do {
            snippet = try EvidenceSourceLoader.load(
                repoRoot: repoRoot, anchor: evidence.anchor, startLine: evidence.startLine,
                endLine: evidence.endLine)
        } catch {
            loadError = String(describing: error)
        }
    }

    private func sourceView(_ snippet: EvidenceSnippet) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(snippet.lines) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(line.number)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(width: 40, alignment: .trailing)
                        Text(line.text)
                            .font(.callout.monospaced())
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        isHighlighted(line.number, in: snippet.highlightRange)
                            ? Color.yellow.opacity(0.25) : Color.clear
                    )
                }
            }
        }
    }

    private func isHighlighted(_ number: Int, in range: ClosedRange<Int>?) -> Bool {
        range?.contains(number) ?? false
    }
}
