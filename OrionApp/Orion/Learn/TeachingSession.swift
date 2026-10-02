import Foundation
import OrionAgent
import OrionCodeIntel

/// The Teaching Mode destination's state — the concept rail plus the one concept currently being
/// worked through (Docs/17_phase7_teaching_mode.md §11). Owned by `ContentView`, recreated per
/// repository open (same lifetime as `AskHistory` / `AppShellState`), so a concept picked in one
/// repository never leaks into the next.
@MainActor
@Observable
final class TeachingSession {

    /// **Docs/17 Decision 10 / §11**: until Phase 7 M7's calibration gate clears (per-criterion
    /// Cohen's κ against expert labels), the app grades and shows the full breakdown but does
    /// **not** persist any mastery estimate — `RubricGrader(persistMastery: false)` — and the
    /// screen carries a persistent "self-check only" note. Flip to `true` once M7 confirms the
    /// grader is calibrated.
    static let isCalibrated = false

    enum Phase: Equatable {
        /// No concept selected.
        case idle
        /// A concept is selected but has no active question yet.
        case picking(conceptId: String)
        /// An active question, awaiting the developer's answer.
        case questioning(TeachingQuestionCard)
        /// The answer is being graded (the local model is running).
        case grading(TeachingQuestionCard)
        /// A graded attempt — the checklist, verdict, correction, transfer problem.
        case graded(TeachingQuestionCard, TeachingGradeCard)
    }

    private(set) var concepts: [TeachingConceptRow] = []
    private(set) var overview: TeachingOverview = .empty
    private(set) var phase: Phase = .idle
    var answerDraft: String = ""
    private(set) var isGenerating = false
    private(set) var generateError: String?
    private(set) var loadError: String?

    var selectedConceptId: String? {
        switch phase {
        case .idle: return nil
        case .picking(let id): return id
        case .questioning(let q), .grading(let q): return q.conceptId
        case .graded(let q, _): return q.conceptId
        }
    }

    // MARK: rail

    /// - Parameter bootstrap: `true` (the Teaching screen's own `.task`) runs `ConceptExtractor`
    ///   once if the concept table is empty; `false` (the sidebar's periodic strip refresh) is a
    ///   pure read that never triggers extraction.
    func refresh(outputDirectory: URL, bootstrap: Bool = true) async {
        do {
            let rows = try TeachingLoader.concepts(
                outputDirectory: outputDirectory, bootstrap: bootstrap)
            concepts = rows
            overview = TeachingLoader.overview(from: rows)
            loadError = nil
        } catch {
            concepts = []
            overview = .empty
            loadError = String(describing: error)
        }
    }

    /// Selecting a concept resumes its most recent verified question if it has one, otherwise
    /// drops into `.picking` where "Get a question" generates the first (Docs/17 §10).
    func select(conceptId: String, outputDirectory: URL) {
        generateError = nil
        answerDraft = ""
        if let card = try? TeachingLoader.latestVerifiedQuestion(
            conceptId: conceptId, band: nil, outputDirectory: outputDirectory) {
            phase = .questioning(card)
        } else {
            phase = .picking(conceptId: conceptId)
        }
    }

    // MARK: generate

    func getQuestion(
        band: Int?, repoRoot: URL, outputDirectory: URL,
        drafter: (any TeachingQuestionDrafting)? = nil
    ) async {
        guard let conceptId = selectedConceptId else { return }
        let seedBand =
            band ?? concepts.first { $0.id == conceptId }?.difficultyBand ?? 1
        await generate(conceptId: conceptId, band: seedBand, repoRoot: repoRoot,
                       outputDirectory: outputDirectory, drafter: drafter)
    }

    private func generate(
        conceptId: String, band: Int, repoRoot: URL, outputDirectory: URL,
        drafter: (any TeachingQuestionDrafting)?
    ) async {
        isGenerating = true
        generateError = nil
        defer { isGenerating = false }
        let outcome = await TeachingRunner.generate(
            conceptId: conceptId, band: band, repoRoot: repoRoot, outputDirectory: outputDirectory,
            drafter: drafter)
        switch outcome {
        case .generated(let qid):
            if let card = try? TeachingLoader.question(id: qid, outputDirectory: outputDirectory) {
                answerDraft = ""
                phase = .questioning(card)
            } else {
                generateError = "The question was generated but couldn't be loaded back."
            }
        case .rejected(let reasons):
            generateError = "Couldn't produce a sound question:\n" + reasons.joined(separator: "\n")
        case .failed(let message):
            generateError = message
        }
    }

    // MARK: grade

    func submit(
        repoRoot: URL, outputDirectory: URL, judge: (any CriterionJudging)? = nil
    ) async {
        guard case .questioning(let card) = phase else { return }
        let answer = answerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        phase = .grading(card)
        let outcome = await TeachingRunner.grade(
            questionId: card.id, answer: answer, persistMastery: Self.isCalibrated,
            repoRoot: repoRoot, outputDirectory: outputDirectory, judge: judge)
        switch outcome {
        case .graded(let result):
            let grade = (try? TeachingLoader.gradeCard(result, outputDirectory: outputDirectory))
                ?? TeachingGradeCard(result, criteria: [])
            phase = .graded(card, grade)
            await refresh(outputDirectory: outputDirectory)
        case .failed(let message):
            generateError = message
            phase = .questioning(card)
        }
    }

    // MARK: after a grade

    /// "Try the transfer problem" — a fresh question one band harder on the same concept (Docs/17
    /// §8.3). Falls back to the same band at band 3 (nothing harder to ask).
    func tryTransfer(
        repoRoot: URL, outputDirectory: URL, drafter: (any TeachingQuestionDrafting)? = nil
    ) async {
        guard case .graded(let card, _) = phase else { return }
        await generate(
            conceptId: card.conceptId, band: min(3, card.band + 1), repoRoot: repoRoot,
            outputDirectory: outputDirectory, drafter: drafter)
    }

    /// "Another question about this" — same concept, same band.
    func anotherQuestion(
        repoRoot: URL, outputDirectory: URL, drafter: (any TeachingQuestionDrafting)? = nil
    ) async {
        guard case .graded(let card, _) = phase else { return }
        await generate(
            conceptId: card.conceptId, band: card.band, repoRoot: repoRoot,
            outputDirectory: outputDirectory, drafter: drafter)
    }

    /// The rail's primary CTA — pick the top-ranked concept and start a question straight away.
    func startNext(
        repoRoot: URL, outputDirectory: URL, drafter: (any TeachingQuestionDrafting)? = nil
    ) async {
        guard let top = concepts.first else { return }
        select(conceptId: top.id, outputDirectory: outputDirectory)
        if case .picking = phase {
            await getQuestion(
                band: nil, repoRoot: repoRoot, outputDirectory: outputDirectory, drafter: drafter)
        }
    }
}
