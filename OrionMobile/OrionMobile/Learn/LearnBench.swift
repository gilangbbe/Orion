import Foundation
import Observation
import OrionAgent
import OrionCore
import SwiftUI
import UIKit

/// The on-device Learn benchmark (Docs/19 M7). The phone's system model is not the Mac's (Docs/19
/// M0), so the calibration gate has to be measured here.
///
/// - **Calibration:** the hand-labelled gold set (`starlette_teaching_grader.gold.json`, Docs/17
///   §12.2) through the real `RubricGrader` with the phone's judge, once per vote count `k` --
///   κ against the expert labels, verdict accuracy, and per-call timing to choose `k`.
/// - **Drafting:** a question for each of the top-ranked concepts, through the verifier -- how
///   often the device produces a question it can keep, and how long that takes.
///
/// Both run on throwaway copies of the open repository's database: the gold questions and the
/// attempts they produce must not reach the learner's own progress. Writes
/// `Documents/learn-bench-latest.json` after every item.
///
/// Started from Library's ⋯ menu, or at launch with `ORION_LEARN_BENCH=calibration|drafting|all`,
/// `ORION_LEARN_BENCH_K=1,3` and `ORION_LEARN_BENCH_DRAFTS=10`.
@MainActor
@Observable
final class LearnBench {
    struct Request: Equatable {
        var calibration = true
        var drafting = true
        var votes: [Int] = [1, 3]
        var drafts = 10

        static var atLaunch: Request? {
            let env = ProcessInfo.processInfo.environment
            guard let mode = env["ORION_LEARN_BENCH"], !mode.isEmpty else { return nil }
            var request = Request(calibration: mode != "drafting", drafting: mode != "calibration")
            if let k = env["ORION_LEARN_BENCH_K"] {
                let votes = k.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if !votes.isEmpty { request.votes = votes }
            }
            if let drafts = env["ORION_LEARN_BENCH_DRAFTS"].flatMap(Int.init) { request.drafts = drafts }
            return request
        }
    }

    struct CalibrationItem: Encodable {
        let id: String
        let band: Int
        let latencyMs: Int
        let row: CalibrationRow
    }

    struct CalibrationRun: Encodable {
        let k: Int
        var items: [CalibrationItem] = []
        var summary: CalibrationSummary?
        var judgeCalls = 0
        var failedJudgeCalls = 0
        var judgeMsP50: Int?
        var judgeMsP90: Int?
        var judgeMsMax: Int?
        var wallSeconds: Double = 0
    }

    struct DraftRow: Encodable {
        let conceptId: String
        let concept: String
        let kind: String
        let band: Int
        var outcome = "error"
        var attempts = 0
        var latencyMs = 0
        var question: String?
        var explain: String?
        var referenceAnswer: String?
        var criteria: [String] = []
        var reasons: [String] = []
    }

    struct Report: Encodable {
        var repository: String
        var commit: String
        var device: String
        var os: String
        var variant: String
        var contextSize: Int
        var startedAt: Date
        var finishedAt: Date?
        var calibration: [CalibrationRun] = []
        var drafting: [DraftRow] = []
    }

    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var current: String?
    private(set) var lastSaved: URL?

    static func goldItems() -> [GraderGoldItem] {
        guard let url = Bundle.main.url(forResource: "starlette_teaching_grader.gold", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(GraderGoldFile.self, from: data)
        else { return [] }
        return file.items
    }

    func run(entry: LocalLibrary.Entry, request: Request) async {
        guard !isRunning else { return }
        let gold = request.calibration ? Self.goldItems() : []
        isRunning = true
        done = 0
        total = gold.count * request.votes.count + (request.drafting ? request.drafts : 0)
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isRunning = false
            current = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }

        var report = Report(
            repository: entry.manifest.repositoryName, commit: entry.manifest.commitHash, device: Self.deviceModel,
            os: ProcessInfo.processInfo.operatingSystemVersionString, variant: SystemModelInfo.variantName,
            contextSize: SystemModelInfo.contextSize, startedAt: Date())

        if request.calibration {
            for k in request.votes {
                report.calibration.append(CalibrationRun(k: k))
                let index = report.calibration.count - 1
                await calibrate(entry: entry, gold: gold, k: k) { run in
                    report.calibration[index] = run
                    self.lastSaved = Self.save(report)
                }
            }
        }
        if request.drafting {
            await draft(entry: entry, count: request.drafts) { rows in
                report.drafting = rows
                self.lastSaved = Self.save(report)
            }
        }
        report.finishedAt = Date()
        lastSaved = Self.save(report)
    }

    // MARK: - Calibration

    private func calibrate(
        entry: LocalLibrary.Entry, gold: [GraderGoldItem], k: Int, update: (CalibrationRun) -> Void
    ) async {
        var run = CalibrationRun(k: k)
        guard let work = Self.copyDatabase(of: entry, named: "learn-bench-k\(k)") else { return }
        let path = work.appendingPathComponent("orion.db").path
        let times = CallTimes()
        let judge = TimedJudge(inner: SystemModelTeaching.judge(), times: times)
        let start = ContinuousClock.now
        for item in gold {
            current = "k=\(k) · \(item.id)"
            let itemStart = ContinuousClock.now
            let row = await Task.detached(priority: .userInitiated) { () -> CalibrationRow? in
                guard let store = try? Store(OrionDatabase(path: path)),
                      let snapshotRun = try? store.latestRun(commitHash: nil)
                else { return nil }
                return await GraderCalibration.evaluate(
                    item: item, store: store, run: snapshotRun, judge: judge, comparer: nil, k: k,
                    verifyGold: false, now: { Timestamp.now() })
            }.value
            if let row {
                run.items.append(CalibrationItem(
                    id: item.id, band: item.band, latencyMs: Self.milliseconds(itemStart.duration(to: .now)), row: row))
            }
            run.summary = CalibrationSummary(rows: run.items.map(\.row), kappaBar: 0.60)
            let stats = times.stats()
            run.judgeCalls = stats.count
            run.failedJudgeCalls = stats.failed
            run.judgeMsP50 = stats.p50
            run.judgeMsP90 = stats.p90
            run.judgeMsMax = stats.max
            run.wallSeconds = Double(Self.milliseconds(start.duration(to: .now))) / 1000
            done += 1
            update(run)
        }
    }

    // MARK: - Drafting

    private func draft(entry: LocalLibrary.Entry, count: Int, update: ([DraftRow]) -> Void) async {
        guard let work = Self.copyDatabase(of: entry, named: "learn-bench-drafts") else { return }
        let path = work.appendingPathComponent("orion.db").path
        let concepts = Array(((try? TeachingLoader.concepts(outputDirectory: work, bootstrap: false)) ?? []).prefix(count))
        total = total - count + concepts.count
        var rows: [DraftRow] = []
        for concept in concepts {
            current = "draft · \(concept.label.prefix(40))"
            var row = DraftRow(
                conceptId: concept.id, concept: concept.label, kind: concept.kind, band: min(concept.difficultyBand, 2))
            let band = row.band
            let start = ContinuousClock.now
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> (TeachingQuestionGenerator.Result, TeachingQuestionRecord?, [String]) in
                    let store = Store(try OrionDatabase(path: path))
                    guard let run = try store.latestRun(commitHash: nil),
                          let record = try store.teachingConcept(id: concept.id)
                    else { throw AgentSessionError.noAnalyzedRun(path) }
                    let result = try await TeachingQuestionGenerator(store: store, run: run, drafter: SystemModelTeaching.drafter())
                        .generate(concept: record, band: band)
                    guard case .generated(let questionId, _, _, _) = result else { return (result, nil, []) }
                    let criteria = try store.teachingRubricCriteria(questionId: questionId).map { "[\($0.kind)] \($0.text)" }
                    return (result, try store.teachingQuestion(id: questionId), criteria)
                }.value
                switch result.0 {
                case .generated(_, _, _, let attempts):
                    row.outcome = "generated"
                    row.attempts = attempts
                case .rejected(let reasons, let attempts):
                    row.outcome = "rejected"
                    row.attempts = attempts
                    row.reasons = reasons
                case .draftUnusable(let detail, let attempts):
                    row.outcome = "unusable"
                    row.attempts = attempts
                    row.reasons = [detail]
                }
                row.question = result.1?.prompt
                row.explain = result.1?.explain
                row.referenceAnswer = result.1?.referenceAnswer
                row.criteria = result.2
            } catch {
                row.reasons = [AskModel.describe(error)]
            }
            row.latencyMs = Self.milliseconds(start.duration(to: .now))
            rows.append(row)
            done += 1
            update(rows)
        }
    }

    // MARK: - Support

    /// A throwaway copy of the knowledge, WAL files included (recent writes may live there).
    private static func copyDatabase(of entry: LocalLibrary.Entry, named name: String) -> URL? {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        guard (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)) != nil else { return nil }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: entry.databaseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.copyItem(at: source, to: work.appendingPathComponent("orion.db" + suffix))
        }
        return work
    }

    private static func save(_ report: Report) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return nil }
        let stamped = documents.appendingPathComponent("learn-bench-\(Int(report.startedAt.timeIntervalSince1970)).json")
        try? data.write(to: stamped)
        try? data.write(to: documents.appendingPathComponent("learn-bench-latest.json"))
        return stamped
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

/// Every judge call's duration, from whichever thread grades.
final class CallTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Int] = []
    private var failures = 0

    func record(_ ms: Int, failed: Bool) {
        lock.withLock {
            durations.append(ms)
            if failed { failures += 1 }
        }
    }

    func stats() -> (count: Int, failed: Int, p50: Int?, p90: Int?, max: Int?) {
        lock.withLock {
            let sorted = durations.sorted()
            func pct(_ p: Double) -> Int? { sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            return (sorted.count, failures, pct(0.5), pct(0.9), sorted.last)
        }
    }
}

/// Times each judge call for the report.
struct TimedJudge: CriterionJudging {
    let inner: any CriterionJudging
    let times: CallTimes

    var source: TeachingQuestionSource { inner.source }

    func judge(
        criterionText: String, criterionKind: RubricCriterionKind, answer: String, conceptEvidence: [String]
    ) async throws -> CriterionVerdict {
        let start = ContinuousClock.now
        do {
            let verdict = try await inner.judge(
                criterionText: criterionText, criterionKind: criterionKind, answer: answer, conceptEvidence: conceptEvidence)
            times.record(LearnBench.milliseconds(start.duration(to: .now)), failed: false)
            return verdict
        } catch {
            times.record(LearnBench.milliseconds(start.duration(to: .now)), failed: true)
            throw error
        }
    }
}

/// The benchmark's progress sheet.
struct LearnBenchView: View {
    let entry: LocalLibrary.Entry
    let request: LearnBench.Request
    var autostart = false
    @State private var bench = LearnBench()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: DesignTokens.Spacing.lg) {
                if bench.isRunning {
                    ProgressView(value: Double(bench.done), total: Double(max(bench.total, 1)))
                    Text("\(bench.done) of \(bench.total)\(bench.current.map { " · \($0)" } ?? "")")
                        .font(.callout.monospacedDigit())
                        .multilineTextAlignment(.center)
                    Text("Keep Orion open; the screen stays on until it finishes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if bench.done > 0 {
                    Label("Finished \(bench.done) items", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let url = bench.lastSaved { ShareLink(item: url) }
                } else {
                    Text("Grades \(LearnBench.goldItems().count) hand-labelled Starlette answers with k = \(request.votes.map(String.init).joined(separator: ", ")), then drafts questions for the top \(request.drafts) concepts, on the on-device model against a copy of \(entry.manifest.repositoryName)'s knowledge.")
                        .multilineTextAlignment(.center)
                    Button("Start") { Task { await bench.run(entry: entry, request: request) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Learn Benchmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(bench.isRunning)
                }
            }
        }
        .interactiveDismissDisabled(bench.isRunning)
        .task {
            if autostart { await bench.run(entry: entry, request: request) }
        }
    }
}
