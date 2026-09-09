import Foundation

/// Routes a question to depth 1/2/3 —
/// [03_agent_and_model_routing.md](../../../../Docs/03_agent_and_model_routing.md) §2-3. Tries
/// `DepthHeuristics` first; only calls the (slower, model-backed) fallback when no explicit
/// rule matches. Confidence below `.high` is escalated, but not all the way to depth 3 by
/// default any more: `.medium` goes to depth 2, `.low` (and a timed-out fallback, treated as
/// `.low`) goes to depth 3. Revised from the original "anything below `.high` escalates
/// straight to Claude Code" policy after M5's validation (Docs/12_phase3_mlx_agent.md Risk #7)
/// found every non-trivial question landing on `.medium` confidence and jumping straight past
/// depth 2 to depth 3 every time — `DepthHeuristics`' fixed patterns can't cover the open-ended
/// space of real questions, so routing every not-quite-certain question all the way to Claude
/// left depth 2 effectively unreachable in practice. Decision recorded directly in that risk
/// entry: bias `.medium` toward depth 2 rather than depth 3, since depth 2's real tools ground
/// an uncertain classification in actual evidence for free, before paying for delegation.
///
/// **The default fallback is `AppleFoundationDepthClassifier`** (Apple's on-device
/// `SystemLanguageModel` + `@Generable`/`@Guide`), not the originally-planned Qwen3 tool-calling
/// path. `ModelBackedDepthClassifier` (Qwen3-based) hung 10+ minutes on a tool-calling
/// classification call against real `Qwen3-8B-4bit` — reproduced on both a hard question and a
/// trivial one ("what color is the sky") once tools were present, and neither
/// `additionalContext: ["enable_thinking": false]` nor a literal `/no_think` suffix (both real,
/// working mechanisms confirmed on the plain-chat path) fixed it for a tool-calling session on
/// that checkpoint. See that type's doc comment and Docs/12_phase3_mlx_agent.md Risk #3 for the
/// full writeup.
///
/// **The fallback call is still time-bounded and escalates on timeout, not just on low
/// confidence, regardless of which classifier is plugged in.** A routing decision that can
/// silently hang the whole agent is a worse failure than an over-eager escalation to Claude
/// Code — so a slow/hung fallback is treated exactly like a low-confidence one, per the same
/// policy above, rather than left to block indefinitely. This defense-in-depth is kept even
/// though `AppleFoundationDepthClassifier` has not shown the same failure mode.
///
/// **The losing fallback task is left running, never cancelled.** Also found live at M1: racing
/// the fallback with `withThrowingTaskGroup` and calling `cancelAll()` on timeout crashed the
/// process (SIGSEGV) — cancelling mid-flight MLX/Metal generation is not safe here. Polling an
/// actor-boxed result instead of structured-concurrency cancellation avoids ever sending a
/// cancellation into in-flight generation; the abandoned task keeps running harmlessly (and its
/// result is simply never read) rather than being torn down while GPU work is in progress.
public final class DepthModel {
    private let fallback: DepthFallbackClassifying
    private let fallbackTimeout: Duration

    public init(fallback: DepthFallbackClassifying, fallbackTimeout: Duration = .seconds(20)) {
        self.fallback = fallback
        self.fallbackTimeout = fallbackTimeout
    }

    public func classify(_ question: String) async throws -> DepthDecision {
        if let decision = DepthHeuristics.classify(question) {
            // A question matching one of Docs/03 §2's fixed code-shaped patterns is
            // repository-related by construction (Docs/15 §3.2) -- the guardrail check below
            // never runs for it, exactly like the model-backed fallback itself is skipped.
            return decision
        }

        let decision = try await classifyWithTimeout(question)
        guard decision.isInScope else {
            // Docs/15 §3.2: checked before confidence-based escalation, and unconditionally --
            // an out-of-scope question is never escalated to Claude Code no matter how low its
            // (otherwise irrelevant) confidence came back.
            return decision
        }
        switch decision.confidence {
        case .high:
            return decision
        case .medium:
            return DepthDecision(
                depth: 2, intent: decision.intent, confidence: decision.confidence,
                rationale: decision.rationale
                    + " Routed to depth 2 (local tools): local classification confidence was"
                    + " medium, not high.",
                method: decision.method
            )
        case .low:
            return DepthDecision(
                depth: 3, intent: decision.intent, confidence: decision.confidence,
                rationale: decision.rationale
                    + " Escalated to Claude Code: local classification confidence was low.",
                method: decision.method
            )
        }
    }

    private actor ResultBox {
        private(set) var result: Result<DepthDecision, Error>?
        func set(_ newValue: Result<DepthDecision, Error>) { result = newValue }
    }

    private func classifyWithTimeout(_ question: String) async throws -> DepthDecision {
        let box = ResultBox()
        Task {
            do {
                await box.set(.success(try await fallback.classify(question)))
            } catch {
                await box.set(.failure(error))
            }
        }

        let deadline = ContinuousClock.now.advanced(by: fallbackTimeout)
        while ContinuousClock.now < deadline {
            if let result = await box.result {
                return try result.get()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let result = await box.result {
            return try result.get()
        }

        return DepthDecision(
            depth: 3, intent: "unclassified", confidence: .low,
            rationale:
                "Fallback classifier exceeded \(fallbackTimeout) without answering;"
                + " escalated to Claude Code rather than waiting further.",
            method: .model
        )
    }
}
