import SwiftUI

/// Which depth answered, why, and the tool calls it made (Docs/14 §4.6's "Explain").
struct AskRoutingDetail: View {
    let summary: AskResultSummary

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Depth \(summary.depth) · \(summary.routingMethod) · \(summary.routingConfidence) confidence")
            MarkdownText(raw: summary.rationale)
            ForEach(summary.toolCalls) { call in
                Text("[\(call.turnIndex)] \(call.toolName)(\(call.arguments)) → \(call.result)")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DesignTokens.Spacing.xs)
    }
}
