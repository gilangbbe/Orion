import XCTest

@testable import Orion
import OrionCodeIntel

final class ComponentDetailLoaderTests: XCTestCase {
    private func makeRepoRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComponentDetailLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func analyze(_ repoRoot: URL) throws -> URL {
        let outputDirectory = RepositorySession.outputDirectory(forRepoRoot: repoRoot)
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        let database = try OrionDatabase(
            path: outputDirectory.appendingPathComponent("orion.db").path)
        _ = try AnalysisPipeline(database: database).run(
            AnalysisInput(repoPath: repoRoot, outputDirectory: outputDirectory, resolve: false))
        return outputDirectory
    }

    private func ingestSemanticFindings(_ json: String, into outputDirectory: URL) throws {
        let database = try OrionDatabase(
            path: outputDirectory.appendingPathComponent("orion.db").path)
        let store = Store(database)
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let candidateURL = outputDirectory.appendingPathComponent("semantic_findings.json")
        try json.write(to: candidateURL, atomically: true, encoding: .utf8)
        _ = try SemanticImporter(store: store).ingest(
            candidateURL: candidateURL, metaURL: nil, run: run, now: Timestamp.now())
    }

    // MARK: semantic

    func testLoadSemanticIncludesMembersDependenciesAndOverlappingClaimOnly() throws {
        let repoRoot = try makeRepoRoot()
        try "def foo():\n    pass\n\ndef bar():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)
        try ingestSemanticFindings(
            """
            {
              "schema_version": "phase2.v1",
              "components": [
                {"name": "Core", "description": "The main logic.", "members": ["a.py::foo", "a.py::bar"]},
                {"name": "Other", "members": ["a.py::foo"]}
              ],
              "component_relationships": [{"source": "Core", "target": "Other", "type": "depends_on"}],
              "claims": [
                {"claim_type": "INTERPRETATION", "statement": "foo does nothing.", "evidence": ["a.py::foo"], "confidence": "high"},
                {"claim_type": "INTERPRETATION", "statement": "Unrelated claim.", "evidence": ["a.py::bar"], "confidence": "low"}
              ],
              "uncertainties": []
            }
            """, into: outputDirectory)
        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)
        let coreNode = try XCTUnwrap(model.nodes.first { $0.name == "Core" })

        let detail = try ComponentDetailLoader.load(
            outputDirectory: outputDirectory, node: coreNode, layer: model.layer)

        XCTAssertEqual(detail.name, "Core")
        XCTAssertEqual(detail.subtitle, "The main logic.")
        XCTAssertFalse(detail.isStructural)
        XCTAssertEqual(Set(detail.members.map(\.name)), ["foo", "bar"])
        XCTAssertEqual(detail.dependencies.count, 1)
        XCTAssertEqual(detail.dependencies.first?.targetName, "Other")
        // Both claims cite members of Core (foo and bar are both Core's members) -- both should
        // surface, since "overlap with this component's members" is the real link, not just the
        // first evidence anchor.
        XCTAssertEqual(detail.claims.count, 2)
    }

    func testLoadSemanticExcludesClaimWithNoOverlappingEvidence() throws {
        let repoRoot = try makeRepoRoot()
        try "def foo():\n    pass\n\ndef bar():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)
        try ingestSemanticFindings(
            """
            {
              "schema_version": "phase2.v1",
              "components": [
                {"name": "FooOnly", "members": ["a.py::foo"]},
                {"name": "BarOnly", "members": ["a.py::bar"]}
              ],
              "component_relationships": [],
              "claims": [{"claim_type": "INTERPRETATION", "statement": "bar does nothing.", "evidence": ["a.py::bar"], "confidence": "high"}],
              "uncertainties": []
            }
            """, into: outputDirectory)
        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)
        let fooOnlyNode = try XCTUnwrap(model.nodes.first { $0.name == "FooOnly" })

        let detail = try ComponentDetailLoader.load(
            outputDirectory: outputDirectory, node: fooOnlyNode, layer: model.layer)

        XCTAssertTrue(detail.claims.isEmpty, "the claim only cites bar, not a FooOnly member")
    }

    func testLoadSemanticWithUnknownComponentIdFallsBackToEmptyDetail() throws {
        let repoRoot = try makeRepoRoot()
        try "def foo():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)
        try ingestSemanticFindings(
            """
            {"schema_version": "phase2.v1", "components": [{"name": "Core", "members": ["a.py::foo"]}], "component_relationships": [], "claims": [], "uncertainties": []}
            """, into: outputDirectory)
        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)
        let bogusNode = ArchitectureNode(
            id: "does-not-exist", name: "Ghost", subtitle: nil, size: 0, confidenceTier: "high",
            epistemicType: "INTERPRETATION")

        let detail = try ComponentDetailLoader.load(
            outputDirectory: outputDirectory, node: bogusNode, layer: model.layer)

        XCTAssertEqual(detail.name, "Ghost")
        XCTAssertTrue(detail.members.isEmpty)
    }

    // MARK: structural

    func testLoadStructuralGroupsSymbolsByFileAndFindsImportDependency() throws {
        let repoRoot = try makeRepoRoot()
        try "import b\n\ndef foo():\n    pass\n\ndef qux():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "def bar():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)
        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)
        guard case .structural = model.layer else {
            return XCTFail("expected .structural, got \(model.layer)")
        }
        let moduleA = try XCTUnwrap(model.nodes.first { $0.name == "a" })

        let detail = try ComponentDetailLoader.load(
            outputDirectory: outputDirectory, node: moduleA, layer: model.layer)

        XCTAssertTrue(detail.isStructural)
        XCTAssertEqual(detail.epistemicType, "FACT")
        XCTAssertNil(detail.confidenceTier)
        // "b" is the real `import_alias` symbol `import b` creates in the same file -- a
        // genuine same-file member, not a bug (found live: the first version of this test
        // didn't anticipate it).
        XCTAssertEqual(Set(detail.members.map(\.name)), ["foo", "qux", "b"])
        XCTAssertEqual(detail.members.first { $0.name == "b" }?.kind, "import_alias")
        XCTAssertEqual(detail.dependencies.count, 1)
        XCTAssertEqual(detail.dependencies.first?.targetName, "b")
        XCTAssertTrue(detail.claims.isEmpty)
    }
}
