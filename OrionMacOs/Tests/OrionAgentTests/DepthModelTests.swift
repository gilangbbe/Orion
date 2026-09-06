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
}
