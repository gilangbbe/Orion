import Foundation
import GRDB

/// Phase 3 persisted records (`v3_phase3_schema`). See
/// `Docs/12_phase3_mlx_agent.md` "SQLite schema". Additive only — no Phase 1/2 table altered.

/// One Depth Model classification — heuristic or model-backed — for one investigation's
/// question (Docs/12 "Depth Model"). Kept distinct from `investigations.complexity` (the path
/// actually taken): this is what the router decided, so a later routing-quality benchmark
/// (Phase 5) can compare "what was chosen" against "what happened" without re-deriving either
/// from prose.
public struct RoutingDecisionRecord: OrionRecord {
    public static let databaseTableName = "routing_decisions"

    public var id: String
    public var investigationId: String
    public var depthLevel: Int
    public var method: String          // RoutingMethod ("heuristic" | "model")
    public var confidence: String      // DepthConfidence ("high" | "medium" | "low")
    public var rationale: String
    public var createdAt: String

    /// Explicit, since the auto-synthesized memberwise initializer for a `Decodable`-conforming
    /// struct is only `internal` by default — invisible outside `OrionCodeIntel`. Needed by
    /// `OrionAgent`'s `AgentSession` (Phase 3 M4).
    public init(
        id: String, investigationId: String, depthLevel: Int, method: String, confidence: String,
        rationale: String, createdAt: String
    ) {
        self.id = id
        self.investigationId = investigationId
        self.depthLevel = depthLevel
        self.method = method
        self.confidence = confidence
        self.rationale = rationale
        self.createdAt = createdAt
    }
}

/// One executed tool call from the M2 `ActionLoop` (Docs/12 "Local execution & tool loop") —
/// the loop's own trace, not the model's. `turnIndex` orders calls within one investigation;
/// `arguments` is the raw JSON object text the model requested (kept even if malformed, for
/// debugging); `resultSummary` is what the tool actually returned. Hidden by default per
/// Docs/05 §8 ("internal tool traces"), surfaced only via `orion-agent ask --explain` (M4).
public struct AgentToolCallRecord: OrionRecord {
    public static let databaseTableName = "agent_tool_calls"

    public var id: String
    public var investigationId: String
    public var turnIndex: Int
    public var toolName: String
    public var arguments: String
    public var resultSummary: String
    public var latencyMs: Double?
    public var createdAt: String

    /// Explicit, since the auto-synthesized memberwise initializer for a `Decodable`-conforming
    /// struct is only `internal` by default — invisible outside `OrionCodeIntel`. Needed by
    /// `OrionAgent`'s `AgentSession` (Phase 3 M4).
    public init(
        id: String, investigationId: String, turnIndex: Int, toolName: String, arguments: String,
        resultSummary: String, latencyMs: Double? = nil, createdAt: String
    ) {
        self.id = id
        self.investigationId = investigationId
        self.turnIndex = turnIndex
        self.toolName = toolName
        self.arguments = arguments
        self.resultSummary = resultSummary
        self.latencyMs = latencyMs
        self.createdAt = createdAt
    }
}
