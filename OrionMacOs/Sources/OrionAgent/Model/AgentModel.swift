import FoundationModels

/// A local conversational model the agent can query.
///
/// In practice `FoundationModelsAgent` over a Core AI bundle (Docs/18 M2; the only runtime since
/// M6) -- the tool loop, teaching drafters/judges and CLI depend on this protocol so tests can
/// substitute scripted models. `LocalModelLoader` is what hands one out.
public protocol AgentModel {
    /// Backend-qualified identity persisted as `investigations.model_used`, e.g.
    /// `coreai:qwen3-8b-4bit` or `coreai:qwen3-4b-4bit+nothink`.
    var modelIdentifier: String { get }

    /// Sends one message and returns the model's reply.
    ///
    /// - Parameter instructions: optional system-prompt instructions for this exchange.
    func respond(to message: String, instructions: String?) async throws -> String

    /// A fresh plain-chat multi-turn session -- depth 1's (`NativeToolCallingModel` for depth 2).
    func makeSession(instructions: String?) -> any TurnGenerating
}

extension AgentModel {
    public func respond(to message: String) async throws -> String {
        try await respond(to: message, instructions: nil)
    }
}

/// An `AgentModel` that can generate straight into a `@Generable` schema (Docs/18 M5). Only
/// FoundationModels-backed models conform.
public protocol GuidedGenerating: AgentModel {
    /// A fresh multi-turn session whose every turn is generated into a schema.
    func makeGuidedSession(instructions: String?) -> any GuidedTurnGenerating
}

/// One turn of a guided-generation session (Docs/18 M5).
public protocol GuidedTurnGenerating {
    func respond<Content: Generable>(to message: String, generating type: Content.Type) async throws -> Content
}

/// An `AgentModel` whose runtime executes FoundationModels `Tool`s itself -- the
/// `NativeToolLoop` path (Docs/18 M3.5).
public protocol NativeToolCallingModel: AgentModel {
    func makeToolSession(tools: [any Tool], instructions: String?) -> any ToolCallingTurnGenerating
}
