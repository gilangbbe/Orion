import SwiftUI

/// A change: what it's about, when, and where the model landed, in a line.
struct ModelChangeRow: View {
    let entry: ModelChangeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .lineLimit(2)
            Text(entry.preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(entry.when)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
