import Foundation
import FoundationModels
import Observation
import OrionAgent
import OrionCore

/// Learn on the iPhone (Docs/19 M7): practise the open repository's concepts with questions,
/// graded on device. The Mac's Teaching Mode, on the system model.
///
/// - **Questions**, in order: shipped from the Mac (any band), then drafted here for bands 1–2 by
///   `SystemModelTeaching.drafter()` and always through `TeachingQuestionVerifier`. Band 3 needs
///   the Mac.
/// - **Grading**: `RubricGrader` with the single-call guided judge, `SystemModelTeaching.judgeVotes`
///   votes per point.
/// - **Calibration gate** (Docs/17 Decision 10): until it clears, a grade is a self-check and no
///   mastery estimate is written (`persistMastery: false`) -- the attempt itself is still kept.
///
/// Follows the Foundation Models skill: availability gates every model call, model work runs off
/// the main actor, and every failure is caught and put in plain words.
@MainActor
@Observable
final class LearnModel {
    /// The phone's calibration gate (Docs/19 M7). Held: see `Agent Feasibility Study/IOS_COMPANION_EVAL.md`.
    static let isCalibrated = false

    enum Phase: Equatable {
        /// A concept is open, with no question yet.
        case picking
        /// Writing a question on device.
        case drafting(band: Int)
        case questioning(TeachingQuestionCard)
        /// Grading: `judged` of `total` points done.
        case grading(TeachingQuestionCard, judged: Int, total: Int)
        case graded(TeachingQuestionCard, TeachingGradeCard)
    }

    /// Why no question could be offered, in plain words, plus the verifier's reasons if any.
    struct Problem: Error, Equatable {
        let message: String
        var details: [String] = []
    }

    let entry: LocalLibrary.Entry
    private(set) var availability: AskModel.Availability
    private(set) var concepts: [TeachingConceptRow] = []
    private(set) var overview: TeachingOverview = .empty
    private(set) var loadError: String?
    private(set) var conceptId: String?
    private(set) var phase: Phase = .picking
    private(set) var problem: Problem?
    var answerDraft = ""

    @ObservationIgnored private let makeDrafter: @Sendable () -> any TeachingQuestionDrafting
    @ObservationIgnored private let makeJudge: @Sendable () -> any CriterionJudging
    @ObservationIgnored private let votes: Int
    @ObservationIgnored private var prewarmSession: LanguageModelSession?

    var outputDirectory: URL { entry.databaseURL.deletingLastPathComponent() }
    var concept: TeachingConceptRow? { concepts.first { $0.id == conceptId } }
    var isBusy: Bool {
        switch phase {
        case .drafting, .grading: return true
        default: return false
        }
    }

    init(
        entry: LocalLibrary.Entry,
        availability: AskModel.Availability? = nil,
        drafter: @escaping @Sendable () -> any TeachingQuestionDrafting = { SystemModelTeaching.drafter() },
        judge: @escaping @Sendable () -> any CriterionJudging = { SystemModelTeaching.judge() },
        votes: Int = SystemModelTeaching.judgeVotes
    ) {
        self.entry = entry
        self.availability = availability ?? AskModel.currentAvailability()
        self.makeDrafter = drafter
        self.makeJudge = judge
        self.votes = votes
    }

    func refreshAvailability() {
        availability = AskModel.currentAvailability()
    }

    /// Loads the model while the learner reads the question -- the skill's idle-time prewarm.
    func prewarm() {
        guard availability == .available, prewarmSession == nil else { return }
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        session.prewarm()
        prewarmSession = session
    }

    // MARK: - Concepts

    /// The concept list, ranked by `TeachingPlanner`. Read only: the phone never extracts concepts.
    func refresh() {
        do {
            concepts = try TeachingLoader.concepts(outputDirectory: outputDirectory, bootstrap: false)
            overview = TeachingLoader.overview(from: concepts)
            loadError = nil
        } catch {
            concepts = []
            overview = .empty
            loadError = AskModel.describe(error)
        }
    }

    /// Opens a concept: its best available question if there is one (Mac-shipped first), else
    /// `.picking`, where the learner chooses a depth.
    func open(conceptId: String) {
        self.conceptId = conceptId
        problem = nil
        answerDraft = ""
        if let card = try? TeachingLoader.nextQuestion(conceptId: conceptId, band: nil, outputDirectory: outputDirectory) {
            phase = .questioning(card)
        } else {
            phase = .picking
        }
    }

    func close() {
        conceptId = nil
        phase = .picking
        problem = nil
        answerDraft = ""
    }

    /// Whether the device can write a question at this depth (bands 1–2, Docs/19 M7).
    static func canDraft(band: Int) -> Bool { band <= 2 }

    // MARK: - Questions

    /// A question at `band`: one already here if there is one (not `excluding`), else a fresh
    /// on-device draft for bands 1–2.
    func question(band: Int, excluding: Set<String> = []) async {
        guard let conceptId, !isBusy else { return }
        problem = nil
        if let card = try? TeachingLoader.nextQuestion(
            conceptId: conceptId, band: band, excluding: excluding, outputDirectory: outputDirectory)
        {
            answerDraft = ""
            phase = .questioning(card)
            return
        }
        guard Self.canDraft(band: band) else {
            problem = Problem(message: "Transfer questions are written on your Mac. Generate one there and it syncs here.")
            return
        }
        refreshAvailability()
        guard availability == .available else { return }

        let previous = phase
        phase = .drafting(band: band)
        let outcome = await Self.draft(
            conceptId: conceptId, band: band, databasePath: entry.databaseURL.path, drafter: makeDrafter())
        switch outcome {
        case .success(let questionId):
            if let card = try? TeachingLoader.question(id: questionId, outputDirectory: outputDirectory) {
                answerDraft = ""
                phase = .questioning(card)
            } else {
                phase = previous
                problem = Problem(message: "The question was written but couldn't be loaded back.")
            }
        case .failure(let failure):
            phase = previous
            problem = failure
        }
    }

    /// "Another question": same concept and depth, not the one just answered.
    func anotherQuestion() async {
        guard case .graded(let card, _) = phase else { return }
        await question(band: card.band, excluding: [card.id])
    }

    /// "One level up": the transfer step (Docs/17 §8.3), as far as the device can go.
    func harderQuestion() async {
        guard case .graded(let card, _) = phase, card.band < 3 else { return }
        await question(band: card.band + 1, excluding: [card.id])
    }

    nonisolated private static func draft(
        conceptId: String, band: Int, databasePath: String, drafter: any TeachingQuestionDrafting
    ) async -> Result<String, Problem> {
        do {
            return try await Task.detached(priority: .userInitiated) { () -> Result<String, Problem> in
                let store = Store(try OrionDatabase(path: databasePath))
                guard let run = try store.latestRun(commitHash: nil),
                      let concept = try store.teachingConcept(id: conceptId)
                else { return .failure(Problem(message: "This concept isn't in the repository's knowledge any more.")) }
                switch try await TeachingQuestionGenerator(store: store, run: run, drafter: drafter)
                    .generate(concept: concept, band: band)
                {
                case .generated(let questionId, _, _, _):
                    return .success(questionId)
                case .rejected(let reasons, _):
                    return .failure(Problem(
                        message: "Orion couldn't write a question it could check against the code for this concept. Try another depth or concept.",
                        details: reasons))
                case .draftUnusable(let detail, _):
                    return .failure(Problem(message: "Orion couldn't write a usable question for this concept.", details: [detail]))
                }
            }.value
        } catch {
            return .failure(Problem(message: AskModel.describe(error)))
        }
    }

    // MARK: - Grading

    func submit() async {
        guard case .questioning(let card) = phase else { return }
        let answer = answerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        refreshAvailability()
        guard availability == .available else { return }

        problem = nil
        phase = .grading(card, judged: 0, total: 0)
        let judge = makeJudge()
        let votes = votes
        let path = entry.databaseURL.path
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let store = Store(try OrionDatabase(path: path))
                guard let run = try store.latestRun(commitHash: nil) else {
                    throw AgentSessionError.noAnalyzedRun(path)
                }
                return try await RubricGrader(
                    store: store, run: run, judge: judge, k: votes, persistMastery: LearnModel.isCalibrated
                ).grade(questionId: card.id, answer: answer, developerId: TeachingLoader.developerId) { judged, total in
                    Task { @MainActor [weak self] in
                        guard let self, case .grading(let current, _, _) = self.phase, current.id == card.id else { return }
                        self.phase = .grading(card, judged: judged, total: total)
                    }
                }
            }.value
            let grade = (try? TeachingLoader.gradeCard(result, outputDirectory: outputDirectory))
                ?? TeachingGradeCard(result, criteria: [])
            phase = .graded(card, grade)
            refresh()
        } catch {
            phase = .questioning(card)
            problem = Problem(message: AskModel.describe(error))
        }
    }
}
