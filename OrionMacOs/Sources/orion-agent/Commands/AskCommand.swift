import ArgumentParser
import Foundation
import OrionAgent
import OrionCodeIntel

/// `orion-agent ask` (Docs/12_phase3_mlx_agent.md M4, "State management + CLI"): routes one
/// question through `AgentSession` -- the Depth Model choosing depth 1 (local, no tools),
/// depth 2 (local + deterministic Code Graph tools), or depth 3 (delegate to Claude Code) --
/// and persists the routing decision, tool trace, and any surviving claims/evidence.
struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Ask a question about an analyzed repository."
    )

    @Argument(help: "Path to the repository checkout (must already be analyzed by `orion-index analyze`).")
    var path: String

    @Argument(help: "The question to ask.")
    var question: String

    @Option(help: "Directory containing orion.db + export/ (default: <path>/.orion, matching `orion-index analyze`'s own default).")
    var out: String?

    @Option(help: "Answer against this commit's analyzed run instead of the latest one.")
    var commit: String?

    @Option(
        name: .customLong("force-depth"),
        help: "Override the Depth Model: 1 (local only), 2 (local + tools), or 3 (delegate to Claude Code)."
    )
    var forceDepth: Int?

    @Option(name: .customLong("max-budget-usd"), help: "Cost ceiling for a depth-3 Claude Code investigation.")
    var maxBudgetUsd: Double = 1.00

    @Option(help: "Wall-clock timeout, in seconds, for a depth-3 Claude Code investigation.")
    var timeout: Double = 400

    @Flag(help: "Print the routing decision and the full tool-call trace (hidden by default per Docs/05 §8).")
    var explain: Bool = false

    @Flag(help: "Print a structured JSON answer instead of formatted text.")
    var json: Bool = false

    func validate() throws {
        if let forceDepth, !(1...3).contains(forceDepth) {
            throw ValidationError("--force-depth must be 1, 2, or 3 (got \(forceDepth))")
        }
    }

    func run() async throws {
        let repoURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let outURL = URL(
            fileURLWithPath: ((out ?? repoURL.appendingPathComponent(".orion").path) as NSString)
                .expandingTildeInPath
        ).standardizedFileURL

        let config = AgentSessionConfig(
            repoRoot: repoURL, outputDirectory: outURL, commit: commit, forceDepth: forceDepth,
            maxBudgetUsd: maxBudgetUsd, timeoutSeconds: timeout
        )

        let result: AgentSessionResult
        do {
            result = try await AgentSession(config: config).ask(question)
        } catch let error as AgentSessionError {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw ExitCode(3)
        } catch {
            FileHandle.standardError.write(Data("ask failed: \(error)\n".utf8))
            throw ExitCode(3)
        }

        if json {
            try printJSON(result)
        } else {
            printFormatted(result)
        }

        let failedDelegation =
            result.depthDecision.depth == 3
            && [InvestigationOutcome.rejected.rawValue, InvestigationOutcome.unverified.rawValue]
                .contains(result.investigation.outcome)
        if failedDelegation {
            throw ExitCode(1)
        }
    }

    // MARK: output

    private func printFormatted(_ result: AgentSessionResult) {
        print(result.answerText)

        if result.claimCount > 0 || result.droppedClaimCount > 0 {
            var note = "[\(result.claimCount) claim(s) recorded"
            if result.droppedClaimCount > 0 {
                note += ", \(result.droppedClaimCount) dropped for unresolved evidence"
            }
            note += " -- outcome: \(result.investigation.outcome)]"
            print("")
            print(note)
        }
        if result.partial {
            print("[partial answer]")
        }

        guard explain else { return }
        print("")
        print("--- routing ---")
        let decision = result.depthDecision
        print(
            "depth=\(decision.depth) method=\(decision.method.rawValue) "
                + "confidence=\(decision.confidence.rawValue)")
        print(decision.rationale)

        guard !result.toolCalls.isEmpty else { return }
        print("")
        print("--- tool calls ---")
        for call in result.toolCalls {
            print("[\(call.turnIndex)] \(call.toolName)(\(call.argumentsDescription))")
            print("    -> \(call.result)")
        }
    }

    private func printJSON(_ result: AgentSessionResult) throws {
        var object: [String: Any] = [
            "question": result.question,
            "answer": result.answerText,
            "depth": result.depthDecision.depth,
            "routing_method": result.depthDecision.method.rawValue,
            "routing_confidence": result.depthDecision.confidence.rawValue,
            "routing_rationale": result.depthDecision.rationale,
            "investigation_id": result.investigation.id,
            "outcome": result.investigation.outcome,
            "claim_count": result.claimCount,
            "dropped_claim_count": result.droppedClaimCount,
            "partial": result.partial,
        ]
        if explain {
            object["tool_calls"] = result.toolCalls.map {
                call -> [String: Any] in
                [
                    "turn": call.turnIndex, "tool": call.toolName,
                    "arguments": call.argumentsDescription, "result": call.result,
                ]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        print(String(data: data, encoding: .utf8) ?? "{}")
    }
}
