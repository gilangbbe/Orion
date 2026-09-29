/// A deterministic, read-only capability depth 2 can execute on the model's behalf. A plain,
/// synchronous, in-process function wrapping `OrionCodeIntel`'s `QueryEngine`/`Store`;
/// `NativeToolLoop` exposes it to the model as a FoundationModels `Tool` (`AgentToolAdapter`,
/// Docs/18 M3.5) built from `description` and `parameters`.
public protocol AgentTool {
    var name: String { get }

    /// Included verbatim in the investigation's instructions so the model knows the tool
    /// exists and its exact argument shape (e.g. `Arguments: {"query": "<substring>"}`).
    var description: String { get }

    /// `arguments` is the parsed JSON object from the model's `"arguments"` field. Never
    /// throws for a missing/malformed argument -- returns a plain-English error string instead,
    /// since that string becomes the next turn's prompt and the model needs to be able to read
    /// and react to it.
    func execute(arguments: [String: Any]) -> String

    /// The tool's arguments as a schema, for native tool calling (Docs/18 M3.5), where the model
    /// sees them through its chat template instead of `description`'s inline JSON shape.
    var parameters: [AgentToolParameter] { get }
}

extension AgentTool {
    /// No declared arguments -- only tools offered to `NativeToolLoop` need a real list.
    public var parameters: [AgentToolParameter] { [] }
}

/// One required string argument of an `AgentTool` (every `QueryEngineTools` argument is one).
public struct AgentToolParameter: Equatable, Sendable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}
