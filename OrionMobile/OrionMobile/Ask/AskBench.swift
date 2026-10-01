import Foundation
import Observation
import OrionAgent
import OrionCore
import SwiftUI
import UIKit

/// The on-device Ask benchmark (Docs/19 M6). The Mac runs a different, larger system model
/// (Docs/19 M0), so the phone's quality and latency can only be measured on the phone.
///
/// Runs the bundled Starlette questions (`starlette-ask-bench.json`) against a **copy** of the
/// open repository's database -- 55 benchmark answers must not land in the user's ask history or
/// model changes -- and writes `Documents/ask-bench-latest.json` after every question, so a long
/// run survives interruption. Pulled with `devicectl device copy from`, graded on the Mac against
/// `benchmark.json`.
///
/// Started from Library's ⋯ menu, or at launch with `ORION_ASK_BENCH=all` (or a comma-separated
/// id list) and optionally `ORION_ASK_BENCH_DEPTH=2` to force depth 2, like Docs/18 M4.
@MainActor
@Observable
final class AskBench {
    struct Question: Codable {
        let id: String
        let category: String
        let question: String
    }

    struct Row: Codable {
        let id: String
        let category: String
        let question: String
        var depth: Int?
        var routingMethod: String?
        var outcome: String?
        var partial: Bool?
        var claimCount: Int?
        var toolCalls: [String] = []
        var answer: String?
        var latencyMs: Int?
        /// Until the first streamed answer text.
        var firstAnswerMs: Int?
        var error: String?
    }

    struct Report: Codable {
        var repository: String
        var commit: String
        var device: String
        var os: String
        var variant: String
        var contextSize: Int
        var forcedDepth: Int?
        var startedAt: Date
        var finishedAt: Date?
        var rows: [Row] = []
    }

    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var current: String?
    private(set) var lastSaved: URL?

    static func questions(ids: [String]? = nil) -> [Question] {
        guard let url = Bundle.main.url(forResource: "starlette-ask-bench", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([Question].self, from: data)
        else { return [] }
        guard let ids, !ids.isEmpty else { return all }
        return all.filter { ids.contains($0.id) }
    }

    /// `ORION_ASK_BENCH` / `ORION_ASK_BENCH_DEPTH` at launch, if set.
    static var launchRequest: (ids: [String]?, depth: Int?)? {
        let env = ProcessInfo.processInfo.environment
        guard let value = env["ORION_ASK_BENCH"], !value.isEmpty else { return nil }
        let ids = value == "all" ? nil : value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return (ids, env["ORION_ASK_BENCH_DEPTH"].flatMap(Int.init))
    }

    func run(entry: LocalLibrary.Entry, ids: [String]?, forcedDepth: Int?) async {
        guard !isRunning else { return }
        let questions = Self.questions(ids: ids)
        isRunning = true
        done = 0
        total = questions.count
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isRunning = false
            current = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }

        // A throwaway copy of the knowledge: the benchmark's answers stay out of the library.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ask-bench", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // With its WAL files: once the app has opened the library, recent writes may live there.
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: entry.databaseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.copyItem(at: source, to: work.appendingPathComponent("orion.db" + suffix))
        }

        var report = Report(
            repository: entry.manifest.repositoryName, commit: entry.manifest.commitHash, device: Self.deviceModel,
            os: ProcessInfo.processInfo.operatingSystemVersionString, variant: SystemModelInfo.variantName,
            contextSize: SystemModelInfo.contextSize, forcedDepth: forcedDepth, startedAt: Date())

        var config = AgentSessionConfig(
            repoRoot: work.appendingPathComponent(entry.manifest.repositoryName), outputDirectory: work)
        config.forceDepth = forcedDepth
        let agent = SystemModelAsk.session(config: config)

        for question in questions {
            current = question.id
            var row = Row(id: question.id, category: question.category, question: question.question)
            let start = ContinuousClock.now
            let firstAnswer = FirstAnswerClock()
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await agent.ask(question.question) { text in
                        if !text.isEmpty { firstAnswer.mark() }
                    }
                }.value
                row.depth = result.depthDecision.depth
                row.routingMethod = result.depthDecision.method.rawValue
                row.outcome = result.investigation.outcome
                row.partial = result.partial
                row.claimCount = result.claimCount
                row.toolCalls = result.toolCalls.map { "\($0.toolName)(\($0.argumentsDescription))" }
                row.answer = result.answerText
            } catch {
                row.error = AskModel.describe(error)
            }
            row.latencyMs = Self.milliseconds(start.duration(to: .now))
            row.firstAnswerMs = firstAnswer.elapsed(since: start).map(Self.milliseconds)
            report.rows.append(row)
            done += 1
            lastSaved = Self.save(report)
        }
        report.finishedAt = Date()
        lastSaved = Self.save(report)
    }

    private static func save(_ report: Report) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return nil }
        let stamped = documents.appendingPathComponent("ask-bench-\(Int(report.startedAt.timeIntervalSince1970)).json")
        try? data.write(to: stamped)
        try? data.write(to: documents.appendingPathComponent("ask-bench-latest.json"))
        return stamped
    }

    private static func milliseconds(_ duration: Duration) -> Int {
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

/// When the first answer text streamed in -- set from the generation's callback thread.
private final class FirstAnswerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant?

    func mark() {
        lock.withLock { if instant == nil { instant = .now } }
    }

    func elapsed(since start: ContinuousClock.Instant) -> Duration? {
        lock.withLock { instant.map { start.duration(to: $0) } }
    }
}

/// The benchmark's progress sheet.
struct AskBenchView: View {
    let entry: LocalLibrary.Entry
    let ids: [String]?
    let forcedDepth: Int?
    @State private var bench = AskBench()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: DesignTokens.Spacing.lg) {
                if bench.isRunning {
                    ProgressView(value: Double(bench.done), total: Double(max(bench.total, 1)))
                    Text("\(bench.done) of \(bench.total)\(bench.current.map { " · \($0)" } ?? "")")
                        .font(.callout.monospacedDigit())
                    Text("Keep Orion open; the screen stays on until it finishes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if bench.done > 0 {
                    Label("Finished \(bench.done) questions", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let url = bench.lastSaved { ShareLink(item: url) }
                } else {
                    Text("Runs \(AskBench.questions(ids: ids).count) Starlette benchmark questions on the on-device model against a copy of \(entry.manifest.repositoryName)'s knowledge\(forcedDepth.map { ", forced to depth \($0)" } ?? "").")
                        .multilineTextAlignment(.center)
                    Button("Start") { Task { await bench.run(entry: entry, ids: ids, forcedDepth: forcedDepth) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Ask Benchmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(bench.isRunning)
                }
            }
        }
        .interactiveDismissDisabled(bench.isRunning)
        .task {
            if AskBench.launchRequest != nil {
                await bench.run(entry: entry, ids: ids, forcedDepth: forcedDepth)
            }
        }
    }
}
