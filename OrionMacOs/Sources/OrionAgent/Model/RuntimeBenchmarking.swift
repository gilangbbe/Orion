import Foundation

/// One streamed turn's timing (Docs/18 M3, where it timed MLX and Core AI at the same points).
public struct RuntimeSample: Codable, Sendable {
    /// Tokens Core AI reports for this turn's prompt -- the full re-tokenized context, not just
    /// what it had to prefill after its prefix cache.
    public let promptTokens: Int
    public let outputTokens: Int
    /// Request start -> first non-empty text chunk.
    public let ttftMs: Double
    public let totalMs: Double

    public init(promptTokens: Int, outputTokens: Int, ttftMs: Double, totalMs: Double) {
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.ttftMs = ttftMs
        self.totalMs = totalMs
    }

    public var prefillTokensPerSecond: Double { ttftMs > 0 ? Double(promptTokens) / (ttftMs / 1000) : 0 }
    public var decodeTokensPerSecond: Double {
        let decodeMs = totalMs - ttftMs
        return decodeMs > 0 ? Double(max(outputTokens - 1, 0)) / (decodeMs / 1000) : 0
    }
}

/// Raw-runtime measurement for `orion-agent model-bench`: the given prompts run as consecutive
/// turns of ONE session (so a second prompt measures follow-up-turn cost), streamed, with
/// greedy decoding and thinking disabled -- the same methodology as the Phase 0 MLX leaderboard,
/// so reasoning length can't masquerade as runtime speed.
public protocol RuntimeBenchmarking {
    func benchmarkTurns(_ prompts: [String], maxTokens: Int) async throws -> [RuntimeSample]
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
