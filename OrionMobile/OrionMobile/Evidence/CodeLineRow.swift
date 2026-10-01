import SwiftUI

/// One numbered source line.
struct CodeLineRow: View {
    let line: SourceLine
    let gutterWidth: Double
    let wrap: Bool
    let highlighted: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text(line.number, format: .number.grouping(.never))
                .foregroundStyle(.secondary)
                .frame(width: gutterWidth, alignment: .trailing)
                .accessibilityLabel("Line \(line.number)")
            Text(line.text.isEmpty ? " " : line.text)
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
        }
        .font(.footnote.monospaced())
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? DesignTokens.accent.opacity(0.14) : .clear)
        .accessibilityElement(children: .combine)
    }
}
