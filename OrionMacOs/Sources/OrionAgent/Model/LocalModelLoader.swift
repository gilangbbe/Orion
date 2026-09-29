import CoreAILanguageModels
import Foundation
import FoundationModels

/// Loads each Core AI bundle at most once per process and hands out the shared model (Docs/18
/// M2). Every model call site goes through here, so a process that asks many questions (`bench`,
/// the app) pays the load once instead of per question.
///
/// Since Docs/18 M4 a caller names its `LocalModelRole`: each role resolves to its own variant
/// and reasoning mode (`LocalModelRoles`). Weights load once per variant; roles sharing a variant
/// share them and differ only in their `ContextOptions`.
public actor LocalModelLoader {
    public static let shared = LocalModelLoader()

    private var loads: [LocalModelBackend: Task<FoundationModelsAgent<CoreAILanguageModel>, Error>] = [:]

    public func model(
        for backend: LocalModelBackend,
        role: LocalModelRole = .answering,
        roles: LocalModelRoles? = nil
    ) async throws -> any AgentModel {
        let resolved = backend.resolved(for: role, roles: roles)
        let base = try await load(resolved.backend)
        guard resolved.reasoning == .off else { return base }
        return base.with(
            contextOptions: ContextOptions(reasoningLevel: .custom("none")),
            modelIdentifier: resolved.modelIdentifier)
    }

    private func load(_ backend: LocalModelBackend) async throws -> FoundationModelsAgent<CoreAILanguageModel> {
        if let existing = loads[backend] {
            return try await existing.value
        }
        let task = Task<FoundationModelsAgent<CoreAILanguageModel>, Error> {
            let bundle = try CoreAIModelLocator.bundleURL(variant: backend.variant)
            // `.eager` compiles/loads the engine now (first run ~9s on-device compile, then Core
            // AI's own cache -- Docs/18 M1) instead of on the first request.
            let model = try await CoreAILanguageModel(resourcesAt: bundle, mode: .eager)
            return FoundationModelsAgent(model: model, modelIdentifier: backend.modelIdentifier)
        }
        loads[backend] = task
        do {
            return try await task.value
        } catch {
            // A failed load (missing bundle, bad export) must not poison later attempts.
            loads[backend] = nil
            throw error
        }
    }
}
