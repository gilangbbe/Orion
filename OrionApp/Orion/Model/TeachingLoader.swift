import Foundation
import OrionCodeIntel

/// One concept in the Teaching Mode rail, carrying the developer's current mastery of it.
/// Docs/17_phase7_teaching_mode.md §11. Pure value type — `TeachingLoader` builds it, no SwiftUI.
struct TeachingConceptRow: Identifiable, Equatable {
    let id: String
    let label: String
    let kind: String                 // TeachingConceptKind raw
    let difficultyBand: Int
    let centrality: Double
    let pMastered: Double
    let confidenceBand: String        // KnowledgeConfidenceBand raw
    let attempts: Int
    let lastVerdict: String?
    let openMisconceptions: [String]
    /// The `TeachingPlanner` rank — the rail is ordered by this (most useful to work on next
    /// first), so a never-attempted, load-bearing concept surfaces above a mastered one.
    let plannerScore: Double

    var hasOpenMisconception: Bool { !openMisconceptions.isEmpty }
}

/// A one-line read of the developer's whole teaching state — the app sidebar's mastery strip
/// and the `.teaching` destination badge (Docs/17 §11).
struct TeachingOverview: Equatable {
    let total: Int
    let solid: Int
    let developing: Int
    let shaky: Int
    let new: Int
    /// Concepts with at least one uncleared misconception — the sidebar badge count.
    let misconceptionConcepts: Int

    static let empty = TeachingOverview(
        total: 0, solid: 0, developing: 0, shaky: 0, new: 0, misconceptionConcepts: 0)
    var isEmpty: Bool { total == 0 }
}

/// A generated, verified question ready to work through.
struct TeachingQuestionCard: Identifiable, Equatable {
    let id: String
    let conceptId: String
    let conceptLabel: String
    let conceptKind: String
    let band: Int
    let explain: String
    let prompt: String
    let transferProblem: String?
}

/// One rubric criterion's outcome on a graded attempt — the row that makes the decomposed grade
/// visible rather than a bare number (Docs/17 §2.1/§7, H7).
struct TeachingCriterionRow: Identifiable, Equatable {
    enum Kind: String { case required, bonus, anti }
    let id: String
    let text: String
    let kind: Kind
    let met: Bool
    /// A split k=3 vote — surfaced as "needs your review", never silently pass/fail (Docs/17 §7.3).
    let needsReview: Bool
    let evidenceQuote: String
    let note: String
    let evidence: [EvidenceDetail]
}

/// A graded attempt, projected for display. `masteryBefore`/`After` are `nil` when the calibration
/// gate hasn't cleared (Docs/17 Decision 10) — the app grades and shows the breakdown, but does
/// not move any mastery estimate until M7.
struct TeachingGradeCard: Equatable {
    let score: Double
    let verdict: String              // TeachingVerdictTier raw
    let requiredMet: Int
    let requiredTotal: Int
    let bonusMet: Int
    let antiTripped: Int
    let needsReviewCount: Int
    let correction: String
    let disputed: Bool
    let misconceptionsDetected: [String]
    let misconceptionsCleared: [String]
    let masteryBefore: Double?
    let masteryAfter: Double?
    let bandBefore: String?
    let bandAfter: String?
    let criteria: [TeachingCriterionRow]

    init(_ r: RubricGrader.Result, criteria: [TeachingCriterionRow]) {
        score = r.score
        verdict = r.verdict.rawValue
        requiredMet = r.requiredMet
        requiredTotal = r.requiredTotal
        bonusMet = r.bonusMet
        antiTripped = r.antiTripped
        needsReviewCount = r.needsReview.count
        correction = r.correction
        disputed = r.disputed
        misconceptionsDetected = r.misconceptionsDetected
        misconceptionsCleared = r.misconceptionsCleared
        masteryBefore = r.knowledgeState?.previousPMastered
        masteryAfter = r.knowledgeState?.newPMastered
        bandBefore = r.knowledgeState?.previousBand
        bandAfter = r.knowledgeState?.newBand
        self.criteria = criteria
    }

    /// Test-support memberwise init (defining `init(_:criteria:)` suppresses the synthesized one).
    init(
        score: Double, verdict: String, requiredMet: Int, requiredTotal: Int, bonusMet: Int,
        antiTripped: Int, needsReviewCount: Int, correction: String, disputed: Bool,
        misconceptionsDetected: [String], misconceptionsCleared: [String], masteryBefore: Double?,
        masteryAfter: Double?, bandBefore: String?, bandAfter: String?, criteria: [TeachingCriterionRow]
    ) {
        self.score = score
        self.verdict = verdict
        self.requiredMet = requiredMet
        self.requiredTotal = requiredTotal
        self.bonusMet = bonusMet
        self.antiTripped = antiTripped
        self.needsReviewCount = needsReviewCount
        self.correction = correction
        self.disputed = disputed
        self.misconceptionsDetected = misconceptionsDetected
        self.misconceptionsCleared = misconceptionsCleared
        self.masteryBefore = masteryBefore
        self.masteryAfter = masteryAfter
        self.bandBefore = bandBefore
        self.bandAfter = bandAfter
        self.criteria = criteria
    }
}

/// Docs/17_phase7_teaching_mode.md §11 — reads `teaching_concepts` / `knowledge_states` /
/// `teaching_questions` / `teaching_criterion_results` for the app's Teaching Mode screen. Pure
/// logic, no SwiftUI, unit-testable without rendering — the same discipline `ModelChangeLoader`
/// and `ArchitectureModelLoader` already follow. Opens its own read `Store` per call
/// (`CodebaseModelStore` doesn't wrap the Phase 7 reads, and `TeachingPlanner` needs a real
/// `Store` anyway).
enum TeachingLoader {
    static let developerId = "local"

    private static func store(_ outputDirectory: URL) throws -> Store {
        Store(try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path))
    }

    /// The concept rail, ordered by `TeachingPlanner` rank. `bootstrap: true` runs
    /// `ConceptExtractor` once if the table is empty (a repository with a semantic investigation
    /// but no extraction yet) — matching `orion-agent teach`'s own first-use behavior.
    static func concepts(
        outputDirectory: URL, bootstrap: Bool = true
    ) throws -> [TeachingConceptRow] {
        let store = try store(outputDirectory)
        guard let run = try store.latestRun(commitHash: nil) else { return [] }

        var rows = try store.teachingConcepts(repositoryId: run.repositoryId)
        if rows.isEmpty && bootstrap {
            _ = try ConceptExtractor.extract(
                store: store, commitHash: run.commitHash,
                now: ISO8601DateFormatter().string(from: Date()))
            rows = try store.teachingConcepts(repositoryId: run.repositoryId)
        }
        guard !rows.isEmpty else { return [] }

        let ranked = try TeachingPlanner(store: store)
            .rank(repositoryId: run.repositoryId, developerId: developerId)
        let scoreById = Dictionary(uniqueKeysWithValues: ranked.map { ($0.concept.id, $0.score) })

        return try rows.map { c in
            let ks = try store.knowledgeState(developerId: developerId, conceptId: c.id)
            let open = try ks.map {
                try store.teachingMisconceptions(knowledgeStateId: $0.id, openOnly: true).map(\.statement)
            } ?? []
            return TeachingConceptRow(
                id: c.id, label: c.subjectLabel, kind: c.kind, difficultyBand: c.difficultyBand,
                centrality: c.centrality, pMastered: ks?.pMastered ?? 0.15,
                confidenceBand: ks?.confidenceBand ?? KnowledgeConfidenceBand.new.rawValue,
                attempts: ks?.attemptsCount ?? 0, lastVerdict: ks?.lastVerdict,
                openMisconceptions: open, plannerScore: scoreById[c.id] ?? 0)
        }
        .sorted { $0.plannerScore > $1.plannerScore }
    }

    static func overview(from rows: [TeachingConceptRow]) -> TeachingOverview {
        TeachingOverview(
            total: rows.count,
            solid: rows.filter { $0.confidenceBand == KnowledgeConfidenceBand.solid.rawValue }.count,
            developing: rows.filter { $0.confidenceBand == KnowledgeConfidenceBand.developing.rawValue }.count,
            shaky: rows.filter { $0.confidenceBand == KnowledgeConfidenceBand.shaky.rawValue }.count,
            new: rows.filter { $0.confidenceBand == KnowledgeConfidenceBand.new.rawValue }.count,
            misconceptionConcepts: rows.filter(\.hasOpenMisconception).count)
    }

    /// The freshest verified question for a concept — reused rather than regenerated when the
    /// developer returns to a concept (Docs/17 §10). Matching a specific band when one is given.
    static func latestVerifiedQuestion(
        conceptId: String, band: Int?, outputDirectory: URL
    ) throws -> TeachingQuestionCard? {
        let store = try store(outputDirectory)
        guard let concept = try store.teachingConcept(id: conceptId) else { return nil }
        let questions = try store.teachingQuestions(conceptId: conceptId, verifiedOnly: true)
        let match = band != nil ? questions.last { $0.difficultyBand == band } : questions.last
        guard let q = match else { return nil }
        return card(q, concept: concept)
    }

    static func question(id: String, outputDirectory: URL) throws -> TeachingQuestionCard? {
        let store = try store(outputDirectory)
        guard let q = try store.teachingQuestion(id: id),
              let concept = try store.teachingConcept(id: q.conceptId) else { return nil }
        return card(q, concept: concept)
    }

    private static func card(
        _ q: TeachingQuestionRecord, concept: TeachingConceptRecord
    ) -> TeachingQuestionCard {
        TeachingQuestionCard(
            id: q.id, conceptId: q.conceptId, conceptLabel: concept.subjectLabel,
            conceptKind: concept.kind, band: q.difficultyBand, explain: q.explain, prompt: q.prompt,
            transferProblem: q.transferProblem)
    }

    /// Maps a fresh `RubricGrader.Result` into the display card, resolving each criterion's cited
    /// anchors to `EvidenceDetail`s (so the checklist rows can open `EvidenceView`).
    static func gradeCard(
        _ result: RubricGrader.Result, outputDirectory: URL
    ) throws -> TeachingGradeCard {
        let store = try store(outputDirectory)
        let runId = try store.latestRun(commitHash: nil)?.id
        let criteria = result.perCriterion.map { pc -> TeachingCriterionRow in
            let evidence: [EvidenceDetail] = pc.evidenceAnchors.compactMap { anchor in
                guard let runId, let sym = try? store.symbol(runId: runId, anchor: anchor) else {
                    return EvidenceDetail(id: anchor, anchor: anchor, startLine: nil, endLine: nil)
                }
                return EvidenceDetail(
                    id: sym.id, anchor: anchor, startLine: sym.startLine, endLine: sym.endLine)
            }
            return TeachingCriterionRow(
                id: pc.criterionId, text: pc.text,
                kind: TeachingCriterionRow.Kind(rawValue: pc.kind.rawValue) ?? .required,
                met: pc.met, needsReview: pc.confidence == .low,
                evidenceQuote: pc.evidenceQuote, note: pc.note, evidence: evidence)
        }
        return TeachingGradeCard(result, criteria: criteria)
    }
}
