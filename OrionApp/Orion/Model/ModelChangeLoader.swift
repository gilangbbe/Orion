import Foundation
import OrionCodeIntel

/// Docs/16_phase6_continuous_model_updates.md §8, M5: builds `ModelChangeSummary` cards from the
/// real `model_revisions`/`model_revision_entries` rows `RevisionDiffer` writes (Docs/16 §4) --
/// replacing `ModelChangeSample`'s fixed sample data now that the backend Docs/14 §7 Decision 3
/// deferred actually exists. Pure logic, no SwiftUI -- unit-testable without rendering anything,
/// the same discipline `ArchitectureModelLoader`/`ComponentDetailLoader` already follow.
enum ModelChangeLoader {
    static func load(outputDirectory: URL) throws -> [ModelChangeSummary] {
        let store = CodebaseModelStore(outputDirectory: outputDirectory)
        guard let run = try store.latestRun() else { return [] }
        let revisions = try store.modelRevisions(repositoryId: run.repositoryId)
        return try revisions.flatMap { revision -> [ModelChangeSummary] in
            let entries = try store.modelRevisionEntries(modelRevisionId: revision.id)
            return summaries(revision: revision, entries: entries)
        }
    }

    /// A count of `model_revisions` rows that actually produce a visible card (>= 1
    /// `model_revision_entries` row) -- **not** a bare `model_revisions` row count. Real bug found
    /// live: a repository with real pre-Phase-6 history has one coarse, entry-less
    /// `model_revisions` row per old investigation (Phase 2/3's own unconditional-write behavior,
    /// same shape `orion-index revisions --backfill` exists to fill in, Docs/16 §11 M6) --
    /// `load()` correctly renders zero cards for those (empty `entries` -> `summaries` returns
    /// nothing), but a bare row count still counted every one of them, so the sidebar's badge
    /// could read e.g. "50" while the Model Changes screen itself showed "No model changes yet."
    /// Not merely a cosmetic mismatch: on the real vendored-Starlette database this was the entire
    /// count before `--backfill` ever ran on it. `Store.modelRevisionEntries` is a real DB read
    /// per revision, but at this project's real scale (dozens to low hundreds of revisions per
    /// repository) that's the same "correctness over cleverness" trade-off already made throughout
    /// this codebase (e.g. `ComponentDetailQuery`'s own per-symbol lookups).
    static func revisionCount(outputDirectory: URL) throws -> Int {
        let store = CodebaseModelStore(outputDirectory: outputDirectory)
        guard let run = try store.latestRun() else { return 0 }
        var count = 0
        for revision in try store.modelRevisions(repositoryId: run.repositoryId) {
            if try !store.modelRevisionEntries(modelRevisionId: revision.id).isEmpty {
                count += 1
            }
        }
        return count
    }

    /// Docs/16 §8's own instruction: "a removed relationship and its replacement chain render as
    /// one visual entry when they share a component, not four disconnected rows." Groups
    /// `component`/`component_relationship` entries within one revision by the component name
    /// they're about (a relationship's **source** name, per its `subjectLabel`'s own
    /// `"Source -> Target"` shape); `claim`/`uncertainty` entries have no such shared subject, so
    /// each becomes its own standalone card.
    ///
    /// **Real, deliberate scope limit, not a full implementation of "the whole chain as one
    /// card"**: grouping is by *source* only, so a genuinely multi-hop replacement chain (e.g.
    /// Docs/05 Stage 6's own `AuthService -> SessionManager -> SessionStore -> Keychain`) still
    /// splits into one card per distinct source node (`AuthService`, `SessionManager`,
    /// `SessionStore`) rather than a single unified "this whole path changed" card — a full
    /// connected-chain grouping would need tracing shared endpoints transitively (a small
    /// union-find over the revision's edges), which this milestone didn't build. What's here
    /// still satisfies the concrete case the plan named directly (a removed edge grouped with the
    /// new edge sharing its own source), just not every deeper chain shape.
    static func summaries(
        revision: ModelRevisionRecord, entries: [ModelRevisionEntryRecord]
    ) -> [ModelChangeSummary] {
        let when = relativeTime(revision.createdAt)

        var componentGroups: [String: [ModelRevisionEntryRecord]] = [:]
        var standalone: [ModelRevisionEntryRecord] = []

        for entry in entries {
            switch entry.entityType {
            case ModelRevisionEntityType.component.rawValue:
                componentGroups[entry.subjectLabel, default: []].append(entry)
            case ModelRevisionEntityType.componentRelationship.rawValue:
                let componentName =
                    entry.subjectLabel.components(separatedBy: " -> ").first ?? entry.subjectLabel
                componentGroups[componentName, default: []].append(entry)
            default:
                standalone.append(entry)
            }
        }

        var result: [ModelChangeSummary] = []
        for (component, group) in componentGroups.sorted(by: { $0.key < $1.key }) {
            result.append(
                card(
                    id: "\(revision.id)-\(component)", title: component, when: when, entries: group))
        }
        for entry in standalone {
            result.append(
                card(
                    id: "\(revision.id)-\(entry.id)", title: standaloneTitle(entry), when: when,
                    entries: [entry]))
        }
        return result
    }

    /// A short, scannable row title -- e.g. "Claim reversed", "Open question no longer raised".
    /// The generic "Claim" / "Open question" the redesign (§12) replaced read identically down a
    /// list of dozens of entries; the change type is the one thing that actually distinguishes
    /// them at a glance.
    private static func standaloneTitle(_ entry: ModelRevisionEntryRecord) -> String {
        let isUncertainty = entry.entityType == ModelRevisionEntityType.uncertainty.rawValue
        let noun = isUncertainty ? "Open question" : "Claim"
        let verb: String
        switch entry.changeType {
        case ModelRevisionChangeType.added.rawValue:
            verb = isUncertainty ? "raised" : "added"
        case ModelRevisionChangeType.modified.rawValue:
            verb = "refined"
        case ModelRevisionChangeType.reversed.rawValue:
            verb = "reversed"
        case ModelRevisionChangeType.carriedOver.rawValue:
            verb = "carried over"
        case ModelRevisionChangeType.addressed.rawValue:
            verb = "possibly addressed"
        case ModelRevisionChangeType.noLongerRaised.rawValue:
            verb = "no longer raised"
        default:
            verb = "changed"
        }
        return "\(noun) \(verb)"
    }

    private static func card(
        id: String, title: String, when: String, entries: [ModelRevisionEntryRecord]
    ) -> ModelChangeSummary {
        let before = entries.compactMap(beforeText).joined(separator: "\n")
        let after = entries.compactMap(afterText).joined(separator: "\n")
        let reason = entries.map(\.reason).joined(separator: " ")
        return ModelChangeSummary(
            id: id, title: title, when: when, before: before.isEmpty ? "—" : before,
            after: after.isEmpty ? "—" : after, reason: reason)
    }

    /// Prefer the full text from the state snapshot (`statement` for a claim, `label`/`name` for a
    /// component/relationship) over `subjectLabel` (a 120-char excerpt, Docs/16 §2) so the detail
    /// pane reads as a complete sentence rather than trailing off mid-word -- `decodedStatement`
    /// falls back to `subjectLabel` for any shape it doesn't recognize, or when a snapshot is
    /// absent (uncertainty entries carry no state JSON, so those still show the excerpt).
    private static func beforeText(for entry: ModelRevisionEntryRecord) -> String? {
        switch entry.changeType {
        case ModelRevisionChangeType.removed.rawValue,
            ModelRevisionChangeType.modified.rawValue, ModelRevisionChangeType.reversed.rawValue:
            return decodedStatement(entry.previousStateJson) ?? entry.subjectLabel
        case ModelRevisionChangeType.carriedOver.rawValue, ModelRevisionChangeType.addressed.rawValue,
            ModelRevisionChangeType.noLongerRaised.rawValue:
            return entry.subjectLabel
        default:
            return nil  // .added has nothing to show as "before"
        }
    }

    private static func afterText(for entry: ModelRevisionEntryRecord) -> String? {
        switch entry.changeType {
        case ModelRevisionChangeType.added.rawValue, ModelRevisionChangeType.modified.rawValue,
            ModelRevisionChangeType.reversed.rawValue:
            return decodedStatement(entry.newStateJson) ?? entry.subjectLabel
        case ModelRevisionChangeType.addressed.rawValue:
            return "Possibly addressed (see reason)"
        default:
            return nil  // .removed/.carriedOver/.noLongerRaised have nothing new to show
        }
    }

    /// Best-effort extraction of a `statement`/`description`/`label`/`name` field out of the
    /// embedded JSON snapshot -- never crashes or throws on a shape it doesn't recognize, per
    /// EXPORT.md's own "embedded JSON text, not further decoded" framing; this is a display-only
    /// convenience on top of that, not a promise every snapshot shape is handled.
    private static func decodedStatement(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["statement"] as? String) ?? (object["description"] as? String)
            ?? (object["label"] as? String) ?? (object["name"] as? String)
    }

    private static func relativeTime(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
