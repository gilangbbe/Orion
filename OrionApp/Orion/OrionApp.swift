import AppKit
import SwiftUI

/// Docs/13_phase4_architecture_ui.md: the app shell.
@main
struct OrionApp: App {
    @State private var session = RepositorySession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Orion") { showAboutPanel() }
            }
        }
    }

    /// Docs/13 M8: a real About panel rather than the OS default's blank credits -- explains
    /// what the app actually is (Docs/01's own product thesis), not just its version number.
    private func showAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(
            options: [
                .credits: NSAttributedString(
                    string:
                        "A local-first developer utility that reconstructs, explains, and "
                        + "teaches a repository's architecture -- deterministic code analysis, "
                        + "an optional Claude Code semantic investigation, and a local model for "
                        + "everyday questions.\n\n"
                        + "Every claim on screen is tagged FACT, INTERPRETATION, INFERENCE, "
                        + "UNKNOWN, or CONTRADICTED -- the app is not meant to be trusted more "
                        + "than its own evidence.",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                ),
                .applicationName: "Orion",
            ])
    }
}
