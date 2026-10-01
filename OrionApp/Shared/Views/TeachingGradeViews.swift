import OrionCore
import SwiftUI

// A graded teaching attempt's breakdown -- verdict, per-point checklist, misconceptions -- shared
// by the Mac's Teaching Mode and the phone's Learn tab (Docs/19 M7), so both show a grade the
// same way.

/// Words for concept kinds, depth bands, verdicts and checklist marks.
enum TeachingVocabulary {
    static func kindWord(_ raw: String) -> String {
        switch raw {
        case TeachingConceptKind.component.rawValue: return "Component"
        case TeachingConceptKind.claim.rawValue: return "Claim"
        case TeachingConceptKind.relationship.rawValue: return "Relationship"
        case TeachingConceptKind.role.rawValue: return "Role"
        case TeachingConceptKind.dataflow.rawValue: return "Data flow"
        default: return raw.capitalized
        }
    }

    static func bandWord(_ band: Int) -> String {
        switch band {
        case 1: return "Recall"
        case 2: return "Comprehension"
        default: return "Transfer"
        }
    }

    struct VerdictStyle { let label: String; let icon: String; let color: Color }

    static func verdictStyle(_ raw: String) -> VerdictStyle {
        switch raw {
        case TeachingVerdictTier.solid.rawValue:
            return VerdictStyle(label: "Solid", icon: "checkmark.seal.fill", color: DesignTokens.fact)
        case TeachingVerdictTier.partial.rawValue:
            return VerdictStyle(
                label: "Partial", icon: "circle.lefthalf.filled", color: DesignTokens.confidenceMedium)
        case TeachingVerdictTier.shaky.rawValue:
            return VerdictStyle(
                label: "Shaky", icon: "exclamationmark.circle", color: DesignTokens.confidenceLow)
        default:
            return VerdictStyle(
                label: "Off track", icon: "xmark.circle", color: DesignTokens.contradicted)
        }
    }

    struct CriterionMark { let icon: String; let color: Color; let accessibility: String }

    static func criterionMark(_ row: TeachingCriterionRow) -> CriterionMark {
        if row.kind == .anti {
            return CriterionMark(
                icon: "exclamationmark.triangle.fill", color: DesignTokens.contradicted,
                accessibility: "Misconception")
        }
        if row.needsReview {
            return CriterionMark(
                icon: "minus.circle", color: .secondary, accessibility: "Needs your review")
        }
        return row.met
            ? CriterionMark(icon: "checkmark.circle.fill", color: DesignTokens.fact, accessibility: "Met")
            : CriterionMark(icon: "xmark.circle", color: .secondary, accessibility: "Not met")
    }
}

/// A small all-caps section label.
struct TeachingEyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.bold())
            .foregroundStyle(DesignTokens.accent)
            .tracking(0.5)
    }
}

/// The verdict, "n of m key points" and a gauge.
struct TeachingVerdictHeader: View {
    let grade: TeachingGradeCard

    var body: some View {
        let style = TeachingVocabulary.verdictStyle(grade.verdict)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(style.label, systemImage: style.icon)
                    .font(.headline)
                    .foregroundStyle(style.color)
                Spacer()
                Text(pointsLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Gauge(value: gaugeValue) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(style.color)
                .accessibilityLabel(pointsLine)
            if grade.needsReviewCount > 0 {
                Text(
                    "\(grade.needsReviewCount) point(s) couldn't be graded confidently and were "
                        + "left out — check them yourself below.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "0 of 0 key points" read as a score; say instead that none could be graded.
    private var pointsLine: String {
        grade.requiredTotal > 0 ? "\(grade.requiredMet) of \(grade.requiredTotal) key points" : "No key point graded"
    }

    private var gaugeValue: Double {
        grade.requiredTotal > 0 ? Double(grade.requiredMet) / Double(grade.requiredTotal) : 0
    }
}

/// One row per rubric point -- met, not met, needs review, or a misconception the answer showed
/// (an anti-point only appears when it was tripped). Each point's evidence opens `EvidenceView`.
struct TeachingCriterionChecklist: View {
    let rows: [TeachingCriterionRow]
    let onOpenEvidence: (EvidenceDetail) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ForEach(rows.filter { $0.kind != .anti || $0.met }) { row in
                criterionRow(row)
            }
        }
    }

    @ViewBuilder
    private func criterionRow(_ row: TeachingCriterionRow) -> some View {
        let mark = TeachingVocabulary.criterionMark(row)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: mark.icon)
                .foregroundStyle(mark.color)
                .accessibilityLabel(mark.accessibility)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.text)
                        .font(.callout)
                        .foregroundStyle(row.kind == .anti ? DesignTokens.contradicted : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.kind == .bonus {
                        Text("bonus")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                    }
                }
                if row.needsReview {
                    Text("Not graded confidently — decide for yourself.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if row.met, !row.evidenceQuote.isEmpty {
                    Text("you wrote: “\(row.evidenceQuote)”")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.evidence.isEmpty {
                    // Wraps on a phone's width instead of truncating every anchor to nothing.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { evidenceButtons(row) }
                        VStack(alignment: .leading, spacing: 4) { evidenceButtons(row) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func evidenceButtons(_ row: TeachingCriterionRow) -> some View {
        ForEach(row.evidence) { evidence in
            Button {
                onOpenEvidence(evidence)
            } label: {
                Text(evidence.anchor)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Misconceptions this answer showed, and ones it cleared up.
struct TeachingMisconceptionOutcome: View {
    let grade: TeachingGradeCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(grade.misconceptionsDetected, id: \.self) { s in
                Label {
                    Text("Your answer suggests: \(s)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(DesignTokens.contradicted)
            }
            ForEach(grade.misconceptionsCleared, id: \.self) { s in
                Label {
                    Text("Cleared up: \(s)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(DesignTokens.fact)
            }
        }
    }
}
