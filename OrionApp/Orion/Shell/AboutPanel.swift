import AppKit

/// Docs/13 M8: an About panel that says what the app is, not just its version.
enum AboutPanel {
    static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: """
                    A local-first developer utility that reconstructs, explains, and teaches a \
                    repository's architecture -- deterministic code analysis, an optional Claude \
                    Code semantic investigation, and a local model for everyday questions.

                    Every claim on screen is tagged FACT, INTERPRETATION, INFERENCE, UNKNOWN, or \
                    CONTRADICTED -- the app is not meant to be trusted more than its own evidence.
                    """,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]),
            .applicationName: "Orion",
        ])
    }
}
