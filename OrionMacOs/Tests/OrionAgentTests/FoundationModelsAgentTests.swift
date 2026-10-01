import FoundationModels
import XCTest

@testable import OrionAgent

/// A custom FoundationModels provider (the OS 27 `LanguageModel` protocol) that reports what it
/// was sent instead of generating -- lets `FoundationModelsAgent` be tested through a real
/// `LanguageModelSession`, offline, the same way `CoreAILanguageModel` plugs in (Docs/18 M2).
private struct EchoLanguageModel: LanguageModel {
    /// With `.reasoning` by default, like `CoreAILanguageModel`; `supportsReasoning: false` stands
    /// in for the system model, which has none (Docs/19 M0).
    let capabilities: LanguageModelCapabilities
    let executorConfiguration = Executor.Configuration()

    init(supportsReasoning: Bool = true) {
        capabilities = LanguageModelCapabilities(supportsReasoning ? [.reasoning, .toolCalling] : [.toolCalling])
    }

    struct Executor: LanguageModelExecutor {
        struct Configuration: Hashable, Sendable {}

        init(configuration: Configuration) {}

        func prewarm(model: EchoLanguageModel, transcript: Transcript) {}

        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: EchoLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            var instructions = ""
            var prompts: [String] = []
            var responses = 0
            for entry in request.transcript {
                switch entry {
                case .instructions(let value): instructions = Self.text(value.segments)
                case .prompt(let value): prompts.append(Self.text(value.segments))
                case .response: responses += 1
                default: break
                }
            }
            let options = request.generationOptions
            await channel.send(.reasoning(action: .appendText("private chain of thought", tokenCount: 4)))
            await channel.send(.response(action: .appendText(
                "instructions=\(instructions) prompts=\(prompts.joined(separator: "|")) priorResponses=\(responses) "
                    + "temperature=\(options.temperature.map { String($0) } ?? "nil") "
                    + "max=\(options.maximumResponseTokens.map { String($0) } ?? "nil") "
                    + "reasoning=\(Self.reasoning(request.contextOptions.reasoningLevel))",
                tokenCount: 1)))
        }

        private static func reasoning(_ level: ContextOptions.ReasoningLevel?) -> String {
            guard let level else { return "default" }
            if case .custom(let value) = level { return value }
            return "\(level)"
        }

        private static func text(_ segments: [Transcript.Segment]) -> String {
            segments.compactMap { segment in
                if case .text(let text) = segment { return text.content }
                return nil
            }.joined()
        }
    }
}

final class FoundationModelsAgentTests: XCTestCase {
    private let agent = FoundationModelsAgent(model: EchoLanguageModel(), modelIdentifier: "coreai:test")

    func testRespondSendsInstructionsPromptAndTheMLXMatchedOptions() async throws {
        let reply = try await agent.respond(to: "What does Router do?", instructions: "Be brief.")
        XCTAssertTrue(reply.contains("instructions=Be brief."), reply)
        XCTAssertTrue(reply.contains("prompts=What does Router do?"), reply)
        XCTAssertTrue(reply.contains("temperature=0.6"), reply)
        XCTAssertTrue(reply.contains("max=8192"), reply)
    }

    func testReasoningNeverReachesTheAnswerText() async throws {
        let reply = try await agent.respond(to: "hi", instructions: nil)
        XCTAssertFalse(reply.contains("chain of thought"), reply)
    }

    func testTurnSessionCarriesTheConversationForward() async throws {
        let session = agent.makeSession(instructions: "Loop instructions.")
        _ = try await session.respond(to: "first")
        let second = try await session.respond(to: "Tool result: second")
        XCTAssertTrue(second.contains("prompts=first|Tool result: second"), second)
        XCTAssertTrue(second.contains("priorResponses=1"), second)
        XCTAssertTrue(second.contains("instructions=Loop instructions."), second)
    }

    /// Docs/18 M4: a non-thinking role is the same model with `reasoningLevel .custom("none")`,
    /// on every path -- one-shot, multi-turn and native-tool sessions.
    func testWithContextOptionsReachesEveryRequestPath() async throws {
        let thinking = try await agent.respond(to: "q", instructions: nil)
        XCTAssertTrue(thinking.contains("reasoning=default"), thinking)

        let off = agent.with(
            contextOptions: ContextOptions(reasoningLevel: .custom("none")), modelIdentifier: "coreai:test+nothink")
        XCTAssertEqual(off.modelIdentifier, "coreai:test+nothink")
        let oneShot = try await off.respond(to: "q", instructions: nil)
        XCTAssertTrue(oneShot.contains("reasoning=none"), oneShot)
        let multiTurn = try await off.makeSession(instructions: nil).respond(to: "q")
        XCTAssertTrue(multiTurn.contains("reasoning=none"), multiTurn)
        let toolTurn = try await off.makeToolSession(tools: [], instructions: nil).respond(to: "q", toolsAllowed: true)
        XCTAssertTrue(toolTurn.contains("reasoning=none"), toolTurn)
    }

    /// Docs/19 M1: the system model rejects any `reasoningLevel`, even `.custom("none")`, so on a
    /// model without `.reasoning` a no-think role must send none -- on every request path.
    func testReasoningLevelIsDroppedForAModelWithoutReasoning() async throws {
        let base = FoundationModelsAgent(model: EchoLanguageModel(supportsReasoning: false), modelIdentifier: "system:test")
        let off = base.with(
            contextOptions: ContextOptions(reasoningLevel: .custom("none")), modelIdentifier: "system:test")
        let oneShot = try await off.respond(to: "q", instructions: nil)
        XCTAssertTrue(oneShot.contains("reasoning=default"), oneShot)
        let multiTurn = try await off.makeSession(instructions: nil).respond(to: "q")
        XCTAssertTrue(multiTurn.contains("reasoning=default"), multiTurn)
        let toolTurn = try await off.makeToolSession(tools: [], instructions: nil).respond(to: "q", toolsAllowed: true)
        XCTAssertTrue(toolTurn.contains("reasoning=default"), toolTurn)
    }

    func testSupportedKeepsOtherContextOptions() {
        let options = ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .custom("none"))
        let stripped = FoundationModelsAgent<EchoLanguageModel>.supported(options, reasoning: false)
        XCTAssertNil(stripped.reasoningLevel)
        XCTAssertEqual(stripped.includeSchemaInPrompt, true)
        XCTAssertEqual(
            FoundationModelsAgent<EchoLanguageModel>.supported(options, reasoning: true).reasoningLevel, .custom("none"))
    }

    func testIdentifierIsTheBackendQualifiedName() {
        XCTAssertEqual(agent.modelIdentifier, "coreai:test")
    }
}
