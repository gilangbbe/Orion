import FoundationModels
import OrionCore
import XCTest

@testable import Orion

/// Docs/19 M6: the iPhone's Ask model without the model -- conversations, "Ask about" routing and
/// error wording. Answering itself needs the on-device model; the on-device benchmark covers it.
@MainActor
final class AskModelTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("orion-ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "orion-ask-tests-\(UUID().uuidString)")
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

    func testAskAboutResumesThatComponentsLatestConversation() async throws {
        let entry = try await importedEntry()
        let existing = try store(entry).createAskSession(
            repositoryId: "repo", commitHash: "c0ffee1234", scopeType: .component, componentId: "comp",
            title: "About App Core", now: "t1")
        let model = AskModel(entry: entry)
        model.startConversation(aboutComponent: "comp", name: "App Core")
        XCTAssertEqual(model.selectedSessionId, existing.id)
        XCTAssertNil(model.pendingComponent)
    }

    func testAskAboutANewComponentScopesTheNextConversation() async throws {
        let entry = try await importedEntry()
        let model = AskModel(entry: entry)
        model.startConversation(aboutComponent: "comp", name: "App Core")
        XCTAssertNil(model.selectedSessionId)
        XCTAssertEqual(model.pendingComponent?.id, "comp")
        XCTAssertEqual(model.pendingComponent?.name, "App Core")

        model.startNewConversation()
        XCTAssertNil(model.pendingComponent, "a plain new conversation isn't scoped")
    }

    func testConversationsLoadAndDelete() async throws {
        let entry = try await importedEntry()
        let session = try store(entry).createAskSession(
            repositoryId: "repo", commitHash: "c0ffee1234", scopeType: .repository, title: "Routing?", now: "t1")
        let model = AskModel(entry: entry)
        model.load()
        XCTAssertEqual(model.sessions.map(\.id), [session.id])
        XCTAssertEqual(model.selectedSessionId, session.id)

        model.delete(session)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.selectedSessionId)
    }

    func testFailuresAreDescribedInPlainWords() {
        let overflow = LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "x"))
        XCTAssertTrue(AskModel.describe(overflow).contains("narrower question"))
        XCTAssertTrue(AskModel.describe(LanguageModelSession.Error.concurrentRequests)
            .contains("current answer"))
    }
}
