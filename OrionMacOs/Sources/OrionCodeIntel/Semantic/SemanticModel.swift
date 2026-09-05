import Foundation

/// Assembles one investigation's persisted rows into the shapes the JSON/JSONL export emits
/// (Docs/11 M3). Mirrors `CodeGraphModel`'s pattern (Phase 1) but for the semantic layer —
/// kept separate from the file writer so the shapes are unit-testable.
public struct SemanticModel {
    let investigation: InvestigationRecord
    let components: [ComponentRecord]
    let componentMembers: [ComponentMemberRecord]
    let componentRelationships: [ComponentRelationshipRecord]
    let claims: [ClaimRecord]
    let evidence: [EvidenceRecord]
    /// Every investigation ever ingested for this run, not just the latest — `investigations
    /// .jsonl` is a full history (like Phase 1's `diagnostics.jsonl`), while every other export
    /// file here scopes to `investigation` alone (Docs/11: "the" current semantic model).
    let allInvestigations: [InvestigationRecord]

    private let componentNameById: [String: String]
    private let anchorBySymbolId: [String: String]

    public init(
        investigation: InvestigationRecord, components: [ComponentRecord],
        componentMembers: [ComponentMemberRecord],
        componentRelationships: [ComponentRelationshipRecord], claims: [ClaimRecord],
        evidence: [EvidenceRecord], allInvestigations: [InvestigationRecord],
        anchorBySymbolId: [String: String]
    ) {
        self.investigation = investigation
        self.components = components
        self.componentMembers = componentMembers
        self.componentRelationships = componentRelationships
        self.claims = claims
        self.evidence = evidence
        self.allInvestigations = allInvestigations
        self.anchorBySymbolId = anchorBySymbolId
        self.componentNameById = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0.name) })
    }

    // MARK: components.jsonl

    public struct ComponentExport: Encodable {
        public var id, name: String
        public var description, architecturalRole: String?
        public var confidence: Double
        public var confidenceTier, epistemicType: String
        public var memberAnchors: [String]
    }

    public func componentExports() -> [ComponentExport] {
        let membersByComponent = Dictionary(grouping: componentMembers, by: \.componentId)
        return components.map { c in
            let anchors = (membersByComponent[c.id] ?? [])
                .compactMap { anchorBySymbolId[$0.symbolId] }
                .sorted()
            return ComponentExport(
                id: c.id, name: c.name, description: c.description,
                architecturalRole: c.architecturalRole, confidence: c.confidence,
                confidenceTier: c.confidenceTier, epistemicType: c.epistemicType,
                memberAnchors: anchors
            )
        }.sorted { $0.name < $1.name }
    }

    // MARK: claims.jsonl

    public struct ClaimExport: Encodable {
        public var id: String
        public var subjectRef, predicate, objectRef: String?
        public var statement, claimType: String
        public var confidence: Double
        public var evidenceIds: [String]
    }

    public func claimExports() -> [ClaimExport] {
        let evidenceByClaimId = Dictionary(grouping: evidence, by: \.claimId)
        return claims.map { c in
            ClaimExport(
                id: c.id, subjectRef: c.subjectRef, predicate: c.predicate, objectRef: c.objectRef,
                statement: c.statement, claimType: c.claimType, confidence: c.confidence,
                evidenceIds: (evidenceByClaimId[c.id] ?? []).map(\.id).sorted()
            )
        }.sorted { $0.id < $1.id }
    }

    // MARK: evidence.jsonl

    public struct EvidenceRangeExport: Encodable {
        public var startLine, endLine: Int?
    }
    public struct EvidenceExport: Encodable {
        public var id, claimId, anchor, evidenceType: String
        public var range: EvidenceRangeExport
    }

    public func evidenceExports() -> [EvidenceExport] {
        evidence.map {
            EvidenceExport(
                id: $0.id, claimId: $0.claimId, anchor: $0.anchor, evidenceType: $0.evidenceType,
                range: .init(startLine: $0.startLine, endLine: $0.endLine)
            )
        }.sorted { $0.id < $1.id }
    }

    // MARK: investigations.jsonl

    public struct InvestigationExport: Encodable {
        public var id, question, outcome: String
        public var modelUsed: String?
        public var numTurns: Int?
        public var totalCostUsd, durationMs: Double?
    }

    public func investigationExports() -> [InvestigationExport] {
        allInvestigations.map {
            InvestigationExport(
                id: $0.id, question: $0.question, outcome: $0.outcome, modelUsed: $0.modelUsed,
                numTurns: $0.numTurns, totalCostUsd: $0.totalCostUsd, durationMs: $0.durationMs
            )
        }.sorted { $0.id < $1.id }
    }

    // MARK: semantic_model.json

    /// Compact skeleton — the artifact a future Architecture UI (Phase 4) would render
    /// directly, per Docs/11's export design.
    public struct SemanticModelExport: Encodable {
        public var investigationId: String
        public var components: [ComponentSkeleton]
        public var componentRelationships: [RelationshipSkeleton]
        public var uncertaintyCount: Int
        public var contradictionCount: Int

        public struct ComponentSkeleton: Encodable {
            public var name: String
            public var architecturalRole: String?
            public var memberCount: Int
            public var confidence: Double
        }
        public struct RelationshipSkeleton: Encodable {
            public var source, target, type, confidenceTier: String
        }
    }

    public func semanticModelExport() -> SemanticModelExport {
        let memberCountByComponent = Dictionary(grouping: componentMembers, by: \.componentId)
            .mapValues(\.count)

        let componentSkeletons = components.map {
            SemanticModelExport.ComponentSkeleton(
                name: $0.name, architecturalRole: $0.architecturalRole,
                memberCount: memberCountByComponent[$0.id] ?? 0, confidence: $0.confidence
            )
        }.sorted { $0.name < $1.name }

        let relationshipSkeletons = componentRelationships
            .compactMap { r -> SemanticModelExport.RelationshipSkeleton? in
                guard let source = componentNameById[r.sourceComponentId],
                      let target = componentNameById[r.targetComponentId] else { return nil }
                return .init(
                    source: source, target: target, type: r.relationshipType,
                    confidenceTier: r.confidenceTier
                )
            }
            .sorted { $0.source == $1.source ? $0.target < $1.target : $0.source < $1.source }

        return SemanticModelExport(
            investigationId: investigation.id,
            components: componentSkeletons,
            componentRelationships: relationshipSkeletons,
            uncertaintyCount: claims.filter { $0.claimType == EpistemicType.unknown.rawValue }.count,
            contradictionCount: claims.filter { $0.claimType == EpistemicType.contradicted.rawValue }.count
        )
    }
}
