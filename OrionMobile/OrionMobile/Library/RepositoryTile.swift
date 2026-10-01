import SwiftUI

/// A repository's symbol on a tinted tile, sized with Dynamic Type.
struct RepositoryTile: View {
    @ScaledMetric(relativeTo: .headline) private var size = 36

    var body: some View {
        Image(systemName: "shippingbox.fill")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(DesignTokens.accentStrong.gradient, in: .rect(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}
