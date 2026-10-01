import Foundation
import OrionCore

/// Produces a raw candidate-JSON string for a question-generation prompt. A protocol so
/// `TeachingQuestionGenerator`'s orchestration (gather context -> prompt -> parse -> verify ->
/// retry-once) is unit-testable with a scripted stub, no live model.
public protocol TeachingQuestionDrafting: Sendable {
    /// Which model authored the draft — recorded on the persisted `teaching_questions` row.
    var source: TeachingQuestionSource { get }
    func draft(prompt: String, band: Int) async throws -> String
    /// Drafts from the prompt's inputs. The default builds `TeachingPromptBuilder`'s prompt and
    /// calls `draft(prompt:band:)`; a drafter that shapes its own prompt and output -- the guided
    /// one, whose schema allows only the concept's anchors (Docs/19 M7) -- implements this.
    func draft(inputs: TeachingPromptInputs) async throws -> String
}

extension TeachingQuestionDrafting {
    public func draft(inputs: TeachingPromptInputs) async throws -> String {
        try await draft(prompt: TeachingPromptBuilder.build(inputs), band: inputs.band)
    }
}

/// Docs/17_phase7_teaching_mode.md §6 — turns one `teaching_concepts` row into a verified,
/// persisted `teaching_questions` row (+ its rubric criteria). Band selection is structural
/// (Docs/17 §6.2): the caller picks a local drafter for band 1–2 and a Claude drafter for band 3;
/// the Depth Model is **not** re-run here, so this is a standalone type rather than a method on
/// `AgentSession` (a deliberate, recorded deviation from §14's sketch — bolting a
/// non-routing-mediated entry point onto `AgentSession` would just muddy that type).
public struct TeachingQuestionGenerator {

    public enum Result: Sendable, Equatable {
        case generated(questionId: String, band: Int, droppedCriteria: Int, attempts: Int)
        case rejected(reasons: [String], attempts: Int)
        case draftUnusable(detail: String, attempts: Int)
    }

    /// How many neighbouring concepts to name in a band >= 2 prompt.
    static let relatedConceptLimit = 6
    static let maxAttempts = 2

    let store: Store
    let run: AnalysisRunRecord
    let drafter: any TeachingQuestionDrafting
    let now: @Sendable () -> String

    public init(
        store: Store, run: AnalysisRunRecord, drafter: any TeachingQuestionDrafting,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.store = store
        self.run = run
        self.drafter = drafter
        self.now = now
    }

    public func generate(concept: TeachingConceptRecord, band: Int? = nil) async throws -> Result {
        let targetBand = min(3, max(1, band ?? concept.difficultyBand))

        // --- Gather grounding: one line per member anchor, resolved to its signature/docstring.
        var evidenceLines: [String] = []
        var anchors: [String] = []
        var codeExcerpts: [String: String] = [:]
        for anchor in concept.evidenceAnchors.sorted() {
            guard let sym = try store.symbol(runId: run.id, anchor: anchor) else { continue }
            let detail = sym.signature
                ?? sym.docstring?.split(separator: "\n").first.map(String.init)
                ?? sym.kind
            evidenceLines.append("\(anchor) — \(detail)")
            anchors.append(anchor)
            if let slice = try store.evidenceSlice(anchor: anchor, startLine: sym.startLine, endLine: sym.endLine) {
                codeExcerpts[anchor] = Self.excerpt(slice)
            }
        }
        if evidenceLines.isEmpty {
            return .draftUnusable(detail: "concept has no resolvable evidence anchors", attempts: 0)
        }

        var relatedLabels: [String] = []
        if targetBand >= 2 {
            relatedLabels = try store.teachingConcepts(repositoryId: run.repositoryId)
                .filter { $0.id != concept.id }
                .prefix(Self.relatedConceptLimit)
                .map(\.subjectLabel)
        }

        var priorReasons: [String] = []
        var lastDetail = ""
        for attempt in 1...Self.maxAttempts {
            let raw = try await drafter.draft(inputs: TeachingPromptInputs(
                conceptId: concept.id, conceptKind: concept.kind, conceptLabel: concept.subjectLabel,
                band: targetBand, evidenceLines: evidenceLines, relatedConceptLabels: relatedLabels,
                priorRejectionReasons: priorReasons, evidenceAnchors: anchors, codeExcerpts: codeExcerpts))

            guard let jsonText = Self.extractJSONObject(raw) else {
                lastDetail = "model output contained no JSON object"
                priorReasons = ["Your output was not a single JSON object. Return ONLY the object."]
                continue
            }
            let candidate: TeachingQuestionCandidate
            do {
                candidate = try JSONDecoder().decode(
                    TeachingQuestionCandidate.self, from: Data(jsonText.utf8))
            } catch {
                lastDetail = "JSON did not match the schema shape: \(error)"
                priorReasons = ["Your JSON did not match the required shape. Follow the schema exactly."]
                continue
            }

            let outcome = try TeachingQuestionVerifier.verifyAndPersist(
                candidate: candidate, concept: concept, store: store, run: run,
                generatedBy: drafter.source, now: now())

            switch outcome {
            case .persisted(let questionId, let dropped):
                return .generated(
                    questionId: questionId, band: candidate.difficultyBand,
                    droppedCriteria: dropped, attempts: attempt)
            case .rejected(let reasons):
                priorReasons = reasons.map(\.message)
                lastDetail = reasons.map(\.message).joined(separator: "; ")
                if attempt == Self.maxAttempts {
                    return .rejected(reasons: reasons.map(\.message), attempts: attempt)
                }
            }
        }
        return .draftUnusable(detail: lastDetail, attempts: Self.maxAttempts)
    }

    /// Lines of a symbol's code given to a drafter -- its head, which is where a question's facts
    /// usually are (signature, docstring, the first branches).
    static let excerptLines = 14

    /// The cited lines of a slice (its highlighted range, without the surrounding context), capped.
    static func excerpt(_ slice: EvidenceSlice.Slice) -> String {
        let lines: ArraySlice<String>
        if let highlight = slice.highlight {
            let start = max(0, highlight.lowerBound - slice.firstLine)
            let end = min(slice.lines.count, highlight.upperBound - slice.firstLine + 1)
            lines = start < end ? slice.lines[start..<end] : slice.lines[...]
        } else {
            lines = slice.lines[...]
        }
        return lines.prefix(excerptLines).joined(separator: "\n")
    }

    /// Tolerant extraction: first `{` to last `}`, matching the "don't trust the model to format
    /// perfectly" posture of Phase 2's `extract_json` and Phase 3's `ActionLoop.extractJSONObject`.
    static func extractJSONObject(_ raw: String) -> String? {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"),
              open < close else { return nil }
        return String(raw[open...close])
    }
}
