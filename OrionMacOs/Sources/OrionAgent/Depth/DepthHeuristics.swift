import Foundation

/// Explicit, cheap rule matching for the depth shapes
/// [03_agent_and_model_routing.md](../../../../Docs/03_agent_and_model_routing.md) §2 gives by
/// example — "start with explicit rules rather than a fully autonomous router" (§3). Returns
/// `nil` when nothing matches confidently; the caller (`DepthModel`) falls back to a
/// model-backed classifier in that case.
public enum DepthHeuristics {

    private struct Pattern {
        let regex: NSRegularExpression
        let depth: Int
        let intent: String
    }

    private static func pattern(_ raw: String, depth: Int, intent: String) -> Pattern {
        // Fixed, developer-authored patterns, never runtime input -- a bad regex here is a
        // build-time bug (caught by the unit tests below), not a runtime failure to guard.
        Pattern(
            regex: try! NSRegularExpression(pattern: raw, options: [.caseInsensitive]),
            depth: depth, intent: intent)
    }

    /// Ordered so a more specific pattern (e.g. "which components depend on") is tried before
    /// a more general one that could otherwise shadow it.
    private static let patterns: [Pattern] = [
        // L1 -- Docs/03 §2: "What does `AuthService` do?", "What is the responsibility of
        // this class?", "Which files belong to this component?"
        pattern(#"\bwhat does\b.*\bdo\b\??\s*$"#, depth: 1, intent: "component_purpose"),
        pattern(#"\bresponsibilit(y|ies)\s+of\b"#, depth: 1, intent: "component_purpose"),
        pattern(#"\bwhich files\b.*\bbelong(s)?\s+to\b"#, depth: 1, intent: "component_membership"),

        // L2 -- Docs/03 §2: "Which components depend on `AuthService`?", "Where is this data
        // persisted?", "What tests cover this component?"
        pattern(#"\bwhich components?\b.*\bdepend(s)?\s+on\b"#, depth: 2, intent: "dependency_lookup"),
        pattern(#"\bwhere is\b.*\bpersisted\b"#, depth: 2, intent: "persistence_lookup"),
        pattern(#"\bwhat tests?\b.*\bcover(s)?\b"#, depth: 2, intent: "test_lookup"),
        pattern(#"\b(who|what)\s+calls\b"#, depth: 2, intent: "caller_lookup"),
    ]

    /// Returns a high-confidence `DepthDecision` if `question` matches an explicit rule, else
    /// `nil`.
    public static func classify(_ question: String) -> DepthDecision? {
        let range = NSRange(question.startIndex..., in: question)
        for candidate in patterns {
            if candidate.regex.firstMatch(in: question, options: [], range: range) != nil {
                return DepthDecision(
                    depth: candidate.depth, intent: candidate.intent, confidence: .high,
                    rationale:
                        "Matched explicit depth-\(candidate.depth) rule for \"\(candidate.intent)\".",
                    method: .heuristic
                )
            }
        }
        return nil
    }
}
