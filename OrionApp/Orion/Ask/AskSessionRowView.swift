import SwiftUI

/// A session's title, how long it is, and when it was last used.
struct AskSessionRowView: View {
    let session: AskSessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title)
                .lineLimit(2)
            Text("\(session.turnCount) \(session.turnCount == 1 ? "turn" : "turns") · \(session.lastActiveAt, format: .relative(presentation: .named))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
