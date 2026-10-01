import Foundation
import FoundationModels
import Observation
import OrionAgent
import OrionCore

/// Ask on the iPhone (Docs/19 M6): one repository's conversations, answered by the on-device
/// system model through `SystemModelAsk` -- the same `AgentSession` the Mac runs, with a
/// token-budgeted context and the phone's tool set.
///
/// Follows the Foundation Models skill: availability is checked before any session exists and
/// each unavailable reason becomes its own state; sessions are owned by `AgentSession` (one per
/// question, primed with that question's context), never created in a view; every failure is
/// caught and mapped to plain words; the model is prewarmed while idle.
@MainActor
@Observable
final class AskModel {
    enum Availability: Equatable {
        case available
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unavailable
    }

    struct Turn: Identifiable, Equatable {
        let id: String
        let question: String
        let summary: AskResultSummary?
        let failure: String?
    }

    let entry: LocalLibrary.Entry
    private(set) var availability: Availability = .unavailable
    private(set) var sessions: [AskSessionRecord] = []
    private(set) var selectedSessionId: String?
    private(set) var turns: [Turn] = []
    private(set) var pendingQuestion: String?
    private(set) var streamingAnswer = ""
    private(set) var isAsking = false
    /// A component-scoped conversation waiting for its first question ("Ask about").
    private(set) var pendingComponent: (id: String, name: String)?
    /// Starter questions for an empty conversation (Docs/19 M8).
    private(set) var suggestions: [String] = []

    @ObservationIgnored private var prewarmSession: LanguageModelSession?
    @ObservationIgnored private var scope: (repositoryId: String, commitHash: String)?

    var outputDirectory: URL { entry.databaseURL.deletingLastPathComponent() }
    var selectedSession: AskSessionRecord? { sessions.first { $0.id == selectedSessionId } }

    init(entry: LocalLibrary.Entry) {
        self.entry = entry
        refreshAvailability()
    }

    private func store() throws -> Store {
        Store(try OrionDatabase(path: entry.databaseURL.path))
    }

    // MARK: - Availability (gate before any session exists)

    func refreshAvailability() {
        availability = Self.currentAvailability()
    }

    /// The system model's availability as one of `Availability`'s states -- Ask's and Learn's gate.
    static func currentAvailability() -> Availability {
        switch SystemModelInfo.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        default: return .unavailable
        }
    }

    /// Loads the model's resources while the user is still reading or typing -- the skill's
    /// "prewarm during idle time, not right before generating".
    func prewarm() {
        guard availability == .available, prewarmSession == nil else { return }
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        session.prewarm()
        prewarmSession = session
    }

    // MARK: - Conversations

    func load() {
        if suggestions.isEmpty {
            suggestions = AskSuggestions.make(model: try? ArchitectureModelLoader.load(outputDirectory: outputDirectory))
        }
        do {
            let store = try store()
            guard let run = try store.latestRun(commitHash: nil) else { return }
            scope = (run.repositoryId, run.commitHash)
            sessions = try store.askSessions(repositoryId: run.repositoryId, commitHash: run.commitHash)
            if selectedSessionId == nil, pendingComponent == nil { selectedSessionId = sessions.first?.id }
            loadTurns()
        } catch {
            turns = [Turn(id: "load-error", question: "", summary: nil, failure: Self.describe(error))]
        }
    }

    func select(_ sessionId: String?) {
        selectedSessionId = sessionId
        pendingComponent = nil
        loadTurns()
    }

    /// A fresh conversation; the next question starts it.
    func startNewConversation() {
        selectedSessionId = nil
        pendingComponent = nil
        turns = []
    }

    /// "Ask about" from a component in Explore: resume that component's latest conversation, or
    /// scope the next question's new one to it -- the Mac's rule (Docs/15 §5).
    func startConversation(aboutComponent id: String?, name: String) {
        load()
        if let id, let existing = sessions.first(where: { $0.componentId == id }) {
            select(existing.id)
            return
        }
        selectedSessionId = nil
        turns = []
        pendingComponent = id.map { ($0, name) }
    }

    func delete(_ session: AskSessionRecord) {
        try? store().deleteAskSession(id: session.id)
        if selectedSessionId == session.id { selectedSessionId = nil }
        load()
    }

    private func loadTurns() {
        guard let selectedSessionId, let store = try? store() else {
            turns = []
            return
        }
        let records = (try? store.askSessionTurns(sessionId: selectedSessionId)) ?? []
        turns = records.map { record in
            do {
                let loaded = try AskTurnLoader.loadPersistedTurn(
                    investigationId: record.investigationId, outputDirectory: outputDirectory)
                return Turn(id: record.id, question: loaded.question, summary: loaded.summary, failure: nil)
            } catch {
                return Turn(id: record.id, question: "", summary: nil, failure: Self.describe(error))
            }
        }
    }

    // MARK: - Asking

    func ask(_ question: String) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking else { return }
        refreshAvailability()
        guard availability == .available else { return }

        isAsking = true
        pendingQuestion = question
        streamingAnswer = ""
        defer {
            isAsking = false
            pendingQuestion = nil
            streamingAnswer = ""
        }

        let sessionId: String
        do {
            sessionId = try ensureSession(firstQuestion: question)
        } catch {
            turns.append(Turn(id: UUID().uuidString, question: question, summary: nil, failure: Self.describe(error)))
            return
        }

        let config = AgentSessionConfig(
            // The classifier judges relevance by the repository's name (Docs/15 §11 M8); the path
            // itself is never read on iOS.
            repoRoot: outputDirectory.appendingPathComponent(entry.manifest.repositoryName),
            outputDirectory: outputDirectory)
        let agent = SystemModelAsk.session(config: config)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try await agent.ask(question, sessionId: sessionId) { text in
                    Task { @MainActor [weak self] in self?.streamingAnswer = text }
                }
            }.value
            let claims = (try? AskTurnLoader.loadClaims(
                investigationId: result.investigation.id, outputDirectory: outputDirectory)) ?? []
            let summary = AskResultSummary(result, claims: claims)
            if summary.isDeclined {
                // A decline is never persisted as a turn (Docs/15 §4.5); keep it on screen.
                loadTurns()
                turns.append(Turn(id: result.investigation.id, question: question, summary: summary, failure: nil))
            } else {
                load()
            }
        } catch {
            loadTurns()
            turns.append(Turn(id: UUID().uuidString, question: question, summary: nil, failure: Self.describe(error)))
        }
    }

    private func ensureSession(firstQuestion: String) throws -> String {
        if let selectedSessionId { return selectedSessionId }
        let store = try store()
        if scope == nil, let run = try store.latestRun(commitHash: nil) { scope = (run.repositoryId, run.commitHash) }
        guard let scope else { throw AgentSessionError.noAnalyzedRun(entry.databaseURL.path) }
        let title = pendingComponent.map { "About \($0.name)" } ?? String(firstQuestion.prefix(60))
        let session = try store.createAskSession(
            repositoryId: scope.repositoryId, commitHash: scope.commitHash,
            scopeType: pendingComponent == nil ? .repository : .component, componentId: pendingComponent?.id,
            title: title, now: Timestamp.now())
        selectedSessionId = session.id
        pendingComponent = nil
        sessions = (try? store.askSessions(repositoryId: scope.repositoryId, commitHash: scope.commitHash)) ?? sessions
        return session.id
    }

    /// Plain words for every failure family the framework reports (the skill's OS 27 mapping).
    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case LanguageModelError.contextSizeExceeded:
            return "That needed more than the on-device model can hold at once. Try a narrower question."
        case LanguageModelError.guardrailViolation:
            return "The on-device model's safety guardrails declined this question."
        case LanguageModelError.refusal:
            return "The on-device model declined to answer this."
        case LanguageModelError.unsupportedLanguageOrLocale:
            return "The on-device model doesn't support this language yet."
        case LanguageModelError.rateLimited:
            return "The on-device model is busy. Try again in a moment."
        case LanguageModelError.timeout:
            return "The on-device model took too long. Try again."
        case LanguageModelSession.Error.concurrentRequests:
            return "Wait for the current answer to finish."
        case SystemLanguageModel.Error.assetsUnavailable:
            return "The on-device model isn't ready yet. Try again shortly."
        case let error as LanguageModelSession.ToolCallError:
            return "A lookup in this repository's knowledge failed: \(error.underlyingError.localizedDescription)"
        default:
            return String(describing: error)
        }
    }
}
