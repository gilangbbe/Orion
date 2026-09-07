import SwiftUI

/// Docs/13_phase4_architecture_ui.md M5 / Docs/05 Stage 4 / Docs/08 "component cards": Purpose,
/// member list (grouped by kind), Dependencies, Claims & Evidence, Confidence. A structural
/// (Phase-1-only) node is plainly labeled as such -- no semantic grouping, no claims -- rather
/// than presented the same way a real investigated component is (Docs/13's own instruction).
/// Epistemic type and confidence tier both use the shared `EpistemicBadge`/`ConfidenceBadge`
/// (Docs/13 M6) -- this view's own ad-hoc badges were retrofitted there.
struct ComponentDetailView: View {
    let outputDirectory: URL
    let repoRoot: URL
    let node: ArchitectureNode
    let layer: ArchitectureLayer

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
                ProgressView().frame(minWidth: 480, minHeight: 360)
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

    @ViewBuilder
    private func content(_ detail: ComponentDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(detail)

                if detail.isStructural {
                    Label(
                        "Structural view — from Phase 1 deterministic analysis only, not a semantic grouping.",
                        systemImage: "cube"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let subtitle = detail.subtitle {
                    section("Purpose") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(subtitle)
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
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 480)
    }

    private func header(_ detail: ComponentDetail) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(detail.name).font(.title2.bold())
            Spacer()
            if let tier = detail.confidenceTier {
                ConfidenceBadge(tier: tier)
            }
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
                    Text(claim.statement)
                    HStack(spacing: 8) {
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
