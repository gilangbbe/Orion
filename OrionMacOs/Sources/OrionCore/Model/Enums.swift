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

/// What kind of entity one `model_revision_entries` row describes (Docs/16 §2).
public enum ModelRevisionEntityType: String, Codable, Sendable, CaseIterable {
    case component
    case componentRelationship = "component_relationship"
    case claim
    case uncertainty
}

/// What changed, from one investigation to the next, for one `model_revision_entries` row
/// (Docs/16 §2/§4/§5). `.reversed` is a revision-level concept — two claims across investigations
/// whose evidence overlaps but whose structural verdicts disagree — not a sixth `EpistemicType`
/// (Docs/16 Decision #5: the Docs/04 vocabulary stays closed). `.carriedOver`/`.addressed`/
/// `.noLongerRaised` only ever apply to `.uncertainty` entries (Docs/16 §5); `.added`/`.removed`/
/// `.modified` apply to any entity type.
public enum ModelRevisionChangeType: String, Codable, Sendable, CaseIterable {
    case added
    case removed
    case modified
    case reversed
    case carriedOver = "carried_over"
    case addressed
    case noLongerRaised = "no_longer_raised"
}

// MARK: - Phase 7 — Teaching Mode (Docs/17 §9)

/// What Codebase-Model row a `teaching_concepts` row was derived from (Docs/17 §5). The
/// `difficulty_band` seed rises with the structure's hop-count: a single `component`/`claim` is
/// recall (band 1), a `relationship`/`role` is comprehension (band 2), a multi-hop `dataflow` is
/// transfer (band 3).
public enum TeachingConceptKind: String, Codable, Sendable, CaseIterable {
    case component
    case claim
    case relationship
    case role
    case dataflow
}

/// A `teaching_rubric_criteria` row's role in scoring (Docs/17 §6.1/§7.3). `required` criteria
/// form the score denominator; `bonus` criteria add a capped margin; `anti` criteria are the
/// misconception detectors — an `anti` judged *met* means the wrong mental model is present.
public enum RubricCriterionKind: String, Codable, Sendable, CaseIterable {
    case required
    case bonus
    case anti
}

/// Which model produced a `teaching_questions` row (Docs/17 §6.2). Band 1–2 generation runs on
/// the local Qwen3-8B; band 3 (multi-hop / change-impact) delegates to Claude Code.
public enum TeachingQuestionSource: String, Codable, Sendable, CaseIterable {
    case local
    case claudeCode = "claude_code"
    /// Drafted on the iOS companion by the on-device system model (Docs/19). Also how a snapshot
    /// re-import tells the phone's own questions from ones the Mac shipped (M3 carry-over).
    case device
}

/// A `teaching_attempts.verdict_tier` — a fixed threshold band over the **derived** score
/// (Docs/17 §7.3), never asked of a model. `off-track` is also forced when an `anti` criterion is
/// tripped alongside two or more missed `required` criteria.
public enum TeachingVerdictTier: String, Codable, Sendable, CaseIterable {
    case solid
    case partial
    case shaky
    case offTrack = "off-track"
}

/// The per-criterion grader's own confidence in one `teaching_criterion_results` row (Docs/17
/// §7.1). A split k=3 self-consistency vote forces `low`, which excludes the criterion from the
/// score denominator and surfaces it as "needs review" rather than counting it either way.
public enum GraderConfidence: String, Codable, Sendable, CaseIterable {
    case high
    case medium
    case low
}

/// A `knowledge_states.confidence_band` — a coarse display band over the probabilistic
/// `p_mastered` estimate (Docs/17 §2.5/§8.2). Deliberately not a percentage: a mastery estimate
/// from a handful of questions is low-precision, and the band stays `new` until at least two
/// attempts regardless of `p_mastered`.
public enum KnowledgeConfidenceBand: String, Codable, Sendable, CaseIterable {
    case new
    case shaky
    case developing
    case solid
}
