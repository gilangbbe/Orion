import XCTest

@testable import OrionAgent

/// Docs/12_phase3_mlx_agent.md M6: the throttling logic tested against real, plain `Progress`
/// instances (no live download, no mocking needed -- `Progress` is a real, directly
/// instantiable Foundation type) rather than the download itself, which would need real network
/// access and ~4.3GB to exercise honestly.
final class ModelDownloadProgressReporterTests: XCTestCase {

    private func progress(_ completed: Int64, of total: Int64) -> Progress {
        let p = Progress(totalUnitCount: total)
        p.completedUnitCount = completed
        return p
    }

    func testPrintsOncePerWholePercentNotEveryCall() {
        var lines: [String] = []
        let reporter = ModelDownloadProgressReporter { lines.append($0) }

        // Five updates that all round down to the same 10% -- only the first should print.
        for completed in Int64(100)...Int64(104) {
            reporter.report(progress(completed, of: 1000))
        }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("10%"))
    }

    func testPrintsAgainOnceThePercentAdvances() {
        var lines: [String] = []
        let reporter = ModelDownloadProgressReporter { lines.append($0) }

        reporter.report(progress(100, of: 1000))  // 10%
        reporter.report(progress(200, of: 1000))  // 20%
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("10%"))
        XCTAssertTrue(lines[1].contains("20%"))
    }

    func testCompletionLineEndsWithNewlineNotCarriageReturn() {
        var lines: [String] = []
        let reporter = ModelDownloadProgressReporter { lines.append($0) }

        reporter.report(progress(1000, of: 1000))  // 100%
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("100%"))
        XCTAssertTrue(lines[0].hasSuffix("\n"), "the final line should end a fresh line, not overwrite in place")
    }

    func testIntermediateLinesUseCarriageReturnToOverwriteInPlace() {
        var lines: [String] = []
        let reporter = ModelDownloadProgressReporter { lines.append($0) }

        reporter.report(progress(500, of: 1000))  // 50%
        XCTAssertTrue(lines[0].hasPrefix("\r"))
        XCTAssertFalse(lines[0].hasSuffix("\n"))
    }

    func testNamesTheRealModel() {
        var lines: [String] = []
        let reporter = ModelDownloadProgressReporter { lines.append($0) }
        reporter.report(progress(100, of: 1000))
        XCTAssertTrue(lines[0].contains(Qwen3Agent.modelConfiguration.name))
    }
}
