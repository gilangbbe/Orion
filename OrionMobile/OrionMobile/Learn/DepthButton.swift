import SwiftUI

/// One depth: its name and what kind of question it asks.
struct DepthButton: View {
    let band: Int
    let hint: String
    let isBusy: Bool
    let choose: (Int) -> Void

    var body: some View {
        Button {
            choose(band)
        } label: {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: "\(band).circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(TeachingVocabulary.bandWord(band))
                        .font(.headline)
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(DesignTokens.Spacing.md)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.fill.quaternary, in: .rect(cornerRadius: DesignTokens.Radius.panel))
        .disabled(isBusy)
        .accessibilityIdentifier("learn.depth.\(band)")
    }
}
