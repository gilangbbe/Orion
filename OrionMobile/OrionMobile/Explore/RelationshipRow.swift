import SwiftUI

/// "Depends on Routing & Endpoint Dispatch" -- opening that component when it's on the map.
struct RelationshipRow: View {
    let dependency: ComponentDependencyDetail
    let targetId: String?

    var body: some View {
        if let targetId {
            NavigationLink(value: ExploreRoute.component(id: targetId)) { label }
        } else {
            label
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(Self.verb(dependency.type))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(dependency.targetName)
            ConfidenceNote(tier: dependency.confidenceTier)
        }
        .accessibilityElement(children: .combine)
    }

    /// `depends_on` → "Depends on".
    static func verb(_ type: String) -> String {
        type.replacing("_", with: " ").capitalizedFirst
    }
}
