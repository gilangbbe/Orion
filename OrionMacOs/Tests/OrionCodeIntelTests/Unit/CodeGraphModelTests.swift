import XCTest
@testable import OrionCodeIntel

final class CodeGraphModelTests: XCTestCase {

    private func model() -> CodeGraphModel {
        let run = AnalysisRunRecord(
            id: "run", repositoryId: "repo", commitHash: "c0ffee", status: "succeeded",
            startedAt: "t0", finishedAt: "t1", orionVersion: "0.1.0", resolver: "scip-python@x",
            grammarVersions: ["python": "0.23.6"], toolVersions: [:], stageTimings: [:],
            fileCount: 2, symbolCount: 0, relationshipCount: 0, diagnosticCount: 0, error: nil
        )
        let repo = RepositoryRecord(
            id: "repo", sourceURL: nil, localPath: "/x", commitHash: "c0ffee",
            languages: ["python"], analysisStatus: .succeeded, createdAt: "t0", updatedAt: "t1"
        )
        let pf = Make.file(id: "pf", path: "pkg/core.py", module: "pkg.core")
        let tf = Make.file(id: "tf", path: "tests/test_core.py", module: "tests.test_core", isTest: true)
        let mod = Make.symbol(id: "s_mod", fileId: "pf", anchor: "pkg/core.py", kind: "module", name: "core")
        let base = Make.symbol(id: "s_base", fileId: "pf", anchor: "pkg/core.py::Base", kind: "class", name: "Base")
        let child = Make.symbol(id: "s_child", fileId: "pf", anchor: "pkg/core.py::Child", kind: "class", name: "Child")
        var m1 = Make.symbol(id: "s_run", fileId: "pf", anchor: "pkg/core.py::Child.run", kind: "method", name: "run")
        m1.parentSymbolId = "s_child"
        var childP = child; childP.parentSymbolId = "s_mod"
        var baseP = base; baseP.parentSymbolId = "s_mod"
        let tmod = Make.symbol(id: "s_tmod", fileId: "tf", anchor: "tests/test_core.py", kind: "module", name: "test_core")
        let tfn = Make.symbol(id: "s_tfn", fileId: "tf", anchor: "tests/test_core.py::test_run", kind: "function", name: "test_run")

        let rels = [
            Make.rel(type: "extends", source: "s_child", target: "s_base"),
            Make.rel(type: "calls", source: "s_tfn", target: "s_run"),
            Make.rel(type: "tested_by", source: "s_tfn", target: "s_run"),
        ]
        return CodeGraphModel(
            run: run, repo: repo, files: [pf, tf],
            symbols: [mod, baseP, childP, m1, tmod, tfn],
            relationships: rels, externalDependencies: [], diagnostics: []
        )
    }

    func testSymbolExportCarriesParentAnchorAndFile() {
        let s = model().symbolExports().first { $0.anchor == "pkg/core.py::Child.run" }!
        XCTAssertEqual(s.file, "pkg/core.py")
        XCTAssertEqual(s.parentAnchor, "pkg/core.py::Child")
        XCTAssertEqual(s.modulePath, "pkg.core")
    }

    func testRelationshipEndpoints() {
        let exts = model().relationshipExports().first { $0.type == "extends" }!
        XCTAssertEqual(exts.source.anchor, "pkg/core.py::Child")
        XCTAssertEqual(exts.target.anchor, "pkg/core.py::Base")
        XCTAssertEqual(exts.target.kind, "class")
        XCTAssertNil(exts.target.external)
    }

    func testCodeGraphClassesAndTestMap() {
        let g = model().codeGraphExport()
        XCTAssertEqual(g.stats.symbolsByKind["class"], 2)
        let child = g.classes.first { $0.anchor == "pkg/core.py::Child" }!
        XCTAssertEqual(child.bases, ["pkg/core.py::Base"])
        XCTAssertEqual(child.methods, ["pkg/core.py::Child.run"])
        XCTAssertEqual(g.testMap.first { $0.test == "tests/test_core.py::test_run" }?.targets,
                       ["pkg/core.py::Child.run"])
        XCTAssertTrue(g.entrypoints.contains("pkg/core.py::Base"))
    }

    func testRepositoryExportResolution() {
        let r = model().repositoryExport()
        XCTAssertEqual(r.counts.symbols, 6)
        XCTAssertEqual(r.resolution.calls, 1)
        XCTAssertEqual(r.resolution.totalRelationships, 3)
    }
}
