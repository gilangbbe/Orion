import Foundation
import FoundationModels

/// One turn of a session whose model calls tools itself (Docs/18 M3.5) -- `LanguageModelSession`
/// runs the tool loop inside `respond`, so a turn returns only the model's final prose.
public protocol ToolCallingTurnGenerating {
    /// - Parameter toolsAllowed: `false` forbids tool calls for this turn
    ///   (`GenerationOptions.toolCallingMode = .disallowed`), for the forced final answer.
    func respond(to message: String, toolsAllowed: Bool) async throws -> String

    /// The same turn, reporting the answer text as it streams (Docs/19 M6: the phone shows the
    /// answer arriving). The default runs `respond(to:toolsAllowed:)` and reports the result once.
    func respond(to message: String, toolsAllowed: Bool, onPartial: ((String) -> Void)?) async throws -> String
}

extension ToolCallingTurnGenerating {
    public func respond(to message: String, toolsAllowed: Bool, onPartial: ((String) -> Void)?) async throws -> String {
        let text = try await respond(to: message, toolsAllowed: toolsAllowed)
        onPartial?(text)
        return text
    }
}

/// Depth 2 over FoundationModels' native tool calling (Docs/18 M3.5; the only depth-2 path since
/// M6 removed MLX and its text-JSON `ActionLoop` workaround, Docs/12 Risk #3). The model emits
/// calls in its own trained `<tool_call>` format, `CoreAILanguageModel` parses them, and the
/// session executes `foundationModelsTools` -- this type only enforces what the session can't:
/// the tool budget (via `ToolCallLedger`), at least one tool call, and a non-empty answer.
public final class NativeToolLoop {
    /// Tool calls refused past the budget before the loop stops the session and forces an
    /// answer -- a model that ignores "budget exhausted" would otherwise loop inside `respond`.
    static let refusalsBeforeForcedAnswer = 2

    public let foundationModelsTools: [any Tool]
    private let hasTools: Bool
    private let budget: Int
    private let ledger: ToolCallLedger

    /// - Parameter resultCharLimit: caps each tool result the model reads (and the ledger
    ///   records). `nil` on the Mac; the iPhone's 4,096-token window can't absorb three long
    ///   results (Docs/19 M6).
    public init(tools: [AgentTool], budget: Int, resultCharLimit: Int? = nil) throws {
        let ledger = ToolCallLedger(budget: budget, refusalsBeforeStop: Self.refusalsBeforeForcedAnswer)
        self.ledger = ledger
        self.budget = budget
        self.hasTools = !tools.isEmpty
        self.foundationModelsTools = try tools.map {
            try AgentToolAdapter(tool: $0, ledger: ledger, resultCharLimit: resultCharLimit)
        }
    }

    /// Primed context plus the investigation rules. No JSON contract: the tool schemas reach
    /// the model through its chat template.
    public func instructions(context: String?) -> String {
        var parts: [String] = []
        if let context, !context.isEmpty { parts.append(context) }
        parts.append(
            """
            You are investigating a codebase with the tools provided. Call at least one tool \
            before you answer -- investigate first, never answer from memory alone. You may make \
            up to \(budget) tool calls. When you have enough information, answer the question \
            directly in plain prose.
            """
        )
        return parts.joined(separator: "\n\n")
    }

    /// - Parameter onPartial: the answer text so far, as it streams (Docs/19 M6).
    public func run(
        question: String, session: any ToolCallingTurnGenerating, onPartial: ((String) -> Void)? = nil
    ) async throws -> AgentAnswer {
        // One corrective re-prompt, shared by both failure modes, then accept what comes back
        // (marked partial) rather than nudging forever.
        var nudgesLeft = 1
        var text = try await respond(to: question, session: session, onPartial: onPartial)

        while nudgesLeft > 0 {
            if text.isEmpty {
                // `CoreAILanguageModel` drops a `<tool_call>` block whose JSON doesn't parse,
                // which leaves an empty response rather than an error.
                text = try await respond(
                    to: "Your last reply was empty. Either call one of your tools, or give your "
                        + "final answer in plain prose.",
                    session: session, onPartial: onPartial)
            } else if hasTools && ledger.executed.isEmpty {
                text = try await respond(
                    to: "You have not called a tool yet. You must call at least one tool before "
                        + "answering.",
                    session: session, onPartial: onPartial)
            } else {
                break
            }
            nudgesLeft -= 1
        }

        let calls = ledger.executed
        let requiredToolWasSkipped = hasTools && calls.isEmpty
        return AgentAnswer(
            text: text, toolCalls: calls,
            partial: text.isEmpty || requiredToolWasSkipped || ledger.refusedCount > 0)
    }

    /// One turn, recovering from the ledger stopping a model that kept calling tools past its
    /// budget: the session's turn is abandoned, and one tool-free turn asks for the answer.
    private func respond(
        to message: String, session: any ToolCallingTurnGenerating, onPartial: ((String) -> Void)?
    ) async throws -> String {
        do {
            return try await session.respond(to: message, toolsAllowed: true, onPartial: onPartial).trimmed
        } catch let error as LanguageModelSession.ToolCallError where error.underlyingError is ToolBudgetExhausted {
            return try await session.respond(
                to: "Your tool budget is exhausted. Answer the question now, in plain prose, using "
                    + "the tool results you already have.",
                toolsAllowed: false, onPartial: onPartial
            ).trimmed
        }
    }
}

/// Thrown from a tool call once the model has ignored "budget exhausted" too many times; the
/// session surfaces it as a `LanguageModelSession.ToolCallError`.
struct ToolBudgetExhausted: Error {}

/// Every tool call a native session executed, in order, plus the budget. Shared by all of one
/// loop's adapters -- the session may run a turn's calls concurrently, so access is locked, and
/// `execute` runs under the lock so `QueryEngine` is never used from two threads at once.
final class ToolCallLedger: @unchecked Sendable {
    private let lock = NSLock()
    private let budget: Int
    private let refusalsBeforeStop: Int
    private var calls: [ExecutedToolCall] = []
    private var refusals = 0

    init(budget: Int, refusalsBeforeStop: Int) {
        self.budget = budget
        self.refusalsBeforeStop = refusalsBeforeStop
    }

    var executed: [ExecutedToolCall] { lock.withLock { calls } }
    var refusedCount: Int { lock.withLock { refusals } }

    /// Runs and records `execute` while budget remains; past it, returns a refusal the model
    /// reads as the tool's output, and throws `ToolBudgetExhausted` once refusals run out.
    func call(toolName: String, argumentsDescription: String, execute: () -> String) throws -> String {
        try lock.withLock {
            guard calls.count < budget else {
                refusals += 1
                if refusals > refusalsBeforeStop { throw ToolBudgetExhausted() }
                return "Tool budget exhausted (\(budget) calls). Do not call any more tools; answer "
                    + "the question now using the results you already have."
            }
            let result = execute()
            calls.append(
                ExecutedToolCall(
                    turnIndex: calls.count + 1, toolName: toolName,
                    argumentsDescription: argumentsDescription, result: result))
            return result
        }
    }
}

/// A FoundationModels `Tool` over an existing `AgentTool`, so `QueryEngineTools` serve both tool
/// protocols unchanged. `Arguments` is raw `GeneratedContent` checked against a schema built from
/// `AgentTool.parameters`, then handed to `execute(arguments:)` as a `[String: Any]`.
struct AgentToolAdapter: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    /// Only ever executed under `ledger`'s lock, which is what makes sharing it safe.
    nonisolated(unsafe) private let tool: AgentTool
    private let ledger: ToolCallLedger
    private let resultCharLimit: Int?

    init(tool: AgentTool, ledger: ToolCallLedger, resultCharLimit: Int? = nil) throws {
        self.tool = tool
        self.ledger = ledger
        self.resultCharLimit = resultCharLimit
        self.name = tool.name
        self.description = tool.description
        let root = DynamicGenerationSchema(
            name: "\(tool.name)_arguments",
            properties: tool.parameters.map {
                DynamicGenerationSchema.Property(
                    name: $0.name, description: $0.description,
                    schema: DynamicGenerationSchema(type: String.self))
            })
        self.parameters = try GenerationSchema(root: root, dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let json = arguments.jsonString
        let parsed = json.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let limit = resultCharLimit
        return try ledger.call(toolName: name, argumentsDescription: Self.describe(parsed)) {
            let result = tool.execute(arguments: parsed)
            guard let limit, result.count > limit else { return result }
            return String(result.prefix(limit)) + "\n…(shortened)"
        }
    }

    /// Sorted-key JSON, the `argumentsDescription` persisted in `agent_tool_calls`.
    private static func describe(_ arguments: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
