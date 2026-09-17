import Foundation
import OrionAgent
import OrionCodeIntel

/// Drives Phase 7's `TeachingQuestionGenerator` and `RubricGrader` for the app — in-process, no
/// CLI subprocess, the same shape `AskRunner` / `SemanticInvestigationRunner` already use.
/// Band 1–2 question generation and all answer grading run on the local Qwen3-8B model; band 3
/// generation delegates to the `claude` CLI (Docs/17 §6.2). `drafter` / `judge` are injectable so
/// `TeachingSession` and its tests can drive the state machine without a model load.
enum TeachingRunner {

    enum GenerateOutcome: Equatable {
        case generated(questionId: String)
        case rejected([String])
        case failed(String)
    }

    enum GradeOutcome {
        case graded(RubricGrader.Result)
        case failed(String)
    }

    static func generate(
        conceptId: String, band: Int, repoRoot: URL, outputDirectory: URL,
        drafter injected: (any TeachingQuestionDrafting)? = nil,
        maxBudgetUsd: Double = 0.60, timeoutSeconds: Double = 400
    ) async -> GenerateOutcome {
        let useClaude = band >= 3
        let drafter: any TeachingQuestionDrafting
        if let injected {
            drafter = injected
        } else if useClaude {
            let claudeBinary = await ClaudeBinaryLocator.resolve()
            drafter = ClaudeTeachingDrafter(
                repoRoot: repoRoot, exportDir: outputDirectory.appendingPathComponent("export"),
                maxBudgetUsd: maxBudgetUsd, timeoutSeconds: timeoutSeconds, claudeBinary: claudeBinary)
        } else {
            do {
                let agent = try await Qwen3Agent.load()
                drafter = LocalTeachingDrafter { prompt in
                    try await agent.respond(
                        to: prompt, instructions: LocalTeachingDrafter.systemInstruction)
                }
            } catch {
                return .failed(String(describing: error))
            }
        }

        do {
            return try await Task.detached(priority: .userInitiated) {
                let store = Store(try OrionDatabase(
                    path: outputDirectory.appendingPathComponent("orion.db").path))
                guard let run = try store.latestRun(commitHash: nil) else {
                    return .failed("no analyzed run")
                }
                guard let concept = try store.teachingConcept(id: conceptId) else {
                    return .failed("concept not found")
                }
                let result = try await TeachingQuestionGenerator(
                    store: store, run: run, drafter: drafter
                ).generate(concept: concept, band: band)
                switch result {
                case .generated(let qid, _, _, _):
                    return .generated(questionId: qid)
                case .rejected(let reasons, _):
                    return .rejected(reasons)
                case .draftUnusable(let detail, _):
                    return .rejected([detail])
                }
            }.value
        } catch {
            return .failed(String(describing: error))
        }
    }

    static func grade(
        questionId: String, answer: String, persistMastery: Bool,
        repoRoot: URL, outputDirectory: URL,
        judge injected: (any CriterionJudging)? = nil, k: Int = 3
    ) async -> GradeOutcome {
        let judge: any CriterionJudging
        if let injected {
            judge = injected
        } else {
            do {
                let agent = try await Qwen3Agent.load()
                judge = LocalCriterionJudge { prompt in
                    try await agent.respond(
                        to: prompt, instructions: LocalCriterionJudge.systemInstruction)
                }
            } catch {
                return .failed(String(describing: error))
            }
        }

        do {
            return try await Task.detached(priority: .userInitiated) {
                let store = Store(try OrionDatabase(
                    path: outputDirectory.appendingPathComponent("orion.db").path))
                guard let run = try store.latestRun(commitHash: nil) else {
                    return .failed("no analyzed run")
                }
                let result = try await RubricGrader(
                    store: store, run: run, judge: judge, k: k, persistMastery: persistMastery
                ).grade(questionId: questionId, answer: answer, developerId: TeachingLoader.developerId)
                return .graded(result)
            }.value
        } catch {
            return .failed(String(describing: error))
        }
    }
}
