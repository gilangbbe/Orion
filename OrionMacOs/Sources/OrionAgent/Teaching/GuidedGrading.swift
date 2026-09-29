import Foundation
import FoundationModels
import OrionCodeIntel

// Guided-generation grading on Core AI (Docs/18 M5).
//
// Two constraints shape these schemas:
// 1. Constrained decoding leaves no room for thinking: `CoreAILanguageModel` applies the schema's
//    grammar from the first token. Docs/18 M4 measured a verdict with no reasoning in front of it
//    -- it calls ~95% of criteria "met", misconceptions included. So the reasoning has to be
//    generated explicitly, before the verdict.
// 2. On Core AI, a schema's field order is not its declaration order. FoundationModels encodes
//    `properties` as an unordered dictionary plus an `x-order` list, and xgrammar (via
//    `coreai-models` @ e7b24da) builds the grammar in dictionary order and ignores `x-order`, so
//    "reasoning before met" inside one struct holds only by chance, per process.
// Hence two guided turns in one session: first the analysis, then -- with it in context -- the
// verdict. Order within each turn doesn't matter.

/// Turn 1 of a criterion judgement: what the answer says about the idea.
@Generable
struct CriterionAnalysis {
    @Guide(description: "The exact sentence from the developer's answer that states this idea, copied character for character, or an empty string if no sentence in the answer states it.")
    let evidenceQuote: String

    @Guide(description: "One or two sentences: what the answer actually says on this topic, and whether that is the same idea as the one being judged.")
    let reasoning: String
}

/// Turn 2: the verdict, decided after the analysis. One neutral question for every criterion
/// kind -- "does the answer state this idea" -- because the first short run found the model
/// flipping `met` on anti-criteria (a correct "the answer contradicts it" analysis followed by
/// `met: true`); `RubricScoring` already turns a stated anti-idea into a misconception.
@Generable
struct CriterionDecision {
    @Guide(description: "true only if the answer itself states the idea being judged; false if it states something different, contradicts it, or never addresses it.")
    let answerStatesThisIdea: Bool

    @Guide(.anyOf(["high", "medium", "low"]))
    let confidence: String
}

/// Turn 1 of the §7.4 same-idea check.
@Generable
struct AnswerComparisonAnalysis {
    @Guide(description: "One or two sentences naming each answer's central point about the code.")
    let reasoning: String
}

/// Turn 2: whether those central points are the same.
@Generable
struct AnswerComparisonDecision {
    @Guide(description: "true only if both answers make the same central point about the code.")
    let same: Bool
}

/// `CriterionJudging` over guided generation (Docs/18 M5): both replies are schema instances by
/// construction, so nothing is parsed and nothing can fail to parse. Same prompt as
/// `LocalCriterionJudge`, minus the JSON reply format.
public struct GuidedCriterionJudge: CriterionJudging {
    public let source: TeachingQuestionSource = .local
    static let decisionPrompt =
        "Based only on your analysis above: does the developer's answer itself state the idea being judged?"
    private let makeSession: @Sendable () -> any GuidedTurnGenerating

    public init(model: any GuidedGenerating) {
        self.makeSession = { model.makeGuidedSession(instructions: LocalCriterionJudge.guidedSystemInstruction) }
    }

    public func judge(
        criterionText: String, criterionKind: RubricCriterionKind,
        answer: String, conceptEvidence: [String]
    ) async throws -> CriterionVerdict {
        let session = makeSession()
        let analysis = try await session.respond(
            to: Self.buildPrompt(idea: criterionText, answer: answer, conceptEvidence: conceptEvidence),
            generating: CriterionAnalysis.self)
        let decision = try await session.respond(to: Self.decisionPrompt, generating: CriterionDecision.self)
        let confidence = GraderConfidence(rawValue: decision.confidence) ?? .low
        // A "stated" verdict must rest on a sentence that is really in the answer. Without thinking,
        // the first short run's analyses sometimes claimed the answer "explicitly states" things it
        // never did; a quote that isn't there makes the vote unconfident rather than trusted.
        let grounded = !decision.answerStatesThisIdea || Self.answer(answer, contains: analysis.evidenceQuote)
        return CriterionVerdict(
            met: decision.answerStatesThisIdea, confidence: grounded ? confidence : .low,
            evidenceQuote: analysis.evidenceQuote,
            note: grounded ? analysis.reasoning : Self.ungroundedNotePrefix + analysis.reasoning)
    }

    static let ungroundedNotePrefix = "[quote not found in the answer] "

    /// Kind-neutral on purpose: the same "does the answer state this idea" question for required,
    /// bonus and anti criteria, with no `met` vocabulary to invert (`RubricScoring` owns what a
    /// stated anti-idea means).
    static func buildPrompt(idea: String, answer: String, conceptEvidence: [String]) -> String {
        let grounding = conceptEvidence.isEmpty
            ? "" : "\nConcept grounding:\n" + conceptEvidence.map { "  - \($0)" }.joined(separator: "\n") + "\n"
        return """
        Does the developer's answer state this idea about the code? The idea may be correct or \
        wrong -- judge only whether the answer itself says it, not whether it is true.

        IDEA BEING JUDGED: \(idea)
        \(grounding)
        DEVELOPER'S ANSWER:
        \"\"\"
        \(answer)
        \"\"\"

        Look for the sentence in the answer that states this idea. Do not reward length, fluency, \
        or restating the question, and do not count an answer that says something different or \
        the opposite.
        """
    }

    /// Whitespace- and case-insensitive containment; an empty quote never grounds anything.
    static func answer(_ answer: String, contains quote: String) -> Bool {
        func normalized(_ text: String) -> String {
            text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;:"))
        }
        let q = normalized(quote)
        return !q.isEmpty && normalized(answer).contains(q)
    }
}

/// `AnswerComparing` over guided generation (Docs/18 M5), analysis then decision.
public struct GuidedAnswerComparer: AnswerComparing {
    static let decisionPrompt = "Based on that, do the two answers make the same central point?"
    private let makeSession: @Sendable () -> any GuidedTurnGenerating

    public init(model: any GuidedGenerating) {
        self.makeSession = { model.makeGuidedSession(instructions: nil) }
    }

    public func conveysSameIdea(_ a: String, as b: String) async throws -> Bool {
        let session = makeSession()
        _ = try await session.respond(
            to: LocalAnswerComparer.buildPrompt(a, b, jsonReplyFormat: false),
            generating: AnswerComparisonAnalysis.self)
        return try await session.respond(to: Self.decisionPrompt, generating: AnswerComparisonDecision.self).same
    }
}

/// How the local teaching grader gets its verdicts (Docs/18 M5).
public enum JudgeOutput: String, CaseIterable, Sendable {
    /// Free text with the model's thinking, then a tolerant JSON parse (`LocalCriterionJudge`).
    case text
    /// Guided-generation schemas (`GuidedCriterionJudge`); Core AI only.
    case guided

    /// `text` | `guided`.
    public static let environmentKey = "ORION_JUDGE_OUTPUT"

    /// `ORION_JUDGE_OUTPUT` when it parses, else `text`.
    public static var current: JudgeOutput {
        ProcessInfo.processInfo.environment[environmentKey].flatMap { JudgeOutput(rawValue: $0.lowercased()) } ?? .text
    }
}

/// Builds the local judge and comparer for a loaded model -- the one place `teach answer`,
/// `teach bench` and the app's grader get them from.
public enum LocalGrading {
    public struct GuidedOutputUnsupported: Error, CustomStringConvertible {
        public let model: String
        public var description: String {
            "\(model) has no guided generation -- use \(JudgeOutput.environmentKey)=text"
        }
    }

    public static func judge(agent: any AgentModel, output: JudgeOutput) throws -> any CriterionJudging {
        switch output {
        case .text:
            return LocalCriterionJudge { p in
                try await agent.respond(to: p, instructions: LocalCriterionJudge.systemInstruction)
            }
        case .guided:
            guard let guided = agent as? any GuidedGenerating else {
                throw GuidedOutputUnsupported(model: agent.modelIdentifier)
            }
            return GuidedCriterionJudge(model: guided)
        }
    }

    public static func comparer(agent: any AgentModel, output: JudgeOutput) throws -> any AnswerComparing {
        switch output {
        case .text:
            return LocalAnswerComparer { p in try await agent.respond(to: p) }
        case .guided:
            guard let guided = agent as? any GuidedGenerating else {
                throw GuidedOutputUnsupported(model: agent.modelIdentifier)
            }
            return GuidedAnswerComparer(model: guided)
        }
    }
}
