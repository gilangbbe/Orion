import SwiftUI

/// "Depends on API Schemas", and how sure the investigation is.
struct ComponentDependencyRow: View {
    let dependency: ComponentDependencyDetail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text("\(Text(Self.verb(dependency.type)).foregroundStyle(.secondary)) \(dependency.targetName)")
            Spacer(minLength: DesignTokens.Spacing.sm)
            ConfidenceBadge(tier: dependency.confidenceTier)
        }
    }

    /// `depends_on` → "Depends on".
    static func verb(_ type: String) -> String {
        let words = type.replacing("_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
