import SwiftUI

/// The window with no repository (Docs/05 Stage 1, Docs/14 §4.2), laid out like Xcode's welcome
/// window (Docs/20 R2): what Orion is and the two ways in on the left, recent repositories on the
/// right. File > Open Repository… and Clone from GitHub… do the same from the menu bar.
struct WelcomeView: View {
    let window: RepositoryWindow

    var body: some View {
        HStack(spacing: 0) {
            WelcomeIntro(openFolder: openFolder, clone: clone)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            RecentRepositoriesList(entries: window.recents.entries, open: window.reopen)
                .frame(width: 320)
        }
    }

    private func openFolder() {
        window.isPickingFolder = true
    }

    private func clone() {
        window.isCloning = true
    }
}

#Preview {
    WelcomeView(window: RepositoryWindow(recents: RecentRepositoriesModel()))
        .frame(width: 900, height: 520)
}
