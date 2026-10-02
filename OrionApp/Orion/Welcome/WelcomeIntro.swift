import SwiftUI

/// Orion's name, its thesis, and the two ways to open a repository.
struct WelcomeIntro: View {
    let openFolder: () -> Void
    let clone: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            VStack(spacing: DesignTokens.Spacing.sm) {
                Text("Orion")
                    .font(.largeTitle.bold())
                Text("See what your code actually does, with evidence and confidence attached to every claim.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 380)
            VStack(spacing: DesignTokens.Spacing.sm) {
                Button(action: openFolder) {
                    Label("Open Folder…", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: clone) {
                    Label("Clone from GitHub…", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .frame(width: 240)
            .padding(.top, DesignTokens.Spacing.sm)
        }
        .padding(DesignTokens.Spacing.xxxl)
    }
}
