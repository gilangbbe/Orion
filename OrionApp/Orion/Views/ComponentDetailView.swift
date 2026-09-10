import SwiftUI

/// Docs/13_phase4_architecture_ui.md M5 / Docs/05 Stage 4 / Docs/08 "component cards": Purpose,
/// member list (grouped by kind), Dependencies, Claims & Evidence, Confidence. A structural
/// (Phase-1-only) node is plainly labeled as such -- no semantic grouping, no claims -- rather
/// than presented the same way a real investigated component is.
///
/// Docs/14_phase4_5_ui_ux_redesign.md §4.5/§8 M3: lives inside `ContentView`'s shared inspector
/// now, not its own `.sheet` -- the component's name is the inspector's shared title (this view no
/// longer draws its own `header(_:)`), and this view now also owns the "Ask about {name}" button
/// (Docs/05 Stage 4: "the developer can ask questions about the selected component"). §8 M4 first
/// had this button file a canned question immediately; §8 M8.5 item 6 replaced that with a real
/// hand-off -- see `askAbout(_:)`'s own doc comment.
struct ComponentDetailView: View {
    let outputDirectory: URL
    let repoRoot: URL
    let node: ArchitectureNode
    let layer: ArchitectureLayer
    let shellState: AppShellState
    let askHistory: AskHistory

    @State private var detail: ComponentDetail?
    @State private var loadError: String?
    @State private var selectedEvidence: EvidenceDetail?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Couldn't load component", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else if let detail {
                content(detail)
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .sheet(item: $selectedEvidence) { evidence in
            EvidenceView(repoRoot: repoRoot, evidence: evidence)
        }
    }

    private func load() async {
        do {
            detail = try await Task.detached(priority: .userInitiated) {
                try ComponentDetailLoader.load(outputDirectory: outputDirectory, node: node, layer: layer)
            }.value
        } catch {
            loadError = String(describing: error)
        }
    }

    /// Docs/14 §8 M4's original hand-off asked a canned question ("Tell me more about {name}.")
    /// immediately -- §8 M8.5 item 6 replaced that with a scoped-question hand-off, and
    /// Docs/15_phase5_adaptive_exploration.md §5/M6 replaces *that* with the finalized
    /// resume-or-create session decision (`AskHistory.askAbout(_:componentId:outputDirectory:)`'s
    /// own doc comment has the full reasoning): switches to Ask, and either resumes this
    /// component's most recently active session or marks the next "New session" action as scoped
    /// to it -- either way, still files nothing until the developer actually types and submits
    /// their own question.
    ///
    /// Passes `detail.id` straight through as the real `components` row id -- a live bug this
    /// fixed had `AskHistory` re-derive it later from the component's *name* via "the run's
    /// latest investigation," which silently broke the instant any question had ever been asked
    /// (see `AskHistory`'s own doc comment). `detail` already has the id right here; there's no
    /// reason to lose it and look it back up. `nil` for a structural (Phase-1-only) node, which
    /// has no real `ComponentRecord` at all -- its "Ask about" still starts a session, just
    /// without a component to prime context from.
    private func askAbout(_ detail: ComponentDetail) {
        shellState.destination = .ask
        let componentId = detail.isStructural ? nil : detail.id
        Task { await askHistory.askAbout(detail.name, componentId: componentId, outputDirectory: outputDirectory) }
    }

    @ViewBuilder
    private func content(_ detail: ComponentDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if detail.isStructural {
                    Label(
                        "Structural view — from Phase 1 deterministic analysis only, not a semantic grouping.",
                        systemImage: "cube"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let tier = detail.confidenceTier {
                    ConfidenceBadge(tier: tier)
                }

                Button {
                    askAbout(detail)
                } label: {
                    Label("Ask about \(detail.name)", systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let subtitle = detail.subtitle {
                    section("Purpose") {
                        VStack(alignment: .leading, spacing: 4) {
                            MarkdownText(raw: subtitle)
                            EpistemicBadge(rawValue: detail.epistemicType)
                        }
                    }
                }

                if !detail.members.isEmpty {
                    section("Members (\(detail.members.count))") {
                        membersList(detail.members)
                    }
                }

                if !detail.dependencies.isEmpty {
                    section("Dependencies") {
                        dependenciesList(detail.dependencies)
                    }
                }

                if !detail.claims.isEmpty {
                    section("Claims & Evidence") {
                        claimsList(detail.claims)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func membersList(_ members: [ComponentMemberDetail]) -> some View {
        let grouped = Dictionary(grouping: members, by: \.kind)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(grouped.keys.sorted(), id: \.self) { kind in
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.capitalized)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(grouped[kind] ?? []) { member in
                        evidenceLink(member.name, evidence: member.evidence)
                    }
                }
            }
        }
    }

    private func dependenciesList(_ dependencies: [ComponentDependencyDetail]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(dependencies) { dependency in
                HStack(spacing: 8) {
                    Text(dependency.type)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(dependency.targetName)
                    Spacer()
                    ConfidenceBadge(tier: dependency.confidenceTier)
                }
            }
        }
    }

    private func claimsList(_ claims: [ComponentClaimDetail]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(claims) { claim in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        EpistemicBadge(rawValue: claim.claimType)
                        Spacer()
                        ConfidenceBadge(tier: claim.confidence)
                    }
                    MarkdownText(raw: claim.statement)
                    if let revisionId = claim.reversedByRevisionId {
                        supersededLink(revisionId: revisionId)
                    }
                    // Docs/14 §8 M8.6: one evidence link per line, not a side-by-side `HStack` --
                    // a real `anchor` is a full repo-relative path plus `::symbol`, easily longer
                    // than a third of the inspector's width; squeezed into an `HStack` alongside
                    // its siblings, each link's `Text` wrapped inside its own narrow column
                    // instead of using the row's actual full width, turning three anchors into
                    // an unreadable three-column mess. A full-width leading row per link fixes it
                    // regardless of how long any single anchor gets.
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(claim.evidence) { evidence in
                            evidenceLink(evidence.anchor, evidence: evidence)
                        }
                    }
                }
                if claim.id != claims.last?.id {
                    Divider()
                }
            }
        }
    }

    /// Docs/16_phase6_continuous_model_updates.md §8, M5 / Docs/14 §2's own named PAIR pattern:
    /// "`CONTRADICTED` claims are shown inline with a 'Superseded — see Model Changes'
    /// cross-reference, not hidden or silently dropped" -- previously unbuilt because there was no
    /// persisted revision history to link to (Docs/14 §7 Decision 3). Jumps to the Model Changes
    /// destination with the specific revision that reversed this claim ready to expand.
    private func supersededLink(revisionId: String) -> some View {
        Button {
            shellState.focusedModelChangeRevisionId = revisionId
            shellState.destination = .changes
        } label: {
            Label("Superseded — see Model Changes", systemImage: "clock.arrow.circlepath")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignTokens.accent)
    }

    private func evidenceLink(_ label: String, evidence: EvidenceDetail) -> some View {
        Button {
            selectedEvidence = evidence
        } label: {
            Text(label)
                .font(.callout.monospaced())
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }
}
