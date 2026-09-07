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

/// Loads `ComponentDetail` for one `ArchitectureNode` -- pure logic over `CodebaseModelStore`,
/// same posture as `ArchitectureModelLoader`. `layer` tells it which of the two very different
/// queries to run (a `components` row + its members/relationships/claims, or a module symbol +
/// same-file symbols/import edges).
enum ComponentDetailLoader {
    static func load(
        outputDirectory: URL, node: ArchitectureNode, layer: ArchitectureLayer
    ) throws -> ComponentDetail {
        let store = CodebaseModelStore(outputDirectory: outputDirectory)
        switch layer {
        case .semantic(let investigationId, _, _):
            return try loadSemantic(store: store, node: node, investigationId: investigationId)
        case .structural:
            guard let run = try store.latestRun() else { return emptyDetail(for: node) }
            return try loadStructural(store: store, node: node, runId: run.id)
        }
    }

    private static func emptyDetail(for node: ArchitectureNode) -> ComponentDetail {
        ComponentDetail(
            id: node.id, name: node.name, subtitle: node.subtitle,
            epistemicType: node.epistemicType, confidenceTier: node.confidenceTier,
            isStructural: node.confidenceTier == nil, members: [], dependencies: [], claims: [])
    }

    private static func loadSemantic(
        store: CodebaseModelStore, node: ArchitectureNode, investigationId: String
    ) throws -> ComponentDetail {
        let components = try store.components(investigationId: investigationId)
        guard let component = components.first(where: { $0.id == node.id }) else {
            return emptyDetail(for: node)
        }

        let allSymbols = try store.symbols(runId: component.runId)
        let symbolsById = Dictionary(uniqueKeysWithValues: allSymbols.map { ($0.id, $0) })

        let memberRows = try store.componentMembers(componentIds: [component.id])
        let members: [ComponentMemberDetail] =
            memberRows
            .compactMap { member in
                guard let symbol = symbolsById[member.symbolId] else { return nil }
                return ComponentMemberDetail(
                    id: symbol.id, anchor: symbol.anchor, name: symbol.name, kind: symbol.kind,
                    startLine: symbol.startLine, endLine: symbol.endLine)
            }
            .sorted { $0.name < $1.name }
        let memberAnchors = Set(members.map(\.anchor))

        let namesById = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0.name) })
        let relationships = try store.componentRelationships(investigationId: investigationId)
        let dependencies: [ComponentDependencyDetail] = relationships
            .filter { $0.sourceComponentId == component.id }
            .compactMap { relationship in
                guard let targetName = namesById[relationship.targetComponentId] else { return nil }
                return ComponentDependencyDetail(
                    id: relationship.id, targetName: targetName, type: relationship.relationshipType,
                    confidenceTier: relationship.confidenceTier)
            }

        let allClaims = try store.claims(investigationId: investigationId)
        let allEvidence = try store.evidence(claimIds: allClaims.map(\.id))
        let evidenceByClaim = Dictionary(grouping: allEvidence, by: \.claimId)
        let claims: [ComponentClaimDetail] = allClaims.compactMap { claim -> ComponentClaimDetail? in
            let evidenceRows = evidenceByClaim[claim.id] ?? []
            guard evidenceRows.contains(where: { memberAnchors.contains($0.anchor) }) else {
                return nil
            }
            let evidence = evidenceRows.map {
                EvidenceDetail(id: $0.id, anchor: $0.anchor, startLine: $0.startLine, endLine: $0.endLine)
            }
            return ComponentClaimDetail(
                id: claim.id, statement: claim.statement, claimType: claim.claimType,
                confidence: ConfidenceBadge.tierLabel(forScore: claim.confidence), evidence: evidence)
        }

        return ComponentDetail(
            id: component.id, name: component.name, subtitle: component.description,
            epistemicType: component.epistemicType, confidenceTier: component.confidenceTier,
            isStructural: false, members: members, dependencies: dependencies, claims: claims)
    }

    private static func loadStructural(
        store: CodebaseModelStore, node: ArchitectureNode, runId: String
    ) throws -> ComponentDetail {
        let allSymbols = try store.symbols(runId: runId)
        guard let moduleSymbol = allSymbols.first(where: { $0.id == node.id }) else {
            return emptyDetail(for: node)
        }

        let members: [ComponentMemberDetail] =
            allSymbols
            .filter { $0.fileId == moduleSymbol.fileId && $0.id != moduleSymbol.id }
            .map {
                ComponentMemberDetail(
                    id: $0.id, anchor: $0.anchor, name: $0.name, kind: $0.kind,
                    startLine: $0.startLine, endLine: $0.endLine)
            }
            .sorted { $0.name < $1.name }

        let symbolsById = Dictionary(uniqueKeysWithValues: allSymbols.map { ($0.id, $0) })
        let relationships = try store.relationships(runId: runId)
        let dependencies: [ComponentDependencyDetail] = relationships.compactMap { relationship in
            guard relationship.relationshipType == "imports",
                relationship.sourceSymbolId == moduleSymbol.id,
                let targetId = relationship.targetSymbolId, let target = symbolsById[targetId]
            else { return nil }
            return ComponentDependencyDetail(
                id: relationship.id, targetName: target.qualifiedName, type: "imports",
                confidenceTier: "high")
        }

        return ComponentDetail(
            id: moduleSymbol.id, name: moduleSymbol.qualifiedName, subtitle: nil,
            epistemicType: "FACT", confidenceTier: nil, isStructural: true, members: members,
            dependencies: dependencies, claims: [])
    }
}
