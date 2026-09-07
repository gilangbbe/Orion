import XCTest

@testable import Orion
import OrionCodeIntel

/// `ArchitectureModelLoader` is pure logic over `CodebaseModelStore` -- no SwiftUI, no Grape --
/// so these tests exercise it directly against real analyzed fixture repos, the same posture
/// `AnalysisRunnerTests`/`SemanticInvestigationRunnerTests` already established.
final class ArchitectureModelLoaderTests: XCTestCase {
    private func makeRepoRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchitectureModelLoaderTests-\(UUID().uuidString)")
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

    // MARK: no analyzed run

    func testLoadWithNoAnalyzedRunReturnsEmptyStructuralModel() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchitectureModelLoaderTests-none-\(UUID().uuidString)")

        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)

        XCTAssertEqual(model.layer, .structural(moduleCount: 0))
        XCTAssertTrue(model.nodes.isEmpty)
        XCTAssertTrue(model.edges.isEmpty)
    }

    // MARK: structural fallback (no investigation)

    func testLoadWithoutInvestigationBuildsStructuralModuleGraph() throws {
        let repoRoot = try makeRepoRoot()
        try "import b\n\ndef foo():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "def bar():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)

        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)

        guard case .structural(let moduleCount) = model.layer else {
            return XCTFail("expected .structural, got \(model.layer)")
        }
        XCTAssertEqual(moduleCount, 2)
        XCTAssertEqual(model.nodes.count, 2)
        XCTAssertTrue(model.nodes.allSatisfy { $0.epistemicType == "FACT" && $0.confidenceTier == nil })
        XCTAssertEqual(model.edges.count, 1)
        XCTAssertEqual(model.edges.first?.type, "imports")
        // Every edge endpoint must be a real node id -- Grape crashes on a dangling reference,
        // so this is the one invariant the loader absolutely must uphold.
        let nodeIds = Set(model.nodes.map(\.id))
        for edge in model.edges {
            XCTAssertTrue(nodeIds.contains(edge.sourceId))
            XCTAssertTrue(nodeIds.contains(edge.targetId))
        }
    }

    func testLoadNeverProducesAnEdgeReferencingAMissingNode() throws {
        // A repo with only non-module relationships (e.g. calls, once SCIP is available) proves
        // the structural builder filters to `imports`-among-modules only, not just happens not
        // to have a dangling case in the simple fixture above.
        let repoRoot = try makeRepoRoot()
        try "def foo():\n    return 1\n".write(
            to: repoRoot.appendingPathComponent("solo.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)

        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)

        XCTAssertEqual(model.nodes.count, 1)
        XCTAssertTrue(model.edges.isEmpty)
    }

    // MARK: semantic (a real investigation with components)

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

    func testLoadWithAnInvestigationBuildsSemanticModelWithMemberCountsAsSize() throws {
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
                {"name": "Empty", "members": ["a.py::foo"]}
              ],
              "component_relationships": [{"source": "Core", "target": "Empty", "type": "depends_on"}],
              "claims": [],
              "uncertainties": []
            }
            """, into: outputDirectory)

        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)

        guard case .semantic(_, let componentCount, _) = model.layer else {
            return XCTFail("expected .semantic, got \(model.layer)")
        }
        XCTAssertEqual(componentCount, 2)
        XCTAssertEqual(model.nodes.count, 2)
        let core = try XCTUnwrap(model.nodes.first { $0.name == "Core" })
        XCTAssertEqual(core.size, 2)  // two members
        XCTAssertEqual(core.epistemicType, "INTERPRETATION")
        XCTAssertEqual(model.edges.count, 1)
    }

    // MARK: uncertainties (Docs/13 M6's "Open questions")

    func testLoadPopulatesUncertaintiesFromInvestigationWideUnknownClaims() throws {
        let repoRoot = try makeRepoRoot()
        try "def foo():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)
        try ingestSemanticFindings(
            """
            {
              "schema_version": "phase2.v1",
              "components": [{"name": "Core", "members": ["a.py::foo"]}],
              "component_relationships": [],
              "claims": [{"claim_type": "INTERPRETATION", "statement": "foo does nothing.", "evidence": ["a.py::foo"], "confidence": "high"}],
              "uncertainties": ["Whether foo is ever called at runtime.", "Whether this module has side effects."]
            }
            """, into: outputDirectory)

        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)

        XCTAssertEqual(
            Set(model.uncertainties),
            ["Whether foo is ever called at runtime.", "Whether this module has side effects."])
    }

    func testLoadUncertaintiesIsEmptyWhenInvestigationHasNoUncertainties() throws {
        let repoRoot = try makeRepoRoot()
        try "def foo():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)
        try ingestSemanticFindings(
            """
            {"schema_version": "phase2.v1", "components": [{"name": "Core", "members": ["a.py::foo"]}], "component_relationships": [], "claims": [], "uncertainties": []}
            """, into: outputDirectory)

        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)

        XCTAssertTrue(model.uncertainties.isEmpty)
    }

    func testLoadUncertaintiesIsEmptyForTheStructuralFallback() throws {
        let repoRoot = try makeRepoRoot()
        try "def foo():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)
        // No investigation ingested at all -- the structural layer never has uncertainties.

        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)

        guard case .structural = model.layer else {
            return XCTFail("expected .structural, got \(model.layer)")
        }
        XCTAssertTrue(model.uncertainties.isEmpty)
    }

    func testLoadDropsSelfReferentialComponentRelationships() throws {
        let repoRoot = try makeRepoRoot()
        try "def foo():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)
        try ingestSemanticFindings(
            """
            {
              "schema_version": "phase2.v1",
              "components": [{"name": "Core", "members": ["a.py::foo"]}],
              "component_relationships": [{"source": "Core", "target": "Core", "type": "depends_on"}],
              "claims": [],
              "uncertainties": []
            }
            """, into: outputDirectory)

        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)

        XCTAssertEqual(model.nodes.count, 1)
        XCTAssertTrue(model.edges.isEmpty, "a self-loop should be filtered, not passed to Grape")
    }

    func testLoadFallsBackToStructuralWhenInvestigationHasZeroSurvivingComponents() throws {
        let repoRoot = try makeRepoRoot()
        try "def foo():\n    pass\n".write(
            to: repoRoot.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let outputDirectory = try analyze(repoRoot)
        // Every member anchor is bogus -- SemanticImporter drops the whole component (Docs/11
        // step 2), leaving zero components persisted despite a real investigation existing.
        try ingestSemanticFindings(
            """
            {
              "schema_version": "phase2.v1",
              "components": [{"name": "Bogus", "members": ["a.py::doesNotExist"]}],
              "component_relationships": [],
              "claims": [],
              "uncertainties": ["Nothing grounded."]
            }
            """, into: outputDirectory)

        let model = try ArchitectureModelLoader.load(outputDirectory: outputDirectory)

        guard case .structural = model.layer else {
            return XCTFail("expected fallback to .structural, got \(model.layer)")
        }
        XCTAssertEqual(model.nodes.count, 1)  // the one real module, from Phase 1 data
    }
}
