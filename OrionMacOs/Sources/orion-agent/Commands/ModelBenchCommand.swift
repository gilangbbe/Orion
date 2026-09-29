import ArgumentParser
import Darwin
import Foundation
import OrionAgent

/// `orion-agent model-bench` (Docs/18 M3): raw runtime for ONE Core AI bundle per process, so
/// peak memory is that model's alone. Measures load time, time to first token, prefill and
/// decode rates across three real prompt sizes, and a follow-up turn's cost in the same session
/// (does the engine reuse the first turn's KV cache?). Greedy, thinking off, streamed --
/// `RuntimeBenchmarking` -- so every bundle is timed at the same points.
struct ModelBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model-bench",
        abstract: "Measure a local backend's load/TTFT/prefill/decode/memory on real repository prompts."
    )

    @Argument(help: "Repository checkout whose source files and export/ build the prompts (e.g. vendored Starlette).")
    var path: String

    @Option(help: "Directory containing export/ (default: <path>/.orion).")
    var out: String?

    @Option(name: .customLong("report-dir"), help: "Where to write model_bench_<backend>.json (default: <out>/bench).")
    var reportDir: String?

    @Option(help: "Timed trials per prompt size, after one discarded warm-up run.")
    var trials: Int = 3

    @Option(name: .customLong("max-tokens"), help: "Generation cap per turn.")
    var maxTokens: Int = 256

    @Option(name: .customLong("source-subdir"), help: "Directory under <path> whose .py files build the source prompts.")
    var sourceSubdir: String = "starlette"

    @OptionGroup var backend: LocalBackendOption

    func validate() throws {
        if trials < 1 { throw ValidationError("--trials must be at least 1") }
    }

    func run() async throws {
        let repoURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let outURL = URL(fileURLWithPath: ((out ?? repoURL.appendingPathComponent(".orion").path) as NSString)
            .expandingTildeInPath).standardizedFileURL
        let reportURL = URL(fileURLWithPath: ((reportDir ?? outURL.appendingPathComponent("bench").path) as NSString)
            .expandingTildeInPath).standardizedFileURL
        try FileManager.default.createDirectory(at: reportURL, withIntermediateDirectories: true)

        let selected = try backend.resolve()
        let cases = try Self.prompts(repoURL: repoURL, sourceSubdir: sourceSubdir, exportDir: outURL.appendingPathComponent("export"))

        print("Loading \(selected.modelIdentifier)...")
        let loadStart = ContinuousClock.now
        let agent = try await LocalModelLoader.shared.model(for: selected)
        let loadMs = Self.ms(since: loadStart)
        let afterLoad = Self.footprint()
        print("  loaded in \(Int(loadMs))ms, footprint \(Self.gb(afterLoad.current))")
        guard let bench = agent as? any RuntimeBenchmarking else {
            throw ValidationError("\(selected.modelIdentifier) does not support runtime benchmarking")
        }

        // Every run gets a unique first line. Core AI's engine keeps a token-prefix KV cache across
        // sessions, so an identical repeat would time a cache hit, not prefill. The nonce makes each
        // run cold. Cross-request reuse is measured on purpose
        // by the `production-repeat` case below.
        var runCounter = 0
        func fresh(_ prompt: String) -> String {
            runCounter += 1
            return "Request \(runCounter).\n" + prompt
        }

        var caseReports: [CaseReport] = []
        for (name, prompt) in cases {
            let warmup = try await bench.benchmarkTurns([fresh(prompt)], maxTokens: maxTokens)[0]
            var rows: [SampleRow] = []
            for _ in 0..<trials {
                rows.append(SampleRow(try await bench.benchmarkTurns([fresh(prompt)], maxTokens: maxTokens)[0]))
            }
            let report = CaseReport(name: name, warmup: SampleRow(warmup), samples: rows)
            caseReports.append(report)
            print("  \(name): prompt=\(report.median.promptTokens) tok, TTFT=\(Int(report.median.ttftMs))ms "
                + "(warm-up \(Int(warmup.ttftMs))ms), prefill=\(Int(report.median.prefillTokensPerSecond)) tok/s, "
                + "decode=\(String(format: "%.1f", report.median.decodeTokensPerSecond)) tok/s")
        }

        // The same production context sent again in a NEW session, as consecutive `ask` questions
        // do (their primed context is identical). Primed once, then each trial repeats it verbatim.
        let production = cases.first { $0.name == "production" }!.prompt
        let repeated = fresh(production)
        let repeatWarmup = try await bench.benchmarkTurns([repeated], maxTokens: maxTokens)[0]
        var repeatRows: [SampleRow] = []
        for _ in 0..<trials {
            repeatRows.append(SampleRow(try await bench.benchmarkTurns([repeated], maxTokens: maxTokens)[0]))
        }
        let repeatReport = CaseReport(name: "production-repeat", warmup: SampleRow(repeatWarmup), samples: repeatRows)
        caseReports.append(repeatReport)
        print("  production-repeat (identical prompt, new session): TTFT=\(Int(repeatReport.median.ttftMs))ms")

        // Follow-up turn in the same session: a backend that keeps the first turn's KV cache only
        // processes the follow-up's new tokens; one that re-prefills pays for the whole context again.
        let followUp = "Which one file would you read first to understand request routing, and why? One sentence."
        var multiTurn: [MultiTurnRow] = []
        for _ in 0..<trials {
            let turns = try await bench.benchmarkTurns([fresh(production), followUp], maxTokens: maxTokens)
            multiTurn.append(MultiTurnRow(first: SampleRow(turns[0]), followUp: SampleRow(turns[1])))
        }
        let followUpTTFT = Self.median(multiTurn.map(\.followUp.ttftMs))
        let firstTTFT = Self.median(multiTurn.map(\.first.ttftMs))
        print("  follow-up turn: TTFT=\(Int(followUpTTFT))ms vs first turn \(Int(firstTTFT))ms")

        let peak = Self.footprint().peak
        let report = ModelBenchReport(
            backend: String(describing: selected), modelIdentifier: selected.modelIdentifier,
            loadMs: loadMs, footprintAfterLoadBytes: afterLoad.current, peakFootprintBytes: peak,
            maxTokens: maxTokens, trials: trials, cases: caseReports, multiTurn: multiTurn,
            multiTurnMedianFirstTTFTMs: firstTTFT, multiTurnMedianFollowUpTTFTMs: followUpTTFT)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let fileName = "model_bench_\(selected.modelIdentifier.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")).json"
        try encoder.encode(report).write(to: reportURL.appendingPathComponent(fileName))
        print("  peak footprint \(Self.gb(peak)); wrote \(reportURL.appendingPathComponent(fileName).path)")
    }

    // MARK: - Prompts

    private static let task = "\n\nExplain in detail what the code above does, file by file."

    /// short (~1K tokens) and long (~24K tokens) are real source files; production is the exact
    /// ContextBuilder output `ask` primes depth 1/2 with (Qwen3 ≈ 3.3 chars/token for Python).
    static func prompts(repoURL: URL, sourceSubdir: String, exportDir: URL) throws -> [(name: String, prompt: String)] {
        let dir = repoURL.appendingPathComponent(sourceSubdir)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "py" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        func source(chars budget: Int) throws -> String {
            var text = ""
            for file in files {
                let body = try String(contentsOf: file, encoding: .utf8)
                text += "# File: \(sourceSubdir)/\(file.lastPathComponent)\n\(body)\n"
                if text.count >= budget { break }
            }
            return String(text.prefix(budget))
        }
        guard let production = ContextBuilder.build(exportDir: exportDir) else {
            throw ValidationError("no export/ at \(exportDir.path) -- run `orion-index analyze` first")
        }
        return [
            ("short", try source(chars: 3_300) + task),
            ("production", production + task),
            ("long", try source(chars: 79_000) + task),
        ]
    }

    // MARK: - Measurement helpers

    static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return (0, 0) }
        return (info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint)
    }

    static func ms(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1
            ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func gb(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / 1_073_741_824) }
}

struct SampleRow: Codable {
    let promptTokens: Int
    let outputTokens: Int
    let ttftMs: Double
    let totalMs: Double
    let prefillTokensPerSecond: Double
    let decodeTokensPerSecond: Double

    init(_ sample: RuntimeSample) {
        promptTokens = sample.promptTokens
        outputTokens = sample.outputTokens
        ttftMs = sample.ttftMs
        totalMs = sample.totalMs
        prefillTokensPerSecond = sample.prefillTokensPerSecond
        decodeTokensPerSecond = sample.decodeTokensPerSecond
    }

    init(promptTokens: Int, outputTokens: Int, ttftMs: Double, totalMs: Double,
         prefillTokensPerSecond: Double, decodeTokensPerSecond: Double) {
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.ttftMs = ttftMs
        self.totalMs = totalMs
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
    }
}

struct CaseReport: Codable {
    let name: String
    let warmup: SampleRow
    let samples: [SampleRow]
    let median: SampleRow

    init(name: String, warmup: SampleRow, samples: [SampleRow]) {
        self.name = name
        self.warmup = warmup
        self.samples = samples
        median = SampleRow(
            promptTokens: samples.map(\.promptTokens).max() ?? 0,
            outputTokens: Int(ModelBench.median(samples.map { Double($0.outputTokens) })),
            ttftMs: ModelBench.median(samples.map(\.ttftMs)),
            totalMs: ModelBench.median(samples.map(\.totalMs)),
            prefillTokensPerSecond: ModelBench.median(samples.map(\.prefillTokensPerSecond)),
            decodeTokensPerSecond: ModelBench.median(samples.map(\.decodeTokensPerSecond)))
    }
}

struct MultiTurnRow: Codable {
    let first: SampleRow
    let followUp: SampleRow
}

struct ModelBenchReport: Codable {
    let backend: String
    let modelIdentifier: String
    let loadMs: Double
    let footprintAfterLoadBytes: UInt64
    let peakFootprintBytes: UInt64
    let maxTokens: Int
    let trials: Int
    let cases: [CaseReport]
    let multiTurn: [MultiTurnRow]
    let multiTurnMedianFirstTTFTMs: Double
    let multiTurnMedianFollowUpTTFTMs: Double
}
