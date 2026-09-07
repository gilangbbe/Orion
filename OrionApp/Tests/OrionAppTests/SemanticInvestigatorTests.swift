import XCTest

@testable import Orion

/// Every test here uses a stand-in `claude` shell script instead of the real CLI -- no network
/// call, no real API cost -- mirroring how `RepositoryClonerTests` mocks `git` and Docs/12's own
/// `ClaudeCodeInvestigatorTests` mocks `claude` for the single-question contract.
final class SemanticInvestigatorTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemanticInvestigatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStubClaude(_ script: String) throws -> URL {
        let directory = try makeTempDirectory()
        let scriptURL = directory.appendingPathComponent("claude")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    // MARK: prompt/argument construction (no process launched)

    func testBuildPromptIncludesSchemaVersionAndExportDir() {
        let investigator = SemanticInvestigator(
            repoRoot: URL(fileURLWithPath: "/repo"), exportDir: URL(fileURLWithPath: "/repo/.orion/export"))
        let prompt = investigator.buildPrompt()
        XCTAssertTrue(prompt.contains(SemanticSchemaContract.schemaVersion))
        XCTAssertTrue(prompt.contains("/repo/.orion/export"))
        XCTAssertTrue(prompt.contains("group the repository's symbols"))
    }

    func testBuildArgumentsProducesExpectedReadOnlyFlags() throws {
        let investigator = SemanticInvestigator(
            repoRoot: URL(fileURLWithPath: "/repo"), exportDir: URL(fileURLWithPath: "/repo/.orion/export"),
            model: "claude-sonnet-5", maxBudgetUsd: 1.5, claudeBinary: "claude")
        let args = try investigator.buildArguments(prompt: "PROMPT")

        XCTAssertEqual(args.first, "claude")
        XCTAssertEqual(args.last, "PROMPT")
        XCTAssertTrue(args.contains("--tools"))
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "Read,Grep,Glob")
        XCTAssertTrue(args.contains("--permission-mode"))
        XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], "bypassPermissions")
        XCTAssertTrue(args.contains("--max-budget-usd"))
        XCTAssertEqual(args[args.firstIndex(of: "--max-budget-usd")! + 1], "1.5")
        // Never Bash/Edit/Write -- read-only by construction, not just by convention.
        XCTAssertFalse(args.contains("Bash"))
        XCTAssertFalse(args.contains("Edit"))
        XCTAssertFalse(args.contains("Write"))
    }

    func testCLIJSONSchemaHasNoDollarSchemaKey() {
        // The exact reason `cli_json_schema()` exists in the Python original -- the CLI's
        // offline validator rejects the request if `$schema` names the 2020-12 dialect.
        XCTAssertNil(SemanticSchemaContract.cliJSONSchema()["$schema"])
    }

    // MARK: wrapper parsing (real short-lived stub process)

    func testInvestigatePrefersStructuredOutputOverResultText() async throws {
        let stub = try makeStubClaude(
            """
            #!/bin/sh
            cat <<'JSON'
            {"structured_output": {"schema_version": "phase2.v1", "components": []}, "result": "{\\"schema_version\\": \\"wrong\\"}", "session_id": "s1", "num_turns": 4, "total_cost_usd": 0.21, "is_error": false}
            JSON
            """)
        let investigator = SemanticInvestigator(
            repoRoot: FileManager.default.temporaryDirectory, exportDir: FileManager.default.temporaryDirectory,
            claudeBinary: stub.path)

        let result = try await investigator.investigate()

        XCTAssertNotNil(result.candidateData)
        let decoded = try JSONSerialization.jsonObject(with: result.candidateData!) as? [String: Any]
        XCTAssertEqual(decoded?["schema_version"] as? String, "phase2.v1")
        XCTAssertEqual(result.sessionId, "s1")
        XCTAssertEqual(result.numTurns, 4)
        XCTAssertEqual(result.totalCostUsd, 0.21)
        XCTAssertFalse(result.isError)
    }

    func testInvestigateFallsBackToExtractingResultTextWhenStructuredOutputAbsent() async throws {
        let stub = try makeStubClaude(
            """
            #!/bin/sh
            cat <<'JSON'
            {"result": "some preamble {\\"schema_version\\": \\"phase2.v1\\", \\"components\\": []} trailer", "is_error": false}
            JSON
            """)
        let investigator = SemanticInvestigator(
            repoRoot: FileManager.default.temporaryDirectory, exportDir: FileManager.default.temporaryDirectory,
            claudeBinary: stub.path)

        let result = try await investigator.investigate()

        XCTAssertNotNil(result.candidateData)
        let decoded = try JSONSerialization.jsonObject(with: result.candidateData!) as? [String: Any]
        XCTAssertEqual(decoded?["schema_version"] as? String, "phase2.v1")
    }

    func testInvestigateSurfacesErrorsArrayAsErrorMessage() async throws {
        let stub = try makeStubClaude(
            """
            #!/bin/sh
            cat <<'JSON'
            {"is_error": true, "errors": ["Reached maximum budget ($1.00)"], "subtype": "error_max_budget_usd"}
            JSON
            """)
        let investigator = SemanticInvestigator(
            repoRoot: FileManager.default.temporaryDirectory, exportDir: FileManager.default.temporaryDirectory,
            claudeBinary: stub.path)

        let result = try await investigator.investigate()

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.errorMessage, "Reached maximum budget ($1.00)")
    }

    func testInvestigateReportsTimeout() async throws {
        let stub = try makeStubClaude(
            """
            #!/bin/sh
            sleep 5
            """)
        let investigator = SemanticInvestigator(
            repoRoot: FileManager.default.temporaryDirectory, exportDir: FileManager.default.temporaryDirectory,
            timeoutSeconds: 1, claudeBinary: stub.path)

        let result = try await investigator.investigate()

        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.candidateData)
    }

    func testInvestigatePicksDominantModelByCost() async throws {
        let stub = try makeStubClaude(
            """
            #!/bin/sh
            cat <<'JSON'
            {"structured_output": {"schema_version": "phase2.v1", "components": []}, "modelUsage": {"claude-haiku-4-5": {"costUSD": 0.01}, "claude-sonnet-5": {"costUSD": 0.87}}, "is_error": false}
            JSON
            """)
        let investigator = SemanticInvestigator(
            repoRoot: FileManager.default.temporaryDirectory, exportDir: FileManager.default.temporaryDirectory,
            claudeBinary: stub.path)

        let result = try await investigator.investigate()

        XCTAssertEqual(result.modelUsed, "claude-sonnet-5")
    }
}
