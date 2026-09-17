import Foundation

/// Docs/17_phase7_teaching_mode.md §6.3 — the verification-before-use pipeline a generated
/// question candidate must pass before it is ever shown to a developer. Pure logic over `Store`:
/// no model call, no network. Mirrors the shape of `SemanticImporter`'s own pipeline (schema ->
/// evidence-anchor resolution -> a `CONTRADICTED` consistency check -> persist) rather than
/// re-inventing it — the "reuse the pattern, not necessarily the private helpers" framing Phase 3
/// M3 used for its own ingestion path.
///
/// **Deliberate deviation from §6.3's own sketch, recorded not silently done**: M2 does **not**
/// write an `investigations` row for a generation run. `teaching_questions.investigation_id` stays
/// nullable (M0 schema). A `"phase7_question_generation"` row in `investigations` would become the
/// newest one and silently break `SemanticExporter`'s `Store.latestInvestigation(runId:)`-based
/// scoping (it would export an empty semantic model). `generated_by` on the `teaching_questions`
/// row is the M2 record of provenance; per-generation cost/turn audit, if M7's calibration work
/// needs it, gets a narrow, filtered mechanism then.
public enum TeachingQuestionVerifier {

    public struct Diagnostic: Equatable, Sendable {
        public let code: String
        public let message: String
        public let fatal: Bool   // true -> the candidate is rejected; false -> a criterion was dropped

        public init(code: String, message: String, fatal: Bool) {
            self.code = code
            self.message = message
            self.fatal = fatal
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Persisted. `droppedCriteria` counts `bonus`/`anti` criteria dropped for an unresolvable
        /// anchor (a `required`/reference anchor failure is fatal, never a drop).
        case persisted(questionId: String, droppedCriteria: Int)
        case rejected(reasons: [Diagnostic])
    }

    // Diagnostic codes (persisted with `stage = "teaching_generate"`).
    public static let codeSchemaInvalid = "TEACHING_SCHEMA_INVALID"
    public static let codeAnchorUnresolved = "TEACHING_ANCHOR_UNRESOLVED"
    public static let codeReferenceContradicted = "TEACHING_REFERENCE_CONTRADICTED"
    public static let codeCriterionDropped = "TEACHING_CRITERION_DROPPED"

    /// - Parameters:
    ///   - candidate: the parsed, still-untrusted generator output.
    ///   - concept: the concept this question is meant to teach — `candidate.conceptId` must match.
    ///   - run: the analysis run whose `symbols`/`claims` the anchors resolve against.
    ///   - persistDiagnostics: write `diagnostics` rows (default true; tests that only want the
    ///     `Outcome` can turn it off).
    public static func verifyAndPersist(
        candidate: TeachingQuestionCandidate,
        concept: TeachingConceptRecord,
        store: Store,
        run: AnalysisRunRecord,
        generatedBy: TeachingQuestionSource,
        now: String,
        persistDiagnostics: Bool = true
    ) throws -> Outcome {
        var diagnostics: [Diagnostic] = []

        // --- Step 1: schema / shape.
        func schemaFail(_ msg: String) {
            diagnostics.append(Diagnostic(code: codeSchemaInvalid, message: msg, fatal: true))
        }
        if candidate.schemaVersion != TeachingSchema.currentVersion {
            schemaFail("schema_version is \"\(candidate.schemaVersion)\", expected \"\(TeachingSchema.currentVersion)\"")
        }
        if candidate.conceptId != concept.id {
            schemaFail("concept_id \"\(candidate.conceptId)\" does not match the requested concept \"\(concept.id)\"")
        }
        if !(1...3).contains(candidate.difficultyBand) {
            schemaFail("difficulty_band \(candidate.difficultyBand) is outside 1...3")
        }
        if candidate.explain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            schemaFail("explain is empty")
        }
        if candidate.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            schemaFail("question is empty")
        }
        if candidate.referenceAnswer.trimmingCharacters(in: .whitespacesAndNewlines).count
            < TeachingSchema.minReferenceAnswerChars {
            schemaFail("reference_answer is shorter than \(TeachingSchema.minReferenceAnswerChars) characters")
        }
        let requiredInputs = candidate.rubric.filter { $0.kind == RubricCriterionKind.required.rawValue }
        if requiredInputs.isEmpty {
            schemaFail("rubric has no `required` criteria")
        }
        for c in candidate.rubric where !["required", "bonus"].contains(c.kind) {
            schemaFail("rubric criterion kind \"\(c.kind)\" is not `required` or `bonus`")
        }
        let allCriterionTexts = candidate.rubric.map(\.text) + candidate.antiCriteria.map(\.text)
        for text in allCriterionTexts
        where text.trimmingCharacters(in: .whitespacesAndNewlines).count < TeachingSchema.minCriterionChars {
            schemaFail("a criterion `text` is shorter than \(TeachingSchema.minCriterionChars) characters")
        }
        if !diagnostics.isEmpty {
            if persistDiagnostics { try writeDiagnostics(diagnostics, concept: concept, run: run, store: store) }
            return .rejected(reasons: diagnostics)
        }

        // --- Step 2: evidence-anchor resolution.
        func resolves(_ anchor: String) throws -> Bool {
            try store.symbol(runId: run.id, anchor: anchor) != nil
        }
        // Reference anchors: any unresolved -> fatal.
        var resolvedReferenceAnchors: [String] = []
        for anchor in candidate.referenceAnchors {
            if try resolves(anchor) {
                resolvedReferenceAnchors.append(anchor)
            } else {
                diagnostics.append(Diagnostic(
                    code: codeAnchorUnresolved,
                    message: "reference anchor \"\(anchor)\" does not resolve in run \(run.id)",
                    fatal: true))
            }
        }
        if resolvedReferenceAnchors.isEmpty {
            diagnostics.append(Diagnostic(
                code: codeAnchorUnresolved, message: "reference_anchors has no resolvable anchor",
                fatal: true))
        }

        // Rubric criteria: a `required` with any unresolved anchor -> fatal; a `bonus`/`anti`
        // with an unresolved anchor -> that criterion dropped (kept if it still has one).
        struct KeptCriterion { let kind: RubricCriterionKind; let text: String; let anchors: [String] }
        var kept: [KeptCriterion] = []
        var dropped = 0

        for c in requiredInputs {
            var ok: [String] = []
            for a in c.evidence where try resolves(a) { ok.append(a) }
            if ok.count != c.evidence.count || ok.isEmpty {
                diagnostics.append(Diagnostic(
                    code: codeAnchorUnresolved,
                    message: "required criterion \"\(c.text.prefix(60))…\" has an unresolvable anchor",
                    fatal: true))
            } else {
                kept.append(KeptCriterion(kind: .required, text: c.text, anchors: ok.sorted()))
            }
        }
        func keepOptional(_ text: String, _ evidence: [String], kind: RubricCriterionKind) throws {
            var ok: [String] = []
            for a in evidence where try resolves(a) { ok.append(a) }
            if ok.isEmpty {
                dropped += 1
                diagnostics.append(Diagnostic(
                    code: codeCriterionDropped,
                    message: "\(kind.rawValue) criterion \"\(text.prefix(60))…\" dropped — no resolvable anchor",
                    fatal: false))
            } else {
                kept.append(KeptCriterion(kind: kind, text: text, anchors: ok.sorted()))
            }
        }
        for c in candidate.rubric where c.kind == RubricCriterionKind.bonus.rawValue {
            try keepOptional(c.text, c.evidence, kind: .bonus)
        }
        for c in candidate.antiCriteria {
            try keepOptional(c.text, c.evidence, kind: .anti)
        }

        if diagnostics.contains(where: \.fatal) {
            if persistDiagnostics { try writeDiagnostics(diagnostics, concept: concept, run: run, store: store) }
            return .rejected(reasons: diagnostics)
        }

        // --- Step 3: consistency — the reference answer's grounding must not sit on a claim the
        //     Code Graph already contradicts. Match `reference_anchors` against every persisted
        //     claim's evidence-anchor set (AnchorAlignment Jaccard >= 0.3); if the best match is
        //     `CONTRADICTED`, reject.
        let refSet = AnchorAlignment.normalizedSet(resolvedReferenceAnchors)
        var bestJaccard = 0.0
        var bestClaimType: String?
        for inv in try store.investigations(runId: run.id) {
            let claims = try store.claims(investigationId: inv.id)
            let evidenceByClaim = Dictionary(grouping: try store.evidence(claimIds: claims.map(\.id)),
                                             by: \.claimId)
            for claim in claims {
                let anchors = (evidenceByClaim[claim.id] ?? []).map(\.anchor)
                guard !anchors.isEmpty else { continue }
                let j = AnchorAlignment.jaccard(refSet, AnchorAlignment.normalizedSet(anchors))
                if j > bestJaccard {
                    bestJaccard = j
                    bestClaimType = claim.claimType
                }
            }
        }
        if bestJaccard >= 0.3 && bestClaimType == EpistemicType.contradicted.rawValue {
            diagnostics.append(Diagnostic(
                code: codeReferenceContradicted,
                message: "reference answer's evidence best-matches a CONTRADICTED claim (Jaccard \(String(format: "%.2f", bestJaccard)))",
                fatal: true))
            if persistDiagnostics { try writeDiagnostics(diagnostics, concept: concept, run: run, store: store) }
            return .rejected(reasons: diagnostics)
        }

        // --- Step 4: persist.
        let questionId = DeterministicID.newUUID()
        try store.insertTeachingQuestion(TeachingQuestionRecord(
            id: questionId, conceptId: concept.id, investigationId: nil,
            difficultyBand: candidate.difficultyBand,
            explain: candidate.explain.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: candidate.question.trimmingCharacters(in: .whitespacesAndNewlines),
            referenceAnswer: candidate.referenceAnswer.trimmingCharacters(in: .whitespacesAndNewlines),
            referenceAnchors: resolvedReferenceAnchors.sorted(),
            transferProblem: candidate.transferProblem?.trimmingCharacters(in: .whitespacesAndNewlines),
            generatedBy: generatedBy.rawValue, verified: true, createdAt: now))

        try store.insertTeachingRubricCriteria(kept.enumerated().map { ordinal, c in
            TeachingRubricCriterionRecord(
                id: DeterministicID.newUUID(), questionId: questionId, ordinal: ordinal,
                kind: c.kind.rawValue, text: c.text.trimmingCharacters(in: .whitespacesAndNewlines),
                evidenceAnchors: c.anchors)
        })

        if persistDiagnostics && !diagnostics.isEmpty {
            try writeDiagnostics(diagnostics, concept: concept, run: run, store: store)
        }
        return .persisted(questionId: questionId, droppedCriteria: dropped)
    }

    private static func writeDiagnostics(
        _ diagnostics: [Diagnostic], concept: TeachingConceptRecord, run: AnalysisRunRecord, store: Store
    ) throws {
        // Random ids, not `DeterministicID.diagnostic`: unlike Phase 1's byte-deterministic
        // diagnostics, a generation attempt is non-deterministic and repeatable (a retry, a later
        // re-generation of the same concept), so a content-addressed id would collide across
        // attempts — same reasoning Phase 2 used for its own semantic records (Docs/11).
        try store.insertDiagnostics(diagnostics.map { d in
            DiagnosticRecord(
                id: DeterministicID.newUUID(),
                repositoryId: run.repositoryId, commitHash: run.commitHash, runId: run.id,
                fileId: nil, stage: "teaching_generate",
                severity: d.fatal ? "error" : "warning", code: d.code, message: d.message,
                startLine: nil, startCol: nil, endLine: nil, endCol: nil)
        })
    }
}
