import SwiftUI

/// A line limit that loosens at accessibility text sizes -- the HIG's "keep text truncation to a
/// minimum as font size increases": at AX5, three lines of a concept label held only a few words.
struct ScaledLineLimit: ViewModifier {
    let lines: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.lineLimit(dynamicTypeSize.isAccessibilitySize ? lines * 3 : lines)
    }
}

extension View {
    func scaledLineLimit(_ lines: Int) -> some View {
        modifier(ScaledLineLimit(lines: lines))
    }
}
