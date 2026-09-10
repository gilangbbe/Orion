import Foundation
import GRDB

/// Phase 6 persisted record (`v5_phase6_schema`). See
/// `Docs/16_phase6_continuous_model_updates.md` §2 "Schema". `RevisionDiffer` (§4, not yet built
/// as of M0) is this table's only writer — M0 exists purely to give the schema a typed shape
/// ahead of that logic, the same "types exist from M0" precedent Docs/11 M0 set for
/// `ComponentRecord`/`ClaimRecord` before Phase 2's own importer landed in M2.
///
/// One structured diff fact within a `model_revisions` row: one component added/removed/
/// modified, one `component_relationship` added/removed, one claim added/modified/reversed, or
/// one uncertainty added/carried-over/addressed/no-longer-raised (§4/§5). A `model_revisions` row
/// with `n` real changes has `n` of these underneath it, not one blob.
///
/// `previousStateJson`/`newStateJson` are small, denormalized snapshots captured once, at write
/// time — not a general-purpose history mechanism, and not a second source of truth: the current
/// state always still lives on the `components`/`component_relationships`/`claims` row itself
/// (§2's own "no new snapshot table" reasoning). Both are plain JSON text, not a typed column,
/// since each `entityType` snapshots a different shape.
///
/// `relatedClaimId` is §5's "possibly addressed by" hedge link — nullable, `ON DELETE SET NULL`
/// so deleting the claim it points at doesn't take the historical entry down with it (the entry
/// itself, and its `reason` text, stays meaningful even once the claim it once pointed at is
/// gone).
public struct ModelRevisionEntryRecord: OrionRecord {
    public static let databaseTableName = "model_revision_entries"

    public var id: String
    public var modelRevisionId: String
    public var entityType: String          // ModelRevisionEntityType
    public var changeType: String          // ModelRevisionChangeType
    public var subjectLabel: String
    public var previousStateJson: String?
    public var newStateJson: String?
    public var reason: String
    public var confidenceTier: String?     // ConfidenceTier, when the underlying entity has one
    public var relatedClaimId: String?
    public var createdAt: String
}
