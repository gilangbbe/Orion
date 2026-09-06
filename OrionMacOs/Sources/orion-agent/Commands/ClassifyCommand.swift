import ArgumentParser
import OrionAgent

/// Debug command for the Depth Model (M1) -- runs `DepthHeuristics` first, falling back to
/// `AppleFoundationDepthClassifier` only when no explicit rule matches, exactly like
/// `DepthModel.classify` does. Not part of the product surface; useful for verifying routing
/// decisions directly while `ask` doesn't wire depth routing in yet (that's M4). See
/// Docs/12_phase3_mlx_agent.md.
struct Classify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "classify",
        abstract: "Debug: run the Depth Model on a question and print its routing decision."
    )

    @Argument(help: "The question to classify.")
    var question: String

    func run() async throws {
        let model = DepthModel(fallback: AppleFoundationDepthClassifier())
        let decision = try await model.classify(question)
        printDecision(decision)
    }

    private func printDecision(_ decision: DepthDecision) {
        print(
            "depth=\(decision.depth) method=\(decision.method.rawValue) "
                + "confidence=\(decision.confidence.rawValue) intent=\(decision.intent)")
        print(decision.rationale)
    }
}
