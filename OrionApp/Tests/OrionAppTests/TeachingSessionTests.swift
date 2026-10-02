import XCTest

@testable import Orion
import OrionAgent
import OrionCodeIntel

/// Docs/17 M6: `TeachingSession`'s phase machine, driven with scripted generation/grading stubs
/// so no MLX model or `claude` CLI is needed — the same seam `AskRunnerTests` uses.
@MainActor
final class TeachingSessionTests: XCTestCase {

    /// A drafter that returns a canned candidate JSON for the concept it's asked about.
    private struct ScriptedDrafter: TeachingQuestionDrafting {
        let source: TeachingQuestionSource
        let requiredAnchor: String
        func draft(prompt: String, band: Int) async throws -> String {
            // `prompt` embeds `concept_id ... "<id>"`; echo it back verbatim so the verifier's
            // concept-id check passes.
            let conceptId = Self.conceptId(inPrompt: prompt)
            return """
            {
              "schema_version": "\(TeachingSchema.currentVersion)",
              "concept_id": "\(conceptId)",
              "difficulty_band": \(band),
              "explain": "This concept is the routing entry point.",
              "question": "How does Router choose a Route?",
              "reference_answer": "It iterates its routes in declaration order and dispatches to the first match.",
              "reference_anchors": ["\(requiredAnchor)"],
              "rubric": [
                {"kind": "required", "text": "States declaration order.", "evidence": ["\(requiredAnchor)"]}
              ],
              "anti_criteria": [
                {"text": "Claims specificity ranking.", "evidence": ["\(requiredAnchor)"]}
              ],
              "transfer_problem": "What if two routes match the same path?"
            }
            """
        }
        static func conceptId(inPrompt p: String) -> String {
            // "concept_id must be \"<id>\"" appears in the schema-hint tail of the prompt.
            guard let range = p.range(of: "concept_id must be \"") else { return "" }
            let rest = p[range.upperBound...]
            return String(rest.prefix(while: { $0 != "\"" }))
        }
    }

    private struct ScriptedJudge: CriterionJudging {
        let source: TeachingQuestionSource = .local
        let met: Bool
        func judge(
            criterionText: String, criterionKind: RubricCriterionKind, answer: String,
            conceptEvidence: [String]
        ) async throws -> CriterionVerdict {
            // required -> `met`; anti -> not met (no misconception)
            CriterionVerdict(
                met: criterionKind == .required ? met : false, confidence: .high,
                evidenceQuote: met ? "in order" : "", note: "n")
        }
    }

    private func makeRepo() throws -> (repoRoot: URL, outputDirectory: URL, conceptId: String, anchor: String) {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeachingSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try "class Router:\n    pass\n".write(
            to: repoRoot.appendingPathComponent("routing.py"), atomically: true, encoding: .utf8)
        let outputDirectory = RepositorySession.outputDirectory(forRepoRoot: repoRoot)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let db = try OrionDatabase(path: outputDirectory.appendingPathComponent("orion.db").path)
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repoRoot, outputDirectory: outputDirectory, resolve: false))
        let store = Store(db)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let anchor = "routing.py::Router"
        XCTAssertNotNil(try store.symbol(runId: run.id, anchor: anchor), "fixture anchor must resolve")
        try store.insertTeachingConcepts([
            TeachingConceptRecord(
                id: "concept-1", repositoryId: run.repositoryId, kind: "component",
                subjectLabel: "Routing", evidenceAnchors: [anchor], centrality: 0.9,
                difficultyBand: 1, createdAt: "t0")
        ])
        return (repoRoot, outputDirectory, "concept-1", anchor)
    }

    func testSelectDropsIntoPickingWhenNoQuestionExists() async throws {
        let (_, out, conceptId, _) = try makeRepo()
        let session = TeachingSession()
        await session.refresh(outputDirectory: out, bootstrap: false)
        session.select(conceptId: conceptId, outputDirectory: out)
        XCTAssertEqual(session.phase, .picking(conceptId: conceptId))
        XCTAssertEqual(session.selectedConceptId, conceptId)
    }

    func testGetQuestionGeneratesVerifiesAndAdvancesToQuestioning() async throws {
        let (repo, out, conceptId, anchor) = try makeRepo()
        let session = TeachingSession()
        await session.refresh(outputDirectory: out, bootstrap: false)
        session.select(conceptId: conceptId, outputDirectory: out)

        await session.getQuestion(
            band: 1, repoRoot: repo, outputDirectory: out,
            drafter: ScriptedDrafter(source: .local, requiredAnchor: anchor))

        guard case .questioning(let card) = session.phase else {
            return XCTFail("expected .questioning, got \(session.phase). error=\(session.generateError ?? "nil")")
        }
        XCTAssertEqual(card.conceptId, conceptId)
        XCTAssertFalse(card.prompt.isEmpty)
        XCTAssertNil(session.generateError)
    }

    func testSubmitGradesAndAdvancesToGraded() async throws {
        let (repo, out, conceptId, anchor) = try makeRepo()
        let session = TeachingSession()
        await session.refresh(outputDirectory: out, bootstrap: false)
        session.select(conceptId: conceptId, outputDirectory: out)
        await session.getQuestion(
            band: 1, repoRoot: repo, outputDirectory: out,
            drafter: ScriptedDrafter(source: .local, requiredAnchor: anchor))
        guard case .questioning = session.phase else { return XCTFail("setup: not questioning") }

        session.answerDraft = "Router walks its route list in declaration order and takes the first match."
        await session.submit(repoRoot: repo, outputDirectory: out, judge: ScriptedJudge(met: true))

        guard case .graded(_, let grade) = session.phase else {
            return XCTFail("expected .graded, got \(session.phase)")
        }
        XCTAssertEqual(grade.verdict, "solid")
        XCTAssertEqual(grade.requiredMet, 1)
        // Calibration gate off (TeachingSession.isCalibrated == false) -> mastery not moved.
        XCTAssertNil(grade.masteryAfter)
        XCTAssertNil(try Store(OrionDatabase(path: out.appendingPathComponent("orion.db").path))
            .knowledgeState(conceptId: conceptId))
    }

    func testSubmitWithEmptyAnswerIsANoOp() async throws {
        let (repo, out, conceptId, anchor) = try makeRepo()
        let session = TeachingSession()
        await session.refresh(outputDirectory: out, bootstrap: false)
        session.select(conceptId: conceptId, outputDirectory: out)
        await session.getQuestion(
            band: 1, repoRoot: repo, outputDirectory: out,
            drafter: ScriptedDrafter(source: .local, requiredAnchor: anchor))

        session.answerDraft = "   "
        await session.submit(repoRoot: repo, outputDirectory: out, judge: ScriptedJudge(met: true))
        guard case .questioning = session.phase else {
            return XCTFail("empty answer should leave the phase at .questioning")
        }
    }

    func testStartNextPicksTheTopRankedConceptAndGenerates() async throws {
        let (repo, out, conceptId, anchor) = try makeRepo()
        let session = TeachingSession()
        await session.refresh(outputDirectory: out, bootstrap: false)

        await session.startNext(
            repoRoot: repo, outputDirectory: out,
            drafter: ScriptedDrafter(source: .local, requiredAnchor: anchor))

        XCTAssertEqual(session.selectedConceptId, conceptId)
        guard case .questioning = session.phase else {
            return XCTFail("startNext should reach .questioning, got \(session.phase)")
        }
    }

    func testGenerationRejectionSurfacesAnError() async throws {
        let (repo, out, conceptId, _) = try makeRepo()
        let session = TeachingSession()
        await session.refresh(outputDirectory: out, bootstrap: false)
        session.select(conceptId: conceptId, outputDirectory: out)

        // A drafter citing a symbol that doesn't exist -> the verifier rejects the candidate.
        await session.getQuestion(
            band: 1, repoRoot: repo, outputDirectory: out,
            drafter: ScriptedDrafter(source: .local, requiredAnchor: "routing.py::GhostSymbol"))

        guard case .picking = session.phase else { return XCTFail("should stay in .picking on rejection") }
        XCTAssertNotNil(session.generateError)
    }
}
