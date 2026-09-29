import XCTest

@testable import OrionAgent

final class CoreAIModelLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var environment: [String: String] { [CoreAIModelLocator.environmentKey: root.path] }

    func testDefaultRootIsApplicationSupport() {
        let url = CoreAIModelLocator.rootDirectory(environment: [:])
        XCTAssertTrue(url.path.hasSuffix("Library/Application Support/Orion/CoreAIModels"), url.path)
    }

    func testEnvironmentOverridesRoot() {
        XCTAssertEqual(CoreAIModelLocator.rootDirectory(environment: environment).standardizedFileURL.path,
                       root.standardizedFileURL.path)
    }

    func testFinishedExportResolvesToTheBundleFolder() throws {
        let bundle = root.appendingPathComponent("qwen3-8b-4bit", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("metadata.json"))

        let resolved = try CoreAIModelLocator.bundleURL(environment: environment)
        XCTAssertEqual(resolved.standardizedFileURL.path, bundle.standardizedFileURL.path)
    }

    func testUnfinishedExportIsNotFoundAndNamesTheExportCommand() throws {
        // A folder without metadata.json is an export that never finished (metadata is written last).
        let bundle = root.appendingPathComponent("qwen3-4b-4bit_weights_8bit_kv_cache", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try CoreAIModelLocator.bundleURL(variant: "qwen3-4b-4bit_weights_8bit_kv_cache", environment: environment)
        ) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(
                message.contains("export-qwen3.sh --model qwen3-4b --compression 4bit_weights_8bit_kv_cache"),
                message)
        }
    }

    private func export(_ variant: String) throws {
        let bundle = root.appendingPathComponent(variant, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("metadata.json"))
    }

    /// Docs/18 M6: the app's setup notice lists the bundles a page's roles resolve to (per the
    /// recommended table: answering on 4B, judging/drafting on 8B) that aren't exported yet.
    func testMissingVariantsFollowTheRoleTableAndDeduplicate() throws {
        let backend = LocalModelBackend.defaultCoreAI
        XCTAssertEqual(
            CoreAIModelLocator.missingVariants(
                for: backend, roles: [.answering, .drafting, .judging], environment: environment),
            [
                backend.resolved(for: .answering).backend.variant,
                backend.resolved(for: .judging).backend.variant,
            ].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })

        try export(backend.resolved(for: .judging).backend.variant)
        XCTAssertFalse(
            CoreAIModelLocator.missingVariants(for: backend, roles: [.drafting, .judging], environment: environment)
                .contains(backend.resolved(for: .judging).backend.variant))
        try export(backend.resolved(for: .answering).backend.variant)
        XCTAssertEqual(
            CoreAIModelLocator.missingVariants(
                for: backend, roles: LocalModelRole.allCases, environment: environment), [])
    }

    /// `String(describing:)` is how the app reports a failed ask or grade -- it must carry the
    /// export command, not the enum case.
    func testLocatorErrorDescribesItselfWithTheExportCommand() {
        let error = CoreAIModelLocator.LocatorError.bundleNotFound(root, variant: "qwen3-4b-4bit")
        XCTAssertTrue(
            String(describing: error).contains("export-qwen3.sh --model qwen3-4b --compression 4bit"),
            String(describing: error))
        XCTAssertEqual(
            CoreAIModelLocator.exportCommand(variant: "qwen3-8b-4bit_weights_8bit_kv_cache"),
            "OrionMacOs/scripts/coreai/export-qwen3.sh --model qwen3-8b --compression 4bit_weights_8bit_kv_cache")
    }
}
