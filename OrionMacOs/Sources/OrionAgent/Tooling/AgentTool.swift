/// A deterministic, read-only capability the `ActionLoop` can execute on the model's behalf.
///
/// Deliberately **not** `MLXLMCommon.Tool<Input,Output>` — Docs/12_phase3_mlx_agent.md Risk #3:
/// the model never calls these directly through a native tool-calling format (confirmed broken
/// on `Qwen3-8B`). `ActionLoop` parses the model's own JSON action decision and calls
/// `execute(arguments:)` itself, so a tool here is just a plain, synchronous, in-process
/// function wrapping `OrionCodeIntel`'s `QueryEngine`/`Store` — no schema type, no macro.
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
}
