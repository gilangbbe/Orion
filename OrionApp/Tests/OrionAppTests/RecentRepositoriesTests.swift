import XCTest

@testable import Orion

final class RecentRepositoriesTests: XCTestCase {
    private func makeStore(maxEntries: Int = 10) -> (RecentRepositories, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentRepositoriesTests-\(UUID().uuidString)")
            .appendingPathComponent("recent-repositories.json")
        return (RecentRepositories(fileURL: file, maxEntries: maxEntries), file)
    }

    func testLoadWithNoFileReturnsEmpty() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.load(), [])
    }

    func testRecordOpenedPersistsAndReloads() {
        let (store, _) = makeStore()
        store.recordOpened(input: "/tmp/repo-a", displayName: "repo-a")

        let reloaded = store.load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.input, "/tmp/repo-a")
        XCTAssertEqual(reloaded.first?.displayName, "repo-a")
    }

    func testMostRecentlyOpenedComesFirst() {
        let (store, _) = makeStore()
        store.recordOpened(input: "/tmp/repo-a", displayName: "repo-a")
        store.recordOpened(input: "/tmp/repo-b", displayName: "repo-b")

        XCTAssertEqual(store.load().map(\.input), ["/tmp/repo-b", "/tmp/repo-a"])
    }

    func testReopeningExistingEntryMovesItToFrontInsteadOfDuplicating() {
        let (store, _) = makeStore()
        store.recordOpened(input: "/tmp/repo-a", displayName: "repo-a")
        store.recordOpened(input: "/tmp/repo-b", displayName: "repo-b")
        store.recordOpened(input: "/tmp/repo-a", displayName: "repo-a")

        let reloaded = store.load()
        XCTAssertEqual(reloaded.map(\.input), ["/tmp/repo-a", "/tmp/repo-b"])
    }

    func testEntriesAreTrimmedToMaxEntries() {
        let (store, _) = makeStore(maxEntries: 2)
        store.recordOpened(input: "/tmp/repo-a", displayName: "a")
        store.recordOpened(input: "/tmp/repo-b", displayName: "b")
        store.recordOpened(input: "/tmp/repo-c", displayName: "c")

        XCTAssertEqual(store.load().map(\.input), ["/tmp/repo-c", "/tmp/repo-b"])
    }
}
