/// Confidence a `DepthDecision` reports for itself. `DepthHeuristics` always reports `.high`
/// (an explicit rule either matches or it doesn't); a model-backed classification can report
/// less than that, which `DepthModel` treats as a signal to escalate.
public enum DepthConfidence: String, Codable, Sendable {
    case high, medium, low
}

/// How a `DepthDecision` was produced.
public enum RoutingMethod: String, Codable, Sendable {
    case heuristic
    case model
}

/// The Depth Model's routing decision for one question — Docs/03 §2-3: it decides how much
/// investigation a query needs, it does not answer the query itself.
public struct DepthDecision: Equatable, Sendable {
    /// 1 (local, no tools), 2 (local + deterministic tools), or 3 (delegate to Claude Code).
    /// Meaningless when `isInScope == false` — `AgentSession` never reads `depth` in that case
    /// (Docs/15 §3.3).
    public let depth: Int
    public let intent: String
    public let confidence: DepthConfidence
    public let rationale: String
    public let method: RoutingMethod
    /// Phase 5 guardrail (Docs/15 §3): `false` when the question has nothing to do with the
    /// analyzed repository. Defaulted to `true` so every pre-Phase-5 call site — `DepthHeuristics`'
    /// six hand-written decisions, `AgentSession.resolveDepth`'s `--force-depth` override, and
    /// every existing `DepthDecision`/`DepthModel` test — compiles and behaves unchanged.
    public let isInScope: Bool

    public init(
        depth: Int, intent: String, confidence: DepthConfidence, rationale: String,
        method: RoutingMethod, isInScope: Bool = true
    ) {
        self.depth = depth
        self.intent = intent
        self.confidence = confidence
        self.rationale = rationale
        self.method = method
        self.isInScope = isInScope
    }
}
