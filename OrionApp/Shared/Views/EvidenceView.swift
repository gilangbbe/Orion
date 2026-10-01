import SwiftUI

/// Docs/13_phase4_architecture_ui.md M5's source-snippet panel: shows the cited range highlighted
/// -- plain monospace + line numbers (Docs/08 asks for an "evidence view," not a code editor).
/// Docs/19 M4: shared with the iOS companion. The lines come from `source` -- the analyzed checkout
/// on the Mac (`CheckoutEvidenceSource`), the knowledge snapshot's snippets on iOS
/// (`SnapshotEvidenceSource`), which may be shortened.
///
/// Docs/14_phase4_5_ui_ux_redesign.md §4.11/§8 M5: visual-only restyle -- the highlighted range
/// now uses the app's own accent tint (`DesignTokens.accent`) instead of a plain yellow, matching
/// every other "this is what's being pointed at" treatment in the redesign rather than reading as
/// an unrelated editor-warning color; a close button was added, since a modal sheet with no
/// visible way to dismiss it (previously reliant on Escape alone) was a real, if minor, gap. No
/// logic changed at the time.
struct EvidenceView: View {
    @Environment(\.dismiss) private var dismiss
    let evidence: EvidenceDetail
    /// The checkout on the Mac, the snapshot's snippets on iOS (Docs/19 M4).
    let source: any EvidenceSourceProviding

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
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
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
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
        .task { load() }
    }

    private func load() {
        do {
            snippet = try source.snippet(for: evidence)
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
                            ? DesignTokens.accent.opacity(0.15) : Color.clear)
                }
                if snippet.truncated {
                    Label("Shortened — the full code is in Orion on your Mac.", systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func isHighlighted(_ number: Int, in range: ClosedRange<Int>?) -> Bool {
        range?.contains(number) ?? false
    }
}
