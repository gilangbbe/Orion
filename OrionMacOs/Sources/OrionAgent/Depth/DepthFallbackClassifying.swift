/// The Depth Model's fallback path, used only when `DepthHeuristics` doesn't confidently match
/// a question. A separate protocol (rather than hard-wiring `Qwen3Agent` into `DepthModel`)
/// so `DepthModel`'s routing/escalation logic is unit-testable with a stub, independent of the
/// real model-backed classifier's own (separately, live-gated) tests.
public protocol DepthFallbackClassifying {
    func classify(_ question: String) async throws -> DepthDecision
}
