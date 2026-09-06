/// A local conversational model the agent can query.
///
/// Abstracts over the concrete MLX runtime so the Depth Model, tool loop, and CLI depend on
/// this protocol rather than `Qwen3Agent`/`ChatSession` directly -- see
/// Docs/12_phase3_mlx_agent.md Decision #2 for why a single model is committed to for now, and
/// the "Risks" section for what would change if a second model is added.
public protocol AgentModel {
    /// Sends one message and returns the model's reply.
    ///
    /// - Parameter instructions: optional system-prompt instructions for this exchange.
    func respond(to message: String, instructions: String?) async throws -> String
}

extension AgentModel {
    public func respond(to message: String) async throws -> String {
        try await respond(to: message, instructions: nil)
    }
}
