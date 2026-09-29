import FoundationModels
import XCTest

@testable import OrionAgent

/// A custom FoundationModels provider that replies from a script instead of generating, emitting
/// tool calls through the same `.toolCalls` channel events `CoreAILanguageModel` sends after
/// parsing Qwen3's `<tool_call>` markup -- so `NativeToolLoop` runs through a real
/// `LanguageModelSession`'s tool execution, offline (Docs/18 M3.5).
private struct ScriptedToolModel: LanguageModel {
    enum Reply: Sendable {
        case call(tool: String, argumentsJSON: String)
        case text(String)
    }

    /// What the executor saw on one request.
    struct Request: Sendable {
        let lastPrompt: String
        let toolOutputs: Int
        let offeredTools: [String]
        let toolSchemas: [String]
        let toolsDisallowed: Bool
    }

    typealias Script = @Sendable (Request) -> Reply

    /// Scripts live outside the executor, which FoundationModels constructs from a `Hashable`
    /// configuration.
    final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var scripts: [UUID: Script] = [:]
        private var requests: [UUID: [Request]] = [:]

        func register(_ script: @escaping Script) -> UUID {
            let id = UUID()
            lock.withLock { scripts[id] = script }
            return id
        }

        func reply(_ id: UUID, to request: Request) -> Reply {
            lock.withLock {
                requests[id, default: []].append(request)
                return scripts[id]!(request)
            }
        }

        func requests(_ id: UUID) -> [Request] { lock.withLock { requests[id] ?? [] } }
    }

    let capabilities = LanguageModelCapabilities([.toolCalling])
    let executorConfiguration: Executor.Configuration

    init(script: @escaping Script) {
        executorConfiguration = .init(id: Registry.shared.register(script))
    }

    var requests: [Request] { Registry.shared.requests(executorConfiguration.id) }

    struct Executor: LanguageModelExecutor {
        struct Configuration: Hashable, Sendable { let id: UUID }
        let id: UUID

        init(configuration: Configuration) { id = configuration.id }

        func prewarm(model: ScriptedToolModel, transcript: Transcript) {}

        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ScriptedToolModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            var lastPrompt = ""
            var toolOutputs = 0
            for entry in request.transcript {
                switch entry {
                case .prompt(let prompt):
                    lastPrompt = prompt.segments.compactMap {
                        if case .text(let text) = $0 { return text.content }
                        return nil
                    }.joined()
                case .toolOutput: toolOutputs += 1
                default: break
                }
            }
            let seen = Request(
                lastPrompt: lastPrompt, toolOutputs: toolOutputs,
                offeredTools: request.enabledToolDefinitions.map(\.name),
                toolSchemas: request.enabledToolDefinitions.map {
                    (try? JSONEncoder().encode($0.parameters)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                },
                toolsDisallowed: request.generationOptions.toolCallingMode == .disallowed)

            switch Registry.shared.reply(id, to: seen) {
            case .call(let tool, let argumentsJSON):
                await channel.send(
                    .toolCalls(
                        action: .toolCall(
                            id: "call_\(UUID().uuidString.prefix(8))", name: tool,
                            action: .appendArguments(argumentsJSON, tokenCount: 1))))
            case .text(let text):
                await channel.send(.response(action: .appendText(text, tokenCount: 1)))
            }
        }
    }
}

final class NativeToolLoopTests: XCTestCase {
    private struct LookupTool: AgentTool {
        let name = "lookup_symbol"
        let description = "Find symbols by substring."
        let parameters = [AgentToolParameter(name: "query", description: "Substring to find.")]
        func execute(arguments: [String: Any]) -> String {
            "pkg/router.py::Router (class) for query \(arguments["query"] as? String ?? "<missing>")"
        }
    }

    private func run(
        budget: Int = 6, tools: [AgentTool] = [LookupTool()], script: @escaping ScriptedToolModel.Script
    ) async throws -> (AgentAnswer, ScriptedToolModel) {
        let model = ScriptedToolModel(script: script)
        let agent = FoundationModelsAgent(model: model, modelIdentifier: "coreai:test")
        let loop = try NativeToolLoop(tools: tools, budget: budget)
        let session = agent.makeToolSession(
            tools: loop.foundationModelsTools, instructions: loop.instructions(context: "Primed context."))
        let answer = try await loop.run(question: "What does Router do?", session: session)
        return (answer, model)
    }

    func testExecutesANativeToolCallThenAnswers() async throws {
        let (answer, model) = try await run { request in
            request.toolOutputs == 0
                ? .call(tool: "lookup_symbol", argumentsJSON: #"{"query": "Router"}"#)
                : .text("Router dispatches requests.")
        }
        XCTAssertEqual(answer.text, "Router dispatches requests.")
        XCTAssertFalse(answer.partial)
        XCTAssertEqual(
            answer.toolCalls,
            [
                ExecutedToolCall(
                    turnIndex: 1, toolName: "lookup_symbol", argumentsDescription: #"{"query":"Router"}"#,
                    result: "pkg/router.py::Router (class) for query Router")
            ])
        XCTAssertEqual(model.requests.count, 2, "one request for the call, one after its output")
    }

    func testToolSchemaReachesTheModelInsteadOfAJSONContract() async throws {
        let (_, model) = try await run { request in
            request.toolOutputs == 0
                ? .call(tool: "lookup_symbol", argumentsJSON: #"{"query": "Router"}"#) : .text("done")
        }
        let first = try XCTUnwrap(model.requests.first)
        XCTAssertEqual(first.offeredTools, ["lookup_symbol"])
        XCTAssertTrue(first.toolSchemas[0].contains("query"), first.toolSchemas[0])

        let instructions = try NativeToolLoop(tools: [LookupTool()], budget: 6).instructions(context: "ctx")
        XCTAssertTrue(instructions.hasPrefix("ctx\n\n"))
        XCTAssertTrue(instructions.contains("up to 6 tool calls"))
        XCTAssertFalse(instructions.contains(#""action""#), "no JSON-action contract on the native path")
    }

    func testAnsweringWithoutAToolIsNudgedOnce() async throws {
        let (answer, model) = try await run { request in
            if request.lastPrompt.hasPrefix("You have not called a tool yet") {
                return request.toolOutputs == 0
                    ? .call(tool: "lookup_symbol", argumentsJSON: #"{"query": "Router"}"#)
                    : .text("Grounded answer.")
            }
            return .text("From memory.")
        }
        XCTAssertEqual(answer.text, "Grounded answer.")
        XCTAssertEqual(answer.toolCalls.count, 1)
        XCTAssertFalse(answer.partial)
        XCTAssertEqual(model.requests.count, 3)
    }

    func testStillNoToolAfterTheNudgeIsPartial() async throws {
        let (answer, model) = try await run { _ in .text("From memory.") }
        XCTAssertEqual(answer.text, "From memory.")
        XCTAssertTrue(answer.toolCalls.isEmpty)
        XCTAssertTrue(answer.partial)
        XCTAssertEqual(model.requests.count, 2, "exactly one nudge")
    }

    /// `CoreAILanguageModel` drops a `<tool_call>` whose JSON doesn't parse, leaving an empty reply.
    func testEmptyReplyIsNudgedOnce() async throws {
        let (answer, _) = try await run { request in
            if request.lastPrompt == "What does Router do?" { return .text("  \n") }
            return request.toolOutputs == 0
                ? .call(tool: "lookup_symbol", argumentsJSON: #"{"query": "Router"}"#)
                : .text("Recovered answer.")
        }
        XCTAssertEqual(answer.text, "Recovered answer.")
        XCTAssertEqual(answer.toolCalls.count, 1)
        XCTAssertFalse(answer.partial)
    }

    func testCallsPastTheBudgetAreRefusedThenAnAnswerIsForced() async throws {
        let (answer, model) = try await run(budget: 1) { request in
            request.toolsDisallowed
                ? .text("Forced answer.")
                : .call(tool: "lookup_symbol", argumentsJSON: #"{"query": "Router"}"#)
        }
        XCTAssertEqual(answer.text, "Forced answer.")
        XCTAssertEqual(answer.toolCalls.count, 1, "only the in-budget call executes")
        XCTAssertTrue(answer.partial)
        // 1 executed + `refusalsBeforeForcedAnswer` refused + the one that stops the turn, then
        // the tool-free forced turn.
        XCTAssertEqual(model.requests.count, 1 + NativeToolLoop.refusalsBeforeForcedAnswer + 1 + 1)
        XCTAssertTrue(try XCTUnwrap(model.requests.last).toolsDisallowed)
    }

    func testMissingArgumentReachesTheToolAsItsOwnErrorString() async throws {
        let (answer, _) = try await run { request in
            request.toolOutputs == 0 ? .call(tool: "lookup_symbol", argumentsJSON: "{}") : .text("ok")
        }
        XCTAssertEqual(answer.toolCalls.first?.result, "pkg/router.py::Router (class) for query <missing>")
    }
}
