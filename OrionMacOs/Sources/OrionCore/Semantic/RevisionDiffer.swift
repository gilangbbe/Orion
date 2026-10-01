import Foundation

/// Docs/16_phase6_continuous_model_updates.md §4 — computes what changed between one newly
/// persisted investigation and everything the Codebase Model already knew, as a list of
/// structured diff facts. Pure logic over `Store` — no model call, no network (Docs/16 Decision
/// #2: the "Reason" text is a deterministic template over these facts, not a paraphrase).
///
/// **Not yet wired into `SemanticImporter.ingest()`/`.ingestAnswer()` as of M2** (that's M4) —
/// this type is called directly by its own fixture-driven tests for now, the same "types/logic
/// exist before the pipeline wiring lands" precedent Docs/11 M0→M2 and Docs/12 M1→M4 both used.
///
/// Uncertainty tracking (§5) is **not** part of this type — Docs/16 scopes that to its own M3,
/// given its distinct, more speculative lexical-overlap logic (Docs/08's own separate
/// "uncertainty tracking" bullet).
public enum RevisionDiffer {

    /// One diagnostic emitted by the differ itself — distinct from `SemanticDiagnostic`
    /// (`SemanticImporter`'s own import-validation diagnostics, `stage = "semantic_ingest"`).
    /// `RevisionDiffer`'s diagnostics get `stage = "model_revision"` once M4 wires this into
    /// persistence and converts these into real `diagnostics` table rows.
    public struct Diagnostic: Equatable, Sendable {
        public let code: String
        public let message: String
    }

    /// Everything one call to `diff` produced. `entries` still need a `model_revision_id`,
    /// generated `id`s, and `createdAt` before they're real `ModelRevisionEntryRecord`s — that
    /// assembly is M4's job, once there's a real `model_revisions` row to hang them off.
    public struct Result: Equatable, Sendable {
        public var entries: [ModelRevisionEntryDraft] = []
        public var diagnostics: [Diagnostic] = []

        public var isEmpty: Bool { entries.isEmpty }
    }

    /// A short rollup string for `model_revisions.change_summary` (§4, M4) — e.g. "3 changes: 1
    /// relationship added, 1 claim reversed, 1 uncertainty addressed." Grouped by
    /// `(entityType, changeType)` and sorted by raw value for a deterministic ordering (test- and
    /// diff-friendly, not dependent on `entries`' own incidental order).
    public static func changeSummary(for entries: [ModelRevisionEntryDraft]) -> String {
        struct Key: Hashable { let entity: ModelRevisionEntityType; let change: ModelRevisionChangeType }
        var counts: [Key: Int] = [:]
        for entry in entries {
            counts[Key(entity: entry.entityType, change: entry.changeType), default: 0] += 1
        }
        let parts = counts.keys
            .sorted { ($0.entity.rawValue, $0.change.rawValue) < ($1.entity.rawValue, $1.change.rawValue) }
            .map { key -> String in
                let count = counts[key]!
                return "\(count) \(entityLabel(key.entity, count: count)) \(changeLabel(key.change))"
            }
        return "\(entries.count) change\(entries.count == 1 ? "" : "s"): \(parts.joined(separator: ", "))."
    }

    private static func entityLabel(_ type: ModelRevisionEntityType, count: Int) -> String {
        switch type {
        case .component: return count == 1 ? "component" : "components"
        case .componentRelationship: return count == 1 ? "relationship" : "relationships"
        case .claim: return count == 1 ? "claim" : "claims"
        case .uncertainty: return count == 1 ? "uncertainty" : "uncertainties"
        }
    }

    private static func changeLabel(_ type: ModelRevisionChangeType) -> String {
        switch type {
        case .added: return "added"
        case .removed: return "removed"
        case .modified: return "modified"
        case .reversed: return "reversed"
        case .carriedOver: return "carried over"
        case .addressed: return "addressed"
        case .noLongerRaised: return "no longer raised"
        }
    }

    /// Top-level entry point. Determines the new investigation's own kind by reading its `question`
    /// column directly (`== InvestigationRecord.architectureQuestionMarker`) rather than trusting a
    /// caller-supplied flag that could disagree with what was actually persisted — the same
    /// marker-based check `OrionApp`'s `ArchitectureModelLoader.latestArchitectureInvestigation`
    /// already uses for the identical "which kind of investigation is this" question (Docs/16
    /// Decision #3).
    ///
    /// Component/`component_relationship` diffing (§4.2) only ever runs for an architecture
    /// investigation, against the architecture investigation immediately before it (if any).
    /// Claim diffing (§4.3) runs for *any* investigation kind, against every prior investigation
    /// for the repository (Decision #1/#3) — a repository's very first investigation of any kind
    /// necessarily produces zero *component/relationship/claim* entries (§9 Risk #5), not an
    /// error. **Uncertainty diffing (§5, M3) is the one deliberate exception to Risk #5's own
    /// claim** — a brand-new open question is worth recording the first time it's ever raised,
    /// even on a repository's very first investigation, since (unlike a component/relationship/
    /// claim) there is nothing to meaningfully compare it *against* in the first place; see §9's
    /// amended Risk #5 for the real reasoning, found while implementing this milestone rather
    /// than anticipated by the original plan.
    public static func diff(
        store: Store, repositoryId: String, newInvestigationId: String
    ) throws -> Result {
        var result = Result()

        guard let newInvestigation = try store.investigation(id: newInvestigationId) else {
            return result
        }

        if newInvestigation.question == InvestigationRecord.architectureQuestionMarker {
            let architectureInvestigations = try store.investigations(repositoryId: repositoryId)
                .filter { $0.question == InvestigationRecord.architectureQuestionMarker }
            if let newIndex = architectureInvestigations.firstIndex(where: { $0.id == newInvestigationId }),
               newIndex > 0
            {
                let previousInvestigationId = architectureInvestigations[newIndex - 1].id
                result.entries += try diffComponents(
                    store: store, previousInvestigationId: previousInvestigationId,
                    newInvestigationId: newInvestigationId
                )
                result.entries += try diffComponentRelationships(
                    store: store, previousInvestigationId: previousInvestigationId,
                    newInvestigationId: newInvestigationId
                )
            }
        }

        let claimOutcome = try diffClaims(
            store: store, repositoryId: repositoryId, newInvestigationId: newInvestigationId
        )
        result.entries += claimOutcome.entries
        result.diagnostics += claimOutcome.diagnostics

        result.entries += try diffUncertainties(
            store: store, newInvestigation: newInvestigation, addedClaims: claimOutcome.addedClaims
        )

        return result
    }

    // MARK: - §4.2 Component & component-relationship diffing

    static func diffComponents(
        store: Store, previousInvestigationId: String, newInvestigationId: String
    ) throws -> [ModelRevisionEntryDraft] {
        let previous = try store.components(investigationId: previousInvestigationId)
        let new = try store.components(investigationId: newInvestigationId)
        let previousAnchors = try memberAnchorsByComponent(store: store, components: previous)
        let newAnchors = try memberAnchorsByComponent(store: store, components: new)

        // Case-insensitive exact name match (Docs/16 Decision #3) -- the same convention Docs/15
        // M5's `session create --component` already established for resolving a component by name.
        let previousByName = Dictionary(
            previous.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let newByName = Dictionary(
            new.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

        var entries: [ModelRevisionEntryDraft] = []

        for component in new where previousByName[component.name.lowercased()] == nil {
            let memberCount = newAnchors[component.id]?.count ?? 0
            entries.append(ModelRevisionEntryDraft(
                entityType: .component, changeType: .added, subjectLabel: component.name,
                previousStateJson: nil, newStateJson: componentSnapshotJSON(component, memberCount: memberCount),
                reason: "New component '\(component.name)' identified, \(memberCount) members, "
                    + "\(component.confidenceTier) confidence.",
                confidenceTier: component.confidenceTier, relatedClaimId: nil
            ))
        }

        for component in previous where newByName[component.name.lowercased()] == nil {
            let memberCount = previousAnchors[component.id]?.count ?? 0
            entries.append(ModelRevisionEntryDraft(
                entityType: .component, changeType: .removed, subjectLabel: component.name,
                previousStateJson: componentSnapshotJSON(component, memberCount: memberCount), newStateJson: nil,
                reason: "Component '\(component.name)' no longer appears in the latest "
                    + "architecture investigation.",
                confidenceTier: component.confidenceTier, relatedClaimId: nil
            ))
        }

        for (key, newComponent) in newByName {
            guard let previousComponent = previousByName[key] else { continue }
            let previousSet = previousAnchors[previousComponent.id] ?? []
            let newSet = newAnchors[newComponent.id] ?? []
            let membershipChanged = previousSet != newSet
            let descriptionChanged = previousComponent.description != newComponent.description
                || previousComponent.architecturalRole != newComponent.architecturalRole
            guard membershipChanged || descriptionChanged else { continue }

            var parts: [String] = []
            if membershipChanged {
                let added = newSet.subtracting(previousSet).count
                let removed = previousSet.subtracting(newSet).count
                parts.append("'\(newComponent.name)''s membership changed: +\(added) / -\(removed) symbols.")
            }
            if descriptionChanged {
                parts.append("'\(newComponent.name)''s described role changed.")
            }
            entries.append(ModelRevisionEntryDraft(
                entityType: .component, changeType: .modified, subjectLabel: newComponent.name,
                previousStateJson: componentSnapshotJSON(previousComponent, memberCount: previousSet.count),
                newStateJson: componentSnapshotJSON(newComponent, memberCount: newSet.count),
                reason: parts.joined(separator: " "),
                confidenceTier: newComponent.confidenceTier, relatedClaimId: nil
            ))
        }

        return entries
    }

    static func diffComponentRelationships(
        store: Store, previousInvestigationId: String, newInvestigationId: String
    ) throws -> [ModelRevisionEntryDraft] {
        let previousComponents = try store.components(investigationId: previousInvestigationId)
        let newComponents = try store.components(investigationId: newInvestigationId)
        let previousNameById = Dictionary(uniqueKeysWithValues: previousComponents.map { ($0.id, $0.name) })
        let newNameById = Dictionary(uniqueKeysWithValues: newComponents.map { ($0.id, $0.name) })

        let previousRels = try store.componentRelationships(investigationId: previousInvestigationId)
        let newRels = try store.componentRelationships(investigationId: newInvestigationId)

        let previousKeyed = keyedRelationships(previousRels, names: previousNameById)
        let newKeyed = keyedRelationships(newRels, names: newNameById)

        var entries: [ModelRevisionEntryDraft] = []

        for (key, rel) in newKeyed where previousKeyed[key] == nil {
            let label = relationshipLabel(rel, names: newNameById)
            entries.append(ModelRevisionEntryDraft(
                entityType: .componentRelationship, changeType: .added, subjectLabel: label,
                previousStateJson: nil,
                newStateJson: relationshipSnapshotJSON(rel, label: label),
                reason: "New relationship '\(label)' (\(rel.relationshipType)) identified, "
                    + "\(rel.confidenceTier) confidence.",
                confidenceTier: rel.confidenceTier, relatedClaimId: nil
            ))
        }

        for (key, rel) in previousKeyed where newKeyed[key] == nil {
            let label = relationshipLabel(rel, names: previousNameById)
            entries.append(ModelRevisionEntryDraft(
                entityType: .componentRelationship, changeType: .removed, subjectLabel: label,
                previousStateJson: relationshipSnapshotJSON(rel, label: label), newStateJson: nil,
                reason: "Relationship '\(label)' (\(rel.relationshipType)) no longer appears in "
                    + "the latest architecture investigation.",
                confidenceTier: rel.confidenceTier, relatedClaimId: nil
            ))
        }

        return entries
    }

    private struct RelationshipKey: Hashable {
        let source: String
        let target: String
        let type: String
    }

    /// Relationships whose source/target component id doesn't resolve in `names` (shouldn't
    /// happen -- `component_relationships` FKs into `components` -- but skipped defensively rather
    /// than crashing) are simply excluded from the keyed map, matching `ArchitectureModelLoader`'s
    /// own "drop, don't crash" posture for a dangling edge.
    private static func keyedRelationships(
        _ relationships: [ComponentRelationshipRecord], names: [String: String]
    ) -> [RelationshipKey: ComponentRelationshipRecord] {
        var result: [RelationshipKey: ComponentRelationshipRecord] = [:]
        for rel in relationships {
            guard let source = names[rel.sourceComponentId], let target = names[rel.targetComponentId]
            else { continue }
            let key = RelationshipKey(
                source: source.lowercased(), target: target.lowercased(), type: rel.relationshipType)
            result[key] = rel
        }
        return result
    }

    private static func relationshipLabel(
        _ rel: ComponentRelationshipRecord, names: [String: String]
    ) -> String {
        let source = names[rel.sourceComponentId] ?? rel.sourceComponentId
        let target = names[rel.targetComponentId] ?? rel.targetComponentId
        return "\(source) -> \(target)"
    }

    /// componentId -> the set of its member symbols' real anchors (not `symbol_id`s) --
    /// `component_members` only stores `symbol_id`, so this resolves each one back to its
    /// `SymbolRecord.anchor` the same way `ComponentDetailQuery.semanticDetail` already does.
    private static func memberAnchorsByComponent(
        store: Store, components: [ComponentRecord]
    ) throws -> [String: Set<String>] {
        guard !components.isEmpty else { return [:] }
        var symbolsById: [String: SymbolRecord] = [:]
        for runId in Set(components.map(\.runId)) {
            for symbol in try store.symbols(runId: runId) {
                symbolsById[symbol.id] = symbol
            }
        }
        let members = try store.componentMembers(componentIds: components.map(\.id))
        var result: [String: Set<String>] = [:]
        for member in members {
            guard let symbol = symbolsById[member.symbolId] else { continue }
            result[member.componentId, default: []].insert(symbol.anchor)
        }
        return result
    }

    private struct ComponentSnapshot: Codable {
        let name: String
        let description: String?
        let architecturalRole: String?
        let confidenceTier: String
        let memberCount: Int
    }

    private static func componentSnapshotJSON(_ component: ComponentRecord, memberCount: Int) -> String? {
        let snapshot = ComponentSnapshot(
            name: component.name, description: component.description,
            architecturalRole: component.architecturalRole, confidenceTier: component.confidenceTier,
            memberCount: memberCount
        )
        return jsonString(snapshot)
    }

    private struct RelationshipSnapshot: Codable {
        let label: String
        let relationshipType: String
        let confidenceTier: String
    }

    private static func relationshipSnapshotJSON(
        _ rel: ComponentRelationshipRecord, label: String
    ) -> String? {
        jsonString(RelationshipSnapshot(
            label: label, relationshipType: rel.relationshipType, confidenceTier: rel.confidenceTier))
    }

    // MARK: - §4.3 Claim diffing (any investigation kind, cross-investigation)

    struct ClaimDiffOutcome {
        var entries: [ModelRevisionEntryDraft] = []
        var diagnostics: [Diagnostic] = []
        /// The real `ClaimRecord`s behind every `.added` entry above -- `diffUncertainties` (§5,
        /// M3) needs the claims themselves (real id, full statement text), not just their drafts,
        /// to check whether one of them plausibly addresses a previously open uncertainty.
        var addedClaims: [ClaimRecord] = []
    }

    /// The Jaccard threshold for matching one claim to a historical one -- shares
    /// `AnchorAlignment.defaultThreshold` (0.3) rather than a second, driftable constant.
    static let claimMatchThreshold = AnchorAlignment.defaultThreshold

    static func diffClaims(
        store: Store, repositoryId: String, newInvestigationId: String
    ) throws -> ClaimDiffOutcome {
        var outcome = ClaimDiffOutcome()

        let newClaims = try store.claims(investigationId: newInvestigationId)
            .filter { $0.claimType != EpistemicType.unknown.rawValue }
        guard !newClaims.isEmpty else { return outcome }

        // A real, load-bearing bug found against real data (Docs/16 M6): this used to be
        // `.filter { $0 != newInvestigationId }` -- "every *other* investigation," not "every
        // *earlier* investigation." Every prior test (M2-M5) always diffed the most-recently-
        // inserted investigation, so "all others" and "all earlier ones" were always the same set
        // by construction and this never surfaced. Backfilling a repository's real historical
        // investigations out of live-insertion order (i.e. processing an *older* investigation
        // when *newer* ones already exist in the table) exposed it directly: the repository's own
        // first-ever investigation came back diffing its claims against three investigations that
        // happened chronologically *after* it, misreporting several of its own claims as
        // `.modified` against claims that hadn't been made yet at the time. Fixed to match
        // `diffComponents`/`diffUncertainties`'s own existing index-based "earlier in the ordered
        // investigation list" pattern, rather than inventing a second convention.
        let allInvestigations = try store.investigations(repositoryId: repositoryId)
        guard let newIndex = allInvestigations.firstIndex(where: { $0.id == newInvestigationId })
        else { return outcome }
        let priorInvestigationIds = allInvestigations[..<newIndex].map(\.id)
        guard !priorInvestigationIds.isEmpty else { return outcome }

        var historicalClaims: [(claim: ClaimRecord, anchors: Set<String>)] = []
        for investigationId in priorInvestigationIds {
            let claims = try store.claims(investigationId: investigationId)
                .filter { $0.claimType != EpistemicType.unknown.rawValue }
            guard !claims.isEmpty else { continue }
            let evidence = try store.evidence(claimIds: claims.map(\.id))
            let anchorsByClaim = Dictionary(grouping: evidence, by: \.claimId)
                .mapValues { Set($0.map(\.anchor)) }
            for claim in claims {
                historicalClaims.append((claim, anchorsByClaim[claim.id] ?? []))
            }
        }
        // No early return when `historicalClaims` is empty (e.g. every prior investigation had
        // zero non-UNKNOWN claims, even though prior investigations themselves exist): the main
        // loop below already handles that correctly on its own -- every new claim's candidate
        // list is trivially empty, so it becomes `.added`, exactly as it should. A real M3-found
        // bug: an earlier version of this guard returned here unconditionally, which silently
        // skipped `.added` entries for a second investigation's genuinely new claims whenever the
        // *first* investigation happened to have none of its own -- caught before it shipped by
        // reasoning through this exact scenario while adding uncertainty diffing, not by a failing
        // test (no fixture had exercised it yet).

        let newEvidence = try store.evidence(claimIds: newClaims.map(\.id))
        let newAnchorsByClaim = Dictionary(grouping: newEvidence, by: \.claimId)
            .mapValues { Set($0.map(\.anchor)) }

        for claim in newClaims {
            let anchors = newAnchorsByClaim[claim.id] ?? []
            let normalizedNew = AnchorAlignment.normalizedSet(anchors)

            var candidates: [(claim: ClaimRecord, anchors: Set<String>, jaccard: Double)] = []
            for historical in historicalClaims {
                let score = AnchorAlignment.jaccard(
                    normalizedNew, AnchorAlignment.normalizedSet(historical.anchors))
                if score >= claimMatchThreshold {
                    candidates.append((historical.claim, historical.anchors, score))
                }
            }

            guard !candidates.isEmpty else {
                outcome.entries.append(addedClaimEntry(claim, anchors: anchors))
                outcome.addedClaims.append(claim)
                continue
            }

            candidates.sort { $0.jaccard > $1.jaccard }
            if candidates.count > 1 {
                outcome.diagnostics.append(Diagnostic(
                    code: "CLAIM_DIFF_AMBIGUOUS",
                    message: "Claim \(claim.id) matched \(candidates.count) prior claims at or "
                        + "above threshold \(claimMatchThreshold); picked the highest-Jaccard one "
                        + "(\(candidates[0].claim.id))."
                ))
            }

            let best = candidates[0]
            if let entry = matchedClaimEntry(new: claim, newAnchors: anchors, previous: best.claim, previousAnchors: best.anchors) {
                outcome.entries.append(entry)
            }
        }

        return outcome
    }

    private static func claimSubjectDescriptor(_ claim: ClaimRecord) -> String {
        claim.subjectRef ?? "the repository"
    }

    private static func claimSubjectLabel(_ claim: ClaimRecord) -> String {
        String(claim.statement.prefix(120))
    }

    private static func addedClaimEntry(_ claim: ClaimRecord, anchors: Set<String>) -> ModelRevisionEntryDraft {
        ModelRevisionEntryDraft(
            entityType: .claim, changeType: .added, subjectLabel: claimSubjectLabel(claim),
            previousStateJson: nil, newStateJson: claimSnapshotJSON(claim, anchors: anchors),
            reason: "New claim about \(claimSubjectDescriptor(claim)): "
                + "\"\(claimSubjectLabel(claim))\".",
            confidenceTier: ConfidenceTier.label(forScore: claim.confidence), relatedClaimId: nil
        )
    }

    /// `nil` means "nothing changed, write no entry" (Docs/16 §4.3: "not every re-confirmation is
    /// diff-worthy").
    ///
    /// `relatedClaimId` on both branches below points at **`new.id`, not `previous.id`** — a
    /// real correction made in M5, not the original M2 design (which pointed backward at the
    /// superseded claim, matching the wording written here at the time). The app's own
    /// `CONTRADICTED`-claim cross-reference (Docs/14 §2's "Superseded — see Model Changes") needs
    /// to look up "which revision entry explains *this currently-displayed* claim," and the claim
    /// the UI ever actually shows is always the current, still-persisted one — `new`, never the
    /// superseded `previous` (which may not even resolve any more once its own investigation
    /// ages out). `previous`'s statement/claim-type/anchors are still fully preserved, just in
    /// `previousStateJson` rather than as a live, dereferenceable id. This is now the same
    /// convention `.addressed` (§5) already used for its own hedge link — `relatedClaimId` always
    /// names a currently-relevant claim, never a historical one.
    private static func matchedClaimEntry(
        new: ClaimRecord, newAnchors: Set<String>, previous: ClaimRecord, previousAnchors: Set<String>
    ) -> ModelRevisionEntryDraft? {
        let previousContradicted = previous.claimType == EpistemicType.contradicted.rawValue
        let newContradicted = new.claimType == EpistemicType.contradicted.rawValue
        let subject = claimSubjectDescriptor(new)

        if previousContradicted != newContradicted {
            func verdictLabel(_ contradicted: Bool) -> String { contradicted ? "contradicted" : "confirmed" }
            return ModelRevisionEntryDraft(
                entityType: .claim, changeType: .reversed, subjectLabel: claimSubjectLabel(new),
                previousStateJson: claimSnapshotJSON(previous, anchors: previousAnchors),
                newStateJson: claimSnapshotJSON(new, anchors: newAnchors),
                reason: "Claim about \(subject) reversed: previously \(verdictLabel(previousContradicted)), "
                    + "now \(verdictLabel(newContradicted)) against the current Code Graph.",
                confidenceTier: ConfidenceTier.label(forScore: new.confidence),
                relatedClaimId: new.id
            )
        }

        let anchorsChanged = previousAnchors != newAnchors
        let statementChanged = previous.statement != new.statement
        guard anchorsChanged || statementChanged else { return nil }

        var parts: [String] = []
        if anchorsChanged {
            let added = newAnchors.subtracting(previousAnchors)
            if !added.isEmpty {
                parts.append("evidence now includes \(added.sorted().joined(separator: ", "))")
            }
            let dropped = previousAnchors.subtracting(newAnchors)
            if !dropped.isEmpty {
                parts.append("no longer cites \(dropped.sorted().joined(separator: ", "))")
            }
        }
        if statementChanged {
            parts.append("wording updated")
        }
        return ModelRevisionEntryDraft(
            entityType: .claim, changeType: .modified, subjectLabel: claimSubjectLabel(new),
            previousStateJson: claimSnapshotJSON(previous, anchors: previousAnchors),
            newStateJson: claimSnapshotJSON(new, anchors: newAnchors),
            reason: "Claim about \(subject) refined: \(parts.joined(separator: "; ")).",
            confidenceTier: ConfidenceTier.label(forScore: new.confidence), relatedClaimId: new.id
        )
    }

    private struct ClaimSnapshot: Codable {
        let statement: String
        let claimType: String
        let anchors: [String]
    }

    private static func claimSnapshotJSON(_ claim: ClaimRecord, anchors: Set<String>) -> String? {
        jsonString(ClaimSnapshot(
            statement: claim.statement, claimType: claim.claimType, anchors: anchors.sorted()))
    }

    // MARK: - §5 Uncertainty tracking

    /// `uncertainties[]` claims (Docs/11: `claim_type == UNKNOWN`, no evidence) have no anchors to
    /// align on, so they get their own, deliberately conservative, lexical-overlap comparison
    /// instead of `AnchorAlignment` — Docs/16 §5's own "the most speculative mechanism in this
    /// phase, by design." A `.carriedOver`/`.addressed` verdict is always phrased as a hedge in
    /// its `reason` text, never asserted as a confirmed fact.
    static let uncertaintyCarriedOverThreshold = 0.6
    static let uncertaintyAddressedThreshold = 0.4

    /// Compares this investigation's own `UNKNOWN` claims against the immediately preceding
    /// investigation *of the same kind* (architecture-vs-architecture, question-vs-question) —
    /// comparing an Ask investigation's open questions against an unrelated architecture
    /// investigation's would conflate two different questions' own open items (§5). Unlike
    /// components/relationships/claims, a brand-new uncertainty becomes `.added` even when there
    /// is no previous investigation of the same kind to compare against at all — see the doc
    /// comment on `diff(store:repositoryId:newInvestigationId:)` and §9's amended Risk #5 for why
    /// this is the one deliberate exception to "nothing to diff against yields nothing."
    static func diffUncertainties(
        store: Store, newInvestigation: InvestigationRecord, addedClaims: [ClaimRecord]
    ) throws -> [ModelRevisionEntryDraft] {
        let isArchitecture = newInvestigation.question == InvestigationRecord.architectureQuestionMarker
        let sameKindInvestigations = try store.investigations(repositoryId: newInvestigation.repositoryId)
            .filter { ($0.question == InvestigationRecord.architectureQuestionMarker) == isArchitecture }
        guard let newIndex = sameKindInvestigations.firstIndex(where: { $0.id == newInvestigation.id })
        else { return [] }

        let newUncertainties = try store.claims(investigationId: newInvestigation.id)
            .filter { $0.claimType == EpistemicType.unknown.rawValue }

        let previousUncertainties: [ClaimRecord]
        if newIndex > 0 {
            previousUncertainties = try store.claims(investigationId: sameKindInvestigations[newIndex - 1].id)
                .filter { $0.claimType == EpistemicType.unknown.rawValue }
        } else {
            previousUncertainties = []
        }

        var entries: [ModelRevisionEntryDraft] = []
        var carriedOverPreviousIds = Set<String>()

        for new in newUncertainties {
            let newTokens = tokenSet(new.statement)
            let match = previousUncertainties
                .map { (claim: $0, score: AnchorAlignment.jaccard(newTokens, tokenSet($0.statement))) }
                .filter { $0.score >= uncertaintyCarriedOverThreshold }
                .max { $0.score < $1.score }

            if let match {
                carriedOverPreviousIds.insert(match.claim.id)
                entries.append(ModelRevisionEntryDraft(
                    entityType: .uncertainty, changeType: .carriedOver,
                    subjectLabel: claimSubjectLabel(new), previousStateJson: nil, newStateJson: nil,
                    reason: "Still open: \"\(claimSubjectLabel(new))\".",
                    confidenceTier: nil, relatedClaimId: nil
                ))
            } else {
                entries.append(ModelRevisionEntryDraft(
                    entityType: .uncertainty, changeType: .added,
                    subjectLabel: claimSubjectLabel(new), previousStateJson: nil, newStateJson: nil,
                    reason: "New open question: \"\(claimSubjectLabel(new))\".",
                    confidenceTier: nil, relatedClaimId: nil
                ))
            }
        }

        for previous in previousUncertainties where !carriedOverPreviousIds.contains(previous.id) {
            let previousTokens = tokenSet(previous.statement)
            let match = addedClaims
                .map { (claim: $0, score: AnchorAlignment.jaccard(previousTokens, tokenSet($0.statement))) }
                .filter { $0.score >= uncertaintyAddressedThreshold }
                .max { $0.score < $1.score }

            if let match {
                entries.append(ModelRevisionEntryDraft(
                    entityType: .uncertainty, changeType: .addressed,
                    subjectLabel: claimSubjectLabel(previous), previousStateJson: nil, newStateJson: nil,
                    reason: "Possibly addressed by a new claim: \"\(claimSubjectLabel(match.claim))\" "
                        + "— not a confirmed resolution, worth a manual check.",
                    confidenceTier: ConfidenceTier.label(forScore: match.claim.confidence),
                    relatedClaimId: match.claim.id
                ))
            } else {
                entries.append(ModelRevisionEntryDraft(
                    entityType: .uncertainty, changeType: .noLongerRaised,
                    subjectLabel: claimSubjectLabel(previous), previousStateJson: nil, newStateJson: nil,
                    reason: "No longer raised in the latest investigation — this may mean it was "
                        + "resolved, or simply not revisited; not confirmed either way.",
                    confidenceTier: nil, relatedClaimId: nil
                ))
            }
        }

        return entries
    }

    /// Lowercased, stopword-stripped word set — a simple, inspectable, dependency-free measure
    /// (not embeddings, not a model call, per Docs/16 Decision #2's own "deterministic template"
    /// posture extended to this comparison too). `AnchorAlignment.jaccard` is reused directly on
    /// these token sets — it's a plain `Set<String>` overlap function with nothing anchor-specific
    /// about its own logic, only `normalize`/`align` are code-anchor-shaped.
    private static func tokenSet(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return Set(words.filter { !uncertaintyStopwords.contains($0) })
    }

    private static let uncertaintyStopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "of", "to", "in", "on", "for", "and", "or", "but", "if", "then",
        "this", "that", "these", "those", "it", "its", "as", "at", "by",
        "with", "from", "into", "than", "so", "not", "no", "do", "does",
        "did", "has", "have", "had", "can", "could", "will", "would",
        "should", "may", "might", "must", "whether", "what", "which", "who",
        "whom", "how", "when", "where", "why"
    ]

    // MARK: - shared

    private static func jsonString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// One structured diff fact, not yet assigned a `model_revision_id`/`id`/`createdAt` — those are
/// filled in once a real `model_revisions` row exists to hang it off (M4). Mirrors
/// `ModelRevisionEntryRecord`'s own fields minus that persistence-only metadata.
public struct ModelRevisionEntryDraft: Equatable, Sendable {
    public let entityType: ModelRevisionEntityType
    public let changeType: ModelRevisionChangeType
    public let subjectLabel: String
    public let previousStateJson: String?
    public let newStateJson: String?
    public let reason: String
    public let confidenceTier: String?
    public let relatedClaimId: String?

    public init(
        entityType: ModelRevisionEntityType, changeType: ModelRevisionChangeType,
        subjectLabel: String, previousStateJson: String?, newStateJson: String?, reason: String,
        confidenceTier: String?, relatedClaimId: String?
    ) {
        self.entityType = entityType
        self.changeType = changeType
        self.subjectLabel = subjectLabel
        self.previousStateJson = previousStateJson
        self.newStateJson = newStateJson
        self.reason = reason
        self.confidenceTier = confidenceTier
        self.relatedClaimId = relatedClaimId
    }
}
