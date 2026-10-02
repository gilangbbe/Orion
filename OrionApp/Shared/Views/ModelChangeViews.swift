import SwiftUI

/// One change in full: freely-wrapping, selectable prose -- nothing truncated.
struct ModelChangeDetailView: View {
    let entry: ModelChangeSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.title3.bold())
                    Label("Updated \(entry.when)", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if ModelChangeSummary.isPresent(entry.before) {
                    field("Previously", entry.before, tint: .secondary, ruled: false)
                }
                field("Now", entry.after, tint: DesignTokens.fact, ruled: true)
                field("Reason", entry.reason, tint: .secondary, ruled: false)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A labelled prose block. The *label* carries the color cue (`tint`); the body text stays
    /// `.primary` so it's always readable -- the pre-redesign screenshot rendered whole paragraphs
    /// in monospaced green, which a colored label + a thin leading rule communicates without
    /// fighting legibility. `MarkdownText` renders the inline `` `code` `` spans real statements
    /// carry (e.g. a `` `_TestClientTransport` `` reference) instead of showing the backticks.
    private func field(_ label: String, _ value: String, tint: Color, ruled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .textCase(.uppercase)
            MarkdownText(raw: value)
                .font(.callout)
                .textSelection(.enabled)
                .padding(.leading, ruled ? 10 : 0)
                .overlay(alignment: .leading) {
                    if ruled {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(tint.opacity(0.5))
                            .frame(width: 3)
                    }
                }
        }
    }
}

extension ModelChangeSummary {
    /// A one-line teaser of where the model landed. Truncating *here* is fine -- it's a preview,
    /// and the full, un-clamped text is one tap away in the detail.
    var preview: String {
        let candidate = Self.isPresent(after) ? after : reason
        return candidate.replacingOccurrences(of: "\n", with: " ")
    }

    /// The loader writes `"—"` when a field has nothing to show (an `.added` entry has no
    /// "Previously"); treat that and the empty string as absent.
    static func isPresent(_ value: String) -> Bool {
        !value.isEmpty && value != "—"
    }
}
