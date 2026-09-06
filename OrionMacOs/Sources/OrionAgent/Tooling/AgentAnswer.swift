/// One tool call the `ActionLoop` actually executed.
public struct ExecutedToolCall: Equatable, Sendable {
    public let turnIndex: Int
    public let toolName: String
    public let argumentsDescription: String
    public let result: String
}

/// The `ActionLoop`'s output. `epistemicType` is coarse by design for M2 -- the loop
/// distinguishes "quoted from a tool result" from "the model's own synthesis" at the
/// whole-answer level, not per-sentence claim decomposition (that's an M3/M4-scale concern once
/// answers are persisted as `claims`/`evidence` rows against a real investigation). Per
/// [04_codebase_mental_model.md](../../../../Docs/04_codebase_mental_model.md): the final text
/// is always the model's synthesis, so it is `INTERPRETATION`, never `FACT`, even when it
/// closely paraphrases a tool result -- the individual `toolCalls[].result` strings are the
/// `FACT`-tier material it was built from.
public struct AgentAnswer: Equatable, Sendable {
    public let text: String
    public let toolCalls: [ExecutedToolCall]

    /// `true` when the budget ran out before the model volunteered `{"action": "answer"}`, or
    /// the model's final turn wasn't parseable JSON at all -- the answer is what was available,
    /// not necessarily complete.
    public let partial: Bool
}
