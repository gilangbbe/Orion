import SwiftUI

/// What you've got wrong about this concept before, so the next answer can address it.
struct MisconceptionPanel: View {
    let statements: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Label("You've shown a misconception here", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(DesignTokens.contradicted)
            ForEach(statements, id: \.self) { statement in
                Text(statement)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.contradicted.opacity(0.10), in: .rect(cornerRadius: DesignTokens.Radius.control))
    }
}
