import Foundation
import OrionCodeIntel

/// One evidence anchor -- a member symbol's own location, or a claim's cited evidence row.
/// Clicking it opens `EvidenceView` (Docs/13_phase4_architecture_ui.md M5).
struct EvidenceDetail: Identifiable, Equatable {
    let id: String
    let anchor: String
    let startLine: Int?
    let endLine: Int?
}

struct ComponentMemberDetail: Identifiable, Equatable {
    let id: String
    let anchor: String
    let name: String
    let kind: String
    let startLine: Int
    let endLine: Int

    var evidence: EvidenceDetail {
        EvidenceDetail(id: id, anchor: anchor, startLine: startLine, endLine: endLine)
    }
}

struct ComponentDependencyDetail: Identifiable, Equatable {
    let id: String
    let targetName: String
    let type: String
    let confidenceTier: String
}

/// A claim whose evidence cites at least one of this component's own members -- a real,
/// data-derived link (shared anchors), not a fabricated claim-to-component association; the
/// schema has no direct `claims.component_id` column (Docs/11: a claim is investigation-scoped,
/// not component-scoped).
struct ComponentClaimDetail: Identifiable, Equatable {
    let id: String
    let statement: String
    let claimType: String
    let confidence: String
    let evidence: [EvidenceDetail]
    /// Docs/16_phase6_continuous_model_updates.md §8, M5: the `model_revisions` row that
    /// reversed this exact claim, when one exists -- drives the "Superseded — see Model Changes"
    /// cross-reference (Docs/14 §2's own named, previously-unbuilt PAIR pattern).
    let reversedByRevisionId: String?
}

/// The full Component Exploration payload (Docs/05 Stage 4 / Docs/08 "component cards"): Purpose,
/// member list, Dependencies, Claims & Evidence, Confidence. `isStructural` distinguishes a
/// Phase-1-only module (no semantic grouping, no claims) from a real Phase 2 component, per
/// Docs/13's own instruction that a structural node must be "plainly labeled as structural."
struct ComponentDetail: Equatable {
    let id: String
    let name: String
    let subtitle: String?
    let epistemicType: String
    let confidenceTier: String?
    let isStructural: Bool
    let members: [ComponentMemberDetail]
    let dependencies: [ComponentDependencyDetail]
    let claims: [ComponentClaimDetail]
}

/// Loads `ComponentDetail` for one `ArchitectureNode` -- a thin adapter over
/// `OrionCodeIntel.ComponentDetailQuery` (Docs/15_phase5_adaptive_exploration.md M2: the actual
/// query logic moved down there so a Phase 5 component-scoped session's context-priming can
/// reuse the identical "one component's members/dependencies/evidence-linked claims" slice
/// without a second copy of it living only in this app target). This type's own remaining job is
/// entirely UI-shaped: pick which of the two queries `layer` calls for, and supply the
/// `ArchitectureNode`-shaped empty placeholder `ComponentDetailQuery` itself has no `node` to
/// fall back to.
enum ComponentDetailLoader {
    static func load(
        outputDirectory: URL, node: ArchitectureNode, layer: ArchitectureLayer
    ) throws -> ComponentDetail {
        let store = Store(try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path))
        switch layer {
        case .semantic(let investigationId, _, _):
            guard
                let result = try ComponentDetailQuery.semanticDetail(
                    store: store, investigationId: investigationId, componentId: node.id)
            else { return emptyDetail(for: node) }
            return ComponentDetail(result)
        case .structural:
            guard let run = try store.latestRun(commitHash: nil) else { return emptyDetail(for: node) }
            guard
                let result = try ComponentDetailQuery.structuralDetail(
                    store: store, runId: run.id, moduleSymbolId: node.id)
            else { return emptyDetail(for: node) }
            return ComponentDetail(result)
        }
    }

    private static func emptyDetail(for node: ArchitectureNode) -> ComponentDetail {
        ComponentDetail(
            id: node.id, name: node.name, subtitle: node.subtitle,
            epistemicType: node.epistemicType, confidenceTier: node.confidenceTier,
            isStructural: node.confidenceTier == nil, members: [], dependencies: [], claims: [])
    }
}

extension ComponentDetail {
    init(_ result: ComponentDetailQuery.Detail) {
        self.init(
            id: result.id, name: result.name, subtitle: result.subtitle,
            epistemicType: result.epistemicType, confidenceTier: result.confidenceTier,
            isStructural: result.isStructural, members: result.members.map(ComponentMemberDetail.init),
            dependencies: result.dependencies.map(ComponentDependencyDetail.init),
            claims: result.claims.map(ComponentClaimDetail.init))
    }
}

extension ComponentMemberDetail {
    init(_ member: ComponentDetailQuery.Member) {
        self.init(
            id: member.id, anchor: member.anchor, name: member.name, kind: member.kind,
            startLine: member.startLine, endLine: member.endLine)
    }
}

extension ComponentDependencyDetail {
    init(_ dependency: ComponentDetailQuery.Dependency) {
        self.init(
            id: dependency.id, targetName: dependency.targetName, type: dependency.type,
            confidenceTier: dependency.confidenceTier)
    }
}

extension ComponentClaimDetail {
    init(_ claim: ComponentDetailQuery.Claim) {
        self.init(
            id: claim.id, statement: claim.statement, claimType: claim.claimType,
            confidence: claim.confidence, evidence: claim.evidence.map(EvidenceDetail.init),
            reversedByRevisionId: claim.reversedByRevisionId)
    }
}

extension EvidenceDetail {
    init(_ evidence: ComponentDetailQuery.Evidence) {
        self.init(
            id: evidence.id, anchor: evidence.anchor, startLine: evidence.startLine,
            endLine: evidence.endLine)
    }
}
