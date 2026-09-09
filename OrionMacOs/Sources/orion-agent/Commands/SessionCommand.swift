import ArgumentParser
import Foundation
import OrionAgent
import OrionCodeIntel

/// `orion-agent session` (Docs/15_phase5_adaptive_exploration.md §7/M5): create, list, and
/// inspect conversational sessions -- the CLI surface over `Store.createAskSession`/
/// `askSessions`/`askSessionTurns` (Docs/15 M0/M3). `ask` (`AskCommand.swift`) gained the
/// `--session` flag that actually continues one; this group only manages the sessions
/// themselves.
struct Session: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Create, list, inspect, rename, or delete conversational sessions.",
        subcommands: [
            SessionCreate.self, SessionList.self, SessionShow.self, SessionRename.self,
            SessionDelete.self,
        ]
    )
}

/// Mirrors `Ask`'s own `<path>`/`--out` convention exactly (`orion-index analyze`'s default
/// `<path>/.orion`) so `session`/`ask` commands against the same repo never need different flags
/// to find the same database.
private func resolvePaths(path: String, out: String?) -> (repoURL: URL, outURL: URL) {
    let repoURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    let outURL = URL(
        fileURLWithPath: ((out ?? repoURL.appendingPathComponent(".orion").path) as NSString)
            .expandingTildeInPath
    ).standardizedFileURL
    return (repoURL, outURL)
}

private func openStore(outURL: URL) throws -> Store {
    Store(try OrionDatabase(path: outURL.appendingPathComponent("orion.db").path))
}

struct SessionCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Start a new conversational session, scoped to one component or the whole repository."
    )

    @Argument(help: "Path to the repository checkout (must already be analyzed by `orion-index analyze`).")
    var path: String

    @Option(help: "Directory containing orion.db + export/ (default: <path>/.orion).")
    var out: String?

    @Option(help: "Scope this session to a specific commit's analyzed run instead of the latest one.")
    var commit: String?

    @Option(
        help: """
            Scope this session to one component, by name or by a member symbol's anchor (e.g. \
            "Routing" or "pkg/router.py::Router"). Omit for a repository-wide session.
            """
    )
    var component: String?

    @Option(help: "A short title for this session (default: derived from the scope).")
    var title: String?

    func run() async throws {
        let (_, outURL) = resolvePaths(path: path, out: out)
        let store = try openStore(outURL: outURL)
        guard let run = try store.latestRun(commitHash: commit) else {
            FileHandle.standardError.write(
                Data("no analyzed run found at \(outURL.path) -- run `orion-index analyze` first\n".utf8))
            throw ExitCode(3)
        }

        let scopeType: AskSessionScope
        let componentId: String?
        let resolvedTitle: String
        if let component {
            let resolved = try Self.resolveComponent(store: store, runId: run.id, query: component)
            scopeType = .component
            componentId = resolved.id
            resolvedTitle = title ?? "About \(resolved.name)"
        } else {
            scopeType = .repository
            componentId = nil
            resolvedTitle = title ?? "General"
        }

        let session = try store.createAskSession(
            repositoryId: run.repositoryId, commitHash: run.commitHash, scopeType: scopeType,
            componentId: componentId, title: resolvedTitle, now: Timestamp.now())

        // The id on its own stdout line (scriptable: `id=$(orion-agent session create ...)`);
        // the human-facing confirmation goes to stderr so it doesn't pollute that capture.
        print(session.id)
        FileHandle.standardError.write(
            Data("Created \(scopeType.rawValue) session \"\(resolvedTitle)\" (\(session.id))\n".utf8))
    }

    /// Resolves `query` against the run's latest semantic investigation's components: an exact
    /// (case-insensitive) name match first, then a member symbol's anchor (Docs/15 §7).
    static func resolveComponent(store: Store, runId: String, query: String) throws -> ComponentRecord {
        guard let investigation = try store.latestInvestigation(runId: runId) else {
            throw ValidationError(
                "no semantic investigation found for this run -- build one first (a "
                    + "component-scoped session needs real components to scope to)")
        }
        let components = try store.components(investigationId: investigation.id)
        guard !components.isEmpty else {
            throw ValidationError("the latest investigation has no components to scope a session to")
        }
        if let byName = components.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return byName
        }
        if let symbol = try store.symbol(runId: runId, anchor: query) {
            for candidate in components {
                let members = try store.componentMembers(componentIds: [candidate.id])
                if members.contains(where: { $0.symbolId == symbol.id }) {
                    return candidate
                }
            }
        }
        throw ValidationError("no component named or containing member \"\(query)\" was found")
    }
}

struct SessionList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List this repository's conversational sessions, most recently active first."
    )

    @Argument(help: "Path to the repository checkout.")
    var path: String

    @Option(help: "Directory containing orion.db + export/ (default: <path>/.orion).")
    var out: String?

    @Option(help: "List sessions for this commit's analyzed run instead of the latest one.")
    var commit: String?

    @Flag(help: "Print structured JSON instead of a formatted list.")
    var json: Bool = false

    func run() async throws {
        let (_, outURL) = resolvePaths(path: path, out: out)
        let store = try openStore(outURL: outURL)
        guard let run = try store.latestRun(commitHash: commit) else {
            FileHandle.standardError.write(
                Data("no analyzed run found at \(outURL.path) -- run `orion-index analyze` first\n".utf8))
            throw ExitCode(3)
        }
        let sessions = try store.askSessions(repositoryId: run.repositoryId, commitHash: run.commitHash)

        if json {
            let objects = sessions.map { session -> [String: Any] in
                var object: [String: Any] = [
                    "id": session.id, "scope_type": session.scopeType, "title": session.title,
                    "turn_count": session.turnCount, "created_at": session.createdAt,
                    "last_active_at": session.lastActiveAt,
                ]
                if let componentId = session.componentId { object["component_id"] = componentId }
                return object
            }
            let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys, .prettyPrinted])
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }

        guard !sessions.isEmpty else {
            print("No sessions yet -- create one with `orion-agent session create`.")
            return
        }
        for session in sessions {
            let scope = session.scopeType == AskSessionScope.component.rawValue ? "component" : "repository"
            print(
                "\(session.id)  [\(scope)]  \(session.title)  "
                    + "(\(session.turnCount) turn(s), last active \(session.lastActiveAt))")
        }
    }
}

struct SessionShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one session's full turn-by-turn history."
    )

    @Argument(help: "Path to the repository checkout.")
    var path: String

    @Argument(help: "The session id (from `session create` or `session list`).")
    var sessionId: String

    @Option(help: "Directory containing orion.db + export/ (default: <path>/.orion).")
    var out: String?

    @Flag(help: "Print structured JSON instead of formatted text.")
    var json: Bool = false

    private struct TurnDetail {
        let turnIndex: Int
        let question: String
        let answer: String?
        let outcome: String
        let depth: Int?
    }

    func run() async throws {
        let (_, outURL) = resolvePaths(path: path, out: out)
        let store = try openStore(outURL: outURL)
        guard let session = try store.askSession(id: sessionId) else {
            FileHandle.standardError.write(Data("no session with id \(sessionId)\n".utf8))
            throw ExitCode(3)
        }

        var details: [TurnDetail] = []
        for turn in try store.askSessionTurns(sessionId: sessionId) {
            guard let investigation = try store.investigation(id: turn.investigationId) else { continue }
            let depth = try store.routingDecisions(investigationId: investigation.id).first?.depthLevel
            details.append(
                TurnDetail(
                    turnIndex: turn.turnIndex, question: investigation.question,
                    answer: investigation.answerText, outcome: investigation.outcome, depth: depth))
        }

        if json {
            let object: [String: Any] = [
                "id": session.id, "scope_type": session.scopeType, "title": session.title,
                "turn_count": session.turnCount,
                "turns": details.map { detail -> [String: Any] in
                    var object: [String: Any] = [
                        "turn_index": detail.turnIndex, "question": detail.question,
                        "outcome": detail.outcome,
                    ]
                    if let answer = detail.answer { object["answer"] = answer }
                    if let depth = detail.depth { object["depth"] = depth }
                    return object
                },
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        print("Session \(session.id) -- \(session.title) [\(session.scopeType)]")
        print("")
        if details.isEmpty {
            print("(no turns yet -- ask a question with `orion-agent ask <path> \"...\" --session \(session.id)`)")
        }
        for detail in details {
            let depthLabel = detail.depth.map { "depth \($0)" } ?? "depth ?"
            print("[\(detail.turnIndex)] Q: \(detail.question)")
            print("    A: \(detail.answer ?? "(no answer recorded)")")
            print("    (\(depthLabel), outcome: \(detail.outcome))")
            print("")
        }
    }
}

/// Docs/15_phase5_adaptive_exploration.md §4.7/§7, M8.5.
struct SessionRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a conversational session."
    )

    @Argument(help: "Path to the repository checkout.")
    var path: String

    @Argument(help: "The session id (from `session create` or `session list`).")
    var sessionId: String

    @Argument(help: "The new title.")
    var title: String

    @Option(help: "Directory containing orion.db + export/ (default: <path>/.orion).")
    var out: String?

    func run() async throws {
        let (_, outURL) = resolvePaths(path: path, out: out)
        let store = try openStore(outURL: outURL)
        do {
            try store.renameAskSession(id: sessionId, title: title)
        } catch let error as AskSessionError {
            FileHandle.standardError.write(Data("\(error.description)\n".utf8))
            throw ExitCode(3)
        }
        FileHandle.standardError.write(Data("Renamed \(sessionId) to \"\(title)\"\n".utf8))
    }
}

/// Docs/15_phase5_adaptive_exploration.md §4.7/§7, M8.5. Deleting a session removes it and its
/// own `ask_session_turns` pointers (cascade, §4.2); it deliberately never deletes the
/// `investigations` rows those turns pointed at (§4.1) -- confirms before deleting for the same
/// reason the app does (a destructive, hard-to-reverse action), unless `--yes` is passed.
struct SessionDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a conversational session (its turn-pointers only -- the underlying "
            + "investigations, claims, and evidence are kept)."
    )

    @Argument(help: "Path to the repository checkout.")
    var path: String

    @Argument(help: "The session id (from `session create` or `session list`).")
    var sessionId: String

    @Option(help: "Directory containing orion.db + export/ (default: <path>/.orion).")
    var out: String?

    @Flag(help: "Delete without asking for confirmation.")
    var yes: Bool = false

    func run() async throws {
        let (_, outURL) = resolvePaths(path: path, out: out)
        let store = try openStore(outURL: outURL)
        guard let session = try store.askSession(id: sessionId) else {
            FileHandle.standardError.write(Data("no session with id \(sessionId)\n".utf8))
            throw ExitCode(3)
        }

        if !yes {
            FileHandle.standardError.write(
                Data("Delete session \"\(session.title)\" (\(session.turnCount) turn(s))? [y/N] ".utf8))
            let response = readLine(strippingNewline: true)?.lowercased()
            guard response == "y" || response == "yes" else {
                FileHandle.standardError.write(Data("Cancelled -- no changes made.\n".utf8))
                return
            }
        }

        try store.deleteAskSession(id: sessionId)
        FileHandle.standardError.write(Data("Deleted session \"\(session.title)\" (\(sessionId))\n".utf8))
    }
}
