import Foundation
import OrionCore

/// The grader-calibration run (Docs/17 §12.2), shared by `orion-agent teach bench` and the
/// phone's on-device calibration (Docs/19 M7, whose model the Mac can't stand in for). Seeds each
/// gold question into a **copy** of a repository's database, grades the gold answer with the real
/// `RubricGrader`, and pairs every per-criterion verdict with the expert's label;
/// `CalibrationSummary` turns the rows into κ, score error and verdict confusion.
public enum GraderCalibration {
    // MARK: one gold item

    public static func evaluate(
        item: GraderGoldItem, store: Store, run: AnalysisRunRecord,
        judge: any CriterionJudging, comparer: (any AnswerComparing)?, k: Int,
        verifyGold: Bool, now: @escaping @Sendable () -> String
    ) async -> CalibrationRow {
        func fail(_ message: String) -> CalibrationRow {
            CalibrationRow(
                id: item.id, band: item.band, note: item.note, error: message,
                graderScore: nil, expertScore: nil, graderVerdict: nil, expertVerdict: nil,
                disputed: nil, splitVoteCount: 0, criteria: [])
        }

        guard let concept = (try? store.teachingConcept(id: item.conceptId)) ?? nil else {
            return fail("concept \(item.conceptId) not found — extract concepts first")
        }

        let candidate: TeachingQuestionCandidate
        do {
            candidate = try JSONDecoder().decode(
                TeachingQuestionCandidate.self, from: try JSONSerialization.data(withJSONObject: item.question))
        } catch {
            return fail("question block is not a valid phase7.v1 candidate: \(error)")
        }

        let questionId: String
        do {
            if verifyGold {
                switch try TeachingQuestionVerifier.verifyAndPersist(
                    candidate: candidate, concept: concept, store: store, run: run,
                    generatedBy: .local, now: now(), persistDiagnostics: false)
                {
                case .persisted(let qid, _):
                    questionId = qid
                case .rejected(let reasons):
                    return fail("gold question failed §6.3 verification: "
                        + reasons.map(\.message).joined(separator: "; "))
                }
            } else {
                questionId = try seedTrustedGoldQuestion(
                    candidate: candidate, concept: concept, store: store, run: run, now: now())
            }
        } catch let e as GoldSeedError {
            return fail(e.message)
        } catch {
            return fail("seeding threw: \(error)")
        }

        let result: RubricGrader.Result
        do {
            result = try await RubricGrader(
                store: store, run: run, judge: judge, comparer: comparer, k: k,
                persistMastery: false, now: now
            ).grade(questionId: questionId, answer: item.answer)
        } catch {
            return fail("grade threw: \(error)")
        }

        // Pair each graded criterion with its expert label by verbatim text.
        let expertByText = Dictionary(
            item.expertLabels.map { ($0.text.trimmed, $0.label) }, uniquingKeysWith: { a, _ in a })
        var criteria: [CalibrationRow.Criterion] = []
        var splitVotes = 0
        for pc in result.perCriterion {
            let expert = expertByText[pc.text.trimmed]
            if pc.confidence == .low { splitVotes += 1 }
            criteria.append(CalibrationRow.Criterion(
                text: pc.text, kind: pc.kind.rawValue,
                graderMet: pc.met, graderConfident: pc.confidence != .low,
                expertLabel: expert?.rawValue, matched: expert != nil))
        }
        let unmatchedExpert = item.expertLabels.filter { expertByText[$0.text.trimmed] != nil }
            .filter { label in !result.perCriterion.contains { $0.text.trimmed == label.text.trimmed } }
        for label in unmatchedExpert {
            criteria.append(CalibrationRow.Criterion(
                text: label.text, kind: "?", graderMet: nil, graderConfident: nil,
                expertLabel: label.label.rawValue, matched: false))
        }

        // Expert-derived score/verdict — the same deterministic aggregation, fed the expert's
        // labels (ambiguous -> not confident, so excluded from the denominator just like a split
        // grader vote).
        let expertRows: [RubricScoring.AggregateInput.Row] = result.perCriterion.map { pc in
            let label = expertByText[pc.text.trimmed]
            return RubricScoring.AggregateInput.Row(
                kind: pc.kind, met: label == .met,
                confident: label != nil && label != .ambiguous, text: pc.text)
        }
        let expertAgg = RubricScoring.aggregate(RubricScoring.AggregateInput(rows: expertRows))

        return CalibrationRow(
            id: item.id, band: item.band, note: item.note, error: nil,
            graderScore: result.score, expertScore: expertAgg.score,
            graderVerdict: result.verdict.rawValue, expertVerdict: expertAgg.verdict.rawValue,
            disputed: comparer != nil ? result.disputed : nil,
            splitVoteCount: splitVotes, criteria: criteria)
    }

    // MARK: trusted-gold seeding

    struct GoldSeedError: Error { let message: String }

    /// Persist a hand-authored gold question directly, running only the checks §12.2 actually
    /// needs: schema shape and anchor resolution. Skips the §6.3 CONTRADICTED-claim consistency
    /// check (a *generation* gate) so the grader can be measured on a repo whose semantic layer
    /// carries contradicted claims over the same files the gold questions cite. A required- or
    /// reference-anchor that does not resolve is still fatal — a typo in the gold file fails
    /// loudly; a bonus/anti anchor that doesn't resolve drops just that criterion.
    static func seedTrustedGoldQuestion(
        candidate: TeachingQuestionCandidate, concept: TeachingConceptRecord,
        store: Store, run: AnalysisRunRecord, now: String
    ) throws -> String {
        guard candidate.schemaVersion == TeachingSchema.currentVersion else {
            throw GoldSeedError(message: "schema_version \(candidate.schemaVersion) != \(TeachingSchema.currentVersion)")
        }
        guard candidate.conceptId == concept.id else {
            throw GoldSeedError(message: "concept_id \(candidate.conceptId) != gold concept_id \(concept.id)")
        }
        guard (1...3).contains(candidate.difficultyBand) else {
            throw GoldSeedError(message: "difficulty_band \(candidate.difficultyBand) outside 1...3")
        }
        let requiredInputs = candidate.rubric.filter { $0.kind == RubricCriterionKind.required.rawValue }
        guard !requiredInputs.isEmpty else {
            throw GoldSeedError(message: "rubric has no `required` criteria")
        }

        func resolves(_ anchor: String) -> Bool {
            ((try? store.symbol(runId: run.id, anchor: anchor)) ?? nil) != nil
        }
        let refAnchors = candidate.referenceAnchors.filter(resolves)
        let refMisses = candidate.referenceAnchors.filter { !resolves($0) }
        guard !refAnchors.isEmpty else {
            throw GoldSeedError(message: "no reference anchor resolves (\(candidate.referenceAnchors))")
        }
        guard refMisses.isEmpty else {
            throw GoldSeedError(message: "reference anchor(s) do not resolve: \(refMisses)")
        }

        struct Kept { let kind: RubricCriterionKind; let text: String; let anchors: [String] }
        var kept: [Kept] = []
        for c in requiredInputs {
            let ok = c.evidence.filter(resolves)
            guard ok.count == c.evidence.count, !ok.isEmpty else {
                throw GoldSeedError(
                    message: "required criterion \"\(c.text.prefix(50))…\" has an unresolvable anchor")
            }
            kept.append(Kept(kind: .required, text: c.text, anchors: ok.sorted()))
        }
        for c in candidate.rubric where c.kind == RubricCriterionKind.bonus.rawValue {
            let ok = c.evidence.filter(resolves)
            if !ok.isEmpty { kept.append(Kept(kind: .bonus, text: c.text, anchors: ok.sorted())) }
        }
        for c in candidate.antiCriteria {
            let ok = c.evidence.filter(resolves)
            if !ok.isEmpty { kept.append(Kept(kind: .anti, text: c.text, anchors: ok.sorted())) }
        }

        let questionId = DeterministicID.newUUID()
        try store.insertTeachingQuestion(TeachingQuestionRecord(
            id: questionId, conceptId: concept.id, investigationId: nil,
            difficultyBand: candidate.difficultyBand,
            explain: candidate.explain.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: candidate.question.trimmingCharacters(in: .whitespacesAndNewlines),
            referenceAnswer: candidate.referenceAnswer.trimmingCharacters(in: .whitespacesAndNewlines),
            referenceAnchors: refAnchors.sorted(),
            transferProblem: candidate.transferProblem?.trimmingCharacters(in: .whitespacesAndNewlines),
            generatedBy: TeachingQuestionSource.local.rawValue, verified: true, createdAt: now))
        try store.insertTeachingRubricCriteria(kept.enumerated().map { ordinal, c in
            TeachingRubricCriterionRecord(
                id: DeterministicID.newUUID(), questionId: questionId, ordinal: ordinal,
                kind: c.kind.rawValue, text: c.text.trimmingCharacters(in: .whitespacesAndNewlines),
                evidenceAnchors: c.anchors)
        })
        return questionId
    }
}

// MARK: - Gold file

/// The §12.2 grader-calibration gold set. `question` is an inline `phase7.v1` candidate object
/// (same shape the generator emits) so the harness runs it through the real verifier before
/// grading; `expert_labels` are matched to the persisted criteria by verbatim `text`.
public struct GraderGoldFile: Decodable {
    public let items: [GraderGoldItem]
}

public struct GraderGoldItem: Decodable {
    public let id: String
    public let conceptId: String
    public let band: Int
    public let note: String?
    public let question: [String: Any]
    public let answer: String
    public let expertLabels: [ExpertLabel]

    enum CodingKeys: String, CodingKey {
        case id, band, note, question, answer
        case conceptId = "concept_id"
        case expertLabels = "expert_labels"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conceptId = try c.decode(String.self, forKey: .conceptId)
        band = try c.decode(Int.self, forKey: .band)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        answer = try c.decode(String.self, forKey: .answer)
        expertLabels = try c.decode([ExpertLabel].self, forKey: .expertLabels)
        // The `question` value is arbitrary JSON — decode it back to a Foundation object so it can
        // be re-serialized straight into `TeachingQuestionCandidate`.
        let raw = try c.decode(JSONValue.self, forKey: .question)
        guard let obj = raw.foundationValue as? [String: Any] else {
            throw DecodingError.dataCorruptedError(
                forKey: .question, in: c, debugDescription: "question must be a JSON object")
        }
        question = obj
    }
}

public struct ExpertLabel: Decodable {
    public let text: String
    public let label: ExpertVerdict
}

public enum ExpertVerdict: String, Decodable {
    case met
    case notMet = "not_met"
    case ambiguous
}

/// Minimal `Any`-free JSON tree so `GraderGoldItem.question` can be decoded from `Decodable`
/// context (no `JSONSerialization` on the raw `Data`, which the synthesized decoder doesn't hand
/// us) and then converted to a Foundation object for `JSONSerialization.data(withJSONObject:)`.
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unsupported JSON value")
    }

    var foundationValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(\.foundationValue)
        case .object(let o): return o.mapValues(\.foundationValue)
        }
    }
}

// MARK: - Report rows

public struct CalibrationRow: Encodable, Sendable {
    public struct Criterion: Encodable, Sendable {
        public let text: String
        public let kind: String
        public let graderMet: Bool?
        public let graderConfident: Bool?
        public let expertLabel: String?
        public let matched: Bool
    }
    public let id: String
    public let band: Int
    public let note: String?
    public let error: String?
    public let graderScore: Double?
    public let expertScore: Double?
    public let graderVerdict: String?
    public let expertVerdict: String?
    public let disputed: Bool?
    public let splitVoteCount: Int
    public let criteria: [Criterion]
}

/// Pooled calibration metrics across every graded gold item — the numbers Docs/17 §12.2 lists and
/// Decision 10's gate reads. A plain struct computed once from the finished `rows`.
public struct CalibrationSummary: Encodable, Sendable {
    public let goldItems: Int
    public let gradedItems: Int
    public let skipped: [String: String]           // id -> reason

    public let criterionPairs: Int                 // matched, non-ambiguous expert label
    public let kappaOverall: Double?
    public let kappaConfidentOnly: Double?
    public let kappaRequired: Double?
    public let kappaAnti: Double?
    public let rawAgreementOverall: Double?

    public let scoreMAE: Double?
    public let scoreRMSE: Double?
    public let verdictConfusion: [String: [String: Int]]
    public let verdictAccuracy: Double?

    public let splitVoteCriteria: Int
    public let splitVoteFraction: Double?
    public let splitVoteMajorityMatchesExpert: Double?

    public let disputedItems: Int?
    public let unmatchedCriteria: Int              // gold-authoring integrity check

    public let kappaBar: Double
    public let gatePasses: Bool

    public static let tiers = ["solid", "partial", "shaky", "off-track"]

    public init(rows: [CalibrationRow], kappaBar: Double) {
        self.kappaBar = kappaBar
        goldItems = rows.count
        let graded = rows.filter { $0.error == nil }
        gradedItems = graded.count
        skipped = Dictionary(
            rows.filter { $0.error != nil }.map { ($0.id, $0.error ?? "?") },
            uniquingKeysWith: { a, _ in a })

        // --- per-criterion κ over (expert, grader) `met`/`notmet`. Both sides are collapsed to
        //     the same two tokens: the grader emits a Bool, the expert label's rawValue is
        //     "met"/"not_met"/"ambiguous" (ambiguous already filtered out above).
        func metLabel(_ b: Bool) -> String { b ? "met" : "notmet" }
        func expertTok(_ s: String) -> String { s == "met" ? "met" : "notmet" }
        var allPairs: [(String, String)] = []
        var confidentPairs: [(String, String)] = []
        var requiredPairs: [(String, String)] = []
        var antiPairs: [(String, String)] = []
        var splitPairs: [(expert: String, graderMajority: String)] = []
        var unmatched = 0
        for row in graded {
            for c in row.criteria {
                guard c.matched, let gm = c.graderMet, let expert = c.expertLabel else {
                    if !c.matched { unmatched += 1 }
                    continue
                }
                guard expert != "ambiguous" else { continue }
                let pair = (expertTok(expert), metLabel(gm))
                allPairs.append(pair)
                if c.graderConfident == true { confidentPairs.append(pair) }
                if c.kind == "required" { requiredPairs.append(pair) }
                if c.kind == "anti" { antiPairs.append(pair) }
                if c.graderConfident == false { splitPairs.append(pair) }
            }
        }
        criterionPairs = allPairs.count
        unmatchedCriteria = unmatched
        kappaOverall = CalibrationStats.cohensKappa(allPairs)
        kappaConfidentOnly = CalibrationStats.cohensKappa(confidentPairs)
        kappaRequired = CalibrationStats.cohensKappa(requiredPairs)
        kappaAnti = CalibrationStats.cohensKappa(antiPairs)
        rawAgreementOverall = allPairs.isEmpty
            ? nil : Double(allPairs.filter { $0.0 == $0.1 }.count) / Double(allPairs.count)

        // --- score error + verdict confusion.
        let scorePairs: [(Double, Double)] = graded.compactMap {
            guard let g = $0.graderScore, let e = $0.expertScore else { return nil }
            return (e, g)
        }
        scoreMAE = CalibrationStats.meanAbsoluteError(scorePairs)
        scoreRMSE = CalibrationStats.rootMeanSquareError(scorePairs)
        let verdictPairs: [(expected: String, actual: String)] = graded.compactMap {
            guard let g = $0.graderVerdict, let e = $0.expertVerdict else { return nil }
            return (e, g)
        }
        let matrix = CalibrationStats.confusionMatrix(verdictPairs, categories: Self.tiers)
        var confusion: [String: [String: Int]] = [:]
        for (i, expected) in Self.tiers.enumerated() {
            confusion[expected] = Dictionary(
                uniqueKeysWithValues: Self.tiers.enumerated().map { ($1, matrix.counts[i][$0]) })
        }
        verdictConfusion = confusion
        verdictAccuracy = matrix.accuracy

        // --- self-consistency.
        splitVoteCriteria = splitPairs.count
        let totalMatchedCriteria = allPairs.count + splitPairs.count
        splitVoteFraction = totalMatchedCriteria > 0
            ? Double(splitPairs.count) / Double(totalMatchedCriteria) : nil
        splitVoteMajorityMatchesExpert = splitPairs.isEmpty
            ? nil : Double(splitPairs.filter { $0.expert == $0.graderMajority }.count) / Double(splitPairs.count)

        let disputedRows = graded.filter { $0.disputed != nil }
        disputedItems = disputedRows.isEmpty ? nil : disputedRows.filter { $0.disputed == true }.count

        gatePasses = (kappaOverall ?? -1) >= kappaBar
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
