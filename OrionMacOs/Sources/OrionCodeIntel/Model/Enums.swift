import Foundation

/// Epistemic classification from `Docs/04_codebase_mental_model.md` (resolved open question
/// #5 — this vocabulary wins over the harness `schema.py` set). Phase 1 only ever emits
/// `.fact`; the other cases exist for Phase 2 semantic claims.
public enum EpistemicType: String, Codable, Sendable, CaseIterable {
    case fact = "FACT"
    case interpretation = "INTERPRETATION"
    case inference = "INFERENCE"
    case unknown = "UNKNOWN"
    case contradicted = "CONTRADICTED"
}

/// Kind of a structural symbol.
public enum SymbolKind: String, Codable, Sendable, CaseIterable {
    case module
    case package
    case `class`
    case function
    case method
    case property
    case variable
    case constant
    case parameter
    case importAlias = "import_alias"
    /// Synthetic symbol on an exporting module for a static `__all__` entry or
    /// `from .x import y` re-export; `redirectsTo` points at the real definition.
    case reexport
}

/// Edge types in the Code Graph. Mirrors `Docs/07_data_models.md` plus `references`.
public enum RelationshipType: String, Codable, Sendable, CaseIterable {
    case calls
    case dependsOn = "depends_on"
    case imports
    case implements
    case `extends`
    case reads
    case writes
    case references
    case testedBy = "tested_by"
    case partOf = "part_of"
}

/// Coarse confidence bucket for a relationship edge. Numeric `confidence` is derived from
/// this (`high` = 0.9, `medium` = 0.6, `low` = 0.3, `unresolved` = 0.1).
public enum ConfidenceTier: String, Codable, Sendable, CaseIterable {
    case high
    case medium
    case low
    case unresolved

    public var score: Double {
        switch self {
        case .high: return 0.9
        case .medium: return 0.6
        case .low: return 0.3
        case .unresolved: return 0.1
        }
    }

    /// The tier whose fixed `score` exactly matches `score`, or `nil` if none does (a value
    /// that never came from `ConfidenceTier.score` in the first place).
    public static func matching(score: Double) -> ConfidenceTier? {
        allCases.first { $0.score == score }
    }

    /// A display label for a raw confidence score — the tier name when it exactly matches one
    /// of the four fixed scores, else the score itself formatted to two decimal places. Moved
    /// here from `OrionApp`'s `ConfidenceBadge.tierLabel(forScore:)` (Docs/15 §11 M2) so
    /// `ComponentDetailQuery`/session context-priming logic can use the same mapping without
    /// depending on a SwiftUI view type — `ClaimRecord.confidence` is stored as a bare `Double`
    /// score, unlike `ComponentRecord`/`ComponentRelationshipRecord`, which keep the tier string
    /// alongside it.
    public static func label(forScore score: Double) -> String {
        matching(score: score)?.rawValue ?? String(format: "%.2f", score)
    }
}

/// Outcome of one Claude Code investigation, recorded on `investigations.outcome`. Never
/// present a `rejected`/`incomplete`/`unverified` investigation's findings as fact-tier —
/// `Docs/06_claude_code_integration.md` §7.
///
/// `declined` (Phase 5, Docs/15 §3.3) is a distinct, additive case: a question the guardrail
/// judged unrelated to the analyzed repository, never routed to a local or Claude investigation
/// at all. Unlike `rejected`/`unverified`/`incomplete`, a `declined` outcome is a *correct,
/// complete* result, not a failure — it must not be grouped with those three by anything that
/// treats them as "something went wrong" (e.g. `AskCommand`'s `failedDelegation` check).
public enum InvestigationOutcome: String, Codable, Sendable, CaseIterable {
    case verified
    case partiallyVerified = "partially_verified"
    case unverified
    case incomplete
    case rejected
    case declined
}

/// A symbol's role within a component it is a member of (`component_members.role`).
public enum ComponentMemberRole: String, Codable, Sendable, CaseIterable {
    case core
    case supporting
}

/// What an `ask_sessions` row is scoped to (Docs/15 §4.1/§4.2) — `.component` sessions carry a
/// non-null `component_id`, `.repository` sessions don't.
public enum AskSessionScope: String, Codable, Sendable, CaseIterable {
    case repository
    case component
}
