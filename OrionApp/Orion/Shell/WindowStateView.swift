import SwiftUI

/// What a window shows for each `RepositorySession.State`.
struct WindowStateView: View {
    let window: RepositoryWindow

    var body: some View {
        switch window.session.state {
        case .idle:
            WelcomeView(window: window)
                .navigationTitle("Welcome to Orion")
        case .opening(let input):
            ProgressView(Self.openingLabel(for: input))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(Self.name(of: input))
        case .analyzing:
            AnalysisProgressView(
                repoRoot: window.session.resolvedRepoRoot ?? URL(fileURLWithPath: "/"), progress: window.progress)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(window.session.resolvedRepoRoot?.lastPathComponent ?? "Analyzing")
        case .ready(let summary):
            RepositoryWindowView(window: window, shell: window.shell, summary: summary)
        case .failed(let message):
            OpenFailedView(message: message, tryAgain: window.closeRepository)
                .navigationTitle("Couldn't Open Repository")
        }
    }

    static func openingLabel(for input: RepositorySession.Input) -> String {
        switch input {
        case .localPath: "Opening…"
        case .gitHubURL: "Cloning…"
        }
    }

    static func name(of input: RepositorySession.Input) -> String {
        switch input {
        case .localPath(let url), .gitHubURL(let url): url.lastPathComponent
        }
    }
}
