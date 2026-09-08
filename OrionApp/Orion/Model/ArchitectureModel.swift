import Foundation
import OrionCodeIntel

/// One node in the Architecture Overview diagram (Docs/13_phase4_architecture_ui.md M4) --
/// either a semantic component (Phase 2) or a structural module (Phase 1 fallback).
struct ArchitectureNode: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String?
    /// Member count (components) -- used for node sizing. Always 0 for structural/module nodes
    /// (Docs/13 M4's own v1 simplification: uniform module sizing, not a per-module symbol count).
    let size: Int
    /// `nil` for structural nodes (Phase 1 is all `FACT`-tier; there is no confidence spectrum to
    /// show). Present for semantic components (`ConfidenceTier` raw value).
    let confidenceTier: String?
    let epistemicType: String
}

/// One edge -- a `component_relationships` row (semantic) or an `imports` `relationships` row
/// between two module symbols (structural fallback). `confidenceTier` drives solid-vs-dashed
/// stroke styling (Docs/04: an unconfirmed relationship is drawn, never hidden).
struct ArchitectureEdge: Identifiable, Equatable {
    let id: String
    let sourceId: String
    let targetId: String
    let type: String
    let confidenceTier: String
}

/// Which layer is actually being shown -- Docs/13 M4's own requirement that the epistemic status
/// of what's on screen is never ambiguous.
enum ArchitectureLayer: Equatable {
    case structural(moduleCount: Int)
    case semantic(investigationId: String, componentCount: Int, investigatedAt: String?)
}

struct ArchitectureModel: Equatable {
    let layer: ArchitectureLayer
    let nodes: [ArchitectureNode]
    let edges: [ArchitectureEdge]
    /// Investigation-wide `uncertainties[]` (imported as evidence-free `UNKNOWN` claims, Docs/11)
    /// -- Docs/13 M6: surfaced as a visible "Open questions" list, not buried behind a
    /// disclosure. Always empty for the structural (no-investigation) layer.
    let uncertainties: [String]
}

/// Builds an `ArchitectureModel` from `CodebaseModelStore` -- semantic (components +
/// component_relationships) when a real investigation produced at least one component, else the
/// Phase-1-only module import graph (Docs/13 M4: "architecture is explorable from FACT-tier
/// structure alone; a semantic layer enriches it, it is never a hard prerequisite"). Pure logic,
/// no SwiftUI -- unit-testable without rendering anything.
enum ArchitectureModelLoader {
    static func load(outputDirectory: URL) throws -> ArchitectureModel {
        let store = CodebaseModelStore(outputDirectory: outputDirectory)
        guard let run = try store.latestRun() else {
            return ArchitectureModel(
                layer: .structural(moduleCount: 0), nodes: [], edges: [], uncertainties: [])
        }

        if let investigation = try latestArchitectureInvestigation(store: store, runId: run.id) {
            let components = try store.components(investigationId: investigation.id)
            if !components.isEmpty {
                return try buildSemanticModel(
                    store: store, investigation: investigation, components: components)
            }
        }
        return try buildStructuralModel(store: store, runId: run.id)
    }

    /// Docs/14_phase4_5_ui_ux_redesign.md §8 M5: a real bug found live during this milestone's own
    /// verification, not part of its planned scope. `investigations` is one shared table for both
    /// a whole-architecture "Build Architecture Model" pass (Docs/11's phase2.v1 schema -- its
    /// `question` column is always the literal marker `"phase2_semantic_grouping"`, see
    /// `Migrations.swift`'s own column default) and every one-off Ask question answered at depth 3
    /// (Docs/12), with no separate `kind` column to tell them apart. `store.latestInvestigation(runId:)`
    /// just grabs the single newest row of *either* kind -- so asking even one depth-3 question
    /// after a real architecture investigation silently regressed the whole Architecture Overview
    /// back to "no architecture investigation yet." The semantic components were still sitting in
    /// the database the entire time; they just stopped being what this loader looked at. Filters
    /// to the stable marker instead of trusting recency alone.
    private static func latestArchitectureInvestigation(
        store: CodebaseModelStore, runId: String
    ) throws -> InvestigationRecord? {
        try store.investigations(runId: runId)
            .filter { $0.question == "phase2_semantic_grouping" }
            .max { $0.createdAt < $1.createdAt }
    }

    private static func buildSemanticModel(
        store: CodebaseModelStore, investigation: InvestigationRecord,
        components: [ComponentRecord]
    ) throws -> ArchitectureModel {
        let members = try store.componentMembers(componentIds: components.map(\.id))
        let memberCounts = Dictionary(grouping: members, by: \.componentId).mapValues(\.count)

        let nodes = components.map { component in
            ArchitectureNode(
                id: component.id, name: component.name, subtitle: component.description,
                size: memberCounts[component.id] ?? 0, confidenceTier: component.confidenceTier,
                epistemicType: component.epistemicType)
        }
        let nodeIds = Set(nodes.map(\.id))

        let relationships = try store.componentRelationships(investigationId: investigation.id)
        var seenPairs = Set<String>()
        let edges: [ArchitectureEdge] = relationships.compactMap { relationship in
            guard relationship.sourceComponentId != relationship.targetComponentId,
                nodeIds.contains(relationship.sourceComponentId),
                nodeIds.contains(relationship.targetComponentId)
            else { return nil }
            let pairKey = "\(relationship.sourceComponentId)->\(relationship.targetComponentId)"
            guard seenPairs.insert(pairKey).inserted else { return nil }
            return ArchitectureEdge(
                id: relationship.id, sourceId: relationship.sourceComponentId,
                targetId: relationship.targetComponentId, type: relationship.relationshipType,
                confidenceTier: relationship.confidenceTier)
        }

        // Uncertainties are investigation-wide, not tied to any one component (Docs/11:
        // subject_ref is null for an uncertainties-derived claim) -- imported as `UNKNOWN`
        // claims with no evidence, so they'd never survive `ComponentDetailLoader`'s per-
        // component evidence-overlap filter. Shown once, at the investigation level, instead.
        let uncertainties = try store.claims(investigationId: investigation.id)
            .filter { $0.claimType == EpistemicTag.unknown.rawValue }
            .map(\.statement)

        return ArchitectureModel(
            layer: .semantic(
                investigationId: investigation.id, componentCount: components.count,
                investigatedAt: investigation.createdAt),
            nodes: nodes, edges: edges, uncertainties: uncertainties)
    }

    private static func buildStructuralModel(
        store: CodebaseModelStore, runId: String
    ) throws -> ArchitectureModel {
        let symbols = try store.symbols(runId: runId)
        let moduleSymbols = symbols.filter { $0.kind == "module" || $0.kind == "package" }
        let nodeIds = Set(moduleSymbols.map(\.id))
        let nodes = moduleSymbols.map { symbol in
            ArchitectureNode(
                id: symbol.id, name: symbol.qualifiedName, subtitle: nil, size: 0,
                confidenceTier: nil, epistemicType: "FACT")
        }

        let relationships = try store.relationships(runId: runId)
        var seenPairs = Set<String>()
        let edges: [ArchitectureEdge] = relationships.compactMap { relationship in
            guard relationship.relationshipType == "imports",
                let source = relationship.sourceSymbolId, let target = relationship.targetSymbolId,
                source != target, nodeIds.contains(source), nodeIds.contains(target)
            else { return nil }
            let pairKey = "\(source)->\(target)"
            guard seenPairs.insert(pairKey).inserted else { return nil }
            return ArchitectureEdge(
                id: relationship.id, sourceId: source, targetId: target, type: "imports",
                confidenceTier: "high")
        }

        return ArchitectureModel(
            layer: .structural(moduleCount: nodes.count), nodes: nodes, edges: edges,
            uncertainties: [])
    }
}
