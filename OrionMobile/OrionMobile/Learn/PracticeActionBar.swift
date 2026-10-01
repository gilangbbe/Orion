import SwiftUI

/// The practice screen's next action, at the bottom: check the answer while answering; another
/// question, or one level up, once graded.
struct PracticeActionBar: View {
    let model: LearnModel
    let dismissKeyboard: () -> Void

    var body: some View {
        Group {
            switch model.phase {
            case .questioning:
                Button(action: check) {
                    Text("Check My Answer").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                .accessibilityIdentifier("learn.check")
            case .graded(let card, _):
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button(action: another) {
                        Text("Another Question").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    if card.band < 3 {
                        Button(action: harder) {
                            Text("One Level Up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
                .disabled(model.isBusy)
            default:
                EmptyView()
            }
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private func check() {
        dismissKeyboard()
        Task { await model.submit() }
    }

    private func another() {
        Task { await model.anotherQuestion() }
    }

    private func harder() {
        Task { await model.harderQuestion() }
    }
}
