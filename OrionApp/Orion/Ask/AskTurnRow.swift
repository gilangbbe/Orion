import Foundation

/// One turn in the currently-selected session's history -- `outcome` is `nil` only for a
/// brand-new turn whose live `AgentSession.ask` call hasn't returned yet (mirrors the pre-Phase-5
/// `AskHistoryEntry.outcome: AskOutcome?`'s pending state, now per-turn instead of per-question).
struct AskTurnRow: Identifiable, Equatable {
    let id: String
    let question: String
    var outcome: AskOutcome?
}
