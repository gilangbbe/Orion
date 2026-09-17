import Foundation
import OrionCodeIntel

/// Everything the question-generation prompt needs about one concept, gathered from the `Store`
/// by `TeachingQuestionGenerator` and handed here as plain values so the prompt assembly itself
/// stays pure and unit-testable (no `Store`, no model). Docs/17 §6.
public struct TeachingPromptInputs: Sendable, Equatable {
    public let conceptId: String
    public let conceptKind: String        // TeachingConceptKind raw value
    public let conceptLabel: String
    public let band: Int                  // 1 recall / 2 comprehension / 3 transfer
    /// One line per member anchor: `"<anchor> — <signature or docstring first line>"`.
    public let evidenceLines: [String]
    /// Labels of a few neighbouring concepts, for band >= 2 contrast/interaction questions.
    public let relatedConceptLabels: [String]
    /// On a retry, the reasons the previous attempt was rejected — fed back so the model can fix
    /// them (Docs/17 §6.3: "retried once ... with the diagnostics fed back into the prompt").
    public let priorRejectionReasons: [String]

    public init(
        conceptId: String, conceptKind: String, conceptLabel: String, band: Int,
        evidenceLines: [String], relatedConceptLabels: [String] = [],
        priorRejectionReasons: [String] = []
    ) {
        self.conceptId = conceptId
        self.conceptKind = conceptKind
        self.conceptLabel = conceptLabel
        self.band = band
        self.evidenceLines = evidenceLines
        self.relatedConceptLabels = relatedConceptLabels
        self.priorRejectionReasons = priorRejectionReasons
    }
}

public enum TeachingPromptBuilder {

    static let bandGuidance: [Int: String] = [
        1: "Band 1 — RECALL. Ask the developer to state or define what this concept is / does. "
            + "One hop: the concept's own code only.",
        2: "Band 2 — COMPREHENSION. Ask the developer to explain how this concept relates to or "
            + "differs from a neighbouring one, or the direction of a dependency. Two hops.",
        3: "Band 3 — TRANSFER. Ask a change-impact / novel-scenario question (\"if X were removed "
            + "or changed, what breaks first and why\"). Three or more hops.",
    ]

    public static func build(_ i: TeachingPromptInputs) -> String {
        var out = """
        You are generating ONE teaching question for a developer learning an unfamiliar Python \
        codebase, as the question-authoring step of Orion's teaching mode \
        (Docs/05_user_flow_and_ux.md Stage 7). You are NOT teaching or answering — you produce a \
        question, a concise reference answer, an atomic grading rubric, and misconception \
        anti-criteria, all grounded in specific code.

        Concept to teach (id \(i.conceptId), kind \(i.conceptKind)):
          \(i.conceptLabel)

        \(bandGuidance[i.band] ?? bandGuidance[1]!)

        Grounding — every anchor below is a real symbol in this repository. You MUST cite anchors \
        verbatim from this list (\"<path>::<Dotted.Name>\" form); inventing, paraphrasing or \
        misspelling one gets the whole question rejected.
        """
        for line in i.evidenceLines { out += "\n  - \(line)" }

        if i.band >= 2 && !i.relatedConceptLabels.isEmpty {
            out += "\n\nNeighbouring concepts you may contrast against or reference:"
            for label in i.relatedConceptLabels { out += "\n  - \(label)" }
        }

        out += """


        Rules for the rubric:
        - Each `required` criterion is ONE single, checkable fact the answer must establish — never \
          a compound \"X and Y and Z\". 3–6 of them.
        - `bonus` criteria (0–3) are worthwhile but not essential.
        - `anti_criteria` (1–3) are statements that, if the developer's answer conveys them, reveal \
          a WRONG mental model — usually the negation or reversal of a `required` criterion.
        - Every criterion cites at least one anchor from the grounding list.
        - The `reference_answer` is <= 120 words, and every factual clause in it is backed by an \
          anchor in `reference_anchors`.

        Return EXACTLY one JSON object, nothing else, matching this shape \
        (schema_version must be exactly \"\(TeachingSchema.currentVersion)\", concept_id must be \
        \"\(i.conceptId)\", difficulty_band must be \(i.band)):
        \(TeachingSchema.promptHint)
        """

        if !i.priorRejectionReasons.isEmpty {
            out += "\n\nYour previous attempt was REJECTED for these reasons — fix all of them:"
            for r in i.priorRejectionReasons { out += "\n  - \(r)" }
        }
        return out
    }
}
