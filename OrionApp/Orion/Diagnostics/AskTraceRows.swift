import SwiftUI

/// The last Ask call's routing decision and tool trace (Docs/14 §4.9).
struct AskTraceRows: View {
    let trace: DiagnosticsAskTrace

    var body: some View {
        LabeledContent("Question", value: trace.question)
        LabeledContent("Route", value: "Depth \(trace.summary.depth) · \(trace.summary.routingMethod) · \(trace.summary.routingConfidence) confidence")
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Why")
            MarkdownText(raw: trace.summary.rationale)
                .foregroundStyle(.secondary)
        }
        ForEach(trace.summary.toolCalls) { call in
            Text("[\(call.turnIndex)] \(call.toolName)(\(call.arguments)) → \(call.result)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
