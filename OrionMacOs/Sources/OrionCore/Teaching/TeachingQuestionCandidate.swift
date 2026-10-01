import Foundation

/// Version tag + JSON-Schema contract for Teaching Mode question generation (Docs/17 §6.1).
/// A candidate whose `schema_version` doesn't match is rejected outright — the same
/// versioned-schema discipline `SemanticSchema` (`phase2.v1`) and `AgentAnswerSchema`
/// (`phase3.v1`) already established for Claude's other structured output.
public enum TeachingSchema {
    public static let currentVersion = "phase7.v1"

    /// Minimum acceptable length for the reference answer and each criterion `text` — the Phase 3
    /// M5 lesson (`AgentAnswerSchema`), where the `claude` CLI twice produced a schema-conformant
    /// but degenerate answer until a length floor turned that into a loud, retried failure.
    public static let minReferenceAnswerChars = 20
    public static let minCriterionChars = 8

    /// For the `claude --json-schema` CLI flag. No `$schema` key, for the same reason
    /// `AgentAnswerSchema.cliJSONSchema()` omits it (Phase 2 M1: the CLI's offline validator
    /// rejects an explicit 2020-12 dialect URI). Structural only — the real checks (anchors
    /// resolve, reference answer isn't `CONTRADICTED`) are Swift-side in `TeachingQuestionVerifier`.
    public static func cliJSONSchema() -> [String: Any] {
        let anchorArray: [String: Any] = [
            "type": "array", "items": ["type": "string", "minLength": 1],
        ]
        let criterion: [String: Any] = [
            "type": "object",
            "required": ["kind", "text", "evidence"],
            "additionalProperties": false,
            "properties": [
                "kind": ["enum": ["required", "bonus"]],
                "text": ["type": "string", "minLength": minCriterionChars],
                "evidence": anchorArray,
            ] as [String: Any],
        ]
        let antiCriterion: [String: Any] = [
            "type": "object",
            "required": ["text", "evidence"],
            "additionalProperties": false,
            "properties": [
                "text": ["type": "string", "minLength": minCriterionChars],
                "evidence": anchorArray,
            ] as [String: Any],
        ]
        return [
            "type": "object",
            "required": [
                "schema_version", "concept_id", "difficulty_band", "explain", "question",
                "reference_answer", "reference_anchors", "rubric", "anti_criteria",
            ],
            "additionalProperties": false,
            "properties": [
                "schema_version": ["const": currentVersion],
                "concept_id": ["type": "string", "minLength": 1],
                "difficulty_band": ["type": "integer", "minimum": 1, "maximum": 3],
                "explain": ["type": "string", "minLength": 1],
                "question": ["type": "string", "minLength": 1],
                "reference_answer": ["type": "string", "minLength": minReferenceAnswerChars],
                "reference_anchors": anchorArray,
                "rubric": ["type": "array", "minItems": 1, "items": criterion],
                "anti_criteria": ["type": "array", "items": antiCriterion],
                "transfer_problem": ["type": "string"],
            ] as [String: Any],
        ]
    }

    /// Human-readable shape hint for the model prompt — mirrors `AgentAnswerSchema.promptHint`.
    public static let promptHint = """
        {
          "schema_version": "\(currentVersion)",
          "concept_id": "<the concept id you were given, verbatim>",
          "difficulty_band": 1,
          "explain": "<2-3 sentences that set up the question without answering it>",
          "question": "<the question to pose to the developer>",
          "reference_answer": "<a concise model answer, <= 120 words; every factual clause backed by an anchor>",
          "reference_anchors": ["<path>::<Dotted.Name>", "..."],
          "rubric": [
            { "kind": "required", "text": "<one single, checkable fact the answer must establish>",
              "evidence": ["<path>::<Dotted.Name>"] },
            { "kind": "bonus", "text": "<a worthwhile-but-not-essential point>", "evidence": ["..."] }
          ],
          "anti_criteria": [
            { "text": "<a statement that would reveal a WRONG mental model>", "evidence": ["..."] }
          ],
          "transfer_problem": "<a harder follow-up to try next, not graded here>"
        }
        """
}

/// The untrusted, not-yet-verified candidate JSON a question-generation run produces — one
/// question, its rubric, a reference answer and misconception anti-criteria for one concept. See
/// `Docs/17_phase7_teaching_mode.md` §6.1. Nothing in this type is assumed sound; the M2
/// verification pipeline (§6.3, reusing `SemanticImporter`'s anchor-resolution + consistency
/// check) is what earns a persisted `TeachingQuestionRecord` with `verified = 1`.
///
/// M0 defines the decode shape only. `TeachingQuestionGenerator` (M2, in `OrionAgent`) builds the
/// prompt, invokes the model, and hands the parsed candidate to the verifier.
public struct TeachingQuestionCandidate: Decodable, Sendable {
    public var schemaVersion: String
    public var conceptId: String
    public var difficultyBand: Int
    public var explain: String
    public var question: String
    public var referenceAnswer: String
    /// Anchors, benchmark form (`<path>::<Dotted.Name>`) — resolved against `symbols.anchor` for
    /// the target run, exactly like Phase 2/3 evidence anchors.
    public var referenceAnchors: [String]
    public var rubric: [RubricCriterionInput]
    public var antiCriteria: [AntiCriterionInput]
    public var transferProblem: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case conceptId = "concept_id"
        case difficultyBand = "difficulty_band"
        case explain
        case question
        case referenceAnswer = "reference_answer"
        case referenceAnchors = "reference_anchors"
        case rubric
        case antiCriteria = "anti_criteria"
        case transferProblem = "transfer_problem"
    }
}

/// One rubric criterion in a candidate — `kind` is `"required"` or `"bonus"` here (the persisted
/// `RubricCriterionKind` also has `.anti`, which `antiCriteria` below become at persist time).
/// Kept a plain `String`, like `SemanticComponentRelationshipInput.type`, and validated in M2.
public struct RubricCriterionInput: Decodable, Sendable {
    public var kind: String
    public var text: String
    /// Anchors, benchmark form — the criterion's grounding in the Codebase Model.
    public var evidence: [String]
}

/// One misconception detector — a statement that, if the developer's answer conveys it, indicates
/// a wrong mental model (Docs/17 §2.3/§7.2). Persisted as a `RubricCriterionKind.anti` row.
public struct AntiCriterionInput: Decodable, Sendable {
    public var text: String
    public var evidence: [String]
}
