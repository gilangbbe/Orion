import ArgumentParser
import Foundation
import OrionAgent
import OrionCodeIntel

/// `orion-agent teach bench` (Docs/17_phase7_teaching_mode.md §10, §12.2) — the grader-calibration
/// harness. Feeds a hand-authored gold set of (question, developer answer, expert per-criterion
/// labels) through the real `RubricGrader` (local Qwen3 judge, k-sampled), then measures the
/// grader against the expert labels with `CalibrationStats`:
///
///   * **per-criterion Cohen's κ** — grader `met`/`not-met` vs. expert `met`/`not-met`
///     (`ambiguous` expert labels excluded), overall and restricted to criteria the grader was
///     confident on; broken out by `required` vs. `anti` (the misconception-detection axis).
///   * **score MAE / RMSE** — the grader's *derived* score vs. a score derived the same way
///     (`RubricScoring.aggregate`) from the expert's labels.
///   * **verdict-tier confusion matrix** — grader-derived tier vs. expert-derived tier.
///   * **self-consistency** — fraction of criteria with a split k-vote, and how often the
///     majority on those still matched the expert.
///   * **disputed rate** — §7.4 pairwise-tripwire firings (`--pairwise`).
///
/// Writes `teaching_calibration.jsonl` (one row per gold item) + `teaching_calibration_summary.json`,
/// the same report shape as `orion-agent bench` (Phase 5 M7). The κ number is Docs/17 Decision 10's
/// ship gate: at or above `--kappa-bar` (default 0.60, Landis & Koch "substantial"), the app's
/// confident-grade UI may be switched on (`TeachingSession.isCalibrated = true`).
///
/// Run against a **copy** of the repository's `.orion/orion.db` (`--out`): grading writes real
/// `teaching_attempts` / `teaching_criterion_results` rows and the verifier inserts a
/// `teaching_questions` row per gold item.
struct TeachBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Measure the answer grader against an expert-labelled gold set (per-criterion κ, score MAE, verdict confusion)."
    )

    @Argument(help: "Path to the repository checkout (already analyzed; concepts already extracted).")
    var path: String
    @Option(help: "Gold set JSON (see Agent Feasibility Study/benchmark/starlette_teaching_grader.gold.json).")
    var gold: String
    @Option(help: "Directory containing orion.db (default: <path>/.orion). Use a COPY — grading writes rows.")
    var out: String?
    @Option(name: .customLong("report-dir"), help: "Where to write teaching_calibration.jsonl + summary (default: <out>/bench).")
    var reportDir: String?
    @Option(help: "Use this commit's analyzed run instead of the latest.")
    var commit: String?
    @Option(help: "k for per-criterion self-consistency voting (default 3, matching the product path).")
    var k: Int = 3
    @Option(help: "Only run the first N gold items (after --band filtering), for a cheap smoke run.")
    var limit: Int?
    @Option(help: "Only run gold items for this difficulty band (1, 2, or 3).")
    var band: Int?
    @Option(name: .customLong("kappa-bar"), help: "The κ ship gate for Decision 10 (default 0.60).")
    var kappaBar: Double = 0.60
    @Flag(help: "Also run the §7.4 pairwise same-idea tripwire and report the disputed rate.")
    var pairwise: Bool = false
    @OptionGroup var backend: LocalBackendOption
    @OptionGroup var judgeOutputOption: JudgeOutputOption
    @Flag(
        name: .customLong("verify-gold"),
        help: """
            Run each gold question through the full §6.3 verifier (schema + anchor resolution + \
            the CONTRADICTED-claim consistency check) before grading. Off by default: this command \
            measures the *grader*, and the gold questions are trusted (hand-authored, anchors \
            hand-checked). By default the harness still resolves every anchor — a typo fails loudly \
            — but skips the consistency check, which is a *generation* gate (§12.1's concern) and \
            over-fires on a repo whose semantic layer carries many CONTRADICTED claims.
            """)
    var verifyGold: Bool = false

    func validate() throws {
        if let band, !(1...3).contains(band) { throw ValidationError("--band must be 1, 2, or 3") }
        if let limit, limit < 1 { throw ValidationError("--limit must be at least 1") }
        if k < 1 { throw ValidationError("--k must be at least 1") }
    }

    func run() async throws {
        let repoURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let outURL = URL(
            fileURLWithPath: ((out ?? repoURL.appendingPathComponent(".orion").path) as NSString)
                .expandingTildeInPath
        ).standardizedFileURL
        let reportURL = URL(
            fileURLWithPath: ((reportDir ?? outURL.appendingPathComponent("bench").path) as NSString)
                .expandingTildeInPath
        ).standardizedFileURL
        try FileManager.default.createDirectory(at: reportURL, withIntermediateDirectories: true)

        let dbPath = outURL.appendingPathComponent("orion.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else {
            FileHandle.standardError.write(Data("no database at \(dbPath) — run `orion-index analyze` first\n".utf8))
            throw ExitCode(3)
        }
        let store = Store(try OrionDatabase(path: dbPath))
        guard let run = try store.latestRun(commitHash: commit) else {
            FileHandle.standardError.write(Data("no analyzed run — run `orion-index analyze` first\n".utf8))
            throw ExitCode(3)
        }

        let goldURL = URL(fileURLWithPath: (gold as NSString).expandingTildeInPath)
        let file: GraderGoldFile
        do {
            file = try JSONDecoder().decode(GraderGoldFile.self, from: try Data(contentsOf: goldURL))
        } catch {
            FileHandle.standardError.write(Data("failed to read/decode \(goldURL.path): \(error)\n".utf8))
            throw ExitCode(2)
        }

        var items = file.items
        if let band { items = items.filter { $0.band == band } }
        if let limit { items = Array(items.prefix(limit)) }
        guard !items.isEmpty else {
            FileHandle.standardError.write(Data("no gold items matched (band filter or empty file)\n".utf8))
            throw ExitCode(2)
        }

        print("Grader calibration: \(items.count) gold item(s) against \(repoURL.lastPathComponent) "
            + "(run \(run.id), k=\(k)\(pairwise ? ", pairwise" : ""))")

        let benchStart = ContinuousClock.now
        let localBackend = try backend.resolve()
        let judgeOutput = try judgeOutputOption.resolve()
        let agent = try await LocalModelLoader.shared.model(for: localBackend, role: .judging)
        let comparerAgent = pairwise
            ? try await LocalModelLoader.shared.model(for: localBackend, role: .comparing) : nil
        let modelLoadMs = Self.ms(since: benchStart)
        let judgeStats = JudgeCallStats()
        let judge = CountingJudge(
            inner: try LocalGrading.judge(agent: agent, output: judgeOutput), stats: judgeStats)
        let comparer = try comparerAgent.map { try LocalGrading.comparer(agent: $0, output: judgeOutput) }
        let now: @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }

        var rows: [CalibrationRow] = []
        for (idx, item) in items.enumerated() {
            print("[\(idx + 1)/\(items.count)] \(item.id) (band \(item.band))")
            let row = await GraderCalibration.evaluate(
                item: item, store: store, run: run, judge: judge, comparer: comparer, k: k,
                verifyGold: verifyGold, now: now)
            if let err = row.error {
                print("    skipped: \(err)")
            } else {
                print(String(
                    format: "    grader %.2f/%@  vs  expert %.2f/%@   (%d/%d criteria matched)",
                    row.graderScore ?? -1, row.graderVerdict ?? "?",
                    row.expertScore ?? -1, row.expertVerdict ?? "?",
                    row.criteria.filter { $0.matched }.count, row.criteria.count))
            }
            rows.append(row)
        }

        let summary = CalibrationSummary(rows: rows, kappaBar: kappaBar)
        try Self.writeJSONL(rows, to: reportURL.appendingPathComponent("teaching_calibration.jsonl"))
        try Self.writeJSON(summary, to: reportURL.appendingPathComponent("teaching_calibration_summary.json"))

        let runInfo = TeachBenchRunInfo(
            localModel: agent.modelIdentifier, comparerModel: comparerAgent?.modelIdentifier,
            judgeOutput: judgeOutput.rawValue, modelLoadMs: modelLoadMs,
            wallClockSeconds: Self.ms(since: benchStart) / 1000,
            judgeCalls: await judgeStats.calls, unparseableJudgeOutputs: await judgeStats.unparseable,
            failedJudgeCalls: await judgeStats.failed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(runInfo).write(to: reportURL.appendingPathComponent("teaching_calibration_run.json"))

        print("")
        print("Wrote \(rows.count) row(s) to \(reportURL.path)")
        summary.printFormatted()
        print("model \(runInfo.localModel): \(Int(runInfo.wallClockSeconds))s wall-clock, "
            + "\(runInfo.unparseableJudgeOutputs)/\(runInfo.judgeCalls) judge replies unparseable, "
            + "\(runInfo.failedJudgeCalls) failed (\(runInfo.judgeOutput) output)")

        // Exit 1 if nothing could be graded at all — a broken gold file or run, not a low κ.
        if summary.gradedItems == 0 { throw ExitCode(1) }
    }

    // MARK: report I/O

    private static func writeJSONL(_ rows: [CalibrationRow], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try rows.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(value).write(to: url)
    }
}

// The gold file, rows and summary live in OrionAgent (`GraderCalibration`), shared with the
// phone (Docs/19 M7). The console report stays here.
extension CalibrationSummary {
    func printFormatted() {
        print("--- grader calibration (Docs/17 §12.2) ---")
        print("gold items: \(goldItems)  graded: \(gradedItems)  skipped: \(skipped.count)")
        for (id, reason) in skipped.sorted(by: { $0.key < $1.key }) { print("  · \(id): \(reason)") }
        print("criterion pairs (matched, non-ambiguous): \(criterionPairs)"
            + (unmatchedCriteria > 0 ? "   ⚠ \(unmatchedCriteria) unmatched criterion text(s)" : ""))
        func fmt(_ d: Double?) -> String { d.map { String(format: "%.3f", $0) } ?? "n/a" }
        if let k = kappaOverall {
            print("Cohen's κ (all):            \(fmt(kappaOverall))  — \(CalibrationStats.agreementLabel(forKappa: k))")
        }
        print("Cohen's κ (grader-confident): \(fmt(kappaConfidentOnly))")
        print("Cohen's κ (required only):     \(fmt(kappaRequired))")
        print("Cohen's κ (anti only):         \(fmt(kappaAnti))")
        print("raw agreement:                 \(fmt(rawAgreementOverall))")
        print("score MAE / RMSE:              \(fmt(scoreMAE)) / \(fmt(scoreRMSE))")
        print("verdict-tier accuracy:         \(fmt(verdictAccuracy))")
        for expected in CalibrationSummary.tiers {
            let counts = CalibrationSummary.tiers.map { "\($0.prefix(4))=\(verdictConfusion[expected]?[$0] ?? 0)" }
            print("  expert \(expected.padding(toLength: 9, withPad: " ", startingAt: 0)) -> \(counts.joined(separator: " "))")
        }
        print("split k-votes:                 \(splitVoteCriteria)  (\(fmt(splitVoteFraction)) of criteria; "
            + "majority matched expert \(fmt(splitVoteMajorityMatchesExpert)))")
        if let d = disputedItems { print("disputed (pairwise tripwire):   \(d)/\(gradedItems)") }
        print("")
        print("κ gate (Decision 10): κ \(fmt(kappaOverall)) vs bar \(String(format: "%.2f", kappaBar))  ->  "
            + (gatePasses ? "PASS — grader may ship the confident-grade UI (set TeachingSession.isCalibrated = true)"
                          : "HOLD — keep 'self-check only'; TeachingSession.isCalibrated stays false"))
    }
}

/// Per-run facts `teaching_calibration_summary.json` doesn't carry (Docs/18 M3): which local model
/// graded, how long it took, and how often the judge's reply wasn't a parseable verdict.
struct TeachBenchRunInfo: Encodable {
    /// The judge's model (`LocalModelRole.judging`, Docs/18 M4).
    let localModel: String
    /// The pairwise comparer's model (`LocalModelRole.comparing`), when `--pairwise` ran.
    let comparerModel: String?
    /// `text` or `guided` (Docs/18 M5).
    let judgeOutput: String
    let modelLoadMs: Double
    let wallClockSeconds: Double
    let judgeCalls: Int
    let unparseableJudgeOutputs: Int
    /// Judge calls that threw; `RubricGrader` turns each into an unconfident vote (Docs/18 M5).
    let failedJudgeCalls: Int
}

actor JudgeCallStats {
    private(set) var calls = 0
    private(set) var unparseable = 0
    private(set) var failed = 0

    func record(_ verdict: CriterionVerdict) {
        calls += 1
        if verdict.note == LocalCriterionJudge.unparseableNote { unparseable += 1 }
    }

    func recordFailure() {
        calls += 1
        failed += 1
    }
}

/// Counts every judge call's outcome for `teaching_calibration_run.json`, whichever judge runs.
struct CountingJudge: CriterionJudging {
    let inner: any CriterionJudging
    let stats: JudgeCallStats

    var source: TeachingQuestionSource { inner.source }

    func judge(
        criterionText: String, criterionKind: RubricCriterionKind, answer: String, conceptEvidence: [String]
    ) async throws -> CriterionVerdict {
        do {
            let verdict = try await inner.judge(
                criterionText: criterionText, criterionKind: criterionKind, answer: answer,
                conceptEvidence: conceptEvidence)
            await stats.record(verdict)
            return verdict
        } catch {
            await stats.recordFailure()
            throw error
        }
    }
}

extension TeachBench {
    static func ms(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
}
