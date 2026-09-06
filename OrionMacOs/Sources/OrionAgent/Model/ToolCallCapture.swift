/// Trivial acknowledgement returned to the model after it calls a structured-output tool via
/// `Qwen3Agent.collectStructuredCall` — the agent only cares about the call's *arguments*, not
/// a real result, so every such tool "returns" this.
public struct ToolAck: Codable, Sendable {}

/// Thread-safe one-shot box for the first structured tool call `collectStructuredCall`
/// receives. An `actor` because `ChatSession.toolDispatch` is `@Sendable`; only the first call
/// is kept in case the model calls the tool more than once.
actor CapturedValue<T: Sendable> {
    private(set) var value: T?
    func set(_ newValue: T) {
        if value == nil { value = newValue }
    }
}
