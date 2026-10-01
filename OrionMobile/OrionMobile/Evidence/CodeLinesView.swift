import SwiftUI

/// Numbered source lines with the cited range highlighted. The gutter scales with Dynamic Type
/// (`@ScaledMetric`) instead of the old fixed 40 pt; unwrapped, long lines scroll sideways rather
/// than being clipped.
struct CodeLinesView: View {
    let snippet: EvidenceSnippet
    let wrapLines: Bool

    @ScaledMetric(relativeTo: .footnote) private var digitWidth = 8.5

    var body: some View {
        ScrollView(wrapLines ? .vertical : [.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(snippet.lines) { line in
                    CodeLineRow(
                        line: line, gutterWidth: gutterWidth, wrap: wrapLines,
                        highlighted: snippet.highlightRange?.contains(line.number) ?? false)
                }
                if snippet.truncated {
                    Label("Shortened. The full file is in Orion on your Mac.", systemImage: "scissors")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .scrollIndicators(.visible)
    }

    private var gutterWidth: Double {
        let digits = String(snippet.lines.last?.number ?? 0).count
        return Double(max(digits, 2)) * digitWidth + DesignTokens.Spacing.sm
    }
}
