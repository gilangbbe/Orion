import ArgumentParser
import Foundation
import OrionAgent
import OrionCodeIntel

/// `orion-agent bench` (Docs/15_phase5_adaptive_exploration.md §6/M7): runs a benchmark question
/// set through `AgentSession.ask(_:)` in-process, one question per call, no session (§6.1: this
/// measures the routing mechanism and single-question quality, the same shape Docs/12 M5 already
/// used for its 13-question sample -- this is that same measurement at the full corpus's scale).
/// Every question's `routing_decisions`/`investigations` row is already written by `ask()` itself
/// (Docs/12); this command's own job is orchestration and summarization, not new persistence.
struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Run a benchmark question set through AgentSession, recording routing/latency/cost."
    )

    @Argument(help: "Path to the repository checkout (must already be analyzed by `orion-index analyze`).")
    var path: String

    @Option(
        help: """
            Path to a benchmark JSON file: {"questions": [{"id", "category", "question", \
            "expected_answer"}, ...]} -- the shape `Agent Feasibility Study/benchmark/\
            benchmark.resolved.json` already uses.
            """
    )
    var questions: String

    @Option(help: "Directory containing orion.db + export/ (default: <path>/.orion, matching every other command).")
    var out: String?

    @Option(
        help: """
            Directory to write routing_benchmark.jsonl/routing_benchmark_summary.json into \
            (default: <out>/bench). Deliberately distinct from --out -- that flag names the \
            *analyzed repository's* directory everywhere else in this CLI (`ask`/`session`); \
            reusing it here for the benchmark's own report directory (as this feature's original \
            plan sketched) would have made the two meanings collide on the same flag.
            """
    )
    var reportDir: String?

    @Option(help: "Answer against this commit's analyzed run instead of the latest one.")
    var commit: String?

    @Option(name: .customLong("max-budget-usd"), help: "Per-question cost ceiling for a depth-3 investigation.")
    var maxBudgetUsd: Double = 1.00

    @Option(help: "Per-question wall-clock timeout, in seconds, for a depth-3 investigation.")
    var timeout: Double = 400

    @Option(help: "Only run the first N questions (after --category filtering), for a smoke run before spending on the full set.")
    var limit: Int?

    @Option(help: "Only run questions in this category (e.g. code_understanding).")
    var category: String?

    @Option(
        name: .customLong("force-depth"),
        help: """
            Debug only -- overrides the Depth Model for every question, defeating the actual \
            point of a routing benchmark. Exists for a zero-cost smoke run (`--force-depth 1`) \
            to confirm the harness itself works before spending on a real run with the router \
            actually deciding.
            """
    )
    var forceDepth: Int?

    @Flag(
        name: .customLong("classify-only"),
        help: """
            Only run the Depth Model (heuristics + the on-device system-model fallback, exactly as \
            `ask` routes) for each question -- no answering, no model load, no cost. Writes \
            routing_classification.jsonl/routing_classification_summary.json instead of the \
            routing_benchmark files. Used to re-validate routing and the guardrail whenever the \
            OS ships a new system model (Docs/18 M0).
            """
    )
    var classifyOnly = false

    @OptionGroup var backend: LocalBackendOption

    func validate() throws {
        if let forceDepth, !(1...3).contains(forceDepth) {
            throw ValidationError("--force-depth must be 1, 2, or 3 (got \(forceDepth))")
        }
        if classifyOnly, forceDepth != nil {
            throw ValidationError("--classify-only measures the Depth Model itself; it can't be combined with --force-depth")
        }
        if let limit, limit < 1 {
            throw ValidationError("--limit must be at least 1")
        }
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

        let questionsURL = URL(fileURLWithPath: (questions as NSString).expandingTildeInPath)
        let file: BenchmarkFile
        do {
            let data = try Data(contentsOf: questionsURL)
            file = try JSONDecoder().decode(BenchmarkFile.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("failed to read/decode \(questionsURL.path): \(error)\n".utf8))
            throw ExitCode(2)
        }

        var selected = file.questions
        if let category { selected = selected.filter { $0.category == category } }
        if let limit { selected = Array(selected.prefix(limit)) }
        guard !selected.isEmpty else {
            FileHandle.standardError.write(Data("no questions matched (category filter or empty file)\n".utf8))
            throw ExitCode(2)
        }

        if classifyOnly {
            try await Self.classify(selected, repoURL: repoURL, reportURL: reportURL)
            return
        }

        // A forced local depth always needs the local model: load it once up front (Docs/18 M3) so
        // the first question's latency isn't also the model's load time.
        let localBackend = try backend.resolve()
        var modelLoadMs: Double?
        if let forceDepth, forceDepth < 3 {
            let loadStart = ContinuousClock.now
            _ = try await LocalModelLoader.shared.model(for: localBackend, role: .answering)
            modelLoadMs = Self.milliseconds(since: loadStart)
            print("Loaded \(localBackend.modelIdentifier(for: .answering)) in \(Int(modelLoadMs ?? 0))ms")
        }

        print("Running \(selected.count) question(s) against \(repoURL.path)...")
        var rows: [BenchResultRow] = []
        for (index, question) in selected.enumerated() {
            print("[\(index + 1)/\(selected.count)] \(question.id): \(question.question.prefix(72))...")
            let row = await Self.run(
                question: question, repoURL: repoURL, outURL: outURL, commit: commit,
                forceDepth: forceDepth, maxBudgetUsd: maxBudgetUsd, timeoutSeconds: timeout,
                localBackend: localBackend)
            rows.append(row)
            print(
                "    depth=\(row.depth) outcome=\(row.outcome) cost=$\(row.totalCostUsd.map { String(format: "%.2f", $0) } ?? "0.00") "
                    + "latency=\(Int(row.latencyMs))ms")
        }

        try Self.writeJSONL(rows, to: reportURL.appendingPathComponent("routing_benchmark.jsonl"))
        var summary = BenchSummary(rows: rows)
        summary.localModel = localBackend.modelIdentifier(for: .answering)
        summary.modelLoadMs = modelLoadMs
        try Self.writeSummary(summary, to: reportURL.appendingPathComponent("routing_benchmark_summary.json"))

        print("")
        print("Wrote \(rows.count) row(s) to \(reportURL.path)")
        summary.printFormatted()
    }

    private static func run(
        question: BenchQuestion, repoURL: URL, outURL: URL, commit: String?, forceDepth: Int?,
        maxBudgetUsd: Double, timeoutSeconds: Double, localBackend: LocalModelBackend
    ) async -> BenchResultRow {
        let config = AgentSessionConfig(
            repoRoot: repoURL, outputDirectory: outURL, commit: commit, forceDepth: forceDepth,
            maxBudgetUsd: maxBudgetUsd, timeoutSeconds: timeoutSeconds, localBackend: localBackend)
        let start = ContinuousClock.now
        do {
            let result = try await Ask.agentSession(config: config).ask(question.question)
            let elapsedMs = Self.milliseconds(since: start)
            return BenchResultRow(
                id: question.id, category: question.category, question: question.question,
                expectedAnswer: question.expectedAnswer, depth: result.depthDecision.depth,
                routingMethod: result.depthDecision.method.rawValue,
                routingConfidence: result.depthDecision.confidence.rawValue,
                outcome: result.investigation.outcome, claimCount: result.claimCount,
                droppedClaimCount: result.droppedClaimCount, partial: result.partial,
                totalCostUsd: result.investigation.totalCostUsd, numTurns: result.investigation.numTurns,
                latencyMs: elapsedMs, answerText: result.answerText, errorMessage: nil)
        } catch {
            let elapsedMs = Self.milliseconds(since: start)
            return BenchResultRow(
                id: question.id, category: question.category, question: question.question,
                expectedAnswer: question.expectedAnswer, depth: 0, routingMethod: "unknown",
                routingConfidence: "unknown", outcome: "error", claimCount: 0, droppedClaimCount: 0,
                partial: true, totalCostUsd: nil, numTurns: nil, latencyMs: elapsedMs, answerText: "",
                errorMessage: String(describing: error))
        }
    }

    private static func classify(_ questions: [BenchQuestion], repoURL: URL, reportURL: URL) async throws {
        let depthModel = DepthModel(
            fallback: AppleFoundationDepthClassifier(repositoryName: repoURL.lastPathComponent))
        print("Classifying \(questions.count) question(s) for \(repoURL.lastPathComponent) (no answering)...")
        var rows: [ClassificationRow] = []
        for (index, question) in questions.enumerated() {
            let start = ContinuousClock.now
            let row: ClassificationRow
            do {
                let decision = try await depthModel.classify(question.question)
                row = ClassificationRow(
                    id: question.id, category: question.category, question: question.question,
                    depth: decision.depth, method: decision.method.rawValue,
                    confidence: decision.confidence.rawValue, isInScope: decision.isInScope,
                    rationale: decision.rationale, latencyMs: milliseconds(since: start), errorMessage: nil)
            } catch {
                row = ClassificationRow(
                    id: question.id, category: question.category, question: question.question, depth: 0,
                    method: "unknown", confidence: "unknown", isInScope: true, rationale: "",
                    latencyMs: milliseconds(since: start), errorMessage: String(describing: error))
            }
            rows.append(row)
            let scope = row.isInScope ? "" : " DECLINED"
            print(
                "[\(index + 1)/\(questions.count)] \(question.id): depth=\(row.depth) \(row.method)/\(row.confidence)"
                    + "\(scope) \(Int(row.latencyMs))ms")
        }

        try writeJSONL(rows, to: reportURL.appendingPathComponent("routing_classification.jsonl"))
        let summary = ClassificationSummary(rows: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(summary).write(to: reportURL.appendingPathComponent("routing_classification_summary.json"))

        print("")
        print("Wrote \(rows.count) row(s) to \(reportURL.path)")
        summary.printFormatted()
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func writeJSONL<Row: Encodable>(_ rows: [Row], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        for row in rows {
            let data = try encoder.encode(row)
            lines.append(String(data: data, encoding: .utf8) ?? "{}")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeSummary(_ summary: BenchSummary, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(summary)
        try data.write(to: url)
    }
}

/// One question from a benchmark JSON file's `"questions"` array. Deliberately tolerant of extra
/// fields the real corpus carries (`required_concepts`, `evidence`, `difficulty`, ...) --
/// `Decodable` ignores keys it has no property for, so this doesn't need to mirror the full
/// schema, only the fields this command actually uses.
struct BenchQuestion: Decodable {
    let id: String
    let category: String
    let question: String
    let expectedAnswer: String?

    enum CodingKeys: String, CodingKey {
        case id, category, question
        case expectedAnswer = "expected_answer"
    }
}

struct BenchmarkFile: Decodable {
    let questions: [BenchQuestion]
}

/// One question's real routing/outcome/cost/latency result -- everything §6.2's "what gets
/// measured" needs, plus the question/expected-answer text so a later hand-check (§6.2:
/// correctness is graded by hand, not automated) doesn't need to cross-reference the original
/// benchmark file separately.
struct BenchResultRow: Encodable {
    let id: String
    let category: String
    let question: String
    let expectedAnswer: String?
    let depth: Int
    let routingMethod: String
    let routingConfidence: String
    let outcome: String
    let claimCount: Int
    let droppedClaimCount: Int
    let partial: Bool
    let totalCostUsd: Double?
    let numTurns: Int?
    let latencyMs: Double
    let answerText: String
    let errorMessage: String?
}

/// One question's Depth Model decision under `bench --classify-only` (Docs/18 M0).
struct ClassificationRow: Encodable {
    let id: String
    let category: String
    let question: String
    let depth: Int
    let method: String
    let confidence: String
    let isInScope: Bool
    let rationale: String
    let latencyMs: Double
    let errorMessage: String?
}

/// Depth/scope distribution for a `--classify-only` run, shaped for side-by-side comparison with
/// an earlier run's routing_benchmark summary.
struct ClassificationSummary: Encodable {
    let totalQuestions: Int
    let depthCounts: [String: Int]
    let methodCounts: [String: Int]
    let confidenceCounts: [String: Int]
    let declinedIds: [String]
    let errorIds: [String]
    let depthCountsByCategory: [String: [String: Int]]
    let p50LatencyMs: Double
    let p95LatencyMs: Double

    init(rows: [ClassificationRow]) {
        let answered = rows.filter { $0.errorMessage == nil }
        let inScope = answered.filter(\.isInScope)
        totalQuestions = rows.count
        depthCounts = Self.counts(inScope.map { String($0.depth) })
        methodCounts = Self.counts(answered.map(\.method))
        confidenceCounts = Self.counts(answered.map(\.confidence))
        declinedIds = answered.filter { !$0.isInScope }.map(\.id)
        errorIds = rows.filter { $0.errorMessage != nil }.map(\.id)
        depthCountsByCategory = Dictionary(grouping: inScope, by: \.category)
            .mapValues { Self.counts($0.map { String($0.depth) }) }
        let latencies = answered.map(\.latencyMs).sorted()
        p50LatencyMs = latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, latencies.count / 2)]
        p95LatencyMs = latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]
    }

    private static func counts(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    func printFormatted() {
        print("--- classification summary ---")
        print("total: \(totalQuestions), declined: \(declinedIds.count), errors: \(errorIds.count)")
        print("in-scope depth: " + depthCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        print("method: " + methodCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        print("confidence: " + confidenceCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        if !declinedIds.isEmpty { print("declined: " + declinedIds.joined(separator: ", ")) }
        print("latency p50=\(Int(p50LatencyMs))ms p95=\(Int(p95LatencyMs))ms")
    }
}

/// Per-depth/per-category aggregates (Docs/15 §6.2): counts, cost, and p50/p95 latency. A plain
/// `struct`, not a class -- computed once from a finished `rows` array, never mutated.
struct BenchSummary: Encodable {
    struct DepthAggregate: Encodable {
        let count: Int
        let outcomeCounts: [String: Int]
        let totalCostUsd: Double
        let p50LatencyMs: Double
        let p95LatencyMs: Double
    }

    let totalQuestions: Int
    let totalCostUsd: Double
    let byDepth: [String: DepthAggregate]
    let byCategory: [String: Int]
    /// Which local backend served depth 1/2, and its one-time load when preloaded (Docs/18 M3).
    var localModel: String?
    var modelLoadMs: Double?

    init(rows: [BenchResultRow]) {
        totalQuestions = rows.count
        totalCostUsd = rows.reduce(0) { $0 + ($1.totalCostUsd ?? 0) }
        byCategory = Dictionary(grouping: rows, by: \.category).mapValues(\.count)
        byDepth = Dictionary(grouping: rows, by: { String($0.depth) }).mapValues { group in
            let latencies = group.map(\.latencyMs).sorted()
            var outcomeCounts: [String: Int] = [:]
            for row in group { outcomeCounts[row.outcome, default: 0] += 1 }
            return DepthAggregate(
                count: group.count, outcomeCounts: outcomeCounts,
                totalCostUsd: group.reduce(0) { $0 + ($1.totalCostUsd ?? 0) },
                p50LatencyMs: Self.percentile(latencies, 0.50), p95LatencyMs: Self.percentile(latencies, 0.95))
        }
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[index]
    }

    func printFormatted() {
        print("--- summary ---")
        print("total: \(totalQuestions) question(s), $\(String(format: "%.2f", totalCostUsd))")
        for depth in byDepth.keys.sorted() {
            guard let aggregate = byDepth[depth] else { continue }
            let outcomes = aggregate.outcomeCounts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            print(
                "depth \(depth): \(aggregate.count) question(s), $\(String(format: "%.2f", aggregate.totalCostUsd)), "
                    + "p50=\(Int(aggregate.p50LatencyMs))ms p95=\(Int(aggregate.p95LatencyMs))ms, outcomes: \(outcomes)")
        }
    }
}
