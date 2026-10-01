import Foundation
import FoundationModels
import Observation
import Synchronization

/// Docs/19 M0: measures the on-device system model the iOS companion will run on. The same file
/// builds into the iOS app and the macOS `fm-probe` tool, so one report format answers "does the
/// Mac predict the phone?" (Docs/19 Risk 6).
///
/// Every check catches its own error, so one unsupported feature (say, a reasoning level the
/// system model rejects) is a recorded finding, not an aborted run.
@MainActor
@Observable
final class FMProbe {
    private(set) var report: ProbeReport
    private(set) var isRunning = false
    private(set) var currentStep = ""

    private let model = SystemLanguageModel.default

    init() {
        report = ProbeReport(startedAt: Date())
    }

    func run() async {
        isRunning = true
        defer {
            isRunning = false
            currentStep = ""
        }
        report = ProbeReport(startedAt: Date())
        report.os = ProcessInfo.processInfo.operatingSystemVersionString
        report.deviceModel = DeviceInfo.model
        report.availability = Self.describe(model.availability)
        report.supportsCurrentLocale = model.supportsLocale()
        guard case .available = model.availability else { return }

        report.variant = model.variant.displayName
        report.contextSize = model.contextSize
        report.capabilities = [
            "guidedGeneration": model.capabilities.contains(.guidedGeneration),
            "toolCalling": model.capabilities.contains(.toolCalling),
            "reasoning": model.capabilities.contains(.reasoning),
            "vision": model.capabilities.contains(.vision),
        ]

        currentStep = "Tokenizing sample context"
        await measureTokenization()
        let charsPerToken = report.tokenization.last?.charsPerToken ?? 4

        await step("plain") { try await self.plain() }
        await step("throughput_2k") { try await self.throughput(targetTokens: 2000, charsPerToken: charsPerToken) }
        for level in ReasoningProbe.allCases {
            await step("reasoning_\(level.rawValue)") { try await self.reasoning(level, charsPerToken: charsPerToken) }
        }
        await step("guided_judge") { try await self.guidedJudge() }
        await step("tool_calling") { try await self.toolCalling() }
        await step("multi_turn_cache") { try await self.multiTurnCache(charsPerToken: charsPerToken) }
        await step("context_overflow") { try await self.contextOverflow() }
    }

    // MARK: - Checks

    private func measureTokenization() async {
        let text = SampleContext.text
        for chars in [1_000, 2_000, 4_000, 8_000, 16_000, text.count] where chars <= text.count {
            let slice = String(text.prefix(chars))
            do {
                let tokens = try await model.tokenCount(for: slice)
                report.tokenization.append(.init(
                    chars: chars, tokens: tokens, charsPerToken: Double(chars) / Double(max(tokens, 1))))
            } catch {
                report.checks.append(.failed("tokenization_\(chars)", error))
                return
            }
        }
    }

    private func plain() async throws -> ProbeReport.Check {
        let session = LanguageModelSession(model: model)
        var check = try await Self.stream(
            session, prompt: "In one short sentence: what is an ASGI web framework?",
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120))
        check.name = "plain"
        return check
    }

    /// A realistic answering turn: ~`targetTokens` of real Orion context plus a question, the
    /// shape of an on-device Ask (Docs/19 M6).
    private func throughput(targetTokens: Int, charsPerToken: Double) async throws -> ProbeReport.Check {
        let context = String(SampleContext.text.prefix(Int(Double(targetTokens) * charsPerToken)))
        let session = LanguageModelSession(
            model: model,
            instructions: "You answer questions about a Python codebase using only the provided context.")
        var check = try await Self.stream(
            session,
            prompt: "Context:\n\(context)\n\nQuestion: Summarize this codebase's architecture in about 150 words.",
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 400))
        check.name = "throughput_2k"
        return check
    }

    private func reasoning(_ level: ReasoningProbe, charsPerToken: Double) async throws -> ProbeReport.Check {
        let context = String(SampleContext.text.prefix(Int(1_000 * charsPerToken)))
        let session = LanguageModelSession(model: model)
        var check = try await Self.stream(
            session,
            prompt: "Context:\n\(context)\n\nQuestion: Which component handles request routing? Answer in one sentence.",
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 600),
            contextOptions: ContextOptions(reasoningLevel: level.level))
        check.name = "reasoning_\(level.rawValue)"
        return check
    }

    /// The Phase 7 judge's decision shape (`GuidedGrading.swift`), declared in the order the
    /// model should fill it (quote and reasoning before the verdict). Streamed, so the report
    /// records the order fields actually appeared in -- Core AI ignored declaration order
    /// (Docs/18 M5), which put the verdict before its justification.
    private func guidedJudge() async throws -> ProbeReport.Check {
        let session = LanguageModelSession(
            model: model,
            instructions: "You check whether a developer's answer states a given idea. Quote the answer; do not invent.")
        let prompt = """
            Idea to check: Middleware added with add_middleware wraps the whole application, including routing.
            Developer's answer: "When you call add_middleware, Starlette rebuilds the middleware stack so the \
            new middleware sits outside the router and sees every request before routing happens."
            Does the answer state the idea?
            """
        let start = ContinuousClock.now
        var fieldOrder: [String] = []
        var last: ProbeCriterionDecision.PartiallyGenerated?
        let stream = session.streamResponse(
            to: prompt, generating: ProbeCriterionDecision.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 300))
        for try await snapshot in stream {
            let partial = snapshot.content
            let present: [(String, Bool)] = [
                ("evidenceQuote", partial.evidenceQuote != nil), ("reasoning", partial.reasoning != nil),
                ("answerStatesThisIdea", partial.answerStatesThisIdea != nil), ("confidence", partial.confidence != nil),
            ]
            for (field, isPresent) in present where isPresent && !fieldOrder.contains(field) {
                fieldOrder.append(field)
            }
            last = partial
        }
        let total = start.duration(to: .now)
        let declared = ["evidenceQuote", "reasoning", "answerStatesThisIdea", "confidence"]
        let met = last?.answerStatesThisIdea ?? false
        return ProbeReport.Check(
            name: "guided_judge", ok: met && fieldOrder == declared,
            detail: "met=\(met) confidence=\(last?.confidence ?? "-") fieldOrder=\(fieldOrder) "
                + "declarationOrder=\(fieldOrder == declared) quote=\(last?.evidenceQuote ?? "-")",
            totalMs: total.milliseconds)
    }

    private func toolCalling() async throws -> ProbeReport.Check {
        let tool = LookupSymbolTool()
        let session = LanguageModelSession(
            model: model, tools: [tool],
            instructions: "You answer questions about a Python codebase. Use the lookup_symbol tool to find where symbols are defined; never guess file paths.")
        var check = try await Self.stream(
            session, prompt: "Where is the Router class defined, and on which lines?",
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 300))
        let calls = tool.calls.withLock { $0 }
        check.name = "tool_calling"
        check.ok = !calls.isEmpty && check.detail.contains("routing.py")
        check.detail = "calls=\(calls) answer=\(check.detail)"
        return check
    }

    /// Two turns in one session: does the second turn reuse the first turn's prefix
    /// (`cachedTokenCount`)? That decides whether Ask follow-ups can keep their context (M6).
    private func multiTurnCache(charsPerToken: Double) async throws -> ProbeReport.Check {
        let context = String(SampleContext.text.prefix(Int(1_500 * charsPerToken)))
        let session = LanguageModelSession(
            model: model, instructions: "You answer questions about a Python codebase using only this context:\n\(context)")
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120)
        let first = try await Self.stream(session, prompt: "Name the component that handles routing.", options: options)
        var second = try await Self.stream(session, prompt: "And which component handles middleware?", options: options)
        second.name = "multi_turn_cache"
        second.detail = "turn1 in=\(first.inputTokens ?? -1) cached=\(first.cachedInputTokens ?? -1) ttft=\(first.ttftMs ?? -1)ms; "
            + "turn2 in=\(second.inputTokens ?? -1) cached=\(second.cachedInputTokens ?? -1) ttft=\(second.ttftMs ?? -1)ms"
        return second
    }

    /// Deliberately over the window: confirms the error the M6 shrink-and-retry path must catch.
    private func contextOverflow() async throws -> ProbeReport.Check {
        let session = LanguageModelSession(model: model)
        let prompt = String(repeating: SampleContext.text + "\n", count: 3) + "\nSummarize the above."
        do {
            _ = try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 50))
            return ProbeReport.Check(name: "context_overflow", ok: false, detail: "no error for a \(prompt.count)-char prompt")
        } catch LanguageModelError.contextSizeExceeded(let context) {
            return ProbeReport.Check(
                name: "context_overflow", ok: true,
                detail: "contextSizeExceeded: \(context.tokenCount) tokens > \(context.contextSize)")
        }
    }

    // MARK: - Helpers

    private func step(_ name: String, _ body: () async throws -> ProbeReport.Check) async {
        currentStep = name
        do {
            report.checks.append(try await body())
        } catch {
            report.checks.append(.failed(name, error))
        }
    }

    /// Streams one turn and records TTFT, total time and the session's token usage.
    private static func stream(
        _ session: LanguageModelSession, prompt: String, options: GenerationOptions,
        contextOptions: ContextOptions = ContextOptions()
    ) async throws -> ProbeReport.Check {
        let start = ContinuousClock.now
        var firstChunk: Duration?
        var usage: LanguageModelSession.Usage?
        var text = ""
        for try await snapshot in session.streamResponse(to: prompt, options: options, contextOptions: contextOptions) {
            if firstChunk == nil, !snapshot.content.isEmpty { firstChunk = start.duration(to: .now) }
            text = snapshot.content
            usage = snapshot.usage
        }
        let total = start.duration(to: .now)
        let ttft = firstChunk ?? total
        let outputTokens = usage?.output.totalTokenCount
        let decodeSeconds = Double((total - ttft).milliseconds) / 1000
        return ProbeReport.Check(
            name: "", ok: !text.isEmpty, detail: text,
            ttftMs: ttft.milliseconds, totalMs: total.milliseconds,
            inputTokens: usage?.input.totalTokenCount, cachedInputTokens: usage?.input.cachedTokenCount,
            outputTokens: outputTokens, reasoningTokens: usage?.output.reasoningTokenCount,
            decodeTokensPerSecond: outputTokens.flatMap { $0 > 1 && decodeSeconds > 0 ? Double($0) / decodeSeconds : nil })
    }

    private static func describe(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available: "available"
        case .unavailable(.deviceNotEligible): "unavailable: device not eligible"
        case .unavailable(.appleIntelligenceNotEnabled): "unavailable: Apple Intelligence not enabled"
        case .unavailable(.modelNotReady): "unavailable: model not ready"
        case .unavailable(let other): "unavailable: \(other)"
        }
    }
}

enum ReasoningProbe: String, CaseIterable {
    case none, light, deep

    var level: ContextOptions.ReasoningLevel {
        switch self {
        case .none: .custom("none")
        case .light: .light
        case .deep: .deep
        }
    }
}

@Generable
struct ProbeCriterionDecision {
    @Guide(description: "A short verbatim quote from the developer's answer that supports your decision, or empty.")
    var evidenceQuote: String
    @Guide(description: "Your reasoning in one or two sentences.")
    var reasoning: String
    @Guide(description: "True only if the answer clearly states the idea.")
    var answerStatesThisIdea: Bool
    @Guide(.anyOf(["high", "medium", "low"]))
    var confidence: String
}

/// A stand-in for Orion's `lookup_symbol` (`QueryEngineTools`), returning a fixed Starlette row.
final class LookupSymbolTool: Tool {
    let name = "lookup_symbol"
    let description = "Finds where a symbol (class, function, method) is defined in the analyzed repository."
    let calls = Mutex<[String]>([])

    @Generable
    struct Arguments {
        @Guide(description: "The symbol name to look up, e.g. Router or Starlette.add_middleware")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        calls.withLock { $0.append(arguments.query) }
        return "starlette/routing.py::Router (class) -- starlette/routing.py:580-712"
    }
}

struct ProbeReport: Codable, Sendable {
    var probeVersion = 1
    var startedAt: Date
    var os = ""
    var deviceModel = ""
    var availability = ""
    var supportsCurrentLocale = false
    var variant: String?
    var contextSize: Int?
    var capabilities: [String: Bool] = [:]
    var tokenization: [TokenSample] = []
    var checks: [Check] = []

    struct TokenSample: Codable, Sendable {
        var chars: Int
        var tokens: Int
        var charsPerToken: Double
    }

    struct Check: Codable, Sendable, Identifiable {
        var id: String { name }
        var name: String
        var ok: Bool
        var detail: String
        var ttftMs: Int?
        var totalMs: Int?
        var inputTokens: Int?
        var cachedInputTokens: Int?
        var outputTokens: Int?
        var reasoningTokens: Int?
        var decodeTokensPerSecond: Double?

        static func failed(_ name: String, _ error: any Error) -> Check {
            Check(name: name, ok: false, detail: "error: \(String(describing: error))")
        }
    }

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

enum DeviceInfo {
    /// `hw.machine` is the product identifier on iOS (e.g. "iPhone18,3"); `hw.model` is the Mac's.
    static var model: String {
        #if os(iOS)
        sysctl("hw.machine")
        #else
        sysctl("hw.model")
        #endif
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

extension Duration {
    var milliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
