import Foundation

/// Drives a bounded, multi-turn investigation without ever touching `mlx-swift-lm`'s native
/// tool-calling path -- Docs/12_phase3_mlx_agent.md Risk #3: that mechanism hangs 10+ minutes
/// and crashes the process on `Qwen3-8B`. Instead, reasoning is separated from tool execution:
/// the model does plain-chat generation, prompted each turn for one small JSON action decision;
/// *this* code, not the model, parses that JSON and executes the real tool call. Verified live
/// (Risk #3's resolution): a full call-tool-then-answer round trip in ~3.0-3.1s, twice,
/// reproducibly, on real `Qwen3-8B-4bit`.
public final class ActionLoop {
    private let tools: [String: AgentTool]
    private let toolList: [AgentTool]
    private let budget: Int

    /// - Parameter budget: how many tool calls this loop may execute before it must answer.
    ///   `0` (L1) skips the JSON-action protocol entirely and asks the question directly --
    ///   Docs/12 Decision #4: this is what makes the depth decision actually change what the
    ///   model is *allowed* to do, not just a label.
    public init(tools: [AgentTool], budget: Int) {
        self.toolList = tools
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.budget = budget
    }

    /// The investigation instructions -- primed context plus the tool list and the strict
    /// one-JSON-object-per-turn contract. Only meaningful when `budget > 0`; a budget-0 session
    /// needs no tool/JSON instructions at all since the loop never asks for either.
    public func instructions(context: String?) -> String {
        var parts: [String] = []
        if let context, !context.isEmpty {
            parts.append(context)
        }
        if budget > 0 {
            let toolDescriptions = toolList.map { "- \($0.name): \($0.description)" }
                .joined(separator: "\n")
            parts.append(
                """
                You are investigating a codebase. You have these tools:
                \(toolDescriptions)

                You must call at least one tool before you may answer -- investigate first, \
                never answer from memory alone. Answering without having called a tool will be \
                rejected.

                Every turn, respond with EXACTLY one JSON object and nothing else -- no other \
                text, no explanation, no thinking:
                {"action": "call_tool", "tool": "<name>", "arguments": {...}}
                or, once you have called at least one tool and have enough information:
                {"action": "answer", "text": "..."}
                """
            )
        }
        return parts.joined(separator: "\n\n")
    }

    /// Runs the loop against `session` (already constructed with `instructions(context:)` as
    /// its instructions) and `question`. Never touches the session's `tools`/`toolDispatch` --
    /// `session` is expected to have none configured.
    public func run(question: String, session: any TurnGenerating) async throws -> AgentAnswer {
        guard budget > 0 else {
            let text = try await session.respond(to: question)
            return AgentAnswer(text: Self.stripThinking(text), toolCalls: [], partial: false)
        }

        var remaining = budget
        var executed: [ExecutedToolCall] = []
        var turnIndex = 0
        var hasCalledTool = false
        // Bounded, not infinite: one corrective re-prompt if the model tries to answer without
        // ever having called a tool, then accept whatever it does next (marked `partial`) rather
        // than nudge forever. Found live (Docs/12 M5's Risk #7 re-verification): a depth-2 model
        // frequently answered from pretrained knowledge with zero tool calls, silently producing
        // the same unreliable content depth 1 does -- the JSON contract already *asked* the
        // model to call a tool first, but asking alone didn't change its behavior, so this turns
        // the requirement into something the loop itself enforces rather than something the
        // model can just ignore. Waived entirely when `toolList` is empty -- a budget>0 loop
        // with no tools configured at all has nothing to require a call to.
        var toolRequirementNudgesLeft = 1
        var raw = try await session.respond(to: question)

        // Checks the current turn for "answer" *before* looking at budget, on every turn --
        // including the one immediately after the budget-th tool call. A model that lands on
        // "answer" exactly when its budget runs out is a clean, complete run, not a partial
        // one; only a model that still wants to `call_tool` with nothing left forces the extra
        // turn below. (An earlier version checked budget first and unconditionally forced a
        // final turn once it hit zero, discarding a same-turn answer and always consuming one
        // response too many -- caught by `ActionLoopTests.testAnsweringExactlyAtBudgetIsNotPartial`.)
        while true {
            guard let json = Self.extractJSONObject(raw), let action = json["action"] as? String
            else {
                return AgentAnswer(text: Self.stripThinking(raw), toolCalls: executed, partial: true)
            }

            if action == "answer" {
                guard hasCalledTool || toolList.isEmpty || toolRequirementNudgesLeft <= 0 else {
                    toolRequirementNudgesLeft -= 1
                    raw = try await session.respond(
                        to:
                            "You have not called a tool yet. You must call at least one tool "
                            + "before answering. Respond with EXACTLY "
                            + "{\"action\": \"call_tool\", \"tool\": \"<name>\", "
                            + "\"arguments\": {...}}.")
                    continue
                }
                let text = (json["text"] as? String) ?? raw
                // Only a real, available-but-skipped tool call counts against completeness --
                // waived (see above) when there was nothing to call in the first place.
                let requiredToolWasSkipped = !hasCalledTool && !toolList.isEmpty
                return AgentAnswer(
                    text: Self.stripThinking(text), toolCalls: executed, partial: requiredToolWasSkipped)
            }

            guard action == "call_tool", let toolName = json["tool"] as? String,
                let tool = tools[toolName]
            else {
                return AgentAnswer(text: Self.stripThinking(raw), toolCalls: executed, partial: true)
            }

            guard remaining > 0 else { break }  // wants another tool call, none left -- fall through

            turnIndex += 1
            let arguments = (json["arguments"] as? [String: Any]) ?? [:]
            let result = tool.execute(arguments: arguments)
            executed.append(
                ExecutedToolCall(
                    turnIndex: turnIndex, toolName: toolName,
                    argumentsDescription: Self.describe(arguments), result: result))
            hasCalledTool = true
            remaining -= 1
            raw = try await session.respond(to: "Tool result: \(result)")
        }

        // Budget exhausted and the model still wants a tool -- force one final turn rather than
        // loop forever or silently drop what it was trying to do.
        let forced = try await session.respond(
            to:
                "You must answer now. Respond with EXACTLY {\"action\": \"answer\", \"text\": "
                + "\"...\"} using everything gathered so far.")
        let text = Self.extractJSONObject(forced)?["text"] as? String ?? forced
        return AgentAnswer(text: Self.stripThinking(text), toolCalls: executed, partial: true)
    }

    /// Qwen3-8B's hybrid-thinking chat template wraps its reasoning in `<think>...</think>`
    /// before the actual reply -- harmless for `extractJSONObject` below (which only looks for
    /// `{`...`}` and skips over prose either side), but never stripped from a *budget-0* (L1)
    /// response, since that path returns the model's raw text directly with no JSON to extract
    /// in the first place. Confirmed live via `orion-agent ask --force-depth 1`: without this,
    /// the full multi-paragraph reasoning trace was the visible "answer." Anchors only on the
    /// closing tag so a missing/malformed opening tag still gets cleaned up.
    private static func stripThinking(_ text: String) -> String {
        guard let range = text.range(of: "</think>") else { return text }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tolerant extraction: first `{` to last `}`, then `JSONSerialization`. Verified live to
    /// survive stray `<think>` wrapper text the model sometimes emits around the JSON despite
    /// being told not to -- same "don't trust the model to format perfectly" posture as Phase
    /// 2's `extract_json` for Claude's output.
    static func extractJSONObject(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
            start < end
        else {
            return nil
        }
        guard let data = text[start...end].data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func describe(_ arguments: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}
