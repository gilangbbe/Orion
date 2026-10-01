import OrionCore
import SwiftUI

/// One conversation: its questions and answers, starter questions when it's empty, and the
/// composer in a Liquid Glass bar at the bottom -- the HIG's "use Liquid Glass for controls …
/// floating above content".
struct ConversationScreen: View {
    let model: AskModel
    let startNew: () -> Void

    @State private var draft = ""
    @State private var selectedEvidence: EvidenceDetail?
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xxl) {
                    if model.turns.isEmpty && model.pendingQuestion == nil {
                        AskIntro(
                            title: model.pendingComponent.map { "Ask about \($0.name)" }
                                ?? "Ask about \(model.entry.manifest.repositoryName)",
                            suggestions: model.pendingComponent.map { AskSuggestions.make(component: $0.name) }
                                ?? model.suggestions,
                            ask: send)
                    }
                    ForEach(model.turns) { turn in
                        AskTurnView(turn: turn) { selectedEvidence = $0 }
                            .id(turn.id)
                    }
                    if let question = model.pendingQuestion {
                        PendingTurnView(question: question, streamingAnswer: model.streamingAnswer)
                            .id("pending")
                    }
                }
                .padding()
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.streamingAnswer) { proxy.scrollTo("pending", anchor: .bottom) }
            .onChange(of: model.turns.count) {
                if let last = model.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .safeAreaBar(edge: .bottom) {
            AskComposer(
                draft: $draft, prompt: "Ask about \(model.pendingComponent?.name ?? model.entry.manifest.repositoryName)",
                isAsking: model.isAsking, focused: $composerFocused, send: sendDraft)
            .readableWidth()
        }
        .navigationTitle(model.selectedSession?.title ?? "New Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Conversation", systemImage: "square.and.pencil", action: startNew)
                    .disabled(model.isAsking)
            }
        }
        .sheet(item: $selectedEvidence) { evidence in
            EvidenceSheet(evidence: evidence, source: SnapshotEvidenceSource(outputDirectory: model.outputDirectory))
        }
        .onChange(of: model.pendingComponent?.id) { _, newValue in
            if newValue != nil { composerFocused = true }
        }
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        send(text)
    }

    private func send(_ text: String) {
        composerFocused = false
        Task { await model.ask(text) }
    }
}
