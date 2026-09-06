import Foundation

/// Best-effort extraction of anchor-shaped strings (`<path>::<Dotted.Name>` or a bare module
/// path) out of an `ActionLoop` run's tool-call trace, so a local-model answer can cite the
/// same evidence shape a Claude-delegated one does (Docs/12 M4: "full epistemic claim/evidence
/// persistence"). Deliberately tolerant of false positives: `SemanticImporter`'s own evidence
/// resolution (Docs/11 "step 2") already drops any anchor that doesn't resolve against this
/// run's real symbols -- a bogus match here gets exactly the same protection a Claude-invented
/// anchor gets, it just doesn't survive into a persisted claim.
public enum EvidenceAnchors {
    private static let pattern = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9_./-]+\.py(?:::[A-Za-z_][A-Za-z0-9_.]*)?"#
    )

    /// Scans both the tool-call arguments (an anchor the model asked to look up is itself
    /// evidence it consulted) and the tool's result text (anchors the tool returned), in
    /// first-seen order, deduplicated.
    public static func extract(from toolCalls: [ExecutedToolCall]) -> [String] {
        var seen = Set<String>()
        var anchors: [String] = []
        for call in toolCalls {
            for text in [call.argumentsDescription, call.result] {
                for anchor in matches(in: text) where seen.insert(anchor).inserted {
                    anchors.append(anchor)
                }
            }
        }
        return anchors
    }

    private static func matches(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
