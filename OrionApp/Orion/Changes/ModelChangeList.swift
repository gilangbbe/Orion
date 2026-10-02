import SwiftUI

/// The changes, newest first, scrolled to the selected one on arrival.
struct ModelChangeList: View {
    let entries: [ModelChangeSummary]
    @Binding var selection: ModelChangeSummary.ID?

    var body: some View {
        ScrollViewReader { proxy in
            List(entries, selection: $selection) { entry in
                ModelChangeRow(entry: entry)
                    .id(entry.id)
            }
            // Never animated: this runs as the split pane is inserted under the toolbar, which on
            // macOS 27 loops AppKit's constraint updates until it crashes (Docs/14, macOS 27 addendum).
            .onAppear {
                if let selection { proxy.scrollTo(selection, anchor: .top) }
            }
        }
    }
}
