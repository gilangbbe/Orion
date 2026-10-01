import FoundationModels
import OrionCore
import XCTest

@testable import OrionAgent

/// The on-device system model as an Orion backend (Docs/19 M1), live. Before M1 every no-think
/// or guided call threw "does not support reasoning" on it (Docs/19 M0), so these drive exactly
/// those paths. Gated on `ORION_AGENT_LIVE_SYSTEM_TEST=1` plus Apple Intelligence being available,
/// and skipped in CI.
///
/// On the Mac this is AFM 3 Core Advanced; the iPhone runs the smaller AFM 3 Core, so these check
/// the plumbing, not the phone's quality.
final class SystemModelLiveTests: XCTestCase {
    private func loadAgent(role: LocalModelRole = .answering) async throws -> any AgentModel {
        guard ProcessInfo.processInfo.environment["ORION_AGENT_LIVE_SYSTEM_TEST"] == "1" else {
            throw XCTSkip("set ORION_AGENT_LIVE_SYSTEM_TEST=1 to call the on-device system model")
        }
        guard case .available = SystemModelInfo.availability else {
            throw XCTSkip("system model unavailable: \(SystemModelInfo.availability)")
        }
        // An `ORION_LOCAL_ROLES` table that turns thinking off everywhere must be harmless here.
        let roles = try LocalModelRoles(parsing: "*=off")
        return try await LocalModelLoader.shared.model(for: .system, role: role, roles: roles)
    }

    func testNoThinkRoleAnswers() async throws {
        let agent = try await loadAgent()
        let reply = try await agent.respond(
            to: "In one sentence: what does an HTTP router do?", instructions: "Answer concisely.")
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(agent.modelIdentifier.hasPrefix("system:"), agent.modelIdentifier)
    }

    /// `FoundationModelsGuidedSession` always asked for `.custom("none")`, so the guided judge
    /// threw on every call before the capability guard. This checks the call completes with a
    /// grounded verdict -- not that the verdict is right: on this very example the two-turn judge
    /// answered "not met" on the Mac's model (Docs/19 M1), where M0's single-call probe judge said
    /// "met". Judge quality on the phone is M7's question.
    func testGuidedJudgeRuns() async throws {
        let agent = try await loadAgent(role: .judging)
        let judge = try LocalGrading.judge(agent: agent, output: .guided)
        let answer = "add_middleware rebuilds the middleware stack, so the new middleware sits outside the "
            + "router and sees every request before routing happens."
        let verdict = try await judge.judge(
            criterionText: "Middleware added with add_middleware wraps the whole application, including routing.",
            criterionKind: .required, answer: answer, conceptEvidence: [])
        XCTAssertFalse(verdict.note.isEmpty, "\(verdict)")
        if !verdict.evidenceQuote.isEmpty {
            XCTAssertTrue(answer.contains(verdict.evidenceQuote), "quote not from the answer: \(verdict.evidenceQuote)")
        }
    }

    func testNativeToolTurnRuns() async throws {
        let agent = try await loadAgent()
        let native = try XCTUnwrap(agent as? any NativeToolCallingModel)
        let reply = try await native.makeToolSession(tools: [], instructions: "Answer concisely.")
            .respond(to: "Name one HTTP method.", toolsAllowed: true)
        XCTAssertFalse(reply.isEmpty)
    }
}
