import ArgumentParser
import Foundation
import OrionAgent
import OrionCodeIntel

/// `orion-agent teach bench` (Docs/17_phase7_teaching_mode.md §10, §12.2) — the grader-calibration
/// harness. Feeds a hand-authored gold set of (question, developer answer, expert per-criterion
/// labels) through the real `RubricGrader` (local Qwen3 judge, k-sampled), then measures the
/// grader against the expert labels with `CalibrationStats`:
///
///   * **per-criterion Cohen's κ** — grader `met`/`not-met` vs. expert `met`/`not-met`
///     (`ambiguous` expert labels excluded), overall and restricted to criteria the grader was
///     confident on; broken out by `required` vs. `anti` (the misconception-detection axis).
///   * **score MAE / RMSE** — the grader's *derived* score vs. a score derived the same way
///     (`RubricScoring.aggregate`) from the expert's labels.
///   * **verdict-tier confusion matrix** — grader-derived tier vs. expert-derived tier.
///   * **self-consistency** — fraction of criteria with a split k-vote, and how often the
///     majority on those still matched the expert.
///   * **disputed rate** — §7.4 pairwise-tripwire firings (`--pairwise`).
///
/// Writes `teaching_calibration.jsonl` (one row per gold item) + `teaching_calibration_summary.json`,
/// the same report shape as `orion-agent bench` (Phase 5 M7). The κ number is Docs/17 Decision 10's
/// ship gate: at or above `--kappa-bar` (default 0.60, Landis & Koch "substantial"), the app's
/// confident-grade UI may be switched on (`TeachingSession.isCalibrated = true`).
///
/// Run against a **copy** of the repository's `.orion/orion.db` (`--out`): grading writes real
/// `teaching_attempts` / `teaching_criterion_results` rows and the verifier inserts a
/// `teaching_questions` row per gold item.
struct TeachBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Measure the answer grader against an expert-labelled gold set (per-criterion κ, score MAE, verdict confusion)."
    )

    @Argument(help: "Path to the repository checkout (already analyzed; concepts already extracted).")
    var path: String
    @Option(help: "Gold set JSON (see Agent Feasibility Study/benchmark/starlette_teaching_grader.gold.json).")
    var gold: String
    @Option(help: "Directory containing orion.db (default: <path>/.orion). Use a COPY — grading writes rows.")
    var out: String?
    @Option(name: .customLong("report-dir"), help: "Where to write teaching_calibration.jsonl + summary (default: <out>/bench).")
    var reportDir: String?
    @Option(help: "Use this commit's analyzed run instead of the latest.")
    var commit: String?
    @Option(help: "k for per-criterion self-consistency voting (default 3, matching the product path).")
    var k: Int = 3
    @Option(help: "Only run the first N gold items (after --band filtering), for a cheap smoke run.")
    var limit: Int?
    @Option(help: "Only run gold items for this difficulty band (1, 2, or 3).")
    var band: Int?
    @Option(name: .customLong("kappa-bar"), help: "The κ ship gate for Decision 10 (default 0.60).")
    var kappaBar: Double = 0.60
    @Flag(help: "Also run the §7.4 pairwise same-idea tripwire and report the disputed rate.")
    var pairwise: Bool = false
    @Flag(
        name: .customLong("verify-gold"),
        help: """
            Run each gold question through the full §6.3 verifier (schema + anchor resolution + \
            the CONTRADICTED-claim consistency check) before grading. Off by default: this command \
            measures the *grader*, and the gold questions are trusted (hand-authored, anchors \
            hand-checked). By default the harness still resolves every anchor — a typo fails loudly \
            — but skips the consistency check, which is a *generation* gate (§12.1's concern) and \
            over-fires on a repo whose semantic layer carries many CONTRADICTED claims.
            """)
    var verifyGold: Bool = false

    func validate() throws {
        if let band, !(1...3).contains(band) { throw ValidationError("--band must be 1, 2, or 3") }
        if let limit, limit < 1 { throw ValidationError("--limit must be at least 1") }
        if k < 1 { throw ValidationError("--k must be at least 1") }
    }

    func run() async throws {
        let repoURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let outURL = URL(
            fileURLWithPath: ((out ?? repoURL.appendingPathComponent(".orion").path) as NSString)
                .expandingTildeInPath
        ).standardizedFileURL
        let reportURL = URL(
            fileURLWithPath: ((reportDir ?? outURL.appendingPathComponent("bench").path) as NSString)
                .expandingTildeInPath
        ).standardizedFileURL
        try FileManager.default.createDirectory(at: reportURL, withIntermediateDirectories: true)

        let dbPath = outURL.appendingPathComponent("orion.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else {
            FileHandle.standardError.write(Data("no database at \(dbPath) — run `orion-index analyze` first\n".utf8))
            throw ExitCode(3)
        }
        let store = Store(try OrionDatabase(path: dbPath))
        guard let run = try store.latestRun(commitHash: commit) else {
            FileHandle.standardError.write(Data("no analyzed run — run `orion-index analyze` first\n".utf8))
            throw ExitCode(3)
        }

        let goldURL = URL(fileURLWithPath: (gold as NSString).expandingTildeInPath)
        let file: GraderGoldFile
        do {
            file = try JSONDecoder().decode(GraderGoldFile.self, from: try Data(contentsOf: goldURL))
        } catch {
            FileHandle.standardError.write(Data("failed to read/decode \(goldURL.path): \(error)\n".utf8))
            throw ExitCode(2)
        }

        var items = file.items
        if let band { items = items.filter { $0.band == band } }
        if let limit { items = Array(items.prefix(limit)) }
        guard !items.isEmpty else {
            FileHandle.standardError.write(Data("no gold items matched (band filter or empty file)\n".utf8))
            throw ExitCode(2)
        }

        print("Grader calibration: \(items.count) gold item(s) against \(repoURL.lastPathComponent) "
            + "(run \(run.id), k=\(k)\(pairwise ? ", pairwise" : ""))")

        let agent = try await Qwen3Agent.load()
        let judge = LocalCriterionJudge { p in
            try await agent.respond(to: p, instructions: LocalCriterionJudge.systemInstruction)
        }
        let comparer: (any AnswerComparing)? = pairwise
            ? LocalAnswerComparer { p in try await agent.respond(to: p) } : nil
        let now: @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }

        var rows: [CalibrationRow] = []
        for (idx, item) in items.enumerated() {
            print("[\(idx + 1)/\(items.count)] \(item.id) (band \(item.band))")
            let row = await Self.evaluate(
                item: item, store: store, run: run, judge: judge, comparer: comparer, k: k,
                verifyGold: verifyGold, now: now)
            if let err = row.error {
                print("    skipped: \(err)")
            } else {
                print(String(
                    format: "    grader %.2f/%@  vs  expert %.2f/%@   (%d/%d criteria matched)",
                    row.graderScore ?? -1, row.graderVerdict ?? "?",
                    row.expertScore ?? -1, row.expertVerdict ?? "?",
                    row.criteria.filter { $0.matched }.count, row.criteria.count))
            }
            rows.append(row)
        }

        let summary = CalibrationSummary(rows: rows, kappaBar: kappaBar)
        try Self.writeJSONL(rows, to: reportURL.appendingPathComponent("teaching_calibration.jsonl"))
        try Self.writeJSON(summary, to: reportURL.appendingPathComponent("teaching_calibration_summary.json"))

        print("")
        print("Wrote \(rows.count) row(s) to \(reportURL.path)")
        summary.printFormatted()

        // Exit 1 if nothing could be graded at all — a broken gold file or run, not a low κ.
        if summary.gradedItems == 0 { throw ExitCode(1) }
    }

    // MARK: one gold item

    private static func evaluate(
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
                questionId = try Self.seedTrustedGoldQuestion(
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
    private static func seedTrustedGoldQuestion(
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

    // MARK: report I/O

    private static func writeJSONL(_ rows: [CalibrationRow], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try rows.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(value).write(to: url)
    }
}

// MARK: - Gold file

/// The §12.2 grader-calibration gold set. `question` is an inline `phase7.v1` candidate object
/// (same shape the generator emits) so the harness runs it through the real verifier before
/// grading; `expert_labels` are matched to the persisted criteria by verbatim `text`.
struct GraderGoldFile: Decodable {
    let items: [GraderGoldItem]
}

struct GraderGoldItem: Decodable {
    let id: String
    let conceptId: String
    let band: Int
    let note: String?
    let question: [String: Any]
    let answer: String
    let expertLabels: [ExpertLabel]

    enum CodingKeys: String, CodingKey {
        case id, band, note, question, answer
        case conceptId = "concept_id"
        case expertLabels = "expert_labels"
    }

    init(from decoder: Decoder) throws {
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

struct ExpertLabel: Decodable {
    let text: String
    let label: ExpertVerdict
}

enum ExpertVerdict: String, Decodable {
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

struct CalibrationRow: Encodable {
    struct Criterion: Encodable {
        let text: String
        let kind: String
        let graderMet: Bool?
        let graderConfident: Bool?
        let expertLabel: String?
        let matched: Bool
    }
    let id: String
    let band: Int
    let note: String?
    let error: String?
    let graderScore: Double?
    let expertScore: Double?
    let graderVerdict: String?
    let expertVerdict: String?
    let disputed: Bool?
    let splitVoteCount: Int
    let criteria: [Criterion]
}

/// Pooled calibration metrics across every graded gold item — the numbers Docs/17 §12.2 lists and
/// Decision 10's gate reads. A plain struct computed once from the finished `rows`.
struct CalibrationSummary: Encodable {
    let goldItems: Int
    let gradedItems: Int
    let skipped: [String: String]           // id -> reason

    let criterionPairs: Int                 // matched, non-ambiguous expert label
    let kappaOverall: Double?
    let kappaConfidentOnly: Double?
    let kappaRequired: Double?
    let kappaAnti: Double?
    let rawAgreementOverall: Double?

    let scoreMAE: Double?
    let scoreRMSE: Double?
    let verdictConfusion: [String: [String: Int]]
    let verdictAccuracy: Double?

    let splitVoteCriteria: Int
    let splitVoteFraction: Double?
    let splitVoteMajorityMatchesExpert: Double?

    let disputedItems: Int?
    let unmatchedCriteria: Int              // gold-authoring integrity check

    let kappaBar: Double
    let gatePasses: Bool

    private static let tiers = ["solid", "partial", "shaky", "off-track"]

    init(rows: [CalibrationRow], kappaBar: Double) {
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

    func printFormatted() {
        print("--- grader calibration (Docs/17 §12.2) ---")
        print("gold items: \(goldItems)  graded: \(gradedItems)  skipped: \(skipped.count)")
        for (id, reason) in skipped.sorted(by: { $0.key < $1.key }) { print("  · \(id): \(reason)") }
        print("criterion pairs (matched, non-ambiguous): \(criterionPairs)"
            + (unmatchedCriteria > 0 ? "   ⚠ \(unmatchedCriteria) unmatched criterion text(s)" : ""))
        func fmt(_ d: Double?) -> String { d.map { String(format: "%.3f", $0) } ?? "n/a" }
        if let k = kappaOverall {
            print("Cohen's κ (all):            \(fmt(kappaOverall))  — \(CalibrationStats.agreementLabel(forKappa: k))")
        }
        print("Cohen's κ (grader-confident): \(fmt(kappaConfidentOnly))")
        print("Cohen's κ (required only):     \(fmt(kappaRequired))")
        print("Cohen's κ (anti only):         \(fmt(kappaAnti))")
        print("raw agreement:                 \(fmt(rawAgreementOverall))")
        print("score MAE / RMSE:              \(fmt(scoreMAE)) / \(fmt(scoreRMSE))")
        print("verdict-tier accuracy:         \(fmt(verdictAccuracy))")
        for expected in Self.tiers {
            let counts = Self.tiers.map { "\($0.prefix(4))=\(verdictConfusion[expected]?[$0] ?? 0)" }
            print("  expert \(expected.padding(toLength: 9, withPad: " ", startingAt: 0)) -> \(counts.joined(separator: " "))")
        }
        print("split k-votes:                 \(splitVoteCriteria)  (\(fmt(splitVoteFraction)) of criteria; "
            + "majority matched expert \(fmt(splitVoteMajorityMatchesExpert)))")
        if let d = disputedItems { print("disputed (pairwise tripwire):   \(d)/\(gradedItems)") }
        print("")
        print("κ gate (Decision 10): κ \(fmt(kappaOverall)) vs bar \(String(format: "%.2f", kappaBar))  ->  "
            + (gatePasses ? "PASS — grader may ship the confident-grade UI (set TeachingSession.isCalibrated = true)"
                          : "HOLD — keep 'self-check only'; TeachingSession.isCalibrated stays false"))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
