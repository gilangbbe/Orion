import AppKit
import OrionAgent
import SwiftUI

/// Docs/18 M6: Core AI bundles are exported ahead of time, not downloaded on first use the way
/// the MLX weights were, so a fresh machine has no local model until someone runs the export
/// script. This names exactly which bundles the page's roles need and the command for each,
/// instead of letting the first question fail with a path error.
struct LocalModelSetupNotice: View {
    /// Variants missing on disk (`CoreAIModelLocator.missingVariants`).
    let missing: [String]
    /// Re-checks the disk after an export finishes.
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Label("Local model not installed", systemImage: "shippingbox")
                .font(.callout.bold())
            Text(
                "Local answers and grading run on Core AI model bundles exported ahead of time. "
                    + "From the repository root, run:"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(missing, id: \.self) { variant in
                let command = CoreAIModelLocator.exportCommand(variant: variant)
                HStack(spacing: 6) {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            HStack {
                Text("Each export takes about 5–25 minutes and needs ~15 GB of free memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Check again", action: recheck)
                    .controlSize(.small)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.10),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }
}
