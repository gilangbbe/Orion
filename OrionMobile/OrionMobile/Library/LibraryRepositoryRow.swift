import OrionCore
import SwiftUI

/// A repository on this device. Tapping opens it in Explore; removing is a swipe *or* a context
/// menu -- the HIG's "give people more than one way to interact".
struct LibraryRepositoryRow: View {
    let entry: LocalLibrary.Entry
    let isOpen: Bool
    let noLongerSynced: Bool
    let open: () -> Void
    let remove: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Side by side, or the tile above the text at accessibility sizes -- the HIG's "horizontal
    /// views may stack" (at AX5 the text beside the tile broke mid-word).
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignTokens.Spacing.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DesignTokens.Spacing.md))
    }

    var body: some View {
        let manifest = entry.manifest
        Button(action: open) {
            layout {
                RepositoryTile()
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(manifest.repositoryName)
                        .font(.headline)
                    Text("\(LibraryView.commitLabel(manifest.commitHash).capitalizedFirst) · analyzed \(LibraryView.dateLabel(manifest.analyzedAt))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(LibraryView.contentsLabel(manifest.counts))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if noLongerSynced {
                        StatusLabel("No longer synced from your Mac", systemImage: "icloud.slash", tint: .orange, textStyle: .secondary)
                            .font(.subheadline)
                    }
                }
                Spacer(minLength: 0)
                if isOpen {
                    Image(systemName: "checkmark")
                        .font(.body.bold())
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Open")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .swipeActions {
            Button("Remove", systemImage: "trash", role: .destructive, action: remove)
        }
        .contextMenu {
            Button("Open in Explore", systemImage: "map", action: open)
            Button("Remove from This iPhone…", systemImage: "trash", role: .destructive, action: remove)
        }
    }
}
