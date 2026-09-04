import XCTest
@testable import OrionCodeIntel

final class TestDetectorSymbolTests: XCTestCase {
    func testTestFunctionInTestFile() {
        XCTAssertTrue(TestDetector.isTestSymbol(
            name: "test_thing", kind: "function", decorators: [], fileIsTest: true))
        XCTAssertTrue(TestDetector.isTestSymbol(
            name: "testLegacy", kind: "method", decorators: [], fileIsTest: true))
    }
    func testPytestDecorator() {
        XCTAssertTrue(TestDetector.isTestSymbol(
            name: "scenario", kind: "function",
            decorators: ["pytest.mark.parametrize"], fileIsTest: true))
    }
    func testNonTest() {
        XCTAssertFalse(TestDetector.isTestSymbol(
            name: "helper", kind: "function", decorators: [], fileIsTest: true))
        XCTAssertFalse(TestDetector.isTestSymbol(
            name: "test_thing", kind: "function", decorators: [], fileIsTest: false))
        XCTAssertFalse(TestDetector.isTestSymbol(
            name: "test_data", kind: "constant", decorators: [], fileIsTest: true))
    }
}

final class TestMapperTests: XCTestCase {

    private let mapper = TestMapper(repositoryId: "r", commitHash: "c", runId: "run")

    func testCallFromTestToProductionWithNameMatchIsHigh() {
        let prodFile = Make.file(id: "pf", path: "pkg/thing.py", module: "pkg.thing")
        let testFile = Make.file(id: "tf", path: "tests/test_thing.py", module: "tests.test_thing", isTest: true)
        let compute = Make.symbol(id: "s_compute", fileId: "pf", anchor: "pkg/thing.py::compute", kind: "function", name: "compute")
        let testFn = Make.symbol(id: "s_test", fileId: "tf", anchor: "tests/test_thing.py::test_compute", kind: "function", name: "test_compute")

        let edges = mapper.build(
            files: [prodFile, testFile], symbols: [compute, testFn],
            relationships: [Make.rel(type: "calls", source: "s_test", target: "s_compute")]
        )
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].relationshipType, "tested_by")
        XCTAssertEqual(edges[0].sourceSymbolId, "s_test")
        XCTAssertEqual(edges[0].targetSymbolId, "s_compute")
        XCTAssertEqual(edges[0].confidenceTier, "high")
        XCTAssertEqual(edges[0].provenance, "heuristic:test_reference")
    }

    func testCallWithoutNameMatchIsMedium_referenceIsLow() {
        let prodFile = Make.file(id: "pf", path: "pkg/other.py", module: "pkg.other")
        let testFile = Make.file(id: "tf", path: "tests/test_thing.py", module: "tests.test_thing", isTest: true)
        let f = Make.symbol(id: "s_f", fileId: "pf", anchor: "pkg/other.py::f", kind: "function", name: "f")
        let g = Make.symbol(id: "s_g", fileId: "pf", anchor: "pkg/other.py::G", kind: "class", name: "G")
        let t = Make.symbol(id: "s_t", fileId: "tf", anchor: "tests/test_thing.py::test_x", kind: "function", name: "test_x")

        let edges = mapper.build(
            files: [prodFile, testFile], symbols: [f, g, t],
            relationships: [
                Make.rel(type: "calls", source: "s_t", target: "s_f"),
                Make.rel(type: "references", source: "s_t", target: "s_g"),
            ]
        )
        let byTarget = Dictionary(uniqueKeysWithValues: edges.map { ($0.targetSymbolId, $0.confidenceTier) })
        XCTAssertEqual(byTarget["s_f"], "medium")
        XCTAssertEqual(byTarget["s_g"], "low")
    }

    func testImportOnlyFromTestModule() {
        let prodInit = Make.file(id: "pf", path: "pkg/__init__.py", module: "pkg")
        let testFile = Make.file(id: "tf", path: "tests/test_a.py", module: "tests.test_a", isTest: true)
        let prodMod = Make.symbol(id: "s_pm", fileId: "pf", anchor: "pkg/__init__.py", kind: "package", name: "pkg")
        let testMod = Make.symbol(id: "s_tm", fileId: "tf", anchor: "tests/test_a.py", kind: "module", name: "test_a")

        let edges = mapper.build(
            files: [prodInit, testFile], symbols: [prodMod, testMod],
            relationships: [Make.rel(type: "imports", source: "s_tm", target: "s_pm")]
        )
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].confidenceTier, "low")
        XCTAssertEqual(edges[0].sourceSymbolId, "s_tm")
    }

    func testNonTestSourceAndTestTargetAreIgnored() {
        let prodFile = Make.file(id: "pf", path: "pkg/thing.py", module: "pkg.thing")
        let testFile = Make.file(id: "tf", path: "tests/test_thing.py", module: "tests.test_thing", isTest: true)
        let helper = Make.symbol(id: "s_h", fileId: "pf", anchor: "pkg/thing.py::helper", kind: "function", name: "helper")
        let compute = Make.symbol(id: "s_c", fileId: "pf", anchor: "pkg/thing.py::compute", kind: "function", name: "compute")
        let testFn = Make.symbol(id: "s_t", fileId: "tf", anchor: "tests/test_thing.py::test_compute", kind: "function", name: "test_compute")
        let fixture = Make.symbol(id: "s_fx", fileId: "tf", anchor: "tests/test_thing.py::fixture", kind: "function", name: "fixture")

        let edges = mapper.build(
            files: [prodFile, testFile], symbols: [helper, compute, testFn, fixture],
            relationships: [
                Make.rel(type: "calls", source: "s_h", target: "s_c"),       // prod -> prod
                Make.rel(type: "calls", source: "s_fx", target: "s_c"),      // non-test fn -> prod
                Make.rel(type: "calls", source: "s_t", target: "s_fx"),      // test -> test fn
            ]
        )
        XCTAssertTrue(edges.isEmpty)
    }

    func testDedupKeepsBestTier() {
        let prodFile = Make.file(id: "pf", path: "pkg/thing.py", module: "pkg.thing")
        let testFile = Make.file(id: "tf", path: "tests/test_thing.py", module: "tests.test_thing", isTest: true)
        let compute = Make.symbol(id: "s_c", fileId: "pf", anchor: "pkg/thing.py::compute", kind: "function", name: "compute")
        let testFn = Make.symbol(id: "s_t", fileId: "tf", anchor: "tests/test_thing.py::test_compute", kind: "function", name: "test_compute")

        let edges = mapper.build(
            files: [prodFile, testFile], symbols: [compute, testFn],
            relationships: [
                Make.rel(type: "references", source: "s_t", target: "s_c"),  // low
                Make.rel(type: "calls", source: "s_t", target: "s_c"),       // high (name match)
            ]
        )
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].confidenceTier, "high")
    }
}
