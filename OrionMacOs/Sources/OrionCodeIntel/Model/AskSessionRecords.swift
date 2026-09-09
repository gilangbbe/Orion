import Foundation
import GRDB

/// Phase 5 persisted records (`v4_phase5_schema`). See
/// `Docs/15_phase5_adaptive_exploration.md` §4.2 "Schema". Additive only — no Phase 1/2/3 table
/// altered.
///
/// A session is a thin, ordered pointer over existing `investigations` rows, not a second
/// transcript store (Docs/15 §4.1) — `AskSessionRecord`/`AskSessionTurnRecord` carry no question/
/// answer text of their own; that already lives on the `InvestigationRecord`/`ClaimRecord`/
/// `EvidenceRecord` each turn points at.

/// One conversational session — scoped to either one component or the whole repository (Docs/15
/// §4.1). `componentId` is non-nil iff `scopeType == .component`; both are enforced at the
/// `Store` call site that creates a session (Docs/15 M3), not by a `CHECK` constraint, matching
/// how the rest of this schema leans on Swift-side construction discipline over SQL constraints
/// for anything beyond uniqueness/FK integrity.
public struct AskSessionRecord: OrionRecord {
    public static let databaseTableName = "ask_sessions"

    public var id: String
    public var repositoryId: String
    public var commitHash: String
    public var scopeType: String        // AskSessionScope ("repository" | "component")
    public var componentId: String?
    public var title: String
    /// The Claude CLI's own session id from the most recent depth-3 turn in this session, for
    /// `--resume` (Docs/15 §4.4). Unrelated to `investigations.session_id`, which captures the
    /// same kind of value per-investigation — see Docs/15 §4.2's naming callout. `nil` until a
    /// depth-3 turn actually happens in this session.
    public var claudeSessionId: String?
    public var turnCount: Int
    public var createdAt: String
    public var lastActiveAt: String

    /// Explicit, since the auto-synthesized memberwise initializer for a `Decodable`-conforming
    /// struct is only `internal` by default — invisible outside `OrionCodeIntel`. Needed by
    /// `OrionAgent`'s `AgentSession` (Phase 5 M3).
    public init(
        id: String, repositoryId: String, commitHash: String, scopeType: String,
        componentId: String? = nil, title: String, claudeSessionId: String? = nil,
        turnCount: Int = 0, createdAt: String, lastActiveAt: String
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.commitHash = commitHash
        self.scopeType = scopeType
        self.componentId = componentId
        self.title = title
        self.claudeSessionId = claudeSessionId
        self.turnCount = turnCount
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}

/// One turn (one question, one `AgentSession.ask` call) within a session — `turnIndex` orders
/// turns within one session (`UNIQUE(session_id, turn_index)`); `investigationId` is the actual
/// question/answer/claims/evidence record, already fully persisted by the same
/// `SemanticImporter.ingestAnswer`/`AgentSession.declineOutOfScope` paths a session-less `ask()`
/// call already uses (Docs/15 §4.1).
public struct AskSessionTurnRecord: OrionRecord {
    public static let databaseTableName = "ask_session_turns"

    public var id: String
    public var sessionId: String
    public var turnIndex: Int
    public var investigationId: String
    public var createdAt: String

    /// Explicit, since the auto-synthesized memberwise initializer for a `Decodable`-conforming
    /// struct is only `internal` by default — invisible outside `OrionCodeIntel`. Needed by
    /// `OrionAgent`'s `AgentSession` (Phase 5 M3).
    public init(
        id: String, sessionId: String, turnIndex: Int, investigationId: String, createdAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.turnIndex = turnIndex
        self.investigationId = investigationId
        self.createdAt = createdAt
    }
}

/// One prior turn's question/answer/outcome, read back for priming a follow-up question's
/// context (Docs/15 §4.3) -- a thin projection over `ask_session_turns` joined to
/// `investigations`, not a new persisted concept of its own. Deliberately the one type both
/// `Store.priorTurns` and `OrionAgent.ContextBuilder` share, rather than a second, duplicate DTO
/// at the `OrionAgent` layer -- `OrionAgent` already depends on `OrionCodeIntel`, so there is no
/// module-boundary reason to re-declare this shape a second time the way `OrionApp`'s
/// `ComponentDetail` DTOs re-declare `ComponentDetailQuery.Detail`'s shape (that boundary exists
/// because the app target can't be depended on by `OrionCodeIntel`; `OrionAgent` has no such
/// restriction here).
public struct AskSessionPriorTurn: Equatable, Sendable {
    public let question: String
    public let answerText: String
    public let outcome: String

    public init(question: String, answerText: String, outcome: String) {
        self.question = question
        self.answerText = answerText
        self.outcome = outcome
    }
}

/// Errors from the session-lifecycle `Store` methods (Docs/15 §4, M3) -- distinct from
/// `AgentSessionError` (`OrionAgent`), which wraps the product-level "no analyzed run" case;
/// these are `OrionCodeIntel`-level persistence/invariant failures.
public enum AskSessionError: Error, CustomStringConvertible, Sendable {
    case sessionNotFound(String)
    /// Docs/15 §4.2: `componentId` non-nil iff `scopeType == .component`, enforced here rather
    /// than by a SQL `CHECK` constraint -- matching how the rest of this schema leans on
    /// Swift-side construction discipline for anything beyond uniqueness/FK integrity.
    case componentRequiredForComponentScope
    case componentNotAllowedForRepositoryScope

    public var description: String {
        switch self {
        case .sessionNotFound(let id):
            return "no ask_sessions row with id \(id)"
        case .componentRequiredForComponentScope:
            return "a component-scoped session requires a non-nil componentId"
        case .componentNotAllowedForRepositoryScope:
            return "a repository-scoped session must not specify a componentId"
        }
    }
}
