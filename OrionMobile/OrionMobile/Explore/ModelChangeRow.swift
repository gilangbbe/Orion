import SwiftUI

/// A change in the list: what changed, a two-line preview of where the model landed, and when.
struct ModelChangeRow: View {
    let entry: ModelChangeSummary

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(entry.title)
                    .font(.headline)
                    .scaledLineLimit(2)
                Text(PlainText.from(markdown: entry.preview))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .scaledLineLimit(2)
                Text("Updated \(entry.when)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: Self.symbol(for: entry.title))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// A symbol for the kind of change, read from its title ("Claim added", "Claim reversed",
    /// "Open question raised", …).
    static func symbol(for title: String) -> String {
        let lower = title.lowercased()
        if lower.contains("no longer") { return "checkmark.circle" }
        if lower.contains("question") { return "questionmark.circle" }
        if lower.contains("added") { return "plus.circle" }
        if lower.contains("reversed") || lower.contains("contradicted") { return "arrow.uturn.backward.circle" }
        if lower.contains("removed") { return "minus.circle" }
        if lower.contains("refined") { return "arrow.triangle.2.circlepath.circle" }
        return "clock.arrow.circlepath"
    }
}
