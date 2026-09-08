import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §4.6/§8 M4: a master-detail list, not a chat transcript.
///
/// The first pass of this redesign kept a single flowing transcript (every question and answer in
/// one scrolling column, ChatGPT-style) -- the wrong model for this app specifically. Orion's
/// premise is that a developer returns to a specific answer as reference material (Docs/04 §6),
/// not that they're having one continuous conversation; finding what you asked about a component
/// two days ago meant scrolling past every unrelated question in between. This is the fix: a
/// searchable, component-grouped question list on the left, the selected question's full answer
/// on the right -- matching the rest of the app (a scannable list, click through to detail)
/// instead of a chat app.
struct AskView: View {
    let repoRoot: URL
    let outputDirectory: URL
    let history: AskHistory
    let diagnosticsSession: DiagnosticsSession

    @State private var questionText = ""
    @State private var search = ""
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    questionList
                    Divider()
                    detail
                }
            }
            Divider()
            if let scope = history.pendingScope {
                scopeChip(scope)
            }
            inputBar
        }
    }

    /// Docs/14 §8 M8.5 item 6: makes the pending scope from "Ask about {name}" (or the lack of
    /// one) a visible, deliberate state rather than an invisible flag -- and the × is the real
    /// "ask a general question instead" affordance the moment a scope is showing. When nothing is
    /// scoped, the plain input bar below already *is* the general-question flow, so no separate
    /// control is needed for that case.
    private func scopeChip(_ scope: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.caption2)
            Text("Asking about \(scope)")
                .font(.caption)
            Button {
                history.pendingScope = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask a general question instead")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DesignTokens.accent.opacity(0.12))
        .clipShape(Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 8)
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

    // MARK: - Left: the question list

    private var questionList: some View {
        VStack(spacing: 0) {
            TextField("Search your questions…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            let groups = history.groups(matching: search)
            if groups.isEmpty {
                Text("No questions match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section(group.name, isExpanded: expandedBinding(for: group.name)) {
                            ForEach(group.entries) { entry in
                                questionRow(entry)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 260)
    }

    private func expandedBinding(for groupName: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(groupName) },
            set: { isExpanded in
                if isExpanded {
                    collapsedGroups.remove(groupName)
                } else {
                    collapsedGroups.insert(groupName)
                }
            })
    }

    private func questionRow(_ entry: AskHistoryEntry) -> some View {
        Button {
            history.selectedID = entry.id
        } label: {
            HStack(alignment: .top, spacing: 6) {
                outcomeDot(entry.outcome)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.question)
                        .font(.callout)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Text(entry.askedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            entry.id == history.selectedID ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    @ViewBuilder
    private func outcomeDot(_ outcome: AskOutcome?) -> some View {
        switch outcome {
        case nil:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .answered(let summary):
            if summary.isUngroundedVerified || summary.partial {
                Image(systemName: summary.partial ? "exclamationmark.circle.fill" : "questionmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Right: the selected question's answer

    @ViewBuilder
    private var detail: some View {
        if let selected = history.entries.first(where: { $0.id == history.selectedID }) {
            ScrollView {
                AskEntryView(repoRoot: repoRoot, question: selected.question, outcome: selected.outcome)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Select a question", systemImage: "bubble.left.and.bubble.right",
                description: Text("Choose a question on the left to see its answer."))
        }
    }

    // MARK: - Bottom: asking a new question

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask a new question about this repository…", text: $questionText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Button("Ask", action: submit)
                .disabled(questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func submit() {
        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        questionText = ""
        let id = history.ask(question, component: history.pendingScope)
        Task {
            let outcome = await AskRunner.ask(
                question: question, repoRoot: repoRoot, outputDirectory: outputDirectory)
            history.resolve(id, outcome: outcome)
            diagnosticsSession.recordAsk(question: question, outcome: outcome)
        }
    }
}

/// Unchanged content from before this redesign -- outcome label (including the Docs/12 Risk #5
/// "Not independently checked" treatment for ungrounded depth-1 answers), the answer text, claims
/// with clickable evidence, and routing detail behind "Explain." Only its container changed, from
/// one entry in a scrolling transcript to the sole content of the detail pane.
struct AskEntryView: View {
    let repoRoot: URL
    let question: String
    let outcome: AskOutcome?
    @State private var showExplain = false
    @State private var selectedEvidence: EvidenceDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question).font(.title3.bold())
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
        .sheet(item: $selectedEvidence) { evidence in
            EvidenceView(repoRoot: repoRoot, evidence: evidence)
        }
    }

    @ViewBuilder
    private func answeredView(_ summary: AskResultSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            outcomeLabel(summary)
            MarkdownText(raw: summary.answerText)
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
                    MarkdownText(raw: claim.statement).font(.callout)
                    if !claim.evidence.isEmpty {
                        // Docs/14 §8 M8.6: one evidence link per line -- see
                        // `ComponentDetailView.claimsList`'s identical fix for the full reasoning;
                        // an `HStack` here squeezed each anchor into its own narrow wrapped
                        // column instead of using the row's full width.
                        VStack(alignment: .leading, spacing: 4) {
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
            MarkdownText(raw: summary.rationale)
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
