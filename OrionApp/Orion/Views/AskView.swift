import SwiftUI

private struct AskTranscriptEntry: Identifiable {
    let id: UUID
    let question: String
    var outcome: AskOutcome?
}

/// Docs/13_phase4_architecture_ui.md M7 / Docs/05 Stage 4-5's adaptive-exploration UX: a
/// question box wired directly to `AgentSession.ask(_:)` (via `AskRunner`), in-process, no CLI
/// subprocess. Routing/tool-trace detail is hidden by default behind an "Explain" disclosure
/// (Docs/05 §8's advanced diagnostic view, mirroring `orion-agent ask --explain`). Keeps its own
/// UI-local transcript across questions in this repository session -- `AgentSession` itself has
/// no cross-question memory (Docs/12), so each entry is an independent `ask` call.
struct AskView: View {
    let repoRoot: URL
    let outputDirectory: URL

    @State private var questionText = ""
    @State private var transcript: [AskTranscriptEntry] = []
    @State private var isAsking = false

    var body: some View {
        VStack(spacing: 0) {
            if transcript.isEmpty {
                emptyState
            } else {
                transcriptList
            }
            Divider()
            inputBar
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Ask a question about this repository")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(transcript) { entry in
                    AskEntryView(repoRoot: repoRoot, question: entry.question, outcome: entry.outcome)
                }
            }
            .padding(16)
        }
        .defaultScrollAnchor(.bottom)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask a question…", text: $questionText)
                .textFieldStyle(.roundedBorder)
                .disabled(isAsking)
                .onSubmit(submit)
            if isAsking {
                ProgressView().controlSize(.small)
            } else {
                Button("Ask", action: submit)
                    .disabled(questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func submit() {
        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking else { return }
        questionText = ""
        let entryId = UUID()
        transcript.append(AskTranscriptEntry(id: entryId, question: question, outcome: nil))
        isAsking = true
        Task {
            let outcome = await AskRunner.ask(
                question: question, repoRoot: repoRoot, outputDirectory: outputDirectory)
            if let index = transcript.firstIndex(where: { $0.id == entryId }) {
                transcript[index].outcome = outcome
            }
            isAsking = false
        }
    }
}

private struct AskEntryView: View {
    let repoRoot: URL
    let question: String
    let outcome: AskOutcome?
    @State private var showExplain = false
    @State private var selectedEvidence: EvidenceDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question).font(.headline)
            switch outcome {
            case nil:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(
                        "Thinking… (the first local-model question can take a few minutes to "
                            + "download real model weights)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            case .answered(let summary):
                answeredView(summary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(item: $selectedEvidence) { evidence in
            EvidenceView(repoRoot: repoRoot, evidence: evidence)
        }
    }

    @ViewBuilder
    private func answeredView(_ summary: AskResultSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            outcomeLabel(summary)
            Text(summary.answerText)
            if !summary.claims.isEmpty {
                claimsSection(summary.claims)
            } else if summary.claimCount > 0 || summary.droppedClaimCount > 0 {
                // Claims were recorded but couldn't be read back (best-effort in AskRunner) --
                // still say so, rather than silently showing nothing.
                Text(
                    "\(summary.claimCount) claim(s) recorded"
                        + (summary.droppedClaimCount > 0
                            ? ", \(summary.droppedClaimCount) dropped" : "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            DisclosureGroup("Explain", isExpanded: $showExplain) {
                explainDetail(summary)
            }
            .font(.caption)
        }
    }

    /// Docs/13 M7's own ask -- "evidence links (reusing the same Evidence view as M5)" -- each
    /// claim's evidence anchors are real, clickable, and open the identical `EvidenceView` a
    /// component's members do.
    private func claimsSection(_ claims: [AskClaimSummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(claims) { claim in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        EpistemicBadge(rawValue: claim.claimType)
                        ConfidenceBadge(tier: claim.confidence)
                    }
                    Text(claim.statement).font(.callout)
                    if !claim.evidence.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(claim.evidence) { evidence in
                                Button {
                                    selectedEvidence = evidence
                                } label: {
                                    Text(evidence.anchor)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    /// Docs/12 Risk #5's fix, actually applied at the UX layer here: a depth-1 answer that
    /// asserted nothing is never shown with the same green-checkmark weight a grounded
    /// depth-2/3 `verified` answer gets.
    @ViewBuilder
    private func outcomeLabel(_ summary: AskResultSummary) -> some View {
        if summary.isUngroundedVerified {
            Label("Not independently checked", systemImage: "questionmark.circle")
                .font(.caption.bold())
                .foregroundStyle(.orange)
        } else if summary.partial {
            // Docs/13 M8: name the real outcome (rejected/incomplete/unverified/
            // partially_verified) rather than a single generic "Partial" -- Docs/06 §7's
            // failure-transparency rule applies to *which* failure, not just that one happened.
            Label(
                "Partial — \(summary.outcome.replacingOccurrences(of: "_", with: " "))",
                systemImage: "exclamationmark.circle"
            )
            .font(.caption.bold())
            .foregroundStyle(.orange)
        } else {
            Label(
                summary.outcome.replacingOccurrences(of: "_", with: " ").capitalized,
                systemImage: "checkmark.seal.fill"
            )
            .font(.caption.bold())
            .foregroundStyle(.green)
        }
    }

    private func explainDetail(_ summary: AskResultSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Depth \(summary.depth) · \(summary.routingMethod) · confidence: \(summary.routingConfidence)")
                .foregroundStyle(.secondary)
            Text(summary.rationale)
                .foregroundStyle(.secondary)
            if !summary.toolCalls.isEmpty {
                Divider()
                ForEach(summary.toolCalls) { call in
                    Text("[\(call.turnIndex)] \(call.toolName)(\(call.arguments)) → \(call.result)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
}
