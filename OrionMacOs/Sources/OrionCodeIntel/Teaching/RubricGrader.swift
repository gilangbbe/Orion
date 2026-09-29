import Foundation

/// One model judgement of one rubric criterion against a developer's answer (Docs/17 §7.1). The
/// `evidenceQuote` and `note` come *before* `met` in the schema on purpose — a form-filled
/// mini-rationale, not a bare boolean (Docs/17 §2.4, "Explicit Reasoning Makes Better Judges").
public struct CriterionVerdict: Sendable, Equatable {
    public var met: Bool
    public var confidence: GraderConfidence
    public var evidenceQuote: String   // verbatim span from the answer, or "" if none
    public var note: String

    public init(met: Bool, confidence: GraderConfidence, evidenceQuote: String = "", note: String = "") {
        self.met = met
        self.confidence = confidence
        self.evidenceQuote = evidenceQuote
        self.note = note
    }
}

/// A single-shot per-criterion judge. `RubricGrader` calls this `k` times per criterion for
/// self-consistency (Docs/17 §7.1); the protocol itself stays one call, so a scripted stub can
/// drive `RubricGrader`'s aggregation logic with no model.
public protocol CriterionJudging: Sendable {
    var source: TeachingQuestionSource { get }
    func judge(
        criterionText: String, criterionKind: RubricCriterionKind,
        answer: String, conceptEvidence: [String]
    ) async throws -> CriterionVerdict
}

/// The §7.4 pairwise "does the answer convey the same core idea as the reference" tripwire —
/// optional. `RubricGrader` runs it in both orderings and treats a disagreement with the rubric
/// score as a flag for the calibration set, never as a second grade.
public protocol AnswerComparing: Sendable {
    /// `true` iff `a` conveys the same core idea as `b`.
    func conveysSameIdea(_ a: String, as b: String) async throws -> Bool
}

// MARK: - Pure scoring

/// The deterministic half of Docs/17 §7.3 — no model, no `Store`. Given the aggregated
/// per-criterion outcomes, produce the score, the verdict tier and the correction text. Split out
/// so the threshold math is unit-testable in isolation.
public enum RubricScoring {

    public struct AggregateInput: Sendable {
        /// One entry per criterion: its kind, whether the k-run majority said `met`, and whether
        /// that majority was confident (a split k-run -> `confident == false`).
        public struct Row: Sendable {
            public let kind: RubricCriterionKind
            public let met: Bool
            public let confident: Bool
            public let text: String
            public init(kind: RubricCriterionKind, met: Bool, confident: Bool, text: String) {
                self.kind = kind
                self.met = met
                self.confident = confident
                self.text = text
            }
        }
        public let rows: [Row]
        public init(rows: [Row]) { self.rows = rows }
    }

    public struct Aggregate: Sendable, Equatable {
        public var score: Double
        public var verdict: TeachingVerdictTier
        public var requiredMet: Int
        public var requiredTotal: Int   // confident required criteria only
        public var bonusMet: Int
        public var antiTripped: Int
        /// `required` criteria excluded from scoring for a split k-run — surfaced as "needs your
        /// review", never counted as pass or fail (Docs/17 §7.3).
        public var needsReview: [String]
    }

    public static let bonusStep = 0.05
    public static let bonusCap = 0.15

    public static func aggregate(_ input: AggregateInput) -> Aggregate {
        let required = input.rows.filter { $0.kind == .required }
        let confidentRequired = required.filter(\.confident)
        let requiredTotal = confidentRequired.count
        let requiredMet = confidentRequired.filter(\.met).count
        let needsReview = required.filter { !$0.confident }.map(\.text)

        let bonusMet = input.rows.filter { $0.kind == .bonus && $0.confident && $0.met }.count
        let antiTripped = input.rows.filter { $0.kind == .anti && $0.confident && $0.met }.count

        let raw = requiredTotal > 0 ? Double(requiredMet) / Double(requiredTotal) : 0
        let score = min(1.0, raw + min(bonusCap, Double(bonusMet) * bonusStep))

        let verdict: TeachingVerdictTier
        if antiTripped >= 1 && (requiredTotal - requiredMet) >= 2 {
            verdict = .offTrack
        } else if requiredTotal == 0 {
            // Nothing confidently assessable — not a pass, not an outright failure.
            verdict = .shaky
        } else if score >= 0.85 && antiTripped == 0 {
            verdict = .solid
        } else if score >= 0.6 {
            verdict = .partial
        } else if score >= 0.3 {
            verdict = .shaky
        } else {
            verdict = .offTrack
        }

        return Aggregate(
            score: score, verdict: verdict, requiredMet: requiredMet, requiredTotal: requiredTotal,
            bonusMet: bonusMet, antiTripped: antiTripped, needsReview: needsReview)
    }

    /// Docs/17 §7.5 — a deterministic template over the unmet `required` criteria and any tripped
    /// `anti` criteria. No model call (Docs/16 Decision 2 precedent). A local-model paraphrase
    /// pass to smooth it is an explicit follow-up, not v1.
    public static func correctionText(
        unmetRequired: [String], trippedAnti: [String], needsReview: [String], referenceAnswer: String
    ) -> String {
        var parts: [String] = []
        if unmetRequired.isEmpty && trippedAnti.isEmpty {
            parts.append("You covered every required point.")
        }
        if !unmetRequired.isEmpty {
            parts.append("You didn't establish: " + unmetRequired.map { "“\($0)”" }.joined(separator: "; ") + ".")
        }
        if !trippedAnti.isEmpty {
            parts.append("Your answer implied: " + trippedAnti.map { "“\($0)”" }.joined(separator: "; ")
                + " — which isn't right.")
        }
        if !needsReview.isEmpty {
            parts.append("\(needsReview.count) point(s) couldn't be graded confidently and need a manual look.")
        }
        parts.append("Reference: \(referenceAnswer)")
        return parts.joined(separator: " ")
    }
}

// MARK: - Grader

/// Docs/17 §7 — grades one developer answer to one `teaching_questions` row: k-sampled
/// per-criterion judging, deterministic score/verdict aggregation, the §7.4 pairwise tripwire,
/// misconception (anti-criterion) lifecycle, and persistence of `teaching_attempts` +
/// `teaching_criterion_results` (+ `teaching_misconceptions`). Standalone, not a method on
/// `AgentSession` — grading has no Depth-Model routing, same recorded deviation as M2's generator.
public struct RubricGrader {

    public struct PerCriterion: Sendable, Equatable {
        public let criterionId: String
        public let text: String
        public let kind: RubricCriterionKind
        public let met: Bool
        public let confidence: GraderConfidence
        public let evidenceQuote: String
        public let note: String
        /// Benchmark-form anchors the criterion is grounded in — for a UI that lets the developer
        /// open the cited source (Docs/17 §11).
        public let evidenceAnchors: [String]
    }

    /// The `knowledge_states` change this attempt produced (Docs/17 §8.2), for the CLI/UI to show
    /// the mastery move. `nil` only if the question's concept could not be resolved.
    public struct KnowledgeDelta: Sendable, Equatable {
        public var previousPMastered: Double
        public var newPMastered: Double
        public var previousBand: String
        public var newBand: String
        public var attemptsCount: Int
    }

    public struct Result: Sendable, Equatable {
        public var attemptId: String
        public var score: Double
        public var verdict: TeachingVerdictTier
        public var requiredMet: Int
        public var requiredTotal: Int
        public var bonusMet: Int
        public var antiTripped: Int
        public var needsReview: [String]
        public var correction: String
        public var disputed: Bool
        public var pairwiseSameIdea: Bool?
        public var misconceptionsDetected: [String]
        public var misconceptionsCleared: [String]
        public var knowledgeState: KnowledgeDelta?
        public var perCriterion: [PerCriterion]
    }

    public static let disputedDiagnosticCode = "TEACHING_SCORE_DISPUTED"

    let store: Store
    let run: AnalysisRunRecord
    let judge: any CriterionJudging
    let comparer: (any AnswerComparing)?
    let k: Int
    let persistMastery: Bool
    let now: @Sendable () -> String

    /// - Parameter persistMastery: `true` (default, the CLI) writes `knowledge_states` and
    ///   `teaching_misconceptions` — the mastery update (§8.2) and the misconception lifecycle
    ///   (§7.2). `false` (the app, until Phase 7 M7's calibration gate clears — Docs/17 Decision
    ///   10) grades and persists the *attempt* (`teaching_attempts` + `teaching_criterion_results`,
    ///   the auditable record of what was asked and how each point scored) but does **not** move
    ///   any mastery estimate: the in-memory `Result` still carries `misconceptionsDetected` for
    ///   display, `knowledgeState` is `nil`, and no `knowledge_states` row is touched.
    public init(
        store: Store, run: AnalysisRunRecord, judge: any CriterionJudging,
        comparer: (any AnswerComparing)? = nil, k: Int = 3, persistMastery: Bool = true,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.store = store
        self.run = run
        self.judge = judge
        self.comparer = comparer
        self.k = max(1, k)
        self.persistMastery = persistMastery
        self.now = now
    }

    public enum GradeError: Error, CustomStringConvertible {
        case questionNotFound(String)
        case noCriteria(String)
        public var description: String {
            switch self {
            case .questionNotFound(let id): return "no teaching_questions row with id \(id)"
            case .noCriteria(let id): return "question \(id) has no rubric criteria"
            }
        }
    }

    public func grade(
        questionId: String, answer: String, developerId: String = "local"
    ) async throws -> Result {
        guard let question = try store.teachingQuestion(id: questionId) else {
            throw GradeError.questionNotFound(questionId)
        }
        let criteria = try store.teachingRubricCriteria(questionId: questionId)
        guard !criteria.isEmpty else { throw GradeError.noCriteria(questionId) }
        let concept = try store.teachingConcept(id: question.conceptId)
        let conceptEvidence = conceptEvidenceLines(concept)

        // --- k-sampled per-criterion judging.
        struct Judged {
            let criterion: TeachingRubricCriterionRecord
            let majorityMet: Bool
            let confident: Bool            // false -> split k-run
            let confidence: GraderConfidence
            let representative: CriterionVerdict
            let votes: [CriterionVerdict]
        }
        var judged: [Judged] = []
        for criterion in criteria {
            let kind = RubricCriterionKind(rawValue: criterion.kind) ?? .required
            var votes: [CriterionVerdict] = []
            for _ in 0..<k {
                votes.append(try await Self.vote(
                    judge: judge, criterionText: criterion.text, criterionKind: kind, answer: answer,
                    conceptEvidence: conceptEvidence))
            }
            let metCount = votes.filter(\.met).count
            let majorityMet = metCount * 2 > votes.count
            let unanimous = metCount == 0 || metCount == votes.count
            let representative = votes.first { $0.met == majorityMet } ?? votes[0]
            // Confident iff the k-run agrees AND the representative vote isn't itself `.low`.
            let confident = unanimous && representative.confidence != .low
            let confidence: GraderConfidence = confident ? representative.confidence : .low
            judged.append(Judged(
                criterion: criterion, majorityMet: majorityMet, confident: confident,
                confidence: confidence, representative: representative, votes: votes))
        }

        // --- Deterministic aggregate.
        let agg = RubricScoring.aggregate(RubricScoring.AggregateInput(rows: judged.map {
            RubricScoring.AggregateInput.Row(
                kind: RubricCriterionKind(rawValue: $0.criterion.kind) ?? .required,
                met: $0.majorityMet, confident: $0.confident, text: $0.criterion.text)
        }))

        let unmetRequired = judged
            .filter { $0.criterion.kind == RubricCriterionKind.required.rawValue && $0.confident && !$0.majorityMet }
            .map { $0.criterion.text }
        let trippedAnti = judged
            .filter { $0.criterion.kind == RubricCriterionKind.anti.rawValue && $0.confident && $0.majorityMet }
            .map { $0.criterion.text }
        let correction = RubricScoring.correctionText(
            unmetRequired: unmetRequired, trippedAnti: trippedAnti, needsReview: agg.needsReview,
            referenceAnswer: question.referenceAnswer)

        // --- §7.4 pairwise tripwire.
        var pairwiseSame: Bool?
        var disputed = false
        // A comparer failure leaves the tripwire unrun (`pairwiseSame` nil) rather than failing the
        // grade -- it's a calibration flag, never the grade itself (Docs/18 M5).
        if let comparer {
            do {
                let a = try await comparer.conveysSameIdea(answer, as: question.referenceAnswer)
                let b = try await comparer.conveysSameIdea(question.referenceAnswer, as: answer)
                let same = a && b
                pairwiseSame = same
                disputed = (agg.score >= 0.6) != same
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pairwiseSame = nil
            }
        }

        // --- Persist.
        let attemptId = DeterministicID.newUUID()
        try store.insertTeachingAttempt(TeachingAttemptRecord(
            id: attemptId, questionId: questionId, developerId: developerId, answerText: answer,
            score: agg.score, verdictTier: agg.verdict.rawValue, modelUsed: judge.source.rawValue,
            disputed: disputed, createdAt: now()))

        try store.insertTeachingCriterionResults(judged.map { j in
            TeachingCriterionResultRecord(
                id: DeterministicID.newUUID(), attemptId: attemptId, criterionId: j.criterion.id,
                met: j.majorityMet, confidence: j.confidence.rawValue,
                evidenceQuote: j.representative.evidenceQuote, note: j.representative.note,
                voteDetail: encodeVotes(j.votes))
        })

        if disputed {
            try store.insertDiagnostics([DiagnosticRecord(
                id: DeterministicID.newUUID(), repositoryId: run.repositoryId,
                commitHash: run.commitHash, runId: run.id, fileId: nil, stage: "teaching_grade",
                severity: "warning", code: Self.disputedDiagnosticCode,
                message: "rubric score \(String(format: "%.2f", agg.score)) disagrees with the pairwise same-idea check",
                startLine: nil, startCol: nil, endLine: nil, endCol: nil)])
        }

        // --- KnowledgeState update (Docs/17 §8.2) + misconception lifecycle (§7.2).
        var detected: [String] = []
        var cleared: [String] = []
        var ksDelta: KnowledgeDelta?
        // Always surface which anti-criteria this attempt tripped, for the caller to display —
        // even when `persistMastery` is off (Docs/17 Decision 10) and nothing is written.
        let antiTrippedThisAttempt = judged
            .filter { $0.criterion.kind == RubricCriterionKind.anti.rawValue && $0.confident && $0.majorityMet }
            .map { $0.criterion.text }
        if persistMastery, concept != nil {
            let ks = try store.ensureKnowledgeState(
                developerId: developerId, conceptId: question.conceptId, now: now())
            let openMisconceptions = try store.teachingMisconceptions(
                knowledgeStateId: ks.id, openOnly: true)

            for j in judged where j.criterion.kind == RubricCriterionKind.anti.rawValue && j.confident {
                if j.majorityMet {
                    // Present — but don't double-record one already open with the same statement.
                    if !openMisconceptions.contains(where: { $0.statement == j.criterion.text }) {
                        try store.insertTeachingMisconception(TeachingMisconceptionRecord(
                            id: DeterministicID.newUUID(), knowledgeStateId: ks.id,
                            criterionId: j.criterion.id, attemptId: attemptId,
                            statement: j.criterion.text, detectedAt: now()))
                        detected.append(j.criterion.text)
                    }
                } else if j.confidence == .high {
                    // Not-met, high confidence -> clear any open misconception with this statement
                    // for this concept (Docs/17 §7.2: "any question for the same concept").
                    for m in openMisconceptions where m.statement == j.criterion.text {
                        try store.setTeachingMisconceptionCleared(id: m.id, clearedAt: now())
                        cleared.append(m.statement)
                    }
                }
            }

            // BKT-style mastery update, fed criterion-level: one observation per confident
            // `required` outcome, plus one strong-negative per tripped anti (Docs/17 §8.2).
            let requiredOutcomes = judged
                .filter { $0.criterion.kind == RubricCriterionKind.required.rawValue && $0.confident }
                .map(\.majorityMet)
            let newP = KnowledgeUpdate.apply(
                prior: ks.pMastered, requiredMet: requiredOutcomes, antiTripped: agg.antiTripped)
            let newAttempts = ks.attemptsCount + 1
            let newBand = KnowledgeUpdate.band(pMastered: newP, attemptsCount: newAttempts)
            var updated = ks
            updated.pMastered = newP
            updated.attemptsCount = newAttempts
            updated.lastVerdict = agg.verdict.rawValue
            updated.confidenceBand = newBand.rawValue
            updated.lastAssessedAt = now()
            try store.updateKnowledgeState(updated)
            ksDelta = KnowledgeDelta(
                previousPMastered: ks.pMastered, newPMastered: newP,
                previousBand: ks.confidenceBand, newBand: newBand.rawValue, attemptsCount: newAttempts)
        }

        return Result(
            attemptId: attemptId, score: agg.score, verdict: agg.verdict,
            requiredMet: agg.requiredMet, requiredTotal: agg.requiredTotal, bonusMet: agg.bonusMet,
            antiTripped: agg.antiTripped, needsReview: agg.needsReview, correction: correction,
            disputed: disputed, pairwiseSameIdea: pairwiseSame,
            misconceptionsDetected: persistMastery ? detected : antiTrippedThisAttempt,
            misconceptionsCleared: cleared,
            knowledgeState: ksDelta,
            perCriterion: judged.map {
                PerCriterion(
                    criterionId: $0.criterion.id, text: $0.criterion.text,
                    kind: RubricCriterionKind(rawValue: $0.criterion.kind) ?? .required,
                    met: $0.majorityMet, confidence: $0.confidence,
                    evidenceQuote: $0.representative.evidenceQuote, note: $0.representative.note,
                    evidenceAnchors: $0.criterion.evidenceAnchors)
            })
    }

    // MARK: helpers

    private func conceptEvidenceLines(_ concept: TeachingConceptRecord?) -> [String] {
        guard let concept else { return [] }
        var lines: [String] = []
        for anchor in concept.evidenceAnchors.sorted() {
            guard let sym = try? store.symbol(runId: run.id, anchor: anchor) else { continue }
            let detail = sym.signature
                ?? sym.docstring?.split(separator: "\n").first.map(String.init) ?? sym.kind
            lines.append("\(anchor) — \(detail)")
        }
        return lines
    }

    static let failedVoteNotePrefix = "judge call failed: "

    /// One k-vote. A judge call that throws (Docs/18 M4: a Core AI call whose thinking ran into the
    /// token cap ended with no response) becomes an unconfident "not met" vote instead of failing
    /// the whole grade -- the other votes still decide, and a criterion left with only failed
    /// votes is unconfident, so the attempt is flagged for review rather than silently scored.
    static func vote(
        judge: any CriterionJudging, criterionText: String, criterionKind: RubricCriterionKind,
        answer: String, conceptEvidence: [String]
    ) async throws -> CriterionVerdict {
        do {
            return try await judge.judge(
                criterionText: criterionText, criterionKind: criterionKind, answer: answer,
                conceptEvidence: conceptEvidence)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return CriterionVerdict(
                met: false, confidence: .low, evidenceQuote: "", note: failedVoteNotePrefix + "\(error)")
        }
    }

    private func encodeVotes(_ votes: [CriterionVerdict]) -> String {
        let arr = votes.map { ["met": $0.met, "confidence": $0.confidence.rawValue] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
