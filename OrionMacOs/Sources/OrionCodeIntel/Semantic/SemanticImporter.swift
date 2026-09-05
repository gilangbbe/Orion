import Foundation

// MARK: - Step 2 output (evidence validation)

/// A component member anchor that resolved to a real symbol. `parentSymbolId` (e.g. a method's
/// enclosing class) is carried along for step 3's connectivity checks: Phase 1 relationships
/// like `extends` are recorded class-to-class, so a claim that only cites a *method* would
/// otherwise look structurally unconnected even when its enclosing class plainly is (Docs/11
/// M2 risks — confirmed against real Starlette output, see `claimContradicted`).
public struct ResolvedMember: Sendable, Equatable {
    public var anchor: String
    public var symbolId: String
    public var parentSymbolId: String?
}

/// A claim evidence anchor that resolved to a real symbol. `startLine`/`endLine` are copied
/// from the resolved symbol's own range — evidence is grounded in the Code Graph, not in a
/// line range Claude invents. `parentSymbolId`: see `ResolvedMember`.
public struct ResolvedEvidence: Sendable, Equatable {
    public var anchor: String
    public var symbolId: String
    public var parentSymbolId: String?
    public var fileId: String
    public var startLine: Int
    public var endLine: Int
}

/// A component that survived step 2 (evidence validation) with at least one resolved member.
public struct ValidatedComponent: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var architecturalRole: String?
    public var members: [ResolvedMember]
    public var droppedMemberAnchors: [String]
}

/// A claim that survived step 2 with at least one resolved evidence anchor, or an
/// `uncertainties[]` entry (which requires none — an `UNKNOWN` claim is honest about having no
/// evidence by construction).
public struct ValidatedClaim: Sendable, Equatable {
    public var claimType: SemanticClaimType
    public var statement: String
    public var confidence: String
    public var evidence: [ResolvedEvidence]
}

/// One dropped-item or malformed-reference note produced during validation.
public enum SemanticDiagnostic: Sendable, Equatable {
    case anchorUnresolved(context: String, anchor: String)
    case componentDropped(name: String, reason: String)
    case claimDropped(statement: String, reason: String)
    case componentRelationshipDropped(source: String, target: String, reason: String)
    /// Step 3: a later component reused a name an earlier one already claimed for this run —
    /// the later one is dropped, not renamed or merged.
    case duplicateComponent(name: String)
    /// Step 3: the structural connectivity check found no Phase 1 relationship at all between
    /// either component's member symbols. Kept, not dropped — an unconfirmed relationship is
    /// still informative (Docs/04: contradictions/uncertainty stay visible, not hidden) — but
    /// inserted at `.unresolved` confidence rather than trusted at face value.
    case componentRelationshipUnconfirmed(source: String, target: String)
    /// Step 3: a claim citing >= 2 evidence symbols where no pair of them has any existing
    /// Phase 1 relationship — a structural proxy for "this claim's premise doesn't check out
    /// against the Code Graph", not true semantic contradiction detection (Docs/11 M2 risks).
    /// Reclassified to `CONTRADICTED`, kept and still queryable, never silently dropped.
    case claimContradicted(statement: String)
}

/// The result of running steps 1-2 of the Docs/11 validation pipeline over one candidate.
public struct SemanticValidationOutcome: Sendable, Equatable {
    public var components: [ValidatedComponent] = []
    public var droppedComponents: [String] = []
    public var componentRelationships: [SemanticComponentRelationshipInput] = []
    public var droppedComponentRelationships: [SemanticComponentRelationshipInput] = []
    public var claims: [ValidatedClaim] = []
    public var droppedClaims: [String] = []
    public var diagnostics: [SemanticDiagnostic] = []
}

extension SemanticComponentRelationshipInput: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.target == rhs.target && lhs.type == rhs.type
    }
}

extension SemanticClaimType {
    /// Claude's self-reported tier, widened to the full Docs/04 vocabulary so step 3 can
    /// reclassify a claim to `CONTRADICTED` — a verdict Claude itself never asserts.
    var epistemicType: EpistemicType {
        switch self {
        case .interpretation: return .interpretation
        case .inference: return .inference
        case .unknown: return .unknown
        }
    }
}

// MARK: - Step 3 output (consistency check)

public struct ComponentToPersist: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var architecturalRole: String?
    public var members: [ResolvedMember]
    public var confidenceTier: ConfidenceTier
}

public struct ComponentRelationshipToPersist: Sendable, Equatable {
    public var source: String
    public var target: String
    public var type: String
    public var confidenceTier: ConfidenceTier
}

public struct ClaimToPersist: Sendable, Equatable {
    public var claimType: EpistemicType
    public var statement: String
    public var confidence: String
    public var evidence: [ResolvedEvidence]
}

/// Step 3's output: what step 4 actually persists, plus every diagnostic accumulated since
/// step 1 (steps 1-2's diagnostics are carried forward, not re-derived).
public struct SemanticConsistentOutcome: Sendable, Equatable {
    public var components: [ComponentToPersist] = []
    public var componentRelationships: [ComponentRelationshipToPersist] = []
    public var claims: [ClaimToPersist] = []
    public var diagnostics: [SemanticDiagnostic] = []
    public var droppedComponents: [String] = []
    public var droppedComponentRelationships: [SemanticComponentRelationshipInput] = []
    public var droppedClaims: [String] = []
    public var duplicateComponentsDropped: [String] = []
}

// MARK: - ingest() result / errors

public struct SemanticIngestOutcome {
    public var investigation: InvestigationRecord
    public var consistent: SemanticConsistentOutcome
}

public enum SemanticImportError: Error, CustomStringConvertible {
    /// The candidate file isn't even valid JSON / doesn't match `SemanticFindings`'s shape.
    /// An `investigations` row is still persisted (Docs/07: an attempt is itself useful).
    case decodeFailed(underlying: String, investigation: InvestigationRecord)
    /// Step 1 failed: well-formed JSON, but schema_version mismatch or a required-field/
    /// confidence-vocabulary violation. An `investigations` row is still persisted.
    case schemaInvalid([String], investigation: InvestigationRecord)

    public var description: String {
        switch self {
        case .decodeFailed(let underlying, let inv):
            return "candidate did not decode as JSON (investigation \(inv.id)): \(underlying)"
        case .schemaInvalid(let errors, let inv):
            return "schema validation failed (investigation \(inv.id)): \(errors.joined(separator: "; "))"
        }
    }
}

// MARK: - Importer

/// The full Docs/11 §"Validation pipeline": schema validation -> evidence validation ->
/// consistency check -> Codebase Model update -> (export is M3, not here). Never treats an
/// unresolved anchor, an unconfirmed relationship, or a contradicted claim as if it were a
/// verified fact: unconfirmed/contradicted items are kept and marked, not silently dropped or
/// silently trusted (Docs/03 §5, Docs/04 §3).
public struct SemanticImporter {
    public let store: Store
    public init(store: Store) { self.store = store }

    // MARK: step 1 — schema

    public func decode(data: Data) throws -> SemanticFindings {
        try JSONDecoder().decode(SemanticFindings.self, from: data)
    }

    public func decodeMeta(data: Data) throws -> InvestigationMeta {
        try JSONDecoder().decode(InvestigationMeta.self, from: data)
    }

    public func validateSchema(_ findings: SemanticFindings) -> [String] {
        var errors: [String] = []
        if findings.schemaVersion != SemanticSchema.currentVersion {
            errors.append(
                "schema_version '\(findings.schemaVersion)' != '\(SemanticSchema.currentVersion)'"
            )
        }
        for (i, c) in findings.components.enumerated() {
            if c.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("components[\(i)].name is empty")
            }
            if c.members.isEmpty {
                errors.append("components[\(i)].members is empty")
            }
        }
        for (i, r) in findings.componentRelationships.enumerated() {
            if r.source.isEmpty || r.target.isEmpty {
                errors.append("component_relationships[\(i)] missing source/target")
            }
        }
        for (i, cl) in findings.claims.enumerated() {
            if cl.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("claims[\(i)].statement is empty")
            }
            if ConfidenceTier(rawValue: cl.confidence) == nil {
                errors.append("claims[\(i)].confidence '\(cl.confidence)' is not high|medium|low|unresolved")
            }
        }
        return errors
    }

    // MARK: step 2 — evidence

    public func validateEvidence(
        _ findings: SemanticFindings, runId: String
    ) throws -> SemanticValidationOutcome {
        var outcome = SemanticValidationOutcome()
        var validComponentNames = Set<String>()

        for input in findings.components {
            var resolved: [ResolvedMember] = []
            var dropped: [String] = []
            for anchor in input.members {
                if let symbol = try store.symbol(runId: runId, anchor: anchor) {
                    resolved.append(ResolvedMember(
                        anchor: anchor, symbolId: symbol.id, parentSymbolId: symbol.parentSymbolId
                    ))
                } else {
                    dropped.append(anchor)
                    outcome.diagnostics.append(
                        .anchorUnresolved(context: "component '\(input.name)'", anchor: anchor)
                    )
                }
            }
            guard !resolved.isEmpty else {
                outcome.droppedComponents.append(input.name)
                outcome.diagnostics.append(
                    .componentDropped(name: input.name, reason: "no resolvable members")
                )
                continue
            }
            validComponentNames.insert(input.name)
            outcome.components.append(ValidatedComponent(
                name: input.name, description: input.description,
                architecturalRole: input.architecturalRole,
                members: resolved, droppedMemberAnchors: dropped
            ))
        }

        for rel in findings.componentRelationships {
            guard validComponentNames.contains(rel.source), validComponentNames.contains(rel.target) else {
                outcome.droppedComponentRelationships.append(rel)
                outcome.diagnostics.append(
                    .componentRelationshipDropped(
                        source: rel.source, target: rel.target,
                        reason: "source or target component was dropped"
                    )
                )
                continue
            }
            outcome.componentRelationships.append(rel)
        }

        for claim in findings.claims {
            var resolved: [ResolvedEvidence] = []
            var dropped: [String] = []
            for anchor in claim.evidence {
                if let symbol = try store.symbol(runId: runId, anchor: anchor) {
                    resolved.append(ResolvedEvidence(
                        anchor: anchor, symbolId: symbol.id, parentSymbolId: symbol.parentSymbolId,
                        fileId: symbol.fileId, startLine: symbol.startLine, endLine: symbol.endLine
                    ))
                } else {
                    dropped.append(anchor)
                    outcome.diagnostics.append(.anchorUnresolved(context: "claim", anchor: anchor))
                }
            }
            guard !resolved.isEmpty else {
                outcome.droppedClaims.append(claim.statement)
                outcome.diagnostics.append(
                    .claimDropped(statement: claim.statement, reason: "no resolvable evidence")
                )
                continue
            }
            outcome.claims.append(ValidatedClaim(
                claimType: claim.claimType, statement: claim.statement,
                confidence: claim.confidence, evidence: resolved
            ))
        }

        for text in findings.uncertainties {
            outcome.claims.append(ValidatedClaim(
                claimType: .unknown, statement: text,
                confidence: ConfidenceTier.unresolved.rawValue, evidence: []
            ))
        }

        return outcome
    }

    // MARK: step 3 — consistency check

    /// De-duplicates component names (first occurrence wins), verifies component relationships
    /// against the surviving component set, confirms every component relationship and every
    /// multi-evidence claim against the actual Phase 1 Code Graph — downgrading confidence or
    /// reclassifying to `CONTRADICTED` rather than dropping when the structural check comes up
    /// empty, per Docs/04 §3 ("contradictions" stay visible, not hidden).
    public func applyConsistencyCheck(
        _ validated: SemanticValidationOutcome, runId: String
    ) throws -> SemanticConsistentOutcome {
        var out = SemanticConsistentOutcome()
        out.diagnostics = validated.diagnostics
        out.droppedComponents = validated.droppedComponents
        out.droppedComponentRelationships = validated.droppedComponentRelationships
        out.droppedClaims = validated.droppedClaims

        var seenNames = Set<String>()
        var keptComponents: [ValidatedComponent] = []
        for c in validated.components {
            guard !seenNames.contains(c.name) else {
                out.duplicateComponentsDropped.append(c.name)
                out.diagnostics.append(.duplicateComponent(name: c.name))
                continue
            }
            seenNames.insert(c.name)
            keptComponents.append(c)
        }

        for c in keptComponents {
            let tier: ConfidenceTier = c.droppedMemberAnchors.isEmpty ? .high : .medium
            out.components.append(ComponentToPersist(
                name: c.name, description: c.description, architecturalRole: c.architecturalRole,
                members: c.members, confidenceTier: tier
            ))
        }

        // Include each member's enclosing symbol too (Docs/11 M2 risks): a Phase 1 `extends`
        // edge is recorded class-to-class, so a component whose cited members are all methods
        // would otherwise look unconnected to a base class it plainly extends.
        let memberIdsByName = Dictionary(
            uniqueKeysWithValues: keptComponents.map { ($0.name, Self.idsWithParents($0.members)) }
        )

        for rel in validated.componentRelationships {
            guard rel.source != rel.target else {
                out.droppedComponentRelationships.append(rel)
                out.diagnostics.append(
                    .componentRelationshipDropped(source: rel.source, target: rel.target, reason: "self-referential")
                )
                continue
            }
            guard let sourceIds = memberIdsByName[rel.source], let targetIds = memberIdsByName[rel.target] else {
                out.droppedComponentRelationships.append(rel)
                out.diagnostics.append(
                    .componentRelationshipDropped(
                        source: rel.source, target: rel.target,
                        reason: "component dropped as a duplicate"
                    )
                )
                continue
            }
            let confirmed = try store.relationshipExists(runId: runId, among: sourceIds, and: targetIds)
            let tier: ConfidenceTier = confirmed ? .high : .unresolved
            if !confirmed {
                out.diagnostics.append(.componentRelationshipUnconfirmed(source: rel.source, target: rel.target))
            }
            out.componentRelationships.append(ComponentRelationshipToPersist(
                source: rel.source, target: rel.target, type: rel.type, confidenceTier: tier
            ))
        }

        for claim in validated.claims {
            var claimType = claim.claimType.epistemicType
            if claim.evidence.count >= 2 {
                let ids = Self.idsWithParents(claim.evidence)
                let connected = try store.relationshipExistsAmongAnyPair(runId: runId, symbolIds: ids)
                if !connected {
                    claimType = .contradicted
                    out.diagnostics.append(.claimContradicted(statement: claim.statement))
                }
            }
            out.claims.append(ClaimToPersist(
                claimType: claimType, statement: claim.statement,
                confidence: claim.confidence, evidence: claim.evidence
            ))
        }

        return out
    }

    /// Each resolved item's own symbol id plus its enclosing symbol's id, deduplicated — the
    /// candidate set step 3's connectivity checks query against.
    private static func idsWithParents(_ members: [ResolvedMember]) -> [String] {
        Array(Set(members.flatMap { [$0.symbolId] + ($0.parentSymbolId.map { [$0] } ?? []) }))
    }

    private static func idsWithParents(_ evidence: [ResolvedEvidence]) -> [String] {
        Array(Set(evidence.flatMap { [$0.symbolId] + ($0.parentSymbolId.map { [$0] } ?? []) }))
    }

    // MARK: step 4 — Codebase Model update

    private func classifyOutcome(_ consistent: SemanticConsistentOutcome) -> InvestigationOutcome {
        let keptAnything = !consistent.components.isEmpty || !consistent.claims.isEmpty
        guard keptAnything else { return .unverified }
        let anyIssues = !consistent.droppedComponents.isEmpty
            || !consistent.droppedClaims.isEmpty
            || !consistent.duplicateComponentsDropped.isEmpty
            || !consistent.droppedComponentRelationships.isEmpty
            || consistent.claims.contains { $0.claimType == .contradicted }
            || consistent.componentRelationships.contains { $0.confidenceTier == .unresolved }
        return anyIssues ? .partiallyVerified : .verified
    }

    /// `stage = "semantic_ingest"`, scoped per-investigation so re-ingesting the same run under
    /// a new investigation never collides with a prior attempt's diagnostic ids.
    private func diagnosticRecords(
        for items: [String], code: String, severity: String, run: AnalysisRunRecord,
        investigationId: String
    ) -> [DiagnosticRecord] {
        items.enumerated().map { i, message in
            DiagnosticRecord(
                id: DeterministicID.diagnostic(
                    repositoryId: run.repositoryId, commitHash: run.commitHash,
                    stage: "semantic_ingest", code: code, scope: investigationId, ordinal: i
                ),
                repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
                fileId: nil, stage: "semantic_ingest", severity: severity, code: code,
                message: String(message.prefix(500)), startLine: nil, startCol: nil,
                endLine: nil, endCol: nil
            )
        }
    }

    private func diagnosticRecords(
        for diagnostics: [SemanticDiagnostic], run: AnalysisRunRecord, investigationId: String
    ) -> [DiagnosticRecord] {
        let messages: [(code: String, severity: String, message: String)] = diagnostics.map { d in
            switch d {
            case .anchorUnresolved(let context, let anchor):
                return ("ANCHOR_UNRESOLVED", "warning", "\(context): anchor '\(anchor)' does not resolve in this run")
            case .componentDropped(let name, let reason):
                return ("COMPONENT_DROPPED", "warning", "component '\(name)' dropped: \(reason)")
            case .claimDropped(let statement, let reason):
                return ("CLAIM_DROPPED", "warning", "claim dropped (\(reason)): \(statement)")
            case .componentRelationshipDropped(let source, let target, let reason):
                return ("COMPONENT_RELATIONSHIP_DROPPED", "warning", "\(source) -> \(target) dropped: \(reason)")
            case .duplicateComponent(let name):
                return ("DUPLICATE_COMPONENT", "warning", "component '\(name)' reused a name already claimed in this run; later occurrence dropped")
            case .componentRelationshipUnconfirmed(let source, let target):
                return ("COMPONENT_RELATIONSHIP_UNCONFIRMED", "info", "\(source) -> \(target): no Phase 1 relationship confirms this; kept at unresolved confidence")
            case .claimContradicted(let statement):
                return ("CLAIM_CONTRADICTED", "info", "claim's evidence symbols share no Phase 1 relationship: \(statement)")
            }
        }
        return messages.enumerated().map { i, m in
            DiagnosticRecord(
                id: DeterministicID.diagnostic(
                    repositoryId: run.repositoryId, commitHash: run.commitHash,
                    stage: "semantic_ingest", code: m.code, scope: investigationId, ordinal: i
                ),
                repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
                fileId: nil, stage: "semantic_ingest", severity: m.severity, code: m.code,
                message: String(m.message.prefix(500)), startLine: nil, startCol: nil,
                endLine: nil, endCol: nil
            )
        }
    }

    @discardableResult
    private func persistInvestigation(
        run: AnalysisRunRecord, meta: InvestigationMeta?, schemaVersion: String?,
        outcome: InvestigationOutcome, now: String
    ) throws -> InvestigationRecord {
        let record = InvestigationRecord(
            id: DeterministicID.newUUID(), repositoryId: run.repositoryId, commitHash: run.commitHash,
            runId: run.id, question: "phase2_semantic_grouping", complexity: "high",
            schemaVersion: schemaVersion, modelUsed: meta?.modelUsed,
            toolsUsed: meta?.toolsUsed ?? [], sessionId: meta?.sessionId, numTurns: meta?.numTurns,
            totalCostUsd: meta?.totalCostUsd, durationMs: meta?.durationMs,
            outcome: outcome.rawValue, createdAt: now
        )
        try store.insertInvestigation(record)
        return record
    }

    private func persist(
        _ consistent: SemanticConsistentOutcome, run: AnalysisRunRecord,
        investigation: InvestigationRecord, now: String
    ) throws {
        var componentRecords: [ComponentRecord] = []
        var memberRecords: [ComponentMemberRecord] = []
        var componentIdByName: [String: String] = [:]
        var bestForSymbol: [String: (componentId: String, confidence: Double)] = [:]

        for c in consistent.components {
            let id = DeterministicID.newUUID()
            componentIdByName[c.name] = id
            componentRecords.append(ComponentRecord(
                id: id, repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
                investigationId: investigation.id, name: c.name, description: c.description,
                architecturalRole: c.architecturalRole, confidence: c.confidenceTier.score,
                confidenceTier: c.confidenceTier.rawValue, status: "active",
                epistemicType: EpistemicType.interpretation.rawValue, provenance: "claude_code"
            ))
            for m in c.members {
                memberRecords.append(ComponentMemberRecord(
                    id: DeterministicID.newUUID(), componentId: id, symbolId: m.symbolId,
                    confidence: c.confidenceTier.score, role: ComponentMemberRole.core.rawValue
                ))
                let current = bestForSymbol[m.symbolId]
                if current == nil || c.confidenceTier.score > current!.confidence {
                    bestForSymbol[m.symbolId] = (id, c.confidenceTier.score)
                }
            }
        }

        var relationshipRecords: [ComponentRelationshipRecord] = []
        for r in consistent.componentRelationships {
            guard let sourceId = componentIdByName[r.source], let targetId = componentIdByName[r.target]
            else { continue }
            relationshipRecords.append(ComponentRelationshipRecord(
                id: DeterministicID.newUUID(), repositoryId: run.repositoryId, commitHash: run.commitHash,
                runId: run.id, investigationId: investigation.id, sourceComponentId: sourceId,
                targetComponentId: targetId, relationshipType: r.type, confidence: r.confidenceTier.score,
                confidenceTier: r.confidenceTier.rawValue, provenance: "claude_code"
            ))
        }

        var claimRecords: [ClaimRecord] = []
        var evidenceRecords: [EvidenceRecord] = []
        for c in consistent.claims {
            let claimId = DeterministicID.newUUID()
            let confidenceScore = ConfidenceTier(rawValue: c.confidence)?.score ?? ConfidenceTier.unresolved.score
            claimRecords.append(ClaimRecord(
                id: claimId, repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
                investigationId: investigation.id, subjectRef: c.evidence.first?.anchor, predicate: nil,
                objectRef: nil, statement: c.statement, claimType: c.claimType.rawValue,
                confidence: confidenceScore, status: "active", createdBy: "claude_code"
            ))
            for e in c.evidence {
                evidenceRecords.append(EvidenceRecord(
                    id: DeterministicID.newUUID(), claimId: claimId, fileId: e.fileId, symbolId: e.symbolId,
                    anchor: e.anchor, startLine: e.startLine, endLine: e.endLine, evidenceType: "source"
                ))
            }
        }

        try store.insertComponents(componentRecords)
        try store.insertComponentMembers(memberRecords)
        try store.insertComponentRelationships(relationshipRecords)
        try store.insertClaims(claimRecords)
        try store.insertEvidence(evidenceRecords)
        try store.insertDiagnostics(diagnosticRecords(
            for: consistent.diagnostics, run: run, investigationId: investigation.id
        ))

        let assignments = bestForSymbol.map { (symbolId: $0.key, componentId: $0.value.componentId) }
        try store.backfillComponentIds(assignments)

        guard !componentRecords.isEmpty || !claimRecords.isEmpty else { return }
        let previous = try store.latestModelRevision(repositoryId: run.repositoryId)
        let revision = ModelRevisionRecord(
            id: DeterministicID.newUUID(), repositoryId: run.repositoryId,
            previousRevision: previous?.id,
            changeSummary: "Ingested \(componentRecords.count) components, "
                + "\(relationshipRecords.count) component_relationships, "
                + "\(claimRecords.count) claims from investigation \(investigation.id).",
            triggeringInvestigationId: investigation.id, createdAt: now
        )
        try store.insertModelRevision(revision)
    }

    // MARK: full pipeline entry point

    /// Runs all five Docs/11 pipeline steps (export, step 5, is M3 — not here) and persists the
    /// result. `meta` is optional operational metadata about the investigation that produced
    /// `candidateURL` (cost/turns/session/model — Docs/11 `InvestigationMeta`); an
    /// `investigations` row is written even when validation ultimately rejects the candidate.
    public func ingest(
        candidateURL: URL, metaURL: URL?, run: AnalysisRunRecord, now: String
    ) throws -> SemanticIngestOutcome {
        let meta: InvestigationMeta? = try metaURL.map { try decodeMeta(data: try Data(contentsOf: $0)) }
        let data = try Data(contentsOf: candidateURL)

        let findings: SemanticFindings
        do {
            findings = try decode(data: data)
        } catch {
            let inv = try persistInvestigation(
                run: run, meta: meta, schemaVersion: nil, outcome: .rejected, now: now
            )
            throw SemanticImportError.decodeFailed(underlying: "\(error)", investigation: inv)
        }

        let schemaErrors = validateSchema(findings)
        guard schemaErrors.isEmpty else {
            let inv = try persistInvestigation(
                run: run, meta: meta, schemaVersion: findings.schemaVersion, outcome: .rejected, now: now
            )
            try store.insertDiagnostics(diagnosticRecords(
                for: schemaErrors, code: "SCHEMA_INVALID", severity: "error",
                run: run, investigationId: inv.id
            ))
            throw SemanticImportError.schemaInvalid(schemaErrors, investigation: inv)
        }

        let validated = try validateEvidence(findings, runId: run.id)
        let consistent = try applyConsistencyCheck(validated, runId: run.id)
        let outcome = classifyOutcome(consistent)

        let investigation = try persistInvestigation(
            run: run, meta: meta, schemaVersion: findings.schemaVersion, outcome: outcome, now: now
        )
        try persist(consistent, run: run, investigation: investigation, now: now)

        return SemanticIngestOutcome(investigation: investigation, consistent: consistent)
    }
}
