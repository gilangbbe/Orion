import SwiftUI

/// How an Ask answer is labelled, on the Mac and the iPhone alike (moved from `AskView`, Docs/19
/// M6). Checked in this order:
///
/// 1. A guardrail decline (Docs/15 §7): a correct, complete result, never the orange "partial"
///    warning nor the green seal.
/// 2. An ungrounded depth-1 answer (Docs/12 Risk #5): `verified` only because it asserted nothing,
///    so "Not independently checked", never the green seal a grounded answer gets.
/// 3. Partial: the real outcome named (Docs/13 M8).
/// 4. Verified (or another clean outcome), with the seal.
///
/// The colour is on the symbol, not the words (`StatusLabel`, Docs/19 M8): orange and green text
/// failed the contrast audit.
struct AskOutcomeLabel: View {
    let summary: AskResultSummary

    var body: some View {
        if summary.isDeclined {
            Label("Outside this repository's scope", systemImage: "arrow.turn.up.left")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        } else if summary.isUngroundedVerified {
            StatusLabel("Not independently checked", systemImage: "questionmark.circle", tint: .orange, textStyle: .secondary)
                .font(.caption.bold())
        } else if summary.partial {
            // Docs/13 M8: name the real outcome (rejected/incomplete/unverified/
            // partially_verified) rather than a single generic "Partial" -- Docs/06 §7's
            // failure-transparency rule applies to *which* failure, not just that one happened.
            StatusLabel(
                "Partial — \(summary.outcome.replacingOccurrences(of: "_", with: " "))",
                systemImage: "exclamationmark.circle", tint: .orange, textStyle: .secondary
            )
            .font(.caption.bold())
        } else {
            StatusLabel(
                summary.outcome.replacingOccurrences(of: "_", with: " ").capitalized,
                systemImage: "checkmark.seal.fill", tint: .green, textStyle: .secondary
            )
            .font(.caption.bold())
        }
    }
}
