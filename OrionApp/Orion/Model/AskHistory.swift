import Foundation
import OrionAgent
import OrionCodeIntel

/// One conversational session, as shown in Ask's session-grouped list.
/// Docs/15_phase5_adaptive_exploration.md M6 promotes this list's unit from "one question"
/// (Docs/14_phase4_5_ui_ux_redesign.md §4.6) to "one session" -- a session's own turn-by-turn
/// history is what used to be this list's entire row set.
struct AskSessionRow: Identifiable, Equatable {
    let id: String
    let title: String
    /// `nil` for a repository-wide session; the resolved component *name* (not just its id) for
    /// a component-scoped one -- resolved once when the session list loads, not re-looked-up per
    /// render.
    let componentName: String?
    /// The real `components` row id backing `componentName`, `nil` for a repository-wide session.
    /// Carried alongside the name (not just derived from it) so a "+" on an existing component
    /// group, or a resumed session, can hand the real id straight to a new sibling session
    /// instead of re-deriving it -- see the fix note on `startSession(forGroupNamed:componentId:)`.
    let componentId: String?
    let turnCount: Int
    let lastActiveAt: Date
}

/// One turn in the currently-selected session's history -- `outcome` is `nil` only for a
/// brand-new turn whose live `AgentSession.ask` call hasn't returned yet (mirrors the pre-Phase-5
/// `AskHistoryEntry.outcome: AskOutcome?`'s pending state, now per-turn instead of per-question).
struct AskTurnRow: Identifiable, Equatable {
    let id: String
    let question: String
    var outcome: AskOutcome?
}

/// Docs/14_phase4_5_ui_ux_redesign.md §8 M4's own reasoning for why this survives navigating away
/// and back (owned by `ContentView`, same lifetime as `AppShellState`, not `AskView`'s local
/// `@State`) is unchanged by this redesign -- only *what* it tracks changed, from individual
/// questions to sessions, because the underlying data now genuinely persists across app launches
/// too (Docs/15 §4), not just across a SwiftUI view's own lifetime.
@Observable
final class AskHistory {
    private(set) var sessions: [AskSessionRow] = []
    var selectedSessionID: String?
    private(set) var turns: [AskTurnRow] = []
    private(set) var loadError: String?

    /// Docs/14 §8 M8.5 item 6's reasoning still holds: which component (if any) the next
    /// deliberate "start a session" action should be scoped to. Unlike before Phase 5, this no
    /// longer scopes an individual question -- there is no such thing as a session-less question
    /// in the redesigned Ask any more (Docs/15 §5) -- it scopes the *session* that gets created
    /// (or resumed, see `askAbout(_:componentId:outputDirectory:)`) next.
    private(set) var pendingScope: String?
    /// The real componentId backing `pendingScope`, set and cleared together with it -- see
    /// `askAbout(_:componentId:outputDirectory:)`. `nil` whenever `pendingScope` names "General"
    /// or is itself `nil`. Both are `private(set)` -- always change together through
    /// `clearPendingScope()` or the methods below, never assigned individually from a view.
    private(set) var pendingComponentId: String?

    private var repositoryId: String?
    private var commitHash: String?

    /// Reloads the session list (and, if one is already selected, its turn history) from the
    /// real, persisted `ask_sessions`/`ask_session_turns` tables -- called whenever the Ask
    /// destination becomes visible and after every new turn, since sessions are genuinely shared,
    /// durable state now (Docs/04 §6), not a UI-local array this class invents on its own.
    func refresh(outputDirectory: URL) async {
        do {
            let store = CodebaseModelStore(outputDirectory: outputDirectory)
            guard let run = try store.latestRun(commitHash: nil) else {
                sessions = []
                return
            }
            repositoryId = run.repositoryId
            commitHash = run.commitHash
            let records = try store.askSessions(repositoryId: run.repositoryId, commitHash: run.commitHash)
            sessions = try records.map { record in
                var componentName: String?
                if let componentId = record.componentId {
                    componentName = try store.component(id: componentId)?.name
                }
                return AskSessionRow(
                    id: record.id, title: record.title, componentName: componentName,
                    componentId: record.componentId, turnCount: record.turnCount,
                    lastActiveAt: Self.parseDate(record.lastActiveAt))
            }
            loadError = nil
            if let selectedSessionID, sessions.contains(where: { $0.id == selectedSessionID }) {
                await loadTurns(sessionId: selectedSessionID, outputDirectory: outputDirectory)
            }
        } catch {
            sessions = []
            loadError = String(describing: error)
        }
    }

    /// The scope chip's "×" -- clears back to "the next session created is General," per
    /// `pendingScope`'s own doc comment. A plain `history.pendingScope = nil` from the view would
    /// leave `pendingComponentId` stale (it's `private(set)` precisely to prevent that): the two
    /// only ever change together.
    func clearPendingScope() {
        pendingScope = nil
        pendingComponentId = nil
    }

    func select(_ sessionId: String, outputDirectory: URL) async {
        selectedSessionID = sessionId
        pendingScope = nil
        pendingComponentId = nil
        await loadTurns(sessionId: sessionId, outputDirectory: outputDirectory)
    }

    private func loadTurns(sessionId: String, outputDirectory: URL) async {
        do {
            let store = CodebaseModelStore(outputDirectory: outputDirectory)
            let records = try store.askSessionTurns(sessionId: sessionId)
            turns = try records.map { turn in
                let (question, summary) = try AskRunner.loadPersistedTurn(
                    investigationId: turn.investigationId, outputDirectory: outputDirectory)
                return AskTurnRow(id: turn.investigationId, question: question, outcome: .answered(summary))
            }
        } catch {
            turns = []
        }
    }

    /// Creates a new session -- the CLI's `Store.createAskSession` (Docs/15 §4.6), called
    /// directly rather than through `CodebaseModelStore` (deliberately read-only, Docs/13 M3),
    /// the same way `SemanticInvestigationRunner`/`AnalysisRunner` already open their own
    /// writable `Store` for their own writes rather than routing through it.
    @discardableResult
    func createSession(
        scopeType: AskSessionScope, componentId: String?, title: String, outputDirectory: URL
    ) async throws -> String {
        let store = Store(try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path))
        guard let run = try store.latestRun(commitHash: nil) else {
            throw AskRunner.PersistedTurnError.investigationNotFound("no analyzed run")
        }
        let session = try store.createAskSession(
            repositoryId: run.repositoryId, commitHash: run.commitHash, scopeType: scopeType,
            componentId: componentId, title: title, now: Timestamp.now())
        await refresh(outputDirectory: outputDirectory)
        return session.id
    }

    /// Docs/15_phase5_adaptive_exploration.md §5 -- the "Ask about X twice" decision finalized in
    /// M5: resumes the most recently active session already scoped to `componentName` if one
    /// exists, else marks the *next* "New session" action as creating one for it (deliberately
    /// does *not* create one immediately here -- the developer still types and submits their own
    /// first question before anything is filed, per Docs/05 Stage 4/5's "the developer can ask
    /// questions," not "the app asks a generic one the moment the button is clicked").
    ///
    /// - Parameter componentId: the real `components` row id, handed straight in by the caller
    ///   (`ComponentDetailView` already has its own `ComponentDetail.id`) rather than re-derived
    ///   here from `componentName` -- a real, live bug this replaced (see
    ///   `startSession(forGroupNamed:componentId:outputDirectory:)`'s own doc comment) tried to
    ///   look this id up from "the run's *latest* investigation," which stops being the
    ///   Build-Architecture-Model investigation the instant any question has ever been asked
    ///   (every `AgentSession.ask` call inserts its own new `investigations` row), silently
    ///   losing the component association for every "Ask about X" after the first one.
    ///
    /// Refreshes from the database first, unconditionally -- a fresh `AskHistory` (or one that
    /// simply hasn't visited the Ask destination yet this launch, since `AskView`'s own
    /// `.task { refresh }` only starts once it's actually in the view hierarchy) must not decide
    /// "no existing session for this component" off a stale or empty in-memory `sessions` array
    /// racing that unrelated `.task`.
    func askAbout(_ componentName: String, componentId: String?, outputDirectory: URL) async {
        await refresh(outputDirectory: outputDirectory)
        if sessions.contains(where: { $0.componentName == componentName }) {
            _ = await resumeOrStartSession(
                forGroupNamed: componentName, componentId: componentId, outputDirectory: outputDirectory)
        } else {
            selectedSessionID = nil
            turns = []
            pendingScope = componentName
            pendingComponentId = componentId
        }
    }

    /// The explicit "+ New session" affordance's job: unconditionally creates one and selects it,
    /// even if a session for `groupName` already exists -- the deliberate fresh-start path,
    /// distinct from `resumeOrStartSession` (below), which prefers resuming.
    ///
    /// - Parameter componentId: `nil` for "General"; otherwise the real `components` row id for
    ///   `groupName`, supplied by the caller (`AskView`'s "+" passes the group's own
    ///   `AskSessionRow.componentId`, already known from an existing sibling session;
    ///   `askAbout`/`submit()`'s fallback pass `pendingComponentId`). This method no longer tries
    ///   to look the id up itself -- see `askAbout(_:componentId:outputDirectory:)`'s doc comment
    ///   for the real bug that produced (a session silently created with `componentId: nil`,
    ///   grouping under "General" instead of the component it was actually asked about).
    @discardableResult
    func startSession(forGroupNamed groupName: String, componentId: String?, outputDirectory: URL) async -> String? {
        do {
            let isGeneral = groupName == "General"
            let title = isGeneral ? "General" : "About \(groupName)"
            let sessionId = try await createSession(
                scopeType: isGeneral ? .repository : .component, componentId: isGeneral ? nil : componentId,
                title: title, outputDirectory: outputDirectory)
            selectedSessionID = sessionId
            turns = []
            pendingScope = nil
            pendingComponentId = nil
            return sessionId
        } catch {
            loadError = String(describing: error)
            return nil
        }
    }

    /// Resolves the session a new question submitted with nothing selected should go to: resumes
    /// the group's most recently active session if one exists, else creates one. Shared by
    /// `askAbout(_:componentId:outputDirectory:)`'s own resume branch and `AskView`'s input bar
    /// (called when nothing is selected and the developer just starts typing a general question)
    /// so both paths implement the identical Docs/15 §5 resume-or-create decision, not two copies
    /// of it.
    @discardableResult
    func resumeOrStartSession(
        forGroupNamed groupName: String, componentId: String?, outputDirectory: URL
    ) async -> String? {
        if let existing = sessions.filter({ ($0.componentName ?? "General") == groupName })
            .max(by: { $0.lastActiveAt < $1.lastActiveAt })
        {
            await select(existing.id, outputDirectory: outputDirectory)
            return existing.id
        }
        return await startSession(forGroupNamed: groupName, componentId: componentId, outputDirectory: outputDirectory)
    }

    /// Appends one turn to the currently-selected session. The caller (`AskView`) is responsible
    /// for having a session selected first (creating one via `createSession` if needed) -- this
    /// mirrors `AgentSession.ask(_:sessionId:)`'s own "never silently creates a session" rule
    /// (Docs/15 §4.5) at the UI layer.
    ///
    /// - Parameter session: injectable for tests, mirroring `AskRunner.ask`'s own seam -- a
    ///   scripted `TurnGenerating` stub via `--force-depth 1`, or a real `AgentSession` pointed
    ///   at a stand-in `claude` script for depth 3.
    func ask(
        _ question: String, repoRoot: URL, outputDirectory: URL, session: AgentSession? = nil
    ) async -> AskOutcome {
        guard let sessionId = selectedSessionID else {
            return .failed("No session selected -- start a session first.")
        }
        let pendingID = UUID().uuidString
        turns.append(AskTurnRow(id: pendingID, question: question, outcome: nil))
        let outcome = await AskRunner.ask(
            question: question, repoRoot: repoRoot, outputDirectory: outputDirectory,
            sessionId: sessionId, session: session)
        if let index = turns.firstIndex(where: { $0.id == pendingID }) {
            turns[index].outcome = outcome
        }
        // Re-derives the full turn list (and session list ordering/turn counts) from what
        // actually persisted -- the pending row above is only ever a same-frame placeholder for
        // immediate feedback, superseded the moment this returns. Except for a decline: it's
        // deliberately never persisted as a session turn (Docs/15 §4.5), so `loadTurns` reloading
        // from the database here would find no trace of it and silently replace `turns` with a
        // list that no longer includes the one just shown -- a real reported bug (the decline
        // "renders ... but it immediately disappears"). The optimistic local turn set above is
        // already correct and is left standing instead.
        if !outcome.isDeclined {
            await refresh(outputDirectory: outputDirectory)
        }
        return outcome
    }

    /// Renames a session (Docs/15 §4.7, M8.5) -- `Store.renameAskSession`, opened writable the
    /// same way `createSession` does (Docs/13 M3: `CodebaseModelStore` stays deliberately
    /// read-only). Reports a failure (a blank title, or a stale id) via `loadError` and returns
    /// `false` rather than throwing -- matching how every other session action in this class
    /// already surfaces its own failures (`startSession`'s catch, `ask`'s no-session `.failed`)
    /// instead of pushing a `throws` up to the view.
    @discardableResult
    func rename(_ sessionId: String, title: String, outputDirectory: URL) async -> Bool {
        do {
            let store = Store(try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path))
            try store.renameAskSession(id: sessionId, title: title)
            await refresh(outputDirectory: outputDirectory)
            return true
        } catch {
            loadError = String(describing: error)
            return false
        }
    }

    /// Deletes a session (Docs/15 §4.7, M8.5) -- `Store.deleteAskSession`, which removes only the
    /// session and its own `ask_session_turns` pointers (cascade); the `investigations` rows
    /// those turns pointed at are deliberately untouched (§4.1/§4.7 -- a session is a thin
    /// pointer, not a duplicate transcript store). If the deleted session was the one currently
    /// selected, clears the selection back to the "Select a session" empty state (§5) rather than
    /// leaving `selectedSessionID` pointing at a row that no longer resolves.
    @discardableResult
    func delete(_ sessionId: String, outputDirectory: URL) async -> Bool {
        do {
            let store = Store(try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path))
            try store.deleteAskSession(id: sessionId)
            if selectedSessionID == sessionId {
                selectedSessionID = nil
                turns = []
            }
            await refresh(outputDirectory: outputDirectory)
            return true
        } catch {
            loadError = String(describing: error)
            return false
        }
    }

    struct Group: Identifiable {
        let name: String
        let sessions: [AskSessionRow]
        var id: String { name }
        /// Every session in one named group shares the same `componentId` (grouping key is the
        /// resolved component *name*) -- `nil` for "General." Lets the "+" on an existing group's
        /// header hand its real componentId straight to a new sibling session instead of
        /// re-deriving one.
        var componentId: String? { sessions.first?.componentId }
    }

    /// Docs/14 §8 M4's own testing plan, carried forward: grouped by component (`nil` ->
    /// "General", sorted alphabetically with "General" always last), filtered by a
    /// case-insensitive substring match on session title *or* any of its turns' questions --
    /// widened from title-only so a session named "General" that happens to contain the searched
    /// question is still findable, not just one whose title happens to match.
    func groups(matching search: String) -> [Group] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered =
            query.isEmpty
            ? sessions : sessions.filter { $0.title.lowercased().contains(query) }
        let names = Set(filtered.map { $0.componentName ?? "General" })
        let sortedNames = names.sorted { lhs, rhs in
            if lhs == "General" { return false }
            if rhs == "General" { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return sortedNames.map { name in
            Group(
                name: name,
                sessions: filtered.filter { ($0.componentName ?? "General") == name }
                    .sorted { $0.lastActiveAt > $1.lastActiveAt })
        }
    }

    private static func parseDate(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601) ?? .distantPast
    }
}
