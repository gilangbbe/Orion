import Foundation

/// Docs/14_phase4_5_ui_ux_redesign.md §4.8/§8 M7 / §7 Decision 3: this phase deliberately
/// designed the frontend before the backend for Teaching Mode -- "the system evaluates conceptual
/// understanding, not wording similarity" (Docs/05 §7) is itself a real agent-design problem
/// (almost certainly a new prompt/schema, plus persistence for a developer's per-component
/// learning history over time), entirely unscoped by this phase. `TeachingView` renders this
/// fixed scenario -- the prototype's own "TokenManager vs. SessionManager" example -- so the
/// *shape* of Docs/05 Stage 7's Explain -> Question -> Answer -> Evaluation -> Correction ->
/// Transfer loop is validated, not because any grading here is real.
struct TeachingSample {
    let explain: String
    let question: String
    let evaluationVerdict: String
    let evaluationBody: String
    let correction: String
    let transferProblem: String

    static let tokenManagerVsSessionManager = TeachingSample(
        explain:
            "Both TokenManager and SessionManager live inside Authentication, but they act at "
            + "different layers of the login lifecycle.",
        question: "Explain the difference between TokenManager and SessionManager.",
        evaluationVerdict: "Partially Correct",
        evaluationBody:
            "You correctly identified that TokenManager handles refresh and expiry. You didn't "
            + "mention that SessionManager owns the higher-level session lifecycle — including "
            + "the hand-off to SessionStore. They aren't interchangeable.",
        correction:
            "TokenManager is a narrow, stateless helper: it refreshes and validates auth tokens. "
            + "SessionManager is the broader owner of an active session's lifecycle, and now "
            + "delegates persistence to SessionStore.",
        transferProblem:
            "If SessionStore were removed tomorrow, which component would need to change first — "
            + "and why?")
}
