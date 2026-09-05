import XCTest
@testable import OrionCodeIntel

/// Docs/11 M3: `SemanticExporter` — `components.jsonl`/`claims.jsonl`/`evidence.jsonl`/
/// `investigations.jsonl`/`semantic_model.json`, regenerable from the DB without re-ingesting.
final class SemanticExportTests: XCTestCase {

    private var keepAlive: [TempDir] = []

    /// Same fixture shape as `SemanticImporterTests.analyzed()`: `pkg/a.py` imports
    /// `pkg/b.py`; `pkg/c.py` is unconnected. Returns the populated `Store` plus the `outDir`
    /// export files are written under.
    private func analyzed() throws -> (store: Store, outDir: URL) {
        let repo = try TempDir()
        keepAlive.append(repo)
        let git = GitRunner(repoPath: repo.url)
        _ = try git.run(["init", "--quiet", "-b", "main"])
        _ = try git.run(["config", "user.email", "t@e.com"])
        _ = try git.run(["config", "user.name", "T"])
        try repo.write("pkg/__init__.py", "")
        try repo.write("pkg/a.py", "from pkg import b\n\nclass Widget:\n    def run(self):\n        return 1\n")
        try repo.write("pkg/b.py", "VALUE = 1\n")
        _ = try git.run(["add", "."])
        _ = try git.run(["commit", "--quiet", "-m", "init"])

        let out = try TempDir()
        keepAlive.append(out)
        let db = try OrionDatabase(path: out.path("orion.db"))
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: repo.url, outputDirectory: out.url, resolve: false, export: false)
        )
        return (Store(db), out.url)
    }

    private func ingestCleanCandidate(store: Store) throws {
        let run = try XCTUnwrap(store.latestRun(commitHash: nil))
        let dir = try TempDir(); keepAlive.append(dir)
        try dir.write("candidate.json", """
        {
          "schema_version": "phase2.v1",
          "components": [
            {"name": "Alpha", "description": "A.", "architectural_role": "core", "members": ["pkg/a.py"]},
            {"name": "Beta", "members": ["pkg/b.py"]}
          ],
          "component_relationships": [{"source": "Alpha", "target": "Beta", "type": "depends_on"}],
          "claims": [{
            "claim_type": "INTERPRETATION", "statement": "a.py imports b.py.",
            "evidence": ["pkg/a.py", "pkg/b.py"], "confidence": "high"
          }],
          "uncertainties": ["Something unverified."]
        }
        """)
        _ = try SemanticImporter(store: store).ingest(
            candidateURL: URL(fileURLWithPath: dir.path("candidate.json")),
            metaURL: nil, run: run, now: "t0"
        )
    }

    private func jsonl(at url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }

    func testReturnsNilWhenRunHasNoInvestigationYet() throws {
        let (store, outDir) = try analyzed()
        let result = try SemanticExporter(store: store).export(to: outDir)
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outDir.appendingPathComponent("export/components.jsonl").path
        ))
    }

    func testExportsAllFilesWithExpectedShape() throws {
        let (store, outDir) = try analyzed()
        try ingestCleanCandidate(store: store)

        let exportDir = try XCTUnwrap(try SemanticExporter(store: store).export(to: outDir))
        for name in ["components.jsonl", "claims.jsonl", "evidence.jsonl", "investigations.jsonl", "semantic_model.json"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: exportDir.appendingPathComponent(name).path),
                "missing \(name)"
            )
        }

        let components = try jsonl(at: exportDir.appendingPathComponent("components.jsonl"))
        XCTAssertEqual(components.count, 2)
        let alpha = try XCTUnwrap(components.first { $0["name"] as? String == "Alpha" })
        XCTAssertEqual(alpha["member_anchors"] as? [String], ["pkg/a.py"])
        XCTAssertEqual(alpha["epistemic_type"] as? String, "INTERPRETATION")
        XCTAssertNotNil(alpha["confidence_tier"])

        let claims = try jsonl(at: exportDir.appendingPathComponent("claims.jsonl"))
        // 1 evidenced claim + 1 uncertainty-derived UNKNOWN claim
        XCTAssertEqual(claims.count, 2)
        let evidenced = try XCTUnwrap(claims.first { ($0["evidence_ids"] as? [Any])?.isEmpty == false })
        XCTAssertEqual((evidenced["evidence_ids"] as? [Any])?.count, 2)
        let uncertainty = try XCTUnwrap(claims.first { $0["claim_type"] as? String == "UNKNOWN" })
        XCTAssertEqual((uncertainty["evidence_ids"] as? [Any])?.count, 0)
        XCTAssertNil(uncertainty["subject_ref"] as? String)  // uncertainty-derived claims have no evidence anchor

        let evidence = try jsonl(at: exportDir.appendingPathComponent("evidence.jsonl"))
        XCTAssertEqual(evidence.count, 2)
        XCTAssertTrue(evidence.allSatisfy { $0["anchor"] != nil && ($0["range"] as? [String: Any]) != nil })

        let investigations = try jsonl(at: exportDir.appendingPathComponent("investigations.jsonl"))
        XCTAssertEqual(investigations.count, 1)
        XCTAssertEqual(investigations[0]["outcome"] as? String, "verified")

        let modelData = try Data(contentsOf: exportDir.appendingPathComponent("semantic_model.json"))
        let model = try XCTUnwrap(JSONSerialization.jsonObject(with: modelData) as? [String: Any])
        let modelComponents = try XCTUnwrap(model["components"] as? [[String: Any]])
        XCTAssertEqual(modelComponents.count, 2)
        let relationships = try XCTUnwrap(model["component_relationships"] as? [[String: Any]])
        XCTAssertEqual(relationships.count, 1)
        XCTAssertEqual(relationships[0]["source"] as? String, "Alpha")  // by name, not id
        XCTAssertEqual(relationships[0]["target"] as? String, "Beta")
        XCTAssertEqual(relationships[0]["confidence_tier"] as? String, "high")  // confirmed by a real imports edge
        XCTAssertEqual(model["uncertainty_count"] as? Int, 1)
        XCTAssertEqual(model["contradiction_count"] as? Int, 0)
    }

    func testReexportWithoutReingestingIsByteIdentical() throws {
        let (store, outDir) = try analyzed()
        try ingestCleanCandidate(store: store)

        let first = try XCTUnwrap(try SemanticExporter(store: store).export(to: outDir))
        let firstBytes = try Data(contentsOf: first.appendingPathComponent("semantic_model.json"))

        let second = try XCTUnwrap(try SemanticExporter(store: store).export(to: outDir))
        let secondBytes = try Data(contentsOf: second.appendingPathComponent("semantic_model.json"))

        XCTAssertEqual(firstBytes, secondBytes)
    }

    func testExportCommandWritesSemanticLayerAlongsidePhase1() throws {
        let (store, outDir) = try analyzed()
        try ingestCleanCandidate(store: store)

        // exercises the same combined call path as `orion-index export`
        _ = try CodeGraphExporter(store: store).export(to: outDir)
        let semanticDir = try SemanticExporter(store: store).export(to: outDir)
        XCTAssertNotNil(semanticDir)

        let exportDir = outDir.appendingPathComponent("export")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportDir.appendingPathComponent("symbols.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportDir.appendingPathComponent("components.jsonl").path))
    }
}
