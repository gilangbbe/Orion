import SwiftUI

/// The selected change in full, or a prompt to pick one.
struct ModelChangeDetailPane: View {
    let entry: ModelChangeSummary?

    var body: some View {
        if let entry {
            ModelChangeDetailView(entry: entry)
        } else {
            ContentUnavailableView(
                "No Change Selected", systemImage: "clock.arrow.circlepath",
                description: Text("Select a change to see what Orion believed before, what it believes now, and why."))
        }
    }
}
