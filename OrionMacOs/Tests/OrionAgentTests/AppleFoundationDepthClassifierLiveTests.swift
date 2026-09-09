import XCTest
import FoundationModels

@testable import OrionAgent

/// Docs/15_phase5_adaptive_exploration.md §11 M8: real, live regression coverage for the
/// repository-grounding fix to the guardrail (Docs/15 §3). `PHASE5_ROUTING_BENCHMARK.md` §4.2
/// found `AppleFoundationDepthClassifier` wrongly declining two real, unambiguous
/// architecture questions about vendored Starlette ("What are the major components of
/// Starlette...", "How does the WebSocket request path diverge...") as "general knowledge" --
/// root cause: the classifier was never told *which* repository it was routing for, so a
/// question naming a real, well-known open-source project read as a request to recite training
/// knowledge about it, not a request to investigate this specific analyzed instance. Same
/// live-gating posture as `FoundationModelsToolCallingLiveTests` (no `xcodebuild`/Metal
/// workaround needed -- `FoundationModels` is a system framework).
final class AppleFoundationDepthClassifierLiveTests: XCTestCase {

    private func skipIfUnavailable() throws {
        guard ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip(
                "Set ORION_AGENT_LIVE_MODEL_TEST=1 to run this test -- it uses the real "
                    + "on-device Apple Intelligence model and is not run in CI.")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple Intelligence is unavailable on this machine.")
        }
    }

    /// The exact question shape that produced a real false-decline in the M7 benchmark run
    /// (`AR-01`) -- reproduced here verbatim (not paraphrased) so this test would have actually
    /// caught the real bug, not just a similar-looking one.
    func testArchitectureQuestionNamingTheRepositoryIsNotDeclined() async throws {
        try skipIfUnavailable()
        let classifier = AppleFoundationDepthClassifier(repositoryName: "starlette")
        let decision = try await classifier.classify(
            "What are the major components of Starlette, and how are they layered when handling"
                + " an incoming HTTP request?")
        XCTAssertTrue(
            decision.isInScope,
            "a question naming the analyzed repository directly must not be declined -- got: \(decision.rationale)"
        )
    }

    /// `AR-05`'s exact real shape, the second of the two live false-declines.
    func testBehavioralQuestionNamingTheRepositoryIsNotDeclined() async throws {
        try skipIfUnavailable()
        let classifier = AppleFoundationDepthClassifier(repositoryName: "starlette")
        let decision = try await classifier.classify(
            "How does the WebSocket request path diverge from the HTTP path while going through"
                + " the same application stack?")
        XCTAssertTrue(
            decision.isInScope,
            "a specific behavioral question about the analyzed repository must not be declined -- got: \(decision.rationale)"
        )
    }

    /// Regression guard in the other direction: grounding the classifier in a repository name
    /// must not make it indiscriminately permissive -- a genuinely unrelated question is still
    /// declined.
    func testGenuinelyOffTopicQuestionIsStillDeclinedWhenRepositoryNameIsProvided() async throws {
        try skipIfUnavailable()
        let classifier = AppleFoundationDepthClassifier(repositoryName: "starlette")
        let decision = try await classifier.classify("What's a good recipe for pasta?")
        XCTAssertFalse(decision.isInScope)
    }

    /// Confirms the *fix* by reproducing the *bug* in the same process, same model, same
    /// question -- without a repository name, the false-decline is still real (this is the
    /// pre-fix behavior `AgentSession.init` used to always produce; kept as a permanent, honest
    /// record of what the bug looked like, not just asserted from memory of the benchmark run).
    func testTheSameQuestionWithoutARepositoryNameCanStillBeDeclined() async throws {
        try skipIfUnavailable()
        let classifier = AppleFoundationDepthClassifier()
        let decision = try await classifier.classify(
            "What are the major components of Starlette, and how are they layered when handling"
                + " an incoming HTTP request?")
        // Not asserted as always-false (the on-device model is confirmed noisy run to run,
        // Docs/12 Risk #7) -- this test documents the failure mode's continued existence without
        // grounding, it does not assert it reproduces on every single run.
        if !decision.isInScope {
            print("Reproduced the pre-fix false-decline, as expected without repositoryName: \(decision.rationale)")
        }
    }
}
