import SwiftUI

/// The selected session's conversation, or what will start one, and the composer under it.
struct AskConversationPane: View {
    let repoRoot: URL
    let outputDirectory: URL
    let history: AskHistory
    let diagnosticsSession: DiagnosticsSession
    let shellState: AppShellState
    let missingModels: [String]
    let recheckModels: () -> Void

    @State private var question = ""
    @State private var isSubmitting = false
    /// Why the last question couldn't be asked at all, shown above the composer.
    @State private var submitError: String?

    var body: some View {
        VStack(spacing: 0) {
            AskConversationContent(
                history: history, isSubmitting: isSubmitting, repoRoot: repoRoot, shellState: shellState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                if !missingModels.isEmpty {
                    LocalModelSetupNotice(missing: missingModels, recheck: recheckModels)
                }
                if let submitError {
                    NoticeBar(message: submitError, systemImage: "exclamationmark.triangle", tint: .orange, dismiss: clearError)
                } else if let scope = history.pendingScope {
                    NoticeBar(message: "New session about \(scope)", systemImage: "bubble.left.and.text.bubble.right", tint: DesignTokens.accent, dismiss: history.clearPendingScope, dismissLabel: "Ask a general question instead")
                }
                AskComposer(text: $question, placeholder: placeholder, isSubmitting: isSubmitting, submit: submit)
            }
            .padding(DesignTokens.Spacing.md)
        }
    }

    private var placeholder: String {
        if let session = history.sessions.first(where: { $0.id == history.selectedSessionID }) {
            "Ask a follow-up in “\(session.title)”"
        } else {
            "Ask a question about \(repoRoot.lastPathComponent)"
        }
    }

    private func clearError() {
        submitError = nil
    }

    private func submit() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSubmitting else { return }
        submitError = nil
        question = ""
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            if let outcome = await history.submit(text, repoRoot: repoRoot, outputDirectory: outputDirectory) {
                diagnosticsSession.recordAsk(question: text, outcome: outcome)
            } else {
                let reason = history.loadError ?? "Couldn't start a session."
                submitError = "Couldn't ask that question: \(reason)"
                question = text
                diagnosticsSession.recordAsk(question: text, outcome: .failed(reason))
            }
        }
    }
}
