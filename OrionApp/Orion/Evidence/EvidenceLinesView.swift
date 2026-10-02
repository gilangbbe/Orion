import SwiftUI

/// Numbered source lines, the cited range tinted, scrolling both ways. Selectable, so a line can
/// be copied.
struct EvidenceLinesView: View {
    let snippet: EvidenceSnippet

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(snippet.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
                        Text(line.number, format: .number.grouping(.never))
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 36, alignment: .trailing)
                            .accessibilityLabel("Line \(line.number)")
                        Text(line.text)
                            .textSelection(.enabled)
                            .fixedSize()
                    }
                    .font(.body.monospaced())
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isCited(line.number) ? DesignTokens.accent.opacity(0.15) : Color.clear)
                }
            }
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func isCited(_ number: Int) -> Bool {
        snippet.highlightRange?.contains(number) ?? false
    }
}
