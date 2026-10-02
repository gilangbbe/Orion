import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §4.9/§8 M8: Docs/05 §8's reserved "advanced diagnostic
/// view" -- the last Ask call's routing decision + full tool trace, and the last analysis run's
/// raw pipeline stage log with timestamps. Both sections are last-only (Docs/14 §7 Decision 2,
/// `DiagnosticsSession`'s own doc comment), so an empty section here means "hasn't happened yet
/// this session," not "cleared."
struct DiagnosticsView: View {
    let session: DiagnosticsSession
    let summary: RepositorySummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Docs/14 §8 M8.5 item 1: relocated from the sidebar's now-removed
                // `DisclosureGroup` (`ContentView.sidebarHeader(_:)`'s own doc comment has the
                // full story) -- this is exactly the kind of rarely-needed detail Diagnostics is
                // already the home for, not new scope.
                section("Repository") {
                    repositorySection(summary)
                }
                section("Last Ask Trace") {
                    if let trace = session.lastAskTrace {
                        askTrace(trace)
                    } else {
                        emptyRow("No Ask call yet this session.")
                    }
                }
                section("Last Analysis Run") {
                    if let stages = session.lastAnalysisStages, !stages.isEmpty {
                        stageLog(stages)
                    } else {
                        emptyRow("No analysis run yet this session.")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Repository

    private func repositorySection(_ summary: RepositorySummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent("Repository", value: summary.repoRoot.path)
            LabeledContent("Languages", value: summary.languages.joined(separator: ", "))
            LabeledContent("Resolver", value: summary.resolver)
            if summary.resolver == "none" {
                // Docs/06 §7 failure transparency: `resolver == "none"` in a real run always
                // means SCIP (scip-python/npx) was unavailable, not a deliberate choice -- the
                // app never passes --no-resolve itself. Calls/extends/implements simply don't
                // exist without it; say so plainly rather than leaving a bare "none" for the user
                // to puzzle over (Docs/13 M8, carried over verbatim from the removed disclosure).
                Text(
                    "scip-python (Pyright) wasn't available, so call/extends/implements edges "
                        + "weren't resolved. Symbols, imports, and module structure are still "
                        + "complete."
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
            if summary.parseErrorCount > 0 {
                LabeledContent("Parse errors", value: "\(summary.parseErrorCount)")
                    .foregroundStyle(.orange)
            }
            if summary.diagnosticCount > 0 {
                LabeledContent("Diagnostics", value: "\(summary.diagnosticCount)")
            }
            LabeledContent(
                "Analysis time", value: String(format: "%.0f ms", summary.totalDurationMs))
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - Ask trace

    private func askTrace(_ trace: DiagnosticsAskTrace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(trace.question).font(.callout.bold())
            Text(
                "Depth \(trace.summary.depth) · \(trace.summary.routingMethod) · "
                    + "confidence: \(trace.summary.routingConfidence)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            MarkdownText(raw: trace.summary.rationale)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !trace.summary.toolCalls.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(trace.summary.toolCalls) { call in
                        Text("[\(call.turnIndex)] \(call.toolName)(\(call.arguments)) → \(call.result)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }

    // MARK: - Stage log

    private func stageLog(_ stages: [DiagnosticsStageEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(stages) { entry in
                HStack {
                    Text(entry.stage.rawValue)
                        .font(.caption.monospaced())
                    Spacer()
                    Text(entry.startedAt, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }
}

#Preview {
    DiagnosticsView(
        session: DiagnosticsSession(),
        summary: RepositorySummary(
            repoRoot: URL(fileURLWithPath: "/tmp/example"),
            outputDirectory: URL(fileURLWithPath: "/tmp/example/.orion"),
            languages: ["python"], fileCount: 135, symbolCount: 3225, relationshipCount: 815,
            resolver: "scip-python", parseErrorCount: 0, diagnosticCount: 0, totalDurationMs: 420)
    )
    .frame(width: 520, height: 480)
}
