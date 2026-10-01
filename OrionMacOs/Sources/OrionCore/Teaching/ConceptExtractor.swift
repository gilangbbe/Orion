import Foundation

/// Docs/17_phase7_teaching_mode.md §5 — deterministically derives `teaching_concepts` for a
/// repository from its latest analysis run's persisted semantic layer. Pure logic over `Store`:
/// no model call, no network. A concept is never *authored* — it always traces to a real
/// `components` / `component_relationships` / `claims` row and that row's evidence anchors
/// (Docs/17 Decision 2).
///
/// **M1 scope: `component`, `claim` and `relationship` concepts only.** `role` and `dataflow`
/// (Docs/17 §5's other two `TeachingConceptKind`s, band 2–3 material) are deferred: each would
/// produce a concept whose evidence-anchor set is (a subset of) some existing `component`
/// concept's, so the §5 dedup rule would immediately collapse it into that base. They need a
/// distinct, non-anchor-overlap identity — a design question better answered alongside M2's
/// band-3 question generation, which is what actually consumes them.
///
/// Re-run behaviour (§5): `extract` matches existing rows by their natural key
/// (`DeterministicID.teachingConcept`), so calling it again after a new investigation is
/// idempotent for unchanged concepts. A concept whose source rows have all disappeared from the
/// latest run is marked `stale = 1`, **not deleted** — a `knowledge_states` row still resolves.
/// A previously-stale concept that reappears is revived. M1 does **not** rewrite an existing
/// concept's `centrality` / `difficulty_band` / `evidence_anchors` when its natural key is
/// unchanged (a documented simplification — content refresh is a later milestone if graph drift
/// across re-analyses proves to matter in practice).
public enum ConceptExtractor {

    /// Docs/17 Decision 9 — cap the derived set to the top-N concepts by centrality on a large
    /// repo, the same "cap by centrality" posture `ArchitectureModelLoader` already takes for the
    /// diagram. `60` is the starting value; revisit once run against real Starlette (M1's own
    /// open item).
    public static let defaultCap = 60

    /// Number of member anchors a `relationship` concept unions from its two endpoint components
    /// before it's kept — bounded so one relationship doesn't dominate centrality or the dedup
    /// comparison. Anchors are sorted before truncation, so the cap is deterministic.
    static let relationshipAnchorCap = 40

    public struct Result: Equatable, Sendable {
        /// Ids of concepts newly inserted this run (read them back via `Store.teachingConcept`).
        public var inserted: [String] = []
        /// Existing concept ids marked `stale` this run (their source rows are gone).
        public var restaled: [String] = []
        /// Existing concept ids un-`stale`d this run (their source rows came back).
        public var revived: [String] = []
        /// Candidate concepts dropped as near-duplicates of a higher-centrality one (§5).
        public var deduped: Int = 0
        /// Candidate concepts dropped for falling outside the top-N centrality cap.
        public var cappedOut: Int = 0
        /// Total non-stale concepts for the repository after this run.
        public var kept: Int = 0
        /// The run this extraction read from.
        public var runId: String = ""
        public var repositoryId: String = ""
    }

    /// `commitHash == nil` picks the latest run overall (fine for a single-repo `orion.db`).
    /// Returns an empty `Result` (no `runId`) if there is no analysis run yet.
    public static func extract(
        store: Store, commitHash: String? = nil, cap: Int = defaultCap, now: String
    ) throws -> Result {
        guard let run = try store.latestRun(commitHash: commitHash) else { return Result() }
        var result = Result()
        result.runId = run.id
        result.repositoryId = run.repositoryId

        // Anchor <-> symbol-id maps for the run (anchors are UNIQUE per run).
        let symbols = try store.symbols(runId: run.id)
        var anchorForSymbol: [String: String] = [:]
        var symbolForAnchor: [String: String] = [:]
        for s in symbols {
            anchorForSymbol[s.id] = s.anchor
            symbolForAnchor[s.anchor] = s.id
        }
        let degrees = try store.symbolDegrees(runId: run.id)

        // --- Source rows: latest architecture investigation + every investigation's real claims.
        let investigations = try store.investigations(runId: run.id)
        let architecture = investigations
            .last { $0.question == InvestigationRecord.architectureQuestionMarker }

        var components: [ComponentRecord] = []
        var componentName: [String: String] = [:]
        var relationships: [ComponentRelationshipRecord] = []
        var membersByComponent: [String: [String]] = [:]   // componentId -> member anchors
        if let architecture {
            components = try store.components(investigationId: architecture.id)
            componentName = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0.name) })
            relationships = try store.componentRelationships(investigationId: architecture.id)
            let members = try store.componentMembers(componentIds: components.map(\.id))
            for m in members {
                guard let anchor = anchorForSymbol[m.symbolId] else { continue }
                membersByComponent[m.componentId, default: []].append(anchor)
            }
        }

        // --- Build raw candidates (pre-dedup, pre-cap).
        struct Candidate {
            var kind: TeachingConceptKind
            var subjectLabel: String
            var sourceComponentId: String?
            var sourceClaimId: String?
            var anchors: [String]
            var difficultyBand: Int
        }
        var candidates: [Candidate] = []

        for c in components {
            let anchors = (membersByComponent[c.id] ?? []).sorted()
            candidates.append(Candidate(
                kind: .component, subjectLabel: c.name, sourceComponentId: c.id,
                sourceClaimId: nil, anchors: anchors, difficultyBand: 1))
        }

        for r in relationships {
            guard let src = componentName[r.sourceComponentId],
                  let dst = componentName[r.targetComponentId] else { continue }
            let union = Set((membersByComponent[r.sourceComponentId] ?? [])
                + (membersByComponent[r.targetComponentId] ?? []))
            let anchors = Array(union).sorted().prefix(relationshipAnchorCap)
            candidates.append(Candidate(
                kind: .relationship, subjectLabel: "\(src) \u{2192} \(dst)",
                sourceComponentId: r.sourceComponentId, sourceClaimId: nil,
                anchors: Array(anchors), difficultyBand: 2))
        }

        var seenClaimStatements = Set<String>()
        for inv in investigations {
            for claim in try store.claims(investigationId: inv.id) {
                guard claim.claimType != EpistemicType.unknown.rawValue else { continue }
                guard seenClaimStatements.insert(claim.statement).inserted else { continue }
                let anchors = try store.evidence(claimIds: [claim.id])
                    .map(\.anchor).filter { symbolForAnchor[$0] != nil }
                guard !anchors.isEmpty else { continue }
                candidates.append(Candidate(
                    kind: .claim, subjectLabel: claim.statement, sourceComponentId: nil,
                    sourceClaimId: claim.id, anchors: anchors.sorted(),
                    difficultyBand: anchors.count <= 1 ? 1 : 2))
            }
        }

        // --- Centrality: sum member-symbol degree, normalised by the max across all candidates.
        func rawCentrality(_ anchors: [String]) -> Int {
            anchors.reduce(0) { acc, anchor in
                guard let sid = symbolForAnchor[anchor] else { return acc }
                return acc + (degrees[sid] ?? 0)
            }
        }
        let raws = candidates.map { rawCentrality($0.anchors) }
        let maxRaw = raws.max() ?? 0
        func centrality(_ anchors: [String]) -> Double {
            maxRaw > 0 ? Double(rawCentrality(anchors)) / Double(maxRaw) : 0
        }

        // --- Collapse exact natural-key duplicates (e.g. an identical claim statement asserted
        //     by two investigations already filtered above; a component name reused verbatim).
        var byKey: [String: Candidate] = [:]
        for cand in candidates {
            let id = DeterministicID.teachingConcept(
                repositoryId: run.repositoryId, kind: cand.kind.rawValue, subjectLabel: cand.subjectLabel)
            if byKey[id] == nil { byKey[id] = cand }
        }

        // --- §5 dedup: drop a candidate whose normalised-anchor Jaccard with an already-kept,
        //     higher-centrality candidate of the SAME kind is >= 0.6. Same-kind only: a
        //     `relationship` concept's member-union anchors legitimately overlap its endpoint
        //     `component` concepts (a small two-component interaction *is* mostly the same code),
        //     but "how Alpha and Beta interact" is a different unit of understanding from "what
        //     Alpha is" — collapsing across kinds would lose the band-2 material this milestone
        //     exists to surface. Deterministic order: centrality desc, then natural-key id.
        let ordered = byKey
            .map { (id: $0.key, cand: $0.value, cen: centrality($0.value.anchors)) }
            .sorted { $0.cen != $1.cen ? $0.cen > $1.cen : $0.id < $1.id }
        var kept: [(id: String, cand: Candidate, cen: Double, anchorSet: Set<String>)] = []
        for item in ordered {
            let set = AnchorAlignment.normalizedSet(item.cand.anchors)
            let dup = kept.contains {
                $0.cand.kind == item.cand.kind && AnchorAlignment.jaccard(set, $0.anchorSet) >= 0.6
            }
            if dup { result.deduped += 1; continue }
            kept.append((item.id, item.cand, item.cen, set))
        }

        // --- Cap to top-N by centrality (already sorted that way).
        let capped = Array(kept.prefix(max(0, cap)))
        result.cappedOut = kept.count - capped.count

        // --- Reconcile against existing rows.
        let existing = try store.teachingConcepts(
            repositoryId: run.repositoryId, includeStale: true)
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let freshIds = Set(capped.map(\.id))

        var toInsert: [TeachingConceptRecord] = []
        for item in capped {
            if let current = existingById[item.id] {
                if current.stale {
                    try store.setTeachingConceptStale(id: item.id, stale: false)
                    result.revived.append(item.id)
                }
                continue
            }
            toInsert.append(TeachingConceptRecord(
                id: item.id, repositoryId: run.repositoryId, kind: item.cand.kind.rawValue,
                subjectLabel: item.cand.subjectLabel, sourceComponentId: item.cand.sourceComponentId,
                sourceClaimId: item.cand.sourceClaimId, evidenceAnchors: item.cand.anchors,
                centrality: item.cen, difficultyBand: item.cand.difficultyBand, stale: false,
                createdAt: now))
        }
        try store.insertTeachingConcepts(toInsert)
        result.inserted = toInsert.map(\.id)

        for concept in existing where !freshIds.contains(concept.id) && !concept.stale {
            try store.setTeachingConceptStale(id: concept.id, stale: true)
            result.restaled.append(concept.id)
        }

        result.kept = try store.teachingConcepts(repositoryId: run.repositoryId).count
        return result
    }
}
