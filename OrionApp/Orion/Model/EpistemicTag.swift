import SwiftUI

/// Docs/04_codebase_mental_model.md's vocabulary — every knowledge item is classified as one of
/// these five. The one hard UI rule that vocabulary implies ("The UI must not present inference
/// as fact") only actually holds if every screen uses the *same* color/icon/label mapping, not
/// five ad-hoc renderings (Docs/13_phase4_architecture_ui.md M6) — this is that one mapping.
enum EpistemicTag: String, CaseIterable {
    case fact = "FACT"
    case interpretation = "INTERPRETATION"
    case inference = "INFERENCE"
    case unknown = "UNKNOWN"
    case contradicted = "CONTRADICTED"

    /// Tolerant of whatever raw string is actually stored in the database -- falls back to
    /// `.unknown` rather than crashing or, worse, silently defaulting an unrecognized value to
    /// `.fact` and rendering it with unearned confidence.
    static func from(_ rawValue: String) -> EpistemicTag {
        EpistemicTag(rawValue: rawValue.uppercased()) ?? .unknown
    }

    var label: String {
        switch self {
        case .fact: return "Fact"
        case .interpretation: return "Interpretation"
        case .inference: return "Inference"
        case .unknown: return "Unknown"
        case .contradicted: return "Contradicted"
        }
    }

    var systemImage: String {
        switch self {
        case .fact: return "checkmark.seal.fill"
        case .interpretation: return "text.bubble.fill"
        case .inference: return "arrow.triangle.branch"
        case .unknown: return "questionmark.circle.fill"
        case .contradicted: return "exclamationmark.triangle.fill"
        }
    }

    /// `.fact` is the only tier that should ever read as "checked and confident" -- every other
    /// case gets a visually distinct, non-green treatment on purpose. Colors come from
    /// `DesignTokens` (Docs/14_phase4_5_ui_ux_redesign.md §3 / M0) rather than flat system color
    /// names -- same hue families as before (green/purple/indigo/gray/red), tuned per-appearance.
    var color: Color {
        switch self {
        case .fact: return DesignTokens.fact
        case .interpretation: return DesignTokens.interpretation
        case .inference: return DesignTokens.inference
        case .unknown: return DesignTokens.unknown
        case .contradicted: return DesignTokens.contradicted
        }
    }
}
