import Foundation
import FoundationModels
import OrionCore

/// Drafts a teaching question by guided generation (Docs/19 M7) -- the phone's drafter, for bands
/// 1–2 on the system model.
///
/// The Mac's `LocalTeachingDrafter` asks for one JSON object in prose and parses it tolerantly,
/// against a prompt that spells the shape out (`TeachingSchema.promptHint`). On a 4,096-token
/// model that costs tokens twice and still leaves the model free to invent anchors, which
/// `TeachingQuestionVerifier` then rejects. So this drafter, following the Foundation Models skill:
/// - generates into a `DynamicGenerationSchema` built per concept, whose every anchor field is an
///   enum of **that concept's anchors** -- an invented or misspelled anchor can't be produced;
/// - keeps the prompt to the task and the grounding, and lets the schema carry the structure;
/// - budgets the grounding with the model's own `tokenCount` and retries once with half of it
///   after `contextSizeExceeded`.
///
/// The result is re-encoded as a `phase7.v1` candidate, so `TeachingQuestionGenerator` and the
/// verifier treat it exactly like any other draft.
public struct GuidedTeachingDrafter: TeachingQuestionDrafting {
    public typealias Respond = @Sendable (_ instructions: String, _ prompt: String, _ schema: GenerationSchema) async throws -> GeneratedContent
    /// Tokens for the whole request: instructions, prompt and schema.
    public typealias CountTokens = @Sendable (_ instructions: String, _ prompt: String, _ schema: GenerationSchema) async throws -> Int

    public let source: TeachingQuestionSource
    private let respond: Respond
    private let countTokens: CountTokens?
    private let inputBudget: Int?

    /// - Parameters:
    ///   - inputBudget: the most tokens the request may take; grounding lines are dropped until
    ///     it fits. `nil` (with `countTokens`) skips the check.
    public init(
        source: TeachingQuestionSource = .device, inputBudget: Int? = nil, countTokens: CountTokens? = nil,
        respond: @escaping Respond
    ) {
        self.source = source
        self.inputBudget = inputBudget
        self.countTokens = countTokens
        self.respond = respond
    }

    public enum DraftError: Error, CustomStringConvertible {
        case needsInputs
        case malformed(String)

        public var description: String {
            switch self {
            case .needsInputs: return "the guided drafter builds its own prompt; call draft(inputs:)"
            case .malformed(let detail): return "guided draft could not be read: \(detail)"
            }
        }
    }

    /// Code symbols named at most -- each is a grounding line *and* an enum case in the schema.
    static let maxAnchors = 12
    /// The fewest grounding lines a budget trim leaves.
    static let minAnchors = 3

    public func draft(prompt: String, band: Int) async throws -> String {
        throw DraftError.needsInputs
    }

    public func draft(inputs: TeachingPromptInputs) async throws -> String {
        var grounding = Array(Self.prioritized(inputs).prefix(Self.maxAnchors))
        var withCode = Self.maxExcerpts
        if let countTokens, let inputBudget {
            // Over budget: drop code excerpts first, then symbols from the least telling end.
            while try await countTokens(
                Self.instructions, Self.prompt(inputs, grounding: grounding, withCode: withCode),
                Self.schema(anchors: grounding.map(\.anchor))) > inputBudget
            {
                if withCode > 0 {
                    withCode -= 1
                } else if grounding.count > Self.minAnchors {
                    grounding.removeLast(max(1, grounding.count / 4))
                } else {
                    break
                }
            }
        }
        let content: GeneratedContent
        do {
            content = try await respond(
                Self.instructions, Self.prompt(inputs, grounding: grounding, withCode: withCode),
                Self.schema(anchors: grounding.map(\.anchor)))
        } catch LanguageModelError.contextSizeExceeded where grounding.count > Self.minAnchors || withCode > 0 {
            // The skill's overflow rule: shrink and retry once, in a fresh session.
            grounding = Array(grounding.prefix(max(Self.minAnchors, grounding.count / 2)))
            content = try await respond(
                Self.instructions, Self.prompt(inputs, grounding: grounding, withCode: 0),
                Self.schema(anchors: grounding.map(\.anchor)))
        }
        return try Self.candidateJSON(from: content, inputs: inputs)
    }

    /// Symbols shown with their code. Signatures alone let the model guess -- which way an
    /// inheritance runs, what a default is -- and a third of M7's drafts guessed wrong.
    static let maxExcerpts = 3

    // MARK: - Grounding

    struct Grounding: Equatable {
        let anchor: String
        let line: String
    }

    /// The concept's anchors arrive sorted by name, so a cap keeps whatever sorts first -- for
    /// "Routing & Endpoint Dispatch" that was every `convertors.py` class, and the question came
    /// out about convertors (Docs/19 M7). So: symbols sharing a word with the concept's label
    /// first, then classes and functions before methods before modules.
    static func prioritized(_ inputs: TeachingPromptInputs) -> [Grounding] {
        let pairs = zip(inputs.evidenceAnchors, inputs.evidenceLines).map { Grounding(anchor: $0, line: $1) }
        let labelWords = words(inputs.conceptLabel)
        func relevance(_ anchor: String) -> Int { labelWords.intersection(words(anchor)).count }
        func kind(_ anchor: String) -> Int {
            guard let name = anchor.components(separatedBy: "::").dropFirst().first, !name.isEmpty else { return 2 }
            return name.contains(".") ? 1 : 0
        }
        return pairs.enumerated()
            .sorted {
                (-relevance($0.element.anchor), kind($0.element.anchor), $0.offset)
                    < (-relevance($1.element.anchor), kind($1.element.anchor), $1.offset)
            }
            .map(\.element)
    }

    /// `CompactContextBuilder.terms`, singular: "endpoints.py" should match "Endpoint".
    static func words(_ text: String) -> Set<String> {
        Set(CompactContextBuilder.terms(text).map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    // MARK: - Prompt

    static let instructions = """
        You write one teaching question for a developer learning an unfamiliar Python codebase. \
        You don't answer it for them. Every fact you state must come from the code symbols you're \
        given, and you cite only those symbols in the evidence fields. The developer doesn't see \
        the symbol list: never refer to it, and in the text name code by its name, like \
        Router.add_route, not by its file path.
        """

    /// One concrete task per band and concept kind, chosen here rather than offered as "X, or Y"
    /// in the prompt: the phone's model echoed the alternatives back into the question ("How does
    /// it relate to or differ from …, or which dependency pattern …?", Docs/19 M7) -- the skill's
    /// "move conditionals into code".
    static func task(band: Int, kind: String, label: String = "") -> String {
        switch (band, kind) {
        case (1, _):
            return "Ask the developer to state what this concept does, using its own code only."
        case (2, TeachingConceptKind.relationship.rawValue):
            // Named, not "the first side": the model copied that phrase into its questions.
            let sides = label.components(separatedBy: " → ")
            guard sides.count == 2 else {
                return "Ask the developer what one side of this dependency uses from the other, and why."
            }
            return "Ask the developer what \(sides[0]) uses from \(sides[1]), and why that dependency runs that way."
        case (2, _):
            return "Ask the developer how this concept differs from one neighbouring concept below. Name that neighbour in the question."
        default:
            return "Ask the developer what would break first, and why, if this concept's code changed."
        }
    }

    static func prompt(_ inputs: TeachingPromptInputs, grounding: [Grounding], withCode: Int = 0) -> String {
        var out = """
            Concept (\(inputs.conceptKind)): \(inputs.conceptLabel)

            \(task(band: inputs.band, kind: inputs.conceptKind, label: inputs.conceptLabel)) Ask one question, not several.

            Code symbols:
            """
        var shownCode = 0
        for g in grounding {
            out += "\n- \(g.line)"
            if shownCode < withCode, let code = inputs.codeExcerpts[g.anchor], !code.isEmpty {
                out += "\n  Code:\n" + code.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }.joined(separator: "\n")
                shownCode += 1
            }
        }
        if inputs.band >= 2, !inputs.relatedConceptLabels.isEmpty {
            out += "\n\nNeighbouring concepts:"
            for label in inputs.relatedConceptLabels { out += "\n- \(label)" }
        }
        out += "\n\nEach required point and each wrong statement must be one single, checkable fact."
        if !inputs.priorRejectionReasons.isEmpty {
            out += "\n\nYour previous question was rejected. Fix this:"
            for reason in inputs.priorRejectionReasons { out += "\n- \(reason)" }
        }
        return out
    }

    // MARK: - Schema

    /// The question, generated top to bottom: setup and question first, then the answer the
    /// rubric is cut from, then the rubric itself.
    static func schema(anchors: [String]) throws -> GenerationSchema {
        let anchor = DynamicGenerationSchema(name: "Anchor", description: "A code symbol from the list", anyOf: anchors)
        func anchorList(_ min: Int, _ max: Int) -> DynamicGenerationSchema {
            DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Anchor"), minimumElements: min, maximumElements: max)
        }
        func text(_ name: String, _ description: String) -> DynamicGenerationSchema.Property {
            .init(name: name, description: description, schema: DynamicGenerationSchema(type: String.self))
        }
        let criterion = DynamicGenerationSchema(name: "Point", properties: [
            text("text", "One single, checkable fact"),
            .init(name: "evidence", description: "The symbols that show it", schema: anchorList(1, 2)),
        ])
        func points(_ min: Int, _ max: Int) -> DynamicGenerationSchema {
            DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Point"), minimumElements: min, maximumElements: max)
        }
        let root = DynamicGenerationSchema(name: "TeachingQuestion", properties: [
            text("explain", "2-3 sentences that set up the question without answering it"),
            text("question", "The question to ask the developer"),
            text("referenceAnswer", "A model answer, at most 120 words, stating only facts the symbols show"),
            .init(name: "referenceAnchors", description: "The symbols the model answer relies on", schema: anchorList(1, 3)),
            .init(name: "required", description: "Points a correct answer must make", schema: points(3, 4)),
            .init(name: "bonus", description: "Worthwhile extra points", schema: points(0, 2)),
            .init(name: "wrong", description: "Wrong statements that would reveal a misunderstanding, usually the reverse of a required point", schema: points(1, 2)),
            text("transferProblem", "A harder follow-up question to try next"),
        ])
        return try GenerationSchema(root: root, dependencies: [anchor, criterion])
    }

    // MARK: - Re-encoding

    /// The guided content as a `phase7.v1` candidate. The schema version, concept and band come
    /// from the request, not the model.
    static func candidateJSON(from content: GeneratedContent, inputs: TeachingPromptInputs) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: Data(content.jsonString.utf8)) as? [String: Any] else {
            throw DraftError.malformed("not an object")
        }
        func string(_ key: String) -> String { object[key] as? String ?? "" }
        func points(_ key: String) -> [[String: Any]] {
            (object[key] as? [[String: Any]] ?? []).map {
                ["text": $0["text"] as? String ?? "", "evidence": $0["evidence"] as? [String] ?? []]
            }
        }
        let rubric = points("required").map { $0.merging(["kind": "required"]) { $1 } }
            + points("bonus").map { $0.merging(["kind": "bonus"]) { $1 } }
        let candidate: [String: Any] = [
            "schema_version": TeachingSchema.currentVersion,
            "concept_id": inputs.conceptId,
            "difficulty_band": inputs.band,
            "explain": string("explain"),
            "question": string("question"),
            "reference_answer": string("referenceAnswer"),
            "reference_anchors": object["referenceAnchors"] as? [String] ?? [],
            "rubric": rubric,
            "anti_criteria": points("wrong"),
            "transfer_problem": string("transferProblem"),
        ]
        let data = try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
