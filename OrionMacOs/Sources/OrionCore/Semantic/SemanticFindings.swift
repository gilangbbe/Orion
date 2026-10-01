import Foundation

/// Version tag for the Claude Code structured-output contract. A candidate whose
/// `schema_version` doesn't match is rejected outright — Docs/06 §4: "the exact schema should
/// be versioned."
public enum SemanticSchema {
    public static let currentVersion = "phase2.v1"
}

/// The subset of `EpistemicType` Claude is allowed to self-report on a claim. `FACT` is
/// reserved for Phase 1's deterministic output; `CONTRADICTED` is a verdict the Swift-side
/// consistency check assigns (M2), never something Claude tags itself.
public enum SemanticClaimType: String, Decodable, Sendable, CaseIterable {
    case interpretation = "INTERPRETATION"
    case inference = "INFERENCE"
    case unknown = "UNKNOWN"
}

/// The untrusted, not-yet-verified candidate JSON handed to `ingest-semantic` — the output of
/// one Claude Code CLI investigation. See
/// `Docs/11_phase2_semantic_analysis.md` "Structured output contract". Nothing in this type is
/// assumed true; `SemanticImporter` is what earns that.
public struct SemanticFindings: Decodable, Sendable {
    public var schemaVersion: String
    public var components: [SemanticComponentInput]
    public var componentRelationships: [SemanticComponentRelationshipInput]
    public var claims: [SemanticClaimInput]
    public var uncertainties: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case components
        case componentRelationships = "component_relationships"
        case claims
        case uncertainties
    }
}

public struct SemanticComponentInput: Decodable, Sendable {
    public var name: String
    public var description: String?
    public var architecturalRole: String?
    /// Anchors, benchmark form (`<path>::<Dotted.Name>`) — the same join key Phase 1 exports.
    public var members: [String]

    enum CodingKeys: String, CodingKey {
        case name, description, members
        case architecturalRole = "architectural_role"
    }
}

public struct SemanticComponentRelationshipInput: Decodable, Sendable {
    public var source: String    // component name
    public var target: String    // component name
    public var type: String      // RelationshipType, e.g. "depends_on"
}

public struct SemanticClaimInput: Decodable, Sendable {
    public var claimType: SemanticClaimType
    public var statement: String
    /// Anchors, benchmark form — resolved against `symbols.anchor` for the target run.
    public var evidence: [String]
    public var confidence: String   // ConfidenceTier raw value

    enum CodingKeys: String, CodingKey {
        case claimType = "claim_type"
        case statement, evidence, confidence
    }
}

/// Operational metadata about the Claude Code CLI investigation that produced a candidate,
/// written by `harness/orion_eval/semantic/investigate.py`'s `cmd_investigate` as a small
/// sidecar `investigation_meta.json` next to the candidate. Deliberately not the CLI's own
/// `claude --output-format json` wrapper (an internal, evolving shape) — Python already parses
/// that into exactly these fields, so Swift only ever depends on this small, versioned-by-us
/// shape. All fields optional: `ingest-semantic` works without `--meta` too.
public struct InvestigationMeta: Decodable, Sendable {
    public var modelUsed: String?
    public var sessionId: String?
    public var numTurns: Int?
    public var totalCostUsd: Double?
    public var durationMs: Double?
    public var toolsUsed: [String]?

    /// Explicit, since the auto-synthesized memberwise initializer for a `Decodable` struct is
    /// only `internal` by default — invisible outside `OrionCodeIntel`. Needed by
    /// `OrionAgent`'s `ClaudeCodeInvestigationResult.investigationMeta` (Phase 3 M3), which
    /// builds one directly from a live CLI result rather than decoding it from Phase 2's
    /// sidecar JSON file.
    public init(
        modelUsed: String? = nil, sessionId: String? = nil, numTurns: Int? = nil,
        totalCostUsd: Double? = nil, durationMs: Double? = nil, toolsUsed: [String]? = nil
    ) {
        self.modelUsed = modelUsed
        self.sessionId = sessionId
        self.numTurns = numTurns
        self.totalCostUsd = totalCostUsd
        self.durationMs = durationMs
        self.toolsUsed = toolsUsed
    }

    enum CodingKeys: String, CodingKey {
        case modelUsed = "model_used"
        case sessionId = "session_id"
        case numTurns = "num_turns"
        case totalCostUsd = "total_cost_usd"
        case durationMs = "duration_ms"
        case toolsUsed = "tools_used"
    }
}
