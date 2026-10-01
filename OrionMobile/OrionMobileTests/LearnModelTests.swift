import OrionAgent
import OrionCore
import XCTest

@testable import Orion

/// Docs/19 M7: Learn on the phone without the model -- where questions come from, drafting and
/// grading with scripted stand-ins, and the calibration gate's "no mastery written".
@MainActor
final class LearnModelTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("orion-learn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "orion-learn-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func importedEntry() async throws -> LocalLibrary.Entry {
        let inbox = root.appendingPathComponent("Documents")
        try SnapshotFixture.write(to: inbox)
        let library = LibraryModel(
            library: LocalLibrary(root: root.appendingPathComponent("Library")), inbox: inbox, defaults: defaults)
        await library.importInbox()
        return try XCTUnwrap(library.selected)
    }

    private func store(_ entry: LocalLibrary.Entry) throws -> Store {
        Store(try OrionDatabase(path: entry.databaseURL.path))
    }

    /// One concept over the fixture's only symbol, as the Mac's `ConceptExtractor` would ship it.
    private func seedConcept(_ store: Store) throws {
        try store.insertTeachingConcepts([TeachingConceptRecord(
            id: "k1", repositoryId: "repo", kind: "component", subjectLabel: "App Core",
            evidenceAnchors: [SnapshotFixture.anchor], centrality: 0.5, difficultyBand: 1, createdAt: "t0")])
    }

    private func seedQuestion(_ store: Store, id: String, band: Int = 1, by source: TeachingQuestionSource, at: String) throws {
        try store.insertTeachingQuestion(TeachingQuestionRecord(
            id: id, conceptId: "k1", investigationId: nil, difficultyBand: band, explain: "Setup.",
            prompt: "What does helper do? (\(id))", referenceAnswer: "helper helps the app core run.",
            referenceAnchors: [SnapshotFixture.anchor], transferProblem: "And then?", generatedBy: source.rawValue,
            verified: true, createdAt: at))
        try store.insertTeachingRubricCriteria([
            TeachingRubricCriterionRecord(
                id: "\(id)-r", questionId: id, ordinal: 0, kind: "required", text: "helper helps the app.",
                evidenceAnchors: [SnapshotFixture.anchor]),
            TeachingRubricCriterionRecord(
                id: "\(id)-a", questionId: id, ordinal: 1, kind: "anti", text: "helper deletes the app.",
                evidenceAnchors: [SnapshotFixture.anchor]),
        ])
    }

    private struct ScriptedDrafter: TeachingQuestionDrafting {
        let source: TeachingQuestionSource = .device
        let reply: String
        let calls = Calls()
        final class Calls: @unchecked Sendable { var count = 0 }
        func draft(prompt: String, band: Int) async throws -> String {
            calls.count += 1
            return reply
        }
    }

    private struct ScriptedJudge: CriterionJudging {
        let source: TeachingQuestionSource = .device
        func judge(
            criterionText: String, criterionKind: RubricCriterionKind, answer: String, conceptEvidence: [String]
        ) async throws -> CriterionVerdict {
            // Every required point stated, no misconception.
            CriterionVerdict(met: criterionKind == .required, confidence: .high, evidenceQuote: "", note: "scripted")
        }
    }

    private func candidate(anchor: String = SnapshotFixture.anchor) -> String {
        """
        {"schema_version": "\(TeachingSchema.currentVersion)", "concept_id": "k1", "difficulty_band": 1,
         "explain": "App Core runs the app.", "question": "What does helper do?",
         "reference_answer": "helper helps App Core run the application.", "reference_anchors": ["\(anchor)"],
         "rubric": [{"kind": "required", "text": "helper helps the app run.", "evidence": ["\(anchor)"]}],
         "anti_criteria": [{"text": "helper deletes the app.", "evidence": ["\(anchor)"]}],
         "transfer_problem": "What if helper were removed?"}
        """
    }

    private func model(
        _ entry: LocalLibrary.Entry, drafter: ScriptedDrafter? = nil
    ) -> LearnModel {
        let drafter = drafter ?? ScriptedDrafter(reply: candidate())
        return LearnModel(
            entry: entry, availability: .available, drafter: { drafter }, judge: { ScriptedJudge() }, votes: 1)
    }

    // MARK: - Concepts

    func testConceptsAreReadNeverExtractedOnThePhone() async throws {
        let entry = try await importedEntry()
        let model = model(entry)
        model.refresh()
        XCTAssertTrue(model.concepts.isEmpty)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(try store(entry).teachingConcepts(repositoryId: "repo").count, 0, "the phone must not invent concepts")

        try seedConcept(store(entry))
        model.refresh()
        XCTAssertEqual(model.concepts.map(\.label), ["App Core"])
    }

    // MARK: - Question supply

    func testAShippedQuestionComesBeforeTheDevicesOwn() async throws {
        let entry = try await importedEntry()
        let store = try store(entry)
        try seedConcept(store)
        try seedQuestion(store, id: "mac", by: .claudeCode, at: "t1")
        try seedQuestion(store, id: "phone", by: .device, at: "t2")
        let model = model(entry)
        model.refresh()
        model.open(conceptId: "k1")
        guard case .questioning(let card) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(card.id, "mac", "the Mac's verified question first, though the device's is newer")
        XCTAssertEqual(card.generatedBy, TeachingQuestionSource.claudeCode.rawValue)
    }

    func testWithNoQuestionTheDeviceDraftsOneThroughTheVerifier() async throws {
        let entry = try await importedEntry()
        try seedConcept(store(entry))
        let drafter = ScriptedDrafter(reply: candidate())
        let model = model(entry, drafter: drafter)
        model.refresh()
        model.open(conceptId: "k1")
        XCTAssertEqual(model.phase, .picking)

        await model.question(band: 1)
        guard case .questioning(let card) = model.phase else { return XCTFail("\(model.phase) \(String(describing: model.problem))") }
        XCTAssertEqual(card.generatedBy, TeachingQuestionSource.device.rawValue)
        XCTAssertEqual(drafter.calls.count, 1)
        XCTAssertEqual(try store(entry).teachingQuestion(id: card.id)?.verified, true)
    }

    func testARejectedDraftExplainsWhyAndKeepsNothing() async throws {
        let entry = try await importedEntry()
        try seedConcept(store(entry))
        let model = model(entry, drafter: ScriptedDrafter(reply: candidate(anchor: "pkg/app.py::ghost")))
        model.refresh()
        model.open(conceptId: "k1")
        await model.question(band: 1)
        XCTAssertEqual(model.phase, .picking)
        XCTAssertTrue(model.problem?.message.contains("couldn't write a question it could check") ?? false)
        XCTAssertFalse(model.problem?.details.isEmpty ?? true, "the verifier's reasons are kept for Details")
        XCTAssertEqual(try store(entry).teachingQuestions(conceptId: "k1", verifiedOnly: true).count, 0)
    }

    func testTransferQuestionsComeFromTheMac() async throws {
        let entry = try await importedEntry()
        try seedConcept(store(entry))
        let drafter = ScriptedDrafter(reply: candidate())
        let model = model(entry, drafter: drafter)
        model.refresh()
        model.open(conceptId: "k1")
        await model.question(band: 3)
        XCTAssertEqual(drafter.calls.count, 0, "band 3 is never drafted on the phone")
        XCTAssertTrue(model.problem?.message.contains("Mac") ?? false)

        // A band-3 question shipped from the Mac is offered.
        try seedQuestion(store(entry), id: "mac3", band: 3, by: .claudeCode, at: "t1")
        await model.question(band: 3)
        guard case .questioning(let card) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(card.id, "mac3")
    }

    // MARK: - Grading

    func testGradingKeepsTheAttemptButWritesNoMasteryUntilCalibrated() async throws {
        XCTAssertFalse(LearnModel.isCalibrated, "Docs/19 M7: the gate is held")
        let entry = try await importedEntry()
        let store = try store(entry)
        try seedConcept(store)
        try seedQuestion(store, id: "mac", by: .claudeCode, at: "t1")
        let model = model(entry)
        model.refresh()
        model.open(conceptId: "k1")
        model.answerDraft = "helper helps the app run."
        await model.submit()

        guard case .graded(_, let grade) = model.phase else { return XCTFail("\(model.phase) \(String(describing: model.problem))") }
        XCTAssertEqual(grade.verdict, TeachingVerdictTier.solid.rawValue)
        XCTAssertNil(grade.masteryAfter, "no mastery estimate moves")
        XCTAssertEqual(try store.teachingAttempts(questionId: "mac").count, 1, "the attempt itself is kept")
        XCTAssertEqual(try store.teachingAttempts(questionId: "mac").first?.modelUsed, TeachingQuestionSource.device.rawValue)
        XCTAssertNil(try store.knowledgeState(developerId: TeachingLoader.developerId, conceptId: "k1"))

        // "Another question" skips the one just answered; with none left, the device drafts.
        await model.anotherQuestion()
        guard case .questioning(let next) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertNotEqual(next.id, "mac")
    }
}
