import Foundation
import OrionCore

/// The local per-criterion judge (Docs/17 §7.1) — one plain generation per call, tolerant JSON
/// parse. Wraps a closure so the CLI owns model loading and this stays testable; `RubricGrader`
/// calls it `k` times per criterion for self-consistency. A `FoundationModels` `@Generable`
/// variant (stricter structured decoding) is a later refinement, not M3.
public struct LocalCriterionJudge: CriterionJudging {
    public let source: TeachingQuestionSource = .local
    private let generate: @Sendable (_ prompt: String) async throws -> String

    public init(generate: @escaping @Sendable (_ prompt: String) async throws -> String) {
        self.generate = generate
    }

    public static let systemInstruction = """
        You are a strict, terse code-comprehension grader. You judge whether a developer's answer \
        establishes ONE specific fact — nothing else. You always reply with exactly one JSON \
        object and no other text.
        """

    public func judge(
        criterionText: String, criterionKind: RubricCriterionKind,
        answer: String, conceptEvidence: [String]
    ) async throws -> CriterionVerdict {
        let raw = try await generate(Self.buildPrompt(
            criterionText: criterionText, criterionKind: criterionKind, answer: answer,
            conceptEvidence: conceptEvidence))
        return Self.parse(raw)
    }

    /// The system instruction for `GuidedCriterionJudge`, whose reply format is the schema.
    public static let guidedSystemInstruction = """
        You are a strict, terse code-comprehension grader. You judge whether a developer's answer \
        states ONE specific idea — nothing else. You only credit what the answer actually says.
        """

    static func buildPrompt(
        criterionText: String, criterionKind: RubricCriterionKind,
        answer: String, conceptEvidence: [String]
    ) -> String {
        let antiNote = criterionKind == .anti
            ? "\nThis is an ANTI-criterion: `met: true` means the answer CONTAINS this WRONG idea.\n"
            : ""
        let grounding = conceptEvidence.isEmpty
            ? "" : "\nConcept grounding:\n" + conceptEvidence.map { "  - \($0)" }.joined(separator: "\n") + "\n"
        return """
        Judge whether the developer's answer establishes this one point about the code.

        CRITERION (\(criterionKind.rawValue)): \(criterionText)
        \(antiNote)\(grounding)
        DEVELOPER'S ANSWER:
        \"\"\"
        \(answer)
        \"\"\"

        Judge ONLY whether that specific point is present. Do not reward length, fluency, or \
        restating the question. Reply with EXACTLY one JSON object:
        {"evidence_quote": "<verbatim span from the answer that settles it, or empty string>", \
        "note": "<one short line: why met or not>", "met": true or false, \
        "confidence": "high" or "medium" or "low"}
        """
    }

    /// The note on the verdict an unparseable reply becomes (counted by `teach bench`).
    public static let unparseableNote = "grader output was not valid JSON"

    static func parse(_ raw: String) -> CriterionVerdict {
        guard let jsonText = TeachingQuestionGenerator.extractJSONObject(raw),
              let obj = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any]
        else {
            // Unparseable — the safest reading is "not established, and we're not sure".
            return CriterionVerdict(met: false, confidence: .low, evidenceQuote: "",
                                    note: unparseableNote)
        }
        let met = (obj["met"] as? Bool) ?? false
        let confidence = GraderConfidence(rawValue: (obj["confidence"] as? String ?? "").lowercased()) ?? .low
        return CriterionVerdict(
            met: met, confidence: confidence,
            evidenceQuote: (obj["evidence_quote"] as? String) ?? "",
            note: (obj["note"] as? String) ?? "")
    }
}

/// The §7.4 pairwise "same core idea" comparer — one generation per call, tolerant parse.
public struct LocalAnswerComparer: AnswerComparing {
    private let generate: @Sendable (_ prompt: String) async throws -> String

    public init(generate: @escaping @Sendable (_ prompt: String) async throws -> String) {
        self.generate = generate
    }

    static func buildPrompt(_ a: String, _ b: String, jsonReplyFormat: Bool = true) -> String {
        """
        Do these two answers convey the SAME core idea about the code? Ignore wording, length and \
        detail level — judge only whether the central point is the same.

        ANSWER A:
        \"\"\"
        \(a)
        \"\"\"

        ANSWER B:
        \"\"\"
        \(b)
        \"\"\"
        """ + (jsonReplyFormat ? "\n\nReply with EXACTLY one JSON object: {\"same\": true or false}" : "")
    }

    public func conveysSameIdea(_ a: String, as b: String) async throws -> Bool {
        let raw = try await generate(Self.buildPrompt(a, b))
        guard let jsonText = TeachingQuestionGenerator.extractJSONObject(raw),
              let obj = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any]
        else { return false }
        return (obj["same"] as? Bool) ?? false
    }
}
