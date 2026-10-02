import SwiftUI

/// One session's turns, oldest first, kept scrolled to the newest.
struct AskTranscript: View {
    let title: String
    let turns: [AskTurnRow]
    let isSubmitting: Bool
    let repoRoot: URL
    let shellState: AppShellState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                    Text(title)
                        .font(.title2.bold())
                    if turns.isEmpty {
                        Text("No questions in this session yet. Ask one below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(turns) { turn in
                        AskTurnView(turn: turn, repoRoot: repoRoot, shellState: shellState)
                            .id(turn.id)
                        if turn.id != turns.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(DesignTokens.Spacing.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Animated only for a question just asked. Opening a session also changes the last
            // turn, in the layout pass that inserts this pane, and on macOS 27 an animated scroll
            // there loops AppKit's constraint updates until it crashes (Docs/14, macOS 27 addendum).
            .onChange(of: turns.last?.id) { _, id in
                guard let id else { return }
                if isSubmitting {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                } else {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }
}
