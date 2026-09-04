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
}
