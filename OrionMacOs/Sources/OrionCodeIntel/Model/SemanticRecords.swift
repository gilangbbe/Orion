import Foundation
import GRDB

/// Phase 2 persisted records (`v2_phase2_schema`). Written by `SemanticImporter` once a Claude
/// Code candidate has passed schema + evidence validation — see
/// `Docs/11_phase2_semantic_analysis.md` "Validation pipeline". Persistence lands in M2; these
/// types exist from M0 so the schema is fully typed, not just SQL text.

/// One Claude Code investigation over a `(repository, run)`. Always inserted, even when the
/// outcome is `rejected` — a record of the attempt is itself useful (Docs/07 `Investigation`).
public struct InvestigationRecord: OrionRecord, Sendable {
    public static let databaseTableName = "investigations"

    /// The literal `question` marker for a whole-repo architecture (component-grouping)
    /// investigation, as opposed to a real free-form single-question Ask/delegated investigation
    /// sharing this same table. Consolidated here in Phase 6
    /// (`Docs/16_phase6_continuous_model_updates.md` §4) — previously this exact string literal
    /// was independently hardcoded at three call sites (`persistInvestigation`'s own default
    /// parameter here, and `OrionApp`'s `ArchitectureModelLoader.latestArchitectureInvestigation`,
    /// which stays its own independent copy since `OrionApp` is a separate module/target).
    /// `RevisionDiffer` (§4) is the fourth consumer and the reason this got a shared name instead
    /// of a fourth hardcoded copy inside `OrionCodeIntel` itself.
    public static let architectureQuestionMarker = "phase2_semantic_grouping"

    public var id: String
    public var repositoryId: String
    public var commitHash: String
    public var runId: String
    public var question: String
    public var complexity: String
    public var schemaVersion: String?
    public var modelUsed: String?
    public var toolsUsed: [String]
    public var sessionId: String?
    public var numTurns: Int?
    public var totalCostUsd: Double?
    public var durationMs: Double?
    public var outcome: String                // InvestigationOutcome
    public var createdAt: String
    /// The free-text answer this investigation actually produced, when it has one. Added in
    /// Phase 5 (`v4_phase5_schema`, Docs/15 §11 M3) — before this, an investigation's answer
    /// text existed only transiently in `SemanticIngestOutcome.answer`/`AgentSessionResult
    /// .answerText`, never persisted anywhere, which made it impossible to reconstruct a past
    /// turn's answer for a later session's prior-turn context (the actual reason this column
    /// exists). `nil` for `ingest()`'s whole-repo component-grouping investigations (no single
    /// answer to report) and for a decode failure that never produced parseable findings at all;
    /// populated for every `ingestAnswer()` outcome, including a schema-invalid one, since
    /// Claude's own attempted answer is still real, useful context even when it was rejected.
    public var answerText: String?

    /// Explicit, since the auto-synthesized memberwise initializer for a `Decodable`-conforming
    /// struct is only `internal` by default — invisible outside `OrionCodeIntel`. Needed by
    /// `OrionAgent`'s `AgentSession` (Phase 3 M4), which persists a bare investigation row
    /// directly for an L3 timeout/error that never reaches `SemanticImporter.ingestAnswer`'s
    /// own (in-module) construction of one.
    public init(
        id: String, repositoryId: String, commitHash: String, runId: String, question: String,
        complexity: String, schemaVersion: String? = nil, modelUsed: String? = nil,
        toolsUsed: [String] = [], sessionId: String? = nil, numTurns: Int? = nil,
        totalCostUsd: Double? = nil, durationMs: Double? = nil, outcome: String, createdAt: String,
        answerText: String? = nil
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.commitHash = commitHash
        self.runId = runId
        self.question = question
        self.complexity = complexity
        self.schemaVersion = schemaVersion
        self.modelUsed = modelUsed
        self.toolsUsed = toolsUsed
        self.sessionId = sessionId
        self.numTurns = numTurns
        self.totalCostUsd = totalCostUsd
        self.durationMs = durationMs
        self.outcome = outcome
        self.createdAt = createdAt
        self.answerText = answerText
    }
}

/// A semantically-grouped component (Docs/04 §2 "Semantic knowledge"). `epistemicType` is
/// always `INTERPRETATION` — components are never `FACT`.
public struct ComponentRecord: OrionRecord {
    public static let databaseTableName = "components"

    public var id: String
    public var repositoryId: String
    public var commitHash: String
    public var runId: String
    public var investigationId: String
    public var name: String
    public var description: String?
    public var architecturalRole: String?
    public var confidence: Double
    public var confidenceTier: String          // ConfidenceTier
    public var status: String
    public var epistemicType: String           // EpistemicType, always "INTERPRETATION"
    public var provenance: String
}

/// Many-to-many symbol <-> component membership. `symbols.component_id` denormalizes each
/// symbol's single highest-confidence membership for cheap joins; this table is the source of
/// truth (a shared symbol can belong to more than one component).
public struct ComponentMemberRecord: OrionRecord {
    public static let databaseTableName = "component_members"

    public var id: String
    public var componentId: String
    public var symbolId: String
    public var confidence: Double
    public var role: String                    // ComponentMemberRole
}

/// A component-to-component edge (e.g. "Middleware depends_on Routing"). Kept separate from
/// the symbol-scoped `relationships` table so Phase 1's frozen schema/snapshot are untouched.
public struct ComponentRelationshipRecord: OrionRecord {
    public static let databaseTableName = "component_relationships"

    public var id: String
    public var repositoryId: String
    public var commitHash: String
    public var runId: String
    public var investigationId: String
    public var sourceComponentId: String
    public var targetComponentId: String
    public var relationshipType: String         // RelationshipType
    public var confidence: Double
    public var confidenceTier: String
    public var provenance: String
}

/// A claim (Docs/04 §3 / Docs/07 `Claim`). `subjectRef`/`objectRef` are anchors or component
/// names, not hard FKs — claims are interpretive and looser than the structural tables by
/// design. `claimType` is `INTERPRETATION`|`INFERENCE`|`UNKNOWN` as asserted by Claude, or
/// `CONTRADICTED` — a verdict the Swift-side consistency check assigns, never something Claude
/// tags itself. `subjectRef` is the claim's first resolved evidence anchor when it has one (an
/// `uncertainties[]`-derived claim has none, so it is nil there).
public struct ClaimRecord: OrionRecord {
    public static let databaseTableName = "claims"

    public var id: String
    public var repositoryId: String
    public var commitHash: String
    public var runId: String
    public var investigationId: String
    public var subjectRef: String?
    public var predicate: String?
    public var objectRef: String?
    public var statement: String
    public var claimType: String                // EpistemicType subset
    public var confidence: Double
    public var status: String
    public var createdBy: String
}

/// Evidence for one claim (Docs/07 `Evidence`). `symbolId`/`startLine`/`endLine` are copied
/// from the resolved symbol's own range at ingestion time — Claude cites an anchor, not a line
/// range; the range comes from the Code Graph, not from Claude.
public struct EvidenceRecord: OrionRecord {
    public static let databaseTableName = "evidence"

    public var id: String
    public var claimId: String
    public var fileId: String?
    public var symbolId: String?
    public var anchor: String
    public var startLine: Int?
    public var endLine: Int?
    public var evidenceType: String
}

/// A log entry of one semantic-layer update (Docs/07 `ModelRevision`). Phase 2/3 wrote exactly
/// one coarse row per successful ingestion, unconditionally; Phase 6
/// (`Docs/16_phase6_continuous_model_updates.md` §4.1) changes that to "one row only when
/// `RevisionDiffer` actually finds a diff-worthy change" and moves the real structured diff into
/// `model_revision_entries` (`ModelRevisionEntryRecord`) — `changeSummary` stays a short rollup
/// string (e.g. "3 changes: 1 relationship added, 1 claim reversed"), not the diff itself.
public struct ModelRevisionRecord: OrionRecord {
    public static let databaseTableName = "model_revisions"

    public var id: String
    public var repositoryId: String
    public var previousRevision: String?
    public var changeSummary: String
    public var triggeringInvestigationId: String?
    public var createdAt: String
    /// Monotonically increasing per `repositoryId` (Docs/16 §2) — gives Docs/04 §5's "versioned
    /// knowledge state" a literal, displayable number ("Revision 12"), not just a linked list via
    /// `previousRevision`. No separate `commitHash` column: each `repositories` row is already
    /// scoped to one commit via its own `UNIQUE(local_path, commit_hash)`, so `repositoryId`
    /// alone is enough — a deliberate, small simplification against Docs/16 §2's own draft
    /// schema, which had sketched `(repository_id, commit_hash)`; noted here since it's a real
    /// difference from the plan, not silently done. Defaulted to `1` so every pre-Phase-6
    /// construction site (`SemanticImporter`'s two existing writers, `SemanticSchemaTests`) keeps
    /// compiling and behaving unchanged; `RevisionDiffer` (Docs/16 M2) computes the real
    /// incrementing value.
    public var revisionNumber: Int

    /// Explicit, since the auto-synthesized memberwise initializer for a `Decodable`-conforming
    /// struct is only `internal` by default — invisible outside `OrionCodeIntel`. Needed by
    /// `OrionApp`'s own tests once they started constructing a legacy-shaped row directly
    /// (Docs/16 §11 M5/M6's own "entry-less legacy revision" fixtures).
    public init(
        id: String, repositoryId: String, previousRevision: String? = nil, changeSummary: String,
        triggeringInvestigationId: String? = nil, createdAt: String, revisionNumber: Int = 1
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.previousRevision = previousRevision
        self.changeSummary = changeSummary
        self.triggeringInvestigationId = triggeringInvestigationId
        self.createdAt = createdAt
        self.revisionNumber = revisionNumber
    }
}
