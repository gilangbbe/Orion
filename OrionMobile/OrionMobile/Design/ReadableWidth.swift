import SwiftUI

extension View {
    /// Keeps reading content to a comfortable line length on a wide iPad column, centered
    /// (the HIG's readable-width layout guide); a no-op on iPhone, which is narrower.
    func readableWidth() -> some View {
        frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
}
