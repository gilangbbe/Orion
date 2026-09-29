/// One turn of a stateful, multi-turn conversation -- the plain-chat surface depth 1 answers
/// through (Docs/18 M6; depth 2 uses `ToolCallingTurnGenerating`). A protocol so `AgentSession`'s
/// orchestration is testable with a scripted stub, no live model.
public protocol TurnGenerating {
    func respond(to message: String) async throws -> String
}
