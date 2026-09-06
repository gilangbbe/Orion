import Foundation

/// Version tag + JSON-Schema contract for Phase 3's Claude delegation (L3) —
/// `Docs/12_phase3_mlx_agent.md` "Claude delegation (L3)". Narrower than Phase 2's
/// `SEMANTIC_SCHEMA`/`SemanticSchema`: an L3 investigation answers **one question**, not a
/// whole-repo component decomposition, so there is no `components`/`component_relationships`
/// here at all.
public enum AgentAnswerSchema {
    public static let currentVersion = "phase3.v1"

    /// For the `claude --json-schema` CLI flag. Deliberately no `$schema` key — Phase 2 (M1)
    /// found the CLI's offline validator doesn't have the 2020-12 meta-schema registered and
    /// rejects the request outright if `$schema` names it explicitly. Every keyword used here
    /// (type/required/additionalProperties/properties/const/enum/minLength) is unchanged across
    /// drafts, so omitting the dialect declaration doesn't change what's accepted.
    public static func cliJSONSchema() -> [String: Any] {
        [
            "type": "object",
            "required": ["schema_version", "answer", "claims", "uncertainties"],
            "additionalProperties": false,
            "properties": [
                "schema_version": ["const": currentVersion],
                // minLength 20, not just 1 -- found live (Docs/12 M5): a real investigation
                // twice produced the schema-conformant but degenerate answer "test" despite
                // real turns/cost. A length floor turns that into a loud, retried schema
                // failure on the CLI's own side instead of a silently accepted non-answer.
                "answer": ["type": "string", "minLength": 20],
                "claims": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "required": ["claim_type", "statement", "evidence", "confidence"],
                        "additionalProperties": false,
                        "properties": [
                            // FACT and CONTRADICTED are deliberately absent -- Claude never
                            // self-tags either (Docs/11: FACT is Phase 1's, CONTRADICTED is a
                            // Swift-side verdict).
                            "claim_type": ["enum": ["INTERPRETATION", "INFERENCE", "UNKNOWN"]],
                            "statement": ["type": "string", "minLength": 1],
                            "evidence": [
                                "type": "array", "items": ["type": "string", "minLength": 1],
                            ],
                            "confidence": ["enum": ["high", "medium", "low", "unresolved"]],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "uncertainties": [
                    "type": "array", "items": ["type": "string", "minLength": 1],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    /// A human-readable shape hint given to the model in its prompt — mirrors Phase 2's
    /// `SCHEMA_HINT`.
    public static let promptHint = """
        {
          "schema_version": "\(currentVersion)",
          "answer": "<prose answer to the developer's question>",
          "claims": [{
            "claim_type": "INTERPRETATION | INFERENCE | UNKNOWN",
            "statement": "<a specific, evidence-backed claim>",
            "evidence": ["<path>::<Dotted.Name>", "..."],
            "confidence": "high | medium | low | unresolved"
          }],
          "uncertainties": ["<something you could not ground in evidence>"]
        }
        """
}

/// The untrusted, not-yet-verified candidate JSON from one L3 (Claude Code) investigation of a
/// single question — the Phase 3 analogue of Phase 2's `SemanticFindings`. Reuses
/// `SemanticClaimInput` directly: the claim shape (`claim_type`/`statement`/`evidence`/
/// `confidence`) is byte-for-byte identical, just without a whole-repo component wrapper around
/// it.
public struct AgentAnswerFindings: Decodable, Sendable {
    public var schemaVersion: String
    public var answer: String
    public var claims: [SemanticClaimInput]
    public var uncertainties: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case answer, claims, uncertainties
    }
}
