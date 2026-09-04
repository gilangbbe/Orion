import XCTest
import GRDB
@testable import OrionCodeIntel

/// M3 headline validation: extracted symbols line up with the Phase 0 benchmark
/// (`benchmark.resolved.json`) — anchors are in benchmark form and their line ranges cover
/// the evidence lines (modulo the benchmark conflating a few subclass anchors with the
/// superclass method that actually defines them, so line containment is checked against any
/// symbol sharing the `::`-leaf name in the same file).
final class StarletteSymbolsTests: XCTestCase {

    private struct Analyzed {
        let db: OrionDatabase
        let anchors: Set<String>
        let ranges: [String: (Int, Int)]
        let leafRanges: [String: [(Int, Int)]]   // "file::leaf" -> ranges
    }

    private static var cache: Analyzed?

    private func analyze() throws -> Analyzed {
        if let c = Self.cache { return c }
        try TestPaths.requireStarlette()
        let out = try TempDir()
        // keep the temp dir alive for the process
        Self.keepAlive.append(out)
        let db = try OrionDatabase(path: out.path("orion.db"))
        _ = try AnalysisPipeline(database: db).run(
            AnalysisInput(repoPath: TestPaths.vendoredStarlette, outputDirectory: out.url)
        )
        let rows = try db.dbQueue.read { dbc in
            try Row.fetchAll(dbc, sql: "SELECT anchor, start_line, end_line FROM symbols")
        }
        var anchors: Set<String> = []
        var ranges: [String: (Int, Int)] = [:]
        var leafRanges: [String: [(Int, Int)]] = [:]
        for r in rows {
            let a: String = r["anchor"]
            let s: Int = r["start_line"], e: Int = r["end_line"]
            anchors.insert(a)
            ranges[a] = (s, e)
            if let sep = a.range(of: "::") {
                let file = String(a[a.startIndex..<sep.lowerBound])
                let leaf = a[sep.upperBound...].split(separator: ".").last.map(String.init) ?? ""
                leafRanges["\(file)::\(leaf)", default: []].append((s, e))
            }
        }
        let analyzed = Analyzed(db: db, anchors: anchors, ranges: ranges, leafRanges: leafRanges)
        Self.cache = analyzed
        return analyzed
    }

    private static var keepAlive: [TempDir] = []

    private func benchmarkItems() throws -> [[String: Any]] {
        let url = TestPaths.orionRepoRoot
            .appendingPathComponent("Agent Feasibility Study/benchmark/benchmark.resolved.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        if let arr = json as? [[String: Any]] { return arr }
        if let obj = json as? [String: Any], let qs = obj["questions"] as? [[String: Any]] { return qs }
        return []
    }

    func testKnownSymbolsExistInBenchmarkForm() throws {
        let a = try analyze()
        for anchor in [
            "starlette/applications.py::Starlette",
            "starlette/applications.py::Starlette.build_middleware_stack",
            "starlette/applications.py::Starlette.__call__",
            "starlette/responses.py::JSONResponse",
            "starlette/responses.py::Response",
            "starlette/responses.py::JSONResponse.render",
            "starlette/middleware/__init__.py::Middleware",
            "starlette/middleware/__init__.py",
        ] {
            XCTAssertTrue(a.anchors.contains(anchor), "missing symbol anchor: \(anchor)")
        }
        // build_middleware_stack range covers the benchmark evidence line 63
        let r = try XCTUnwrap(a.ranges["starlette/applications.py::Starlette.build_middleware_stack"])
        XCTAssertTrue(r.0 <= 63 && 63 <= r.1)
    }

    func testModuleAndPackageSymbolCounts() throws {
        let a = try analyze()
        let modules = try a.db.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM symbols WHERE kind IN ('module','package')")
        }
        XCTAssertEqual(modules, 71)   // one per Python file
    }

    func testRelevantSymbolAnchorsArePresent() throws {
        let a = try analyze()
        var total = 0, present = 0
        for item in try benchmarkItems() {
            for sym in (item["relevant_symbols"] as? [String]) ?? [] {
                guard sym.contains("::"), sym.split(separator: ":").first?.hasSuffix(".py") == true
                else { continue }
                total += 1
                if a.anchors.contains(sym) { present += 1 }
            }
        }
        XCTAssertGreaterThan(total, 100)
        let rate = Double(present) / Double(total)
        XCTAssertGreaterThanOrEqual(rate, 0.95, "relevant_symbols present: \(present)/\(total)")
    }

    func testEvidenceLinesFallInsideSymbolRanges() throws {
        let a = try analyze()
        var total = 0, contained = 0
        var failures: [String] = []
        for item in try benchmarkItems() {
            for ev in (item["evidence"] as? [[String: Any]]) ?? [] {
                guard (ev["type"] as? String) == "SOURCE",
                      let sym = ev["symbol"] as? String, sym.contains("::"),
                      sym.split(separator: ":").first?.hasSuffix(".py") == true,
                      let line = ev["line"] as? Int
                else { continue }
                total += 1
                let file = String(sym[sym.startIndex..<sym.range(of: "::")!.lowerBound])
                let leaf = sym.split(separator: ":").last.map { $0.split(separator: ".").last.map(String.init) ?? "" } ?? ""
                let key = "\(file)::\(leaf)"
                if (a.leafRanges[key] ?? []).contains(where: { $0.0 <= line && line <= $0.1 }) {
                    contained += 1
                } else {
                    failures.append("\(sym) line \(line)")
                }
            }
        }
        XCTAssertGreaterThan(total, 50)
        let rate = Double(contained) / Double(total)
        XCTAssertGreaterThanOrEqual(
            rate, 0.90,
            "evidence lines contained: \(contained)/\(total)\n" + failures.prefix(10).joined(separator: "\n")
        )
    }
}
