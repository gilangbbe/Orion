import FoundationModels
import OrionCodeIntel
import XCTest

@testable import OrionAgent

/// A custom FoundationModels provider that answers each guided-generation request with the JSON
/// scripted for that schema's title, and records what it was asked -- so `GuidedCriterionJudge` / `GuidedAnswerComparer` run through
/// a real `LanguageModelSession` schema decode, offline (Docs/18 M5).
private struct SchemaReplyModel: LanguageModel {
    struct Seen: Sendable {
        let prompt: String
        let instructions: String
        let schemaJSON: String?
        let schemaTitle: String?
        let reasoningLevel: String
        let priorResponses: Int
    }

    final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var replies: [UUID: [String: String]] = [:]
        private var seen: [UUID: [Seen]] = [:]

        func register(replies byTitle: [String: String]) -> UUID {
            let id = UUID()
            lock.withLock { replies[id] = byTitle }
            return id
        }

        func reply(_ id: UUID, after request: Seen) -> String {
            lock.withLock {
                seen[id, default: []].append(request)
                return replies[id]?[request.schemaTitle ?? ""] ?? "{}"
            }
        }

        func seen(_ id: UUID) -> [Seen] { lock.withLock { seen[id] ?? [] } }
    }

    let capabilities = LanguageModelCapabilities([.guidedGeneration, .reasoning])
    let executorConfiguration: Executor.Configuration

    init(replies: [String: String]) {
        executorConfiguration = .init(id: Registry.shared.register(replies: replies))
    }

    var seen: [Seen] { Registry.shared.seen(executorConfiguration.id) }

    struct Executor: LanguageModelExecutor {
        struct Configuration: Hashable, Sendable { let id: UUID }
        let id: UUID

        init(configuration: Configuration) { id = configuration.id }

        func prewarm(model: SchemaReplyModel, transcript: Transcript) {}

        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: SchemaReplyModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            var prompt = ""
            var instructions = ""
            var priorResponses = 0
            for entry in request.transcript {
                switch entry {
                case .prompt(let value): prompt = Self.text(value.segments)
                case .instructions(let value): instructions = Self.text(value.segments)
                case .response: priorResponses += 1
                default: break
                }
            }
            let reasoning: String
            switch request.contextOptions.reasoningLevel {
            case .some(.custom(let value)): reasoning = value
            case .none: reasoning = "default"
            default: reasoning = "other"
            }
            let schemaJSON = request.schema.flatMap {
                (try? JSONEncoder().encode($0)).flatMap { String(data: $0, encoding: .utf8) }
            }
            let title = schemaJSON
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["title"] as? String
            let reply = Registry.shared.reply(
                id,
                after: Seen(
                    prompt: prompt, instructions: instructions, schemaJSON: schemaJSON, schemaTitle: title,
                    reasoningLevel: reasoning, priorResponses: priorResponses))
            await channel.send(.response(action: .appendText(reply, tokenCount: 1)))
        }

        private static func text(_ segments: [Transcript.Segment]) -> String {
            segments.compactMap {
                if case .text(let text) = $0 { return text.content }
                return nil
            }.joined()
        }
    }
}

final class GuidedGradingTests: XCTestCase {
    private func agent(_ replies: [String: String]) -> (FoundationModelsAgent<SchemaReplyModel>, SchemaReplyModel) {
        let model = SchemaReplyModel(replies: replies)
        return (FoundationModelsAgent(model: model, modelIdentifier: "coreai:test"), model)
    }

    private let judgeReplies = [
        "CriterionAnalysis": #"{"evidenceQuote": "routes are tried in order", "reasoning": "states first-match order"}"#,
        "CriterionDecision": #"{"answerStatesThisIdea": true, "confidence": "high"}"#,
    ]

    func testGuidedJudgeAnalysesThenDecidesAndMapsTheVerdict() async throws {
        let (agent, model) = agent(judgeReplies)
        let verdict = try await GuidedCriterionJudge(model: agent).judge(
            criterionText: "Routes are checked in registration order.", criterionKind: .anti,
            answer: "routes are tried in order", conceptEvidence: ["Router.routes"])

        XCTAssertEqual(
            verdict,
            CriterionVerdict(
                met: true, confidence: .high, evidenceQuote: "routes are tried in order",
                note: "states first-match order"))
        let seen = model.seen
        XCTAssertEqual(seen.map(\.schemaTitle), ["CriterionAnalysis", "CriterionDecision"])
        XCTAssertTrue(seen[0].prompt.contains("IDEA BEING JUDGED: Routes are checked in registration order."))
        XCTAssertFalse(seen[0].prompt.contains("ANTI"), "kind-neutral: no `met` polarity to invert")
        XCTAssertFalse(seen[0].prompt.contains("Reply with EXACTLY one JSON object"), "the schema is the format")
        XCTAssertEqual(seen[0].instructions, LocalCriterionJudge.guidedSystemInstruction)
        XCTAssertEqual(seen[1].prompt, GuidedCriterionJudge.decisionPrompt)
        XCTAssertEqual(seen[1].priorResponses, 1, "the verdict is decided with the analysis in context")
        XCTAssertEqual(seen.map(\.reasoningLevel), ["none", "none"], "a grammar can't admit a <think> block")
    }

    /// Core AI generates a schema's fields in `properties` order, which FoundationModels encodes
    /// as an unordered dictionary (declaration order lives only in the `x-order` that xgrammar
    /// ignores) -- so the analysis turn must not contain the verdict at all.
    func testTheAnalysisSchemaHoldsNoVerdictField() async throws {
        let (agent, model) = agent(judgeReplies)
        _ = try await GuidedCriterionJudge(model: agent).judge(
            criterionText: "c", criterionKind: .required, answer: "a", conceptEvidence: [])
        let analysis = try XCTUnwrap(model.seen.first?.schemaJSON)
        XCTAssertTrue(analysis.contains("reasoning"), analysis)
        XCTAssertFalse(analysis.contains("answerStatesThisIdea"), analysis)
        XCTAssertFalse(analysis.contains("confidence"), analysis)
    }

    /// A "stated" verdict whose quote isn't in the answer is kept but made unconfident.
    func testAStatedVerdictWithAnInventedQuoteIsUnconfident() async throws {
        let (agent, _) = agent([
            "CriterionAnalysis": #"{"evidenceQuote": "the router sorts by specificity", "reasoning": "it says so"}"#,
            "CriterionDecision": #"{"answerStatesThisIdea": true, "confidence": "high"}"#,
        ])
        let verdict = try await GuidedCriterionJudge(model: agent).judge(
            criterionText: "Routes are ranked by specificity.", criterionKind: .anti,
            answer: "Routes are tried in declaration order.", conceptEvidence: [])
        XCTAssertTrue(verdict.met)
        XCTAssertEqual(verdict.confidence, .low)
        XCTAssertTrue(verdict.note.hasPrefix(GuidedCriterionJudge.ungroundedNotePrefix), verdict.note)
    }

    func testANotStatedVerdictNeedsNoQuote() async throws {
        let (agent, _) = agent([
            "CriterionAnalysis": #"{"evidenceQuote": "", "reasoning": "never mentions ordering"}"#,
            "CriterionDecision": #"{"answerStatesThisIdea": false, "confidence": "high"}"#,
        ])
        let verdict = try await GuidedCriterionJudge(model: agent).judge(
            criterionText: "c", criterionKind: .required, answer: "a", conceptEvidence: [])
        XCTAssertEqual(verdict, CriterionVerdict(met: false, confidence: .high, evidenceQuote: "", note: "never mentions ordering"))
    }

    func testQuoteGroundingIgnoresCaseWhitespaceAndEdgePunctuation() {
        let answer = "The Router walks self.routes\n  in declaration order."
        XCTAssertTrue(GuidedCriterionJudge.answer(answer, contains: "\"the router walks self.routes in declaration order\""))
        XCTAssertFalse(GuidedCriterionJudge.answer(answer, contains: "sorted by specificity"))
        XCTAssertFalse(GuidedCriterionJudge.answer(answer, contains: "  "), "an empty quote grounds nothing")
    }

    func testGuidedComparerAnalysesThenReadsTheBoolean() async throws {
        let (agent, model) = agent([
            "AnswerComparisonAnalysis": #"{"reasoning": "both say first match wins"}"#,
            "AnswerComparisonDecision": #"{"same": true}"#,
        ])
        let same = try await GuidedAnswerComparer(model: agent).conveysSameIdea("A", as: "B")
        XCTAssertTrue(same)
        let seen = model.seen
        XCTAssertEqual(seen.map(\.schemaTitle), ["AnswerComparisonAnalysis", "AnswerComparisonDecision"])
        XCTAssertTrue(seen[0].prompt.contains("ANSWER A") && seen[0].prompt.contains("ANSWER B"))
        XCTAssertFalse(seen[0].prompt.contains(#"{"same": true or false}"#))
        XCTAssertEqual(seen[1].priorResponses, 1)
    }

    func testLocalGradingPicksTheJudgeAndRejectsGuidedWithoutGuidedGeneration() throws {
        let (agent, _) = agent([:])
        XCTAssertTrue(try LocalGrading.judge(agent: agent, output: .guided) is GuidedCriterionJudge)
        XCTAssertTrue(try LocalGrading.judge(agent: agent, output: .text) is LocalCriterionJudge)
        XCTAssertTrue(try LocalGrading.comparer(agent: agent, output: .guided) is GuidedAnswerComparer)

        struct PlainModel: AgentModel {
            let modelIdentifier = "mlx:test"
            func respond(to message: String, instructions: String?) async throws -> String { "" }
            func makeSession(instructions: String?) -> any TurnGenerating { fatalError() }
        }
        XCTAssertThrowsError(try LocalGrading.judge(agent: PlainModel(), output: .guided))
        XCTAssertTrue(try LocalGrading.judge(agent: PlainModel(), output: .text) is LocalCriterionJudge)
    }

    func testTextPromptsKeepTheirJSONReplyFormat() {
        XCTAssertTrue(
            LocalCriterionJudge.buildPrompt(
                criterionText: "c", criterionKind: .required, answer: "a", conceptEvidence: []
            ).contains("Reply with EXACTLY one JSON object"))
        XCTAssertTrue(LocalAnswerComparer.buildPrompt("a", "b").hasSuffix(#"{"same": true or false}"#))
    }
}
