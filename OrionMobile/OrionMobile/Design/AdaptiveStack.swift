import SwiftUI

/// A row that becomes a column at accessibility text sizes -- the HIG's "horizontal views may
/// stack". `ViewThatFits` can't decide this: wrapped text always "fits", so at AX5 it kept a label
/// and its badge side by side, broken into syllables.
struct AdaptiveStack<Content: View>: View {
    var spacing: Double = DesignTokens.Spacing.sm
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout { content }
    }
}
