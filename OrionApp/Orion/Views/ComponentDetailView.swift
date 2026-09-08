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
    /// immediately -- §8 M8.5 item 6 replaces that: switches to Ask and marks the *next* question
    /// as scoped to this component (`AskHistory.pendingScope`, its own doc comment has the full
    /// reasoning), but files nothing and calls `AskRunner` for nothing until the developer actually
    /// types and submits their own question in `AskView`'s input bar.
    private func askAbout(_ name: String) {
        shellState.destination = .ask
        askHistory.pendingScope = name
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
                    askAbout(detail.name)
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
