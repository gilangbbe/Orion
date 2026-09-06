import MLXLMCommon

/// One turn of a stateful, multi-turn conversation -- just enough surface for `ActionLoop` to
/// drive its manual JSON-action loop (Docs/12 "Local execution & tool loop"). A protocol rather
/// than a hard dependency on `ChatSession` so `ActionLoop`'s state-machine logic (JSON
/// extraction, budget tracking, tool dispatch) is unit-testable with a scripted stub -- no live
/// model, no MLX/Metal build requirement for that test suite.
public protocol TurnGenerating {
    func respond(to message: String) async throws -> String
}

extension ChatSession: TurnGenerating {
    public func respond(to message: String) async throws -> String {
        try await respond(to: message, role: .user, image: nil, video: nil, audio: nil)
    }
}
