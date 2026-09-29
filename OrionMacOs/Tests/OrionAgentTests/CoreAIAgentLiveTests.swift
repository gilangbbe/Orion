import CoreAILanguageModels
import FoundationModels
import OrionCodeIntel
import XCTest

@testable import OrionAgent

/// Loads the real exported Core AI bundle (Docs/18 M1) through `LocalModelLoader`. Gated on
/// `ORION_AGENT_LIVE_COREAI_TEST=1` plus the bundle existing, and skipped in CI -- it needs the
/// ~4.3GB export on disk.
final class CoreAIAgentLiveTests: XCTestCase {
    private func loadAgent() async throws -> any AgentModel {
        guard ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_COREAI_TEST"] == "1" else {
            throw XCTSkip("set ORION_AGENT_LIVE_COREAI_TEST=1 to load the real Core AI bundle")
        }
        guard (try? CoreAIModelLocator.bundleURL()) != nil else {
            throw XCTSkip("no \(CoreAIModelLocator.defaultVariant) bundle -- run scripts/coreai/export-qwen3.sh")
        }
        return try await LocalModelLoader.shared.model(for: .coreAI(variant: CoreAIModelLocator.defaultVariant))
    }

    func testAnswersWithoutLeakingThinking() async throws {
        let agent = try await loadAgent()
        let reply = try await agent.respond(
            to: "In one sentence: what does an HTTP router do?", instructions: "Answer concisely.")
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(reply.contains("<think>"), reply)
        XCTAssertEqual(agent.modelIdentifier, "coreai:qwen3-8b-4bit")
    }

    func testTurnSessionRemembersEarlierTurns() async throws {
        let agent = try await loadAgent()
        let session = agent.makeSession(instructions: "Answer in as few words as possible.")
        _ = try await session.respond(to: "Remember this codeword: PELICAN.")
        let reply = try await session.respond(to: "What was the codeword? Reply with just the word.")
        XCTAssertTrue(reply.uppercased().contains("PELICAN"), reply)
    }
}

/// Docs/18 M3.5: native FoundationModels tool calling on the real Core AI Qwen3-8B, with the real
/// `QueryEngineTools` over the vendored Starlette index. Prints each tool round's wall-clock
/// timing and the session transcript's shape, so the latency split (reasoning vs tool rounds)
/// is visible. Same gate as `CoreAIAgentLiveTests`.
final class CoreAINativeToolCallingLiveTests: XCTestCase {
    /// Stamps when the session executed each call, relative to the loop's start.
    private final class TimedTool: AgentTool {
        let inner: AgentTool
        let start: ContinuousClock.Instant
        var stamps: [(String, Duration)] = []
        init(_ inner: AgentTool, start: ContinuousClock.Instant) {
            self.inner = inner
            self.start = start
        }
        var name: String { inner.name }
        var description: String { inner.description }
        var parameters: [AgentToolParameter] { inner.parameters }
        func execute(arguments: [String: Any]) -> String {
            stamps.append((inner.name, start.duration(to: .now)))
            return inner.execute(arguments: arguments)
        }
    }

    func testCU01CallsARealToolAndAnswers() async throws {
        guard ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_COREAI_TEST"] == "1" else {
            throw XCTSkip("set ORION_AGENT_LIVE_COREAI_TEST=1 to load the real Core AI bundle")
        }
        let agent = try await LocalModelLoader.shared.model(for: .coreAI(variant: CoreAIModelLocator.defaultVariant))
        let native = try XCTUnwrap(agent as? any NativeToolCallingModel)

        let starlette = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Agent Feasibility Study/vendor/starlette")
        let db = try OrionDatabase(path: starlette.appendingPathComponent(".orion/orion.db").path)
        let start = ContinuousClock.now
        let tools = QueryEngineTools.all(engine: QueryEngine(db)).map { TimedTool($0, start: start) }
        let loop = try NativeToolLoop(tools: tools, budget: 6)
        let context = ContextBuilder.build(exportDir: starlette.appendingPathComponent(".orion/export"))
        let session = native.makeToolSession(
            tools: loop.foundationModelsTools, instructions: loop.instructions(context: context))

        let answer = try await loop.run(
            question: "What does Starlette.build_middleware_stack() do, and in what order are the "
                + "middleware layers applied to an incoming request?",
            session: session)
        let total = start.duration(to: .now)

        let stamps = tools.flatMap(\.stamps).sorted { $0.1 < $1.1 }
        print("M3.5 native: total \(total), \(answer.toolCalls.count) call(s), partial=\(answer.partial)")
        for (name, at) in stamps { print("  tool \(name) at \(at)") }
        if let fm = session as? FoundationModelsToolSession {
            for entry in fm.session.transcript {
                switch entry {
                case .reasoning(let r): print("  reasoning: \(r.segments.count) segment(s)")
                case .toolCalls(let c): print("  toolCalls: \(c.map(\.toolName))")
                case .toolOutput(let o): print("  toolOutput: \(o.toolName)")
                case .response: print("  response")
                case .prompt: print("  prompt")
                case .instructions: print("  instructions")
                @unknown default: print("  other")
                }
            }
        }
        print("  answer: \(answer.text.prefix(400))")

        XCTAssertFalse(answer.toolCalls.isEmpty, "expected at least one real tool call")
        XCTAssertFalse(answer.text.isEmpty)
        XCTAssertFalse(answer.text.contains("<tool_call>"), answer.text)
        XCTAssertTrue(
            answer.toolCalls.contains { $0.result.contains("::") },
            "expected a tool result with a resolved anchor: \(answer.toolCalls)")
    }
}

/// Docs/18 M5: one real two-turn guided judgement on Core AI, timed. Same gate as
/// `CoreAIAgentLiveTests`.
final class CoreAIGuidedJudgeLiveTests: XCTestCase {
    func testGuidedJudgeFinishesQuicklyAndJudgesBothWays() async throws {
        guard ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_COREAI_TEST"] == "1" else {
            throw XCTSkip("set ORION_AGENT_LIVE_COREAI_TEST=1 to load the real Core AI bundle")
        }
        let agent = try await LocalModelLoader.shared.model(
            for: .coreAI(variant: CoreAIModelLocator.defaultVariant), role: .judging)
        let judge = GuidedCriterionJudge(model: try XCTUnwrap(agent as? any GuidedGenerating))
        let criterion = "Routes are checked in the order they were registered."
        for (answer, expected) in [
            ("The Router walks self.routes in declaration order and dispatches to the first full match.", true),
            ("The Router sorts routes by path length and picks the most specific one.", false),
        ] {
            let start = ContinuousClock.now
            let verdict = try await judge.judge(
                criterionText: criterion, criterionKind: .required, answer: answer, conceptEvidence: [])
            print("M5 guided: \(start.duration(to: .now)) met=\(verdict.met) \(verdict.confidence) -- \(verdict.note)")
            XCTAssertEqual(verdict.met, expected, verdict.note)
        }
    }
}
