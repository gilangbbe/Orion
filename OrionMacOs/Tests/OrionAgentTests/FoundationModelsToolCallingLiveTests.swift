import XCTest
import FoundationModels

@testable import OrionAgent

/// M2 exploration (Docs/12_phase3_mlx_agent.md Risk #3, option (a)): does FoundationModels'
/// own `Tool` protocol -- separate from `mlx-swift-lm`'s, and from the `@Generable` classify
/// path `AppleFoundationDepthClassifier` already uses -- work reliably for a
/// representative L2-style lookup call? If so, M2's tool loop could route through
/// `FoundationModels` instead of `mlx-swift-lm`'s broken tool-calling path (Risk #3).
///
/// **Confirmed live, both single- and multi-tool cases: yes.** 0.85-1.9s per call across
/// repeated runs, correct tool selection, correct grounding in the tool's actual result (with
/// one caveat -- the model sometimes paraphrases numerals as words, e.g. "3" -> "three", so
/// downstream evidence-matching in M2 can't assume a verbatim quote). No hangs, no crashes.
/// Unlike the `mlx-swift-lm`-based experiments, this runs fine under plain `swift test` with
/// `ORION_AGENT_LIVE_MODEL_TEST=1` -- no `xcodebuild`/Metal-shader workaround needed, since
/// `FoundationModels` is a system framework, not something MLX has to compile shaders for.
final class FoundationModelsToolCallingLiveTests: XCTestCase {

    @Generable
    struct SymbolLookupArguments {
        let symbolName: String
    }

    /// A stand-in for a real `QueryEngine`-backed L2 tool -- returns a fixed, distinctive
    /// string so a correct tool call is unambiguous in the model's final answer.
    struct SymbolLookupTool: Tool {
        let name = "lookup_symbol"
        let description = "Look up a symbol by name in the indexed codebase and return a summary of it."

        func call(arguments: SymbolLookupArguments) async throws -> String {
            "Symbol '\(arguments.symbolName)': a class with 3 methods and 2 callers."
        }
    }

    func testToolCallCompletesQuicklyAndUsesTheToolResult() async throws {
        guard ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip(
                "Set ORION_AGENT_LIVE_MODEL_TEST=1 to run this test -- it uses the real "
                    + "on-device Apple Intelligence model and is not run in CI.")
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw XCTSkip("Apple Intelligence is unavailable on this machine: \(model.availability)")
        }

        let session = LanguageModelSession(
            tools: [SymbolLookupTool()],
            instructions: Instructions(
                "You are a codebase assistant. Whenever asked about a specific named symbol, "
                    + "call the lookup_symbol tool to find out about it before answering. "
                    + "Then answer in one short sentence, including any detail the tool gave you."
            )
        )

        let start = ContinuousClock.now
        let response = try await session.respond(
            to: "What does the symbol Router do? Use your tool, then answer.")
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(30), "tool-calling round trip should be fast, not hang")
        // The model sometimes paraphrases "3"/"2" as "three"/"two" -- check case-insensitively
        // for either form rather than an exact substring (a real observation for M2's evidence
        // grounding: verbatim tool-result quoting can't be assumed, see the doc note below).
        let lowered = response.content.lowercased()
        XCTAssertTrue(
            lowered.contains("method") && (lowered.contains("3") || lowered.contains("three")),
            "expected the final answer to incorporate the tool's actual result, got: \(response.content)"
        )
    }

    @Generable
    struct CallerLookupArguments {
        let symbolName: String
    }

    struct CallerLookupTool: Tool {
        let name = "lookup_callers"
        let description = "List the callers of a symbol by name."

        func call(arguments: CallerLookupArguments) async throws -> String {
            "Callers of '\(arguments.symbolName)': handle_request, dispatch_middleware."
        }
    }

    /// Closer to M2's real shape: two tools offered, a question that plausibly needs both
    /// (a budget-6-style multi-call scenario, not just a single lookup).
    func testMultiToolQuestionUsesBothToolsAndStaysFast() async throws {
        guard ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip(
                "Set ORION_AGENT_LIVE_MODEL_TEST=1 to run this test -- it uses the real "
                    + "on-device Apple Intelligence model and is not run in CI.")
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw XCTSkip("Apple Intelligence is unavailable on this machine: \(model.availability)")
        }

        let session = LanguageModelSession(
            tools: [SymbolLookupTool(), CallerLookupTool()],
            instructions: Instructions(
                "You are a codebase assistant with two tools: lookup_symbol (what a symbol is) "
                    + "and lookup_callers (who calls it). Use whichever tools are relevant before "
                    + "answering, then answer in 1-2 short sentences including the concrete "
                    + "details the tools gave you."
            )
        )

        let start = ContinuousClock.now
        let response = try await session.respond(
            to: "What is the Router symbol, and who calls it? Use your tools, then answer.")
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(30), "multi-tool round trip should be fast, not hang")
        XCTAssertTrue(
            response.content.contains("3 methods"),
            "expected lookup_symbol's result in the answer, got: \(response.content)")
        XCTAssertTrue(
            response.content.contains("handle_request") || response.content.contains("dispatch_middleware"),
            "expected lookup_callers' result in the answer, got: \(response.content)")
    }
}
