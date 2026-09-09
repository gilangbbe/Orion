import XCTest

@testable import OrionAgent

/// Exercises `DepthModel`'s routing/escalation logic against a stub fallback classifier --
/// no live model needed. `ModelBackedDepthClassifier` itself is covered separately by a
/// live-gated test (see `ModelBackedDepthClassifierLiveTests`).
final class DepthModelTests: XCTestCase {

    private struct StubFallback: DepthFallbackClassifying {
        let result: DepthDecision
        func classify(_ question: String) async throws -> DepthDecision { result }
    }

    func testHeuristicMatchNeverCallsFallback() async throws {
        struct AlwaysThrowsFallback: DepthFallbackClassifying {
            func classify(_ question: String) async throws -> DepthDecision {
                XCTFail("fallback should not be called when a heuristic matches")
                throw CancellationError()
            }
        }
        let model = DepthModel(fallback: AlwaysThrowsFallback())
        let decision = try await model.classify("What does `AuthService` do?")
        XCTAssertEqual(decision.depth, 1)
        XCTAssertEqual(decision.method, .heuristic)
    }

    func testNonHeuristicQuestionUsesFallbackResultWhenConfident() async throws {
        let fallback = StubFallback(
            result: DepthDecision(
                depth: 3, intent: "architectural_reasoning", confidence: .high,
                rationale: "Needs cross-subsystem reasoning.", method: .model))
        let model = DepthModel(fallback: fallback)
        let decision = try await model.classify(
            "Why was the authentication architecture designed this way?")
        XCTAssertEqual(decision.depth, 3)
        XCTAssertEqual(decision.confidence, .high)
        XCTAssertEqual(decision.method, .model)
    }

    /// Revised policy (Docs/12_phase3_mlx_agent.md Risk #7, decided after M5): medium confidence
    /// routes to depth 2, not straight to depth 3 -- M5 found every non-trivial real question
    /// landing on "medium" and escalating past depth 2 every single time, making it effectively
    /// unreachable via the classifier. Low confidence still escalates all the way (see below).
    func testMediumConfidenceFallbackRoutesToDepth2() async throws {
        let fallback = StubFallback(
            result: DepthDecision(
                depth: 1, intent: "component_purpose", confidence: .medium,
                rationale: "Not fully sure this is simple.", method: .model))
        let model = DepthModel(fallback: fallback)
        let decision = try await model.classify("Some ambiguous question about the system")
        XCTAssertEqual(decision.depth, 2, "medium confidence should route to depth 2, not depth 3")
        XCTAssertEqual(decision.confidence, .medium, "the original confidence is preserved for the record")
    }

    func testLowConfidenceFallbackEscalatesToDepth3() async throws {
        let fallback = StubFallback(
            result: DepthDecision(
                depth: 2, intent: "dependency_lookup", confidence: .low,
                rationale: "Could not tell which lookup applies.", method: .model))
        let model = DepthModel(fallback: fallback)
        let decision = try await model.classify("Some ambiguous question about the system")
        XCTAssertEqual(decision.depth, 3)
    }

    /// Verified live at M1: `ModelBackedDepthClassifier` against real `Qwen3-8B-4bit` hung past
    /// 10 minutes on a tool-calling classification call. A slow/hung fallback must not block
    /// the whole agent -- `DepthModel` races it against a deadline and escalates on timeout,
    /// the same way it escalates on a low-confidence result.
    func testHungFallbackEscalatesToDepth3WithinTimeout() async throws {
        struct HangingFallback: DepthFallbackClassifying {
            func classify(_ question: String) async throws -> DepthDecision {
                try await Task.sleep(for: .seconds(3600))
                XCTFail("should have been raced out by the timeout long before this returns")
                throw CancellationError()
            }
        }
        let model = DepthModel(fallback: HangingFallback(), fallbackTimeout: .milliseconds(50))
        let start = ContinuousClock.now
        let decision = try await model.classify("Some ambiguous question about the system")
        XCTAssertEqual(decision.depth, 3)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2), "timeout escalation must be fast")
    }

    // MARK: guardrail (Docs/15 §3)

    /// The guardrail is checked before confidence-based escalation, and unconditionally --
    /// Docs/15 §3.2: an out-of-scope question is never escalated to Claude Code, no matter what
    /// (otherwise-irrelevant) confidence came back alongside the decline.
    func testOutOfScopeFallbackResultIsNeverEscalated() async throws {
        let fallback = StubFallback(
            result: DepthDecision(
                depth: 3, intent: "unclassified", confidence: .low,
                rationale: "This looks like a general knowledge question, not one about the"
                    + " analyzed repository.",
                method: .model, isInScope: false))
        let model = DepthModel(fallback: fallback)
        let decision = try await model.classify("What's a good recipe for pasta?")
        XCTAssertFalse(decision.isInScope)
        XCTAssertEqual(decision.method, .model)
        XCTAssertTrue(decision.rationale.contains("general knowledge"))
    }

    /// An in-scope result still goes through the existing confidence-based escalation unchanged
    /// -- the guardrail is a gate in front of that logic, not a replacement for it.
    func testInScopeFallbackResultStillEscalatesOnLowConfidence() async throws {
        let fallback = StubFallback(
            result: DepthDecision(
                depth: 2, intent: "dependency_lookup", confidence: .low,
                rationale: "Could not tell which lookup applies.", method: .model,
                isInScope: true))
        let model = DepthModel(fallback: fallback)
        let decision = try await model.classify("Some ambiguous question about the system")
        XCTAssertTrue(decision.isInScope)
        XCTAssertEqual(decision.depth, 3)
    }

    /// A heuristic match is repository-related by construction (Docs/03 §2's fixed code-shaped
    /// patterns) -- the guardrail check never even runs for it, mirroring
    /// `testHeuristicMatchNeverCallsFallback` above.
    func testHeuristicMatchIsAlwaysInScope() async throws {
        let model = DepthModel(fallback: StubFallback(result: DepthDecision(
            depth: 3, intent: "x", confidence: .high, rationale: "unused", method: .model)))
        let decision = try await model.classify("What does `AuthService` do?")
        XCTAssertTrue(decision.isInScope)
    }
}
