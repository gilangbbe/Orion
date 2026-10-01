import SwiftUI

/// Why no question could be offered, with the verifier's reasons under Details.
struct ProblemBanner: View {
    let problem: LearnModel.Problem

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            StatusLabel(problem.message, systemImage: "exclamationmark.triangle", tint: .orange)
            if !problem.details.isEmpty {
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        ForEach(problem.details, id: \.self) { detail in
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: DesignTokens.Radius.panel))
    }
}
