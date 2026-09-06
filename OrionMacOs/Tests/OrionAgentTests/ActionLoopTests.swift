import XCTest

@testable import OrionAgent

/// Exercises `ActionLoop`'s state machine (JSON extraction, budget tracking, tool dispatch,
/// forced-final-turn-on-exhaustion) against a scripted `TurnGenerating` stub -- no live model,
/// matching Docs/12_phase3_mlx_agent.md M2's stated test strategy ("mock toolDispatch calls the
/// way Phase 2 mocked subprocess.run").
final class ActionLoopTests: XCTestCase {

    /// Replays a fixed script of responses, one per call to `respond(to:)`, and records every
    /// prompt it was given.
    private final class ScriptedSession: TurnGenerating {
        private var script: [String]
        private(set) var promptsReceived: [String] = []

        init(_ script: [String]) { self.script = script }

        func respond(to message: String) async throws -> String {
            promptsReceived.append(message)
            guard !script.isEmpty else {
                XCTFail("ScriptedSession ran out of scripted responses")
                return "{}"
            }
            return script.removeFirst()
        }
    }

    private struct EchoTool: AgentTool {
        let name = "echo"
        let description = "Echoes its argument. Arguments: {\"text\": \"...\"}"
        func execute(arguments: [String: Any]) -> String {
            "echoed: \(arguments["text"] as? String ?? "<missing>")"
        }
    }

    func testBudgetZeroSkipsJSONProtocolEntirely() async throws {
        let session = ScriptedSession(["This is a plain-text L1 answer."])
        let loop = ActionLoop(tools: [], budget: 0)
        let answer = try await loop.run(question: "What does X do?", session: session)

        XCTAssertEqual(answer.text, "This is a plain-text L1 answer.")
        XCTAssertTrue(answer.toolCalls.isEmpty)
        XCTAssertFalse(answer.partial)
        XCTAssertEqual(session.promptsReceived, ["What does X do?"])
    }

    /// Real bug found live (`orion-agent ask --force-depth 1`): a budget-0 response returns the
    /// model's raw text directly with no JSON to extract, so Qwen3-8B's hybrid-thinking
    /// `<think>...</think>` preamble was going straight into the user-visible answer, unlike
    /// the budget>0 paths where `extractJSONObject`'s `{`...`}` search already skips over it.
    func testBudgetZeroStripsThinkingBlock() async throws {
        let session = ScriptedSession([
            "<think>\nLet me consider what X does...\n</think>\n\nX does the thing."
        ])
        let loop = ActionLoop(tools: [], budget: 0)
        let answer = try await loop.run(question: "What does X do?", session: session)

        XCTAssertEqual(answer.text, "X does the thing.")
    }

    func testSingleToolCallThenAnswer() async throws {
        let session = ScriptedSession([
            #"{"action": "call_tool", "tool": "echo", "arguments": {"text": "hi"}}"#,
            #"{"action": "answer", "text": "Done: echoed: hi"}"#,
        ])
        let loop = ActionLoop(tools: [EchoTool()], budget: 6)
        let answer = try await loop.run(question: "test", session: session)

        XCTAssertEqual(answer.text, "Done: echoed: hi")
        XCTAssertFalse(answer.partial)
        XCTAssertEqual(answer.toolCalls.count, 1)
        XCTAssertEqual(answer.toolCalls[0].toolName, "echo")
        XCTAssertEqual(answer.toolCalls[0].result, "echoed: hi")
        // second prompt must be the tool's real result, not the model's own claim
        XCTAssertEqual(session.promptsReceived[1], "Tool result: echoed: hi")
    }

    /// Revised (Docs/12_phase3_mlx_agent.md Risk #7 re-verification): a budget>0 loop with real
    /// tools available no longer accepts an immediate answer -- it must be nudged into calling
    /// a tool first. See `testAnswerWithoutToolCallIsNudgedThenAcceptedAsPartial` below for the
    /// exact new behavior this replaces.
    func testAnswerAfterNudgeStillMakesNoToolCallsWhenModelRefusesTwice() async throws {
        let session = ScriptedSession([
            #"{"action": "answer", "text": "No tools needed."}"#,
            #"{"action": "answer", "text": "Still no tools needed."}"#,
        ])
        let loop = ActionLoop(tools: [EchoTool()], budget: 6)
        let answer = try await loop.run(question: "test", session: session)

        XCTAssertEqual(answer.text, "Still no tools needed.")
        XCTAssertTrue(answer.toolCalls.isEmpty)
        XCTAssertTrue(answer.partial, "an answer with tools available but never used must be flagged partial")
    }

    /// The core new behavior (Docs/12 Risk #7 re-verification): found live that a depth-2 model
    /// frequently answered from pretrained knowledge with zero tool calls, silently producing
    /// depth-1-quality content at depth 2. The loop now rejects a tool-free "answer" once and
    /// requires the model to actually call a tool before it will accept a final answer.
    func testAnswerWithoutToolCallIsNudgedThenAccepted() async throws {
        let session = ScriptedSession([
            #"{"action": "answer", "text": "I already know this."}"#,
            #"{"action": "call_tool", "tool": "echo", "arguments": {"text": "hi"}}"#,
            #"{"action": "answer", "text": "Now grounded: echoed: hi"}"#,
        ])
        let loop = ActionLoop(tools: [EchoTool()], budget: 6)
        let answer = try await loop.run(question: "test", session: session)

        XCTAssertEqual(answer.text, "Now grounded: echoed: hi")
        XCTAssertEqual(answer.toolCalls.count, 1)
        XCTAssertFalse(answer.partial, "once a tool was actually called, the answer is not partial")
        XCTAssertTrue(
            session.promptsReceived[1].contains("must call at least one tool"),
            "the second prompt must be the corrective nudge, not the model's own answer text")
    }

    /// A budget>0 loop with no tools configured at all has nothing to require a call to -- the
    /// requirement is waived entirely rather than nudging pointlessly forever.
    func testAnswerWithoutToolCallIsAcceptedWhenNoToolsAreConfigured() async throws {
        let session = ScriptedSession([
            #"{"action": "answer", "text": "No tools exist to call."}"#
        ])
        let loop = ActionLoop(tools: [], budget: 6)
        let answer = try await loop.run(question: "test", session: session)

        XCTAssertEqual(answer.text, "No tools exist to call.")
        XCTAssertFalse(answer.partial)
    }

    func testStrayThinkTextAroundJSONIsTolerated() async throws {
        let session = ScriptedSession([
            "<think>\nOkay let me answer\n</think>\n\n"
                + #"{"action": "answer", "text": "Fine despite the wrapper."}"#
        ])
        let loop = ActionLoop(tools: [], budget: 6)
        let answer = try await loop.run(question: "test", session: session)
        XCTAssertEqual(answer.text, "Fine despite the wrapper.")
        XCTAssertFalse(answer.partial)
    }

    func testUnparseableFinalTurnReturnsRawTextAsPartial() async throws {
        let session = ScriptedSession(["I refuse to use JSON today."])
        let loop = ActionLoop(tools: [], budget: 6)
        let answer = try await loop.run(question: "test", session: session)

        XCTAssertEqual(answer.text, "I refuse to use JSON today.")
        XCTAssertTrue(answer.partial)
    }

    func testUnknownToolNameReturnsPartial() async throws {
        let session = ScriptedSession([
            #"{"action": "call_tool", "tool": "does_not_exist", "arguments": {}}"#
        ])
        let loop = ActionLoop(tools: [EchoTool()], budget: 6)
        let answer = try await loop.run(question: "test", session: session)

        XCTAssertTrue(answer.partial)
        XCTAssertTrue(answer.toolCalls.isEmpty)
    }

    func testBudgetExhaustionForcesFinalAnswerTurn() async throws {
        // budget 2: two call_tool turns exhaust it; a *third* call_tool attempt (over budget)
        // is what actually triggers the forced final turn.
        let session = ScriptedSession([
            #"{"action": "call_tool", "tool": "echo", "arguments": {"text": "1"}}"#,
            #"{"action": "call_tool", "tool": "echo", "arguments": {"text": "2"}}"#,
            #"{"action": "call_tool", "tool": "echo", "arguments": {"text": "3"}}"#,
            #"{"action": "answer", "text": "Forced final answer."}"#,
        ])
        let loop = ActionLoop(tools: [EchoTool()], budget: 2)
        let answer = try await loop.run(question: "test", session: session)

        XCTAssertEqual(answer.toolCalls.count, 2, "the third, over-budget call must not execute")
        XCTAssertTrue(answer.partial, "budget exhaustion must be flagged partial")
        XCTAssertEqual(answer.text, "Forced final answer.")
        XCTAssertEqual(session.promptsReceived.count, 4)
        XCTAssertTrue(session.promptsReceived[3].contains("answer now"))
    }

    /// The bug this guards against: an earlier version checked budget *before* checking
    /// whether the model had already answered, so a model that lands on "answer" on exactly
    /// its budget-th turn had that answer discarded and an extra, unscripted turn forced.
    func testAnsweringExactlyAtBudgetIsNotPartial() async throws {
        let session = ScriptedSession([
            #"{"action": "call_tool", "tool": "echo", "arguments": {"text": "1"}}"#,
            #"{"action": "call_tool", "tool": "echo", "arguments": {"text": "2"}}"#,
            #"{"action": "answer", "text": "Answered right at the budget limit."}"#,
        ])
        let loop = ActionLoop(tools: [EchoTool()], budget: 2)
        let answer = try await loop.run(question: "test", session: session)

        XCTAssertEqual(answer.toolCalls.count, 2)
        XCTAssertFalse(answer.partial)
        XCTAssertEqual(answer.text, "Answered right at the budget limit.")
        XCTAssertEqual(session.promptsReceived.count, 3, "no extra forced turn should be sent")
    }

    func testInstructionsIncludeToolDescriptionsWhenBudgetPositive() {
        let loop = ActionLoop(tools: [EchoTool()], budget: 6)
        let instructions = loop.instructions(context: "Some primed context.")
        XCTAssertTrue(instructions.contains("Some primed context."))
        XCTAssertTrue(instructions.contains("echo"))
        XCTAssertTrue(instructions.contains("call_tool"))
    }

    func testInstructionsOmitToolProtocolWhenBudgetZero() {
        let loop = ActionLoop(tools: [EchoTool()], budget: 0)
        let instructions = loop.instructions(context: "Some primed context.")
        XCTAssertEqual(instructions, "Some primed context.")
    }
}
