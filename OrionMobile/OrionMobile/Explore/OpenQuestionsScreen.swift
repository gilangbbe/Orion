import SwiftUI

/// What the analysis couldn't settle from the code, in full.
struct OpenQuestionsScreen: View {
    let uncertainties: [String]

    var body: some View {
        List {
            Section {
                ForEach(uncertainties, id: \.self) { statement in
                    Label {
                        Text(statement)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(DesignTokens.unknown)
                    }
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
            } footer: {
                Text("Questions the Mac's analysis raised but couldn't answer from the code. Ask about them, or look at the code yourself.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Open Questions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
