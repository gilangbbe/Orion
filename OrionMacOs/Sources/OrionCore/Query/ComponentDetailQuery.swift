import Foundation

/// The pure-logic half of what was `OrionApp`'s own `ComponentDetailLoader`
/// (Docs/13_phase4_architecture_ui.md M5) — relocated here (Docs/15_phase5_adaptive_exploration.md
/// M2) so both `OrionApp`'s Component Exploration panel and a Phase 5 component-scoped session's
/// context-priming (`ContextBuilder`, M3) can slice the same "one component's members,
/// dependencies, and evidence-linked claims" shape without one of them holding a private copy of
/// the query logic. Operates directly on `Store` — no `CodebaseModelStore` needed, that type was
/// always a thin, app-local passthrough over methods `Store` already exposed.
///
/// Unlike `OrionApp`'s original `ComponentDetailLoader.load(outputDirectory:node:layer:)`, this
/// takes no `ArchitectureNode`/`ArchitectureLayer` — both are app-target UI model types this
/// module must not depend on (no AppKit/SwiftUI, no app-layer types, per Docs 10/12's existing
/// discipline). The two lookups this type offers (`semanticDetail`/`structuralDetail`) return
/// `nil` when the id doesn't resolve; the "fall back to an empty, node-shaped placeholder" UX
/// behavior stays entirely in `OrionApp`'s own thin adapter, since only the UI layer has a `node`
/// to fall back to.
public enum ComponentDetailQuery {

    /// One member symbol — a component's own member, or (for a structural "component") a
    /// same-file symbol.
    public struct Member: Equatable, Sendable {
        public let id: String
        public let anchor: String
        public let name: String
        public let kind: String
        public let startLine: Int
        public let endLine: Int
    }

    /// One outbound dependency — a semantic `component_relationships` edge to another component,
    /// or (structural) a module-level `imports` edge.
    public struct Dependency: Equatable, Sendable {
        public let id: String
        public let targetName: String
        public let type: String
        public let confidenceTier: String
    }

    /// One evidence anchor backing a claim.
    public struct Evidence: Equatable, Sendable {
        public let id: String
        public let anchor: String
        public let startLine: Int?
        public let endLine: Int?
    }

    /// A claim whose evidence cites at least one of the component's own members — a real,
    /// data-derived link (shared anchors), not a fabricated claim-to-component association; the
    /// schema has no direct `claims.component_id` column (Docs/11: a claim is
    /// investigation-scoped, not component-scoped). Always empty for a structural result — Phase
    /// 1 alone has no claims.
    public struct Claim: Equatable, Sendable {
        public let id: String
        public let statement: String
        public let claimType: String
        /// The tier label for `ClaimRecord.confidence` (a bare `Double` score, not the tier
        /// string other records keep alongside it) — `ConfidenceTier.label(forScore:)`, moved
        /// down from `OrionApp`'s own `ConfidenceBadge.tierLabel(forScore:)` in this same
        /// milestone so this module isn't reaching back up into a SwiftUI-adjacent type for a
        /// pure string mapping.
        public let confidence: String
        public let evidence: [Evidence]
        /// The `model_revisions` row (if any) whose `RevisionDiffer` diff reversed this exact
        /// claim (Docs/16_phase6_continuous_model_updates.md §8, M5) — drives the app's
        /// `CONTRADICTED`-claim -> Model Changes cross-reference (Docs/14 §2's "Superseded — see
        /// Model Changes"). `nil` for a claim nothing ever reversed, including every `CONTRADICTED`
        /// claim from `SemanticImporter`'s own *within*-investigation structural check (Docs/11
        /// M2) that no later investigation has touched — that's a different, older mechanism this
        /// field doesn't speak to.
        public let reversedByRevisionId: String?
    }

    /// Purpose / member list / Dependencies / Claims & Evidence / Confidence — Docs/05 Stage 4,
    /// Docs/08 "component cards"/"evidence view". `isStructural` distinguishes a Phase-1-only
    /// module (no semantic grouping, no claims) from a real Phase 2 component, per Docs/13's own
    /// instruction that a structural node must be "plainly labeled as structural."
    public struct Detail: Equatable, Sendable {
        public let id: String
        public let name: String
        public let subtitle: String?
        public let epistemicType: String
        public let confidenceTier: String?
        public let isStructural: Bool
        public let members: [Member]
        public let dependencies: [Dependency]
        public let claims: [Claim]
    }

    /// A semantic component's full detail. `nil` when `componentId` doesn't resolve within
    /// `investigationId` — the caller decides what "not found" means for its own context (an
    /// empty node-shaped placeholder in `OrionApp`, a skipped context section in `ContextBuilder`).
    public static func semanticDetail(
        store: Store, investigationId: String, componentId: String
    ) throws -> Detail? {
        let components = try store.components(investigationId: investigationId)
        guard let component = components.first(where: { $0.id == componentId }) else {
            return nil
        }

        let allSymbols = try store.symbols(runId: component.runId)
        let symbolsById = Dictionary(uniqueKeysWithValues: allSymbols.map { ($0.id, $0) })

        let memberRows = try store.componentMembers(componentIds: [component.id])
        let members: [Member] =
            memberRows
            .compactMap { member in
                guard let symbol = symbolsById[member.symbolId] else { return nil }
                return Member(
                    id: symbol.id, anchor: symbol.anchor, name: symbol.name, kind: symbol.kind,
                    startLine: symbol.startLine, endLine: symbol.endLine)
            }
            .sorted { $0.name < $1.name }
        let memberAnchors = Set(members.map(\.anchor))

        let namesById = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0.name) })
        let relationships = try store.componentRelationships(investigationId: investigationId)
        let dependencies: [Dependency] = relationships
            .filter { $0.sourceComponentId == component.id }
            .compactMap { relationship in
                guard let targetName = namesById[relationship.targetComponentId] else { return nil }
                return Dependency(
                    id: relationship.id, targetName: targetName, type: relationship.relationshipType,
                    confidenceTier: relationship.confidenceTier)
            }

        let allClaims = try store.claims(investigationId: investigationId)
        let allEvidence = try store.evidence(claimIds: allClaims.map(\.id))
        let evidenceByClaim = Dictionary(grouping: allEvidence, by: \.claimId)
        let claims: [Claim] = allClaims.compactMap { claim -> Claim? in
            let evidenceRows = evidenceByClaim[claim.id] ?? []
            guard evidenceRows.contains(where: { memberAnchors.contains($0.anchor) }) else {
                return nil
            }
            let evidence = evidenceRows.map {
                Evidence(id: $0.id, anchor: $0.anchor, startLine: $0.startLine, endLine: $0.endLine)
            }
            let reversedBy = (try? store.modelRevisionEntries(relatedClaimId: claim.id))?
                .first { $0.changeType == ModelRevisionChangeType.reversed.rawValue }?
                .modelRevisionId
            return Claim(
                id: claim.id, statement: claim.statement, claimType: claim.claimType,
                confidence: ConfidenceTier.label(forScore: claim.confidence), evidence: evidence,
                reversedByRevisionId: reversedBy)
        }

        return Detail(
            id: component.id, name: component.name, subtitle: component.description,
            epistemicType: component.epistemicType, confidenceTier: component.confidenceTier,
            isStructural: false, members: members, dependencies: dependencies, claims: claims)
    }

    /// Convenience entry point for a caller that only has a bare `componentId` — a session
    /// (Docs/15 §4.3) knows which component it's scoped to, not which investigation produced it.
    /// Resolves `investigationId` off the component's own row (`ComponentRecord.investigationId`)
    /// first, then delegates to `semanticDetail(store:investigationId:componentId:)`. `nil` when
    /// `componentId` doesn't resolve to a component at all.
    public static func semanticDetail(store: Store, componentId: String) throws -> Detail? {
        guard let component = try store.component(id: componentId) else { return nil }
        return try semanticDetail(
            store: store, investigationId: component.investigationId, componentId: componentId)
    }

    /// A Phase-1-only structural "component": one module symbol, its same-file symbols as
    /// members, and its own `imports` edges as dependencies. `nil` when `moduleSymbolId` doesn't
    /// resolve within `runId`.
    public static func structuralDetail(
        store: Store, runId: String, moduleSymbolId: String
    ) throws -> Detail? {
        let allSymbols = try store.symbols(runId: runId)
        guard let moduleSymbol = allSymbols.first(where: { $0.id == moduleSymbolId }) else {
            return nil
        }

        let members: [Member] =
            allSymbols
            .filter { $0.fileId == moduleSymbol.fileId && $0.id != moduleSymbol.id }
            .map {
                Member(
                    id: $0.id, anchor: $0.anchor, name: $0.name, kind: $0.kind,
                    startLine: $0.startLine, endLine: $0.endLine)
            }
            .sorted { $0.name < $1.name }

        let symbolsById = Dictionary(uniqueKeysWithValues: allSymbols.map { ($0.id, $0) })
        let relationships = try store.relationships(runId: runId)
        let dependencies: [Dependency] = relationships.compactMap { relationship in
            guard relationship.relationshipType == "imports",
                relationship.sourceSymbolId == moduleSymbol.id,
                let targetId = relationship.targetSymbolId, let target = symbolsById[targetId]
            else { return nil }
            return Dependency(
                id: relationship.id, targetName: target.qualifiedName, type: "imports",
                confidenceTier: "high")
        }

        return Detail(
            id: moduleSymbol.id, name: moduleSymbol.qualifiedName, subtitle: nil,
            epistemicType: "FACT", confidenceTier: nil, isStructural: true, members: members,
            dependencies: dependencies, claims: [])
    }
}
