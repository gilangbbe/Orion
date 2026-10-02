import SwiftUI

/// The one shared way any claim/relationship/component's epistemic status is shown
/// (Docs/13_phase4_architecture_ui.md M6) — Docs/04's hard rule ("the UI must not present
/// inference as fact") only actually holds if every screen renders `EpistemicTag` the same way.
/// Retrofitted into Architecture Overview (M4) and Component Exploration (M5), which each had
/// their own ad-hoc capsule Text badge before this milestone.
struct EpistemicBadge: View {
    let tag: EpistemicTag

    init(_ tag: EpistemicTag) {
        self.tag = tag
    }

    init(rawValue: String) {
        self.tag = .from(rawValue)
    }

    var body: some View {
        Label {
            // One line: at large text sizes a wrapped badge became a circle of syllables. The
            // fixed size belongs on the title, not the whole `Label` -- there it stopped the
            // title from drawing at all, leaving the icon alone in an empty capsule (Docs/19 M8).
            Text(tag.label)
                .lineLimit(1)
                .fixedSize()
        } icon: {
            Image(systemName: tag.systemImage)
        }
        .labelStyle(.badge)
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tag.color)
        .background(tag.color.opacity(0.15))
        .clipShape(Capsule())
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(EpistemicTag.allCases, id: \.self) { EpistemicBadge($0) }
    }
    .padding()
}
