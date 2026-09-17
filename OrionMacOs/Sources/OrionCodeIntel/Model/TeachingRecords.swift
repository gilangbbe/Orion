import Foundation
import GRDB

/// Phase 7 persisted records (`v6_phase7_schema`). See
/// `Docs/17_phase7_teaching_mode.md` §9 "Schema". Additive only — no Phase 1–6 table altered.
///
/// M0 gives every Teaching Mode table a typed shape ahead of the logic that fills it —
/// `ConceptExtractor` (M1) writes `TeachingConceptRecord`s; `TeachingQuestionGenerator` (M2, in
/// `OrionAgent`) writes `TeachingQuestionRecord`/`TeachingRubricCriterionRecord`; `RubricGrader`
/// (M3, in `OrionAgent`) writes `TeachingAttemptRecord`/`TeachingCriterionResultRecord`; the
/// mastery update rule (M4) writes `KnowledgeStateRecord`/`TeachingMisconceptionRecord`. Same
/// "types exist from M0, logic lands later" precedent Docs/11 M0 set for
/// `ComponentRecord`/`ClaimRecord` and Docs/15 M0 set for `AskSessionRecord`.
///
/// Every explicit `public init` here mirrors `AskSessionRecord`'s own M0 reasoning: the
/// auto-synthesized memberwise initializer of a `Codable`-conforming struct is only `internal`,
/// so `OrionAgent` (M2/M3's generator and grader) and the `orion-agent`/`OrionApp` layers can't
/// construct these without one.

/// One evidence-linked unit of understanding derived from the persisted Codebase Model (Docs/17
/// §5). `sourceComponentId`/`sourceClaimId` are `ON DELETE SET NULL` — a re-analysis drops the
/// old run's rows, but the concept survives and `ConceptExtractor` re-marks it `stale` rather
/// than deleting it.
public struct TeachingConceptRecord: OrionRecord {
    public static let databaseTableName = "teaching_concepts"

    public var id: String
    public var repositoryId: String
    public var kind: String                 // TeachingConceptKind
    public var subjectLabel: String
    public var sourceComponentId: String?
    public var sourceClaimId: String?
    public var evidenceAnchors: [String]    // stored as JSON text by GRDB
    public var centrality: Double
    public var difficultyBand: Int
    public var stale: Bool
    public var createdAt: String

    public init(
        id: String, repositoryId: String, kind: String, subjectLabel: String,
        sourceComponentId: String? = nil, sourceClaimId: String? = nil,
        evidenceAnchors: [String] = [], centrality: Double = 0, difficultyBand: Int = 1,
        stale: Bool = false, createdAt: String
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.kind = kind
        self.subjectLabel = subjectLabel
        self.sourceComponentId = sourceComponentId
        self.sourceClaimId = sourceClaimId
        self.evidenceAnchors = evidenceAnchors
        self.centrality = centrality
        self.difficultyBand = difficultyBand
        self.stale = stale
        self.createdAt = createdAt
    }
}

/// One generated, verified teaching question (Docs/17 §6). `verified` is `false` until the
/// candidate has passed `SemanticImporter`'s anchor-resolution + consistency check (§6.3); the
/// app/CLI only ever offer a `verified` question. `investigationId` links to the `investigations`
/// row that records the generation run itself (question, model, cost, turns) — nullable so a
/// hand-seeded fixture question needs no investigation.
public struct TeachingQuestionRecord: OrionRecord {
    public static let databaseTableName = "teaching_questions"

    public var id: String
    public var conceptId: String
    public var investigationId: String?
    public var difficultyBand: Int
    public var explain: String
    public var prompt: String
    public var referenceAnswer: String
    public var referenceAnchors: [String]  // stored as JSON text
    public var transferProblem: String?
    public var generatedBy: String         // TeachingQuestionSource
    public var verified: Bool
    public var createdAt: String

    public init(
        id: String, conceptId: String, investigationId: String? = nil, difficultyBand: Int,
        explain: String, prompt: String, referenceAnswer: String, referenceAnchors: [String] = [],
        transferProblem: String? = nil, generatedBy: String, verified: Bool = false,
        createdAt: String
    ) {
        self.id = id
        self.conceptId = conceptId
        self.investigationId = investigationId
        self.difficultyBand = difficultyBand
        self.explain = explain
        self.prompt = prompt
        self.referenceAnswer = referenceAnswer
        self.referenceAnchors = referenceAnchors
        self.transferProblem = transferProblem
        self.generatedBy = generatedBy
        self.verified = verified
        self.createdAt = createdAt
    }
}

/// One atomic, checkable criterion for a question (Docs/17 §6.1/§7). `kind` is `required`/`bonus`/
/// `anti`; `ordinal` orders criteria within one question (`UNIQUE(question_id, ordinal)`).
public struct TeachingRubricCriterionRecord: OrionRecord {
    public static let databaseTableName = "teaching_rubric_criteria"

    public var id: String
    public var questionId: String
    public var ordinal: Int
    public var kind: String                 // RubricCriterionKind
    public var text: String
    public var evidenceAnchors: [String]    // stored as JSON text

    public init(
        id: String, questionId: String, ordinal: Int, kind: String, text: String,
        evidenceAnchors: [String] = []
    ) {
        self.id = id
        self.questionId = questionId
        self.ordinal = ordinal
        self.kind = kind
        self.text = text
        self.evidenceAnchors = evidenceAnchors
    }
}

/// One graded answer to one question (Docs/17 §7). `score` and `verdictTier` are **derived** by
/// `RubricGrader` (§7.3) from the `TeachingCriterionResultRecord`s below — never model-authored.
/// `disputed` records the §7.4 pairwise-sanity tripwire firing (rubric score vs. a
/// same-idea-as-reference check disagreeing), which flags the attempt for the calibration set,
/// not a re-grade.
public struct TeachingAttemptRecord: OrionRecord {
    public static let databaseTableName = "teaching_attempts"

    public var id: String
    public var questionId: String
    public var developerId: String
    public var answerText: String
    public var score: Double
    public var verdictTier: String          // TeachingVerdictTier
    public var modelUsed: String?
    public var disputed: Bool
    public var createdAt: String

    public init(
        id: String, questionId: String, developerId: String = "local", answerText: String,
        score: Double, verdictTier: String, modelUsed: String? = nil, disputed: Bool = false,
        createdAt: String
    ) {
        self.id = id
        self.questionId = questionId
        self.developerId = developerId
        self.answerText = answerText
        self.score = score
        self.verdictTier = verdictTier
        self.modelUsed = modelUsed
        self.disputed = disputed
        self.createdAt = createdAt
    }
}

/// One criterion's verdict on one attempt (Docs/17 §7.1) — the atomic, quantified observation the
/// score and the mastery update are both computed from. `evidenceQuote` is a verbatim span from
/// the developer's answer (or empty); `voteDetail` is the raw JSON of the k=3 self-consistency
/// samples, kept for `--explain` and the calibration harness.
public struct TeachingCriterionResultRecord: OrionRecord {
    public static let databaseTableName = "teaching_criterion_results"

    public var id: String
    public var attemptId: String
    public var criterionId: String
    public var met: Bool
    public var confidence: String           // GraderConfidence
    public var evidenceQuote: String
    public var note: String
    public var voteDetail: String?          // raw JSON

    public init(
        id: String, attemptId: String, criterionId: String, met: Bool, confidence: String,
        evidenceQuote: String = "", note: String = "", voteDetail: String? = nil
    ) {
        self.id = id
        self.attemptId = attemptId
        self.criterionId = criterionId
        self.met = met
        self.confidence = confidence
        self.evidenceQuote = evidenceQuote
        self.note = note
        self.voteDetail = voteDetail
    }
}

/// Per-`(developer, concept)` mastery (Docs/17 §8, and Docs/07 §9's long-reserved `KnowledgeState`
/// realized at last). `pMastered` is a BKT-style probability updated criterion-level (§8.2);
/// `confidenceBand` is a coarse display band over it that stays `new` until `attemptsCount >= 2`.
public struct KnowledgeStateRecord: OrionRecord {
    public static let databaseTableName = "knowledge_states"

    public var id: String
    public var developerId: String
    public var conceptId: String
    public var pMastered: Double
    public var attemptsCount: Int
    public var lastVerdict: String?         // TeachingVerdictTier
    public var confidenceBand: String       // KnowledgeConfidenceBand
    public var firstSeenAt: String
    public var lastAssessedAt: String

    public init(
        id: String, developerId: String = "local", conceptId: String, pMastered: Double = 0.15,
        attemptsCount: Int = 0, lastVerdict: String? = nil, confidenceBand: String = "new",
        firstSeenAt: String, lastAssessedAt: String
    ) {
        self.id = id
        self.developerId = developerId
        self.conceptId = conceptId
        self.pMastered = pMastered
        self.attemptsCount = attemptsCount
        self.lastVerdict = lastVerdict
        self.confidenceBand = confidenceBand
        self.firstSeenAt = firstSeenAt
        self.lastAssessedAt = lastAssessedAt
    }
}

/// One detected misconception (Docs/17 §7.2) — an `anti` criterion judged *met* on some attempt.
/// `clearedAt` is set once a later attempt on any question for the same concept judges the same
/// `anti` criterion *not met* with high confidence.
public struct TeachingMisconceptionRecord: OrionRecord {
    public static let databaseTableName = "teaching_misconceptions"

    public var id: String
    public var knowledgeStateId: String
    public var criterionId: String
    public var attemptId: String
    public var statement: String
    public var detectedAt: String
    public var clearedAt: String?

    public init(
        id: String, knowledgeStateId: String, criterionId: String, attemptId: String,
        statement: String, detectedAt: String, clearedAt: String? = nil
    ) {
        self.id = id
        self.knowledgeStateId = knowledgeStateId
        self.criterionId = criterionId
        self.attemptId = attemptId
        self.statement = statement
        self.detectedAt = detectedAt
        self.clearedAt = clearedAt
    }
}
