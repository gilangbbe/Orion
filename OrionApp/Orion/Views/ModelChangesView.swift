import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §4.7/§8 M6: Docs/05 Stage 6, given a real home -- this
/// screen didn't exist anywhere in the shipped Phase 4 app. Each entry collapses to one line
/// (title + relative time) and expands to Previously/Now/Reason. Backed by `ModelChangeSample`
/// (Docs/14 §7 Decision 3) rather than `CodebaseModelStore` -- deliberately: the backend for real
/// model-revision history doesn't exist yet, so this validates the screen's shape, not real data.
struct ModelChangesView: View {
    let entries: [ModelChangeSummary]
    @State private var expandedIDs: Set<String>

    init(entries: [ModelChangeSummary] = ModelChangeSample.entries) {
        self.entries = entries
        // The first entry starts expanded, matching the prototype -- so the screen never opens
        // to a wall of collapsed rows with nothing to look at.
        _expandedIDs = State(initialValue: Set(entries.first.map { [$0.id] } ?? []))
    }

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                "No model changes yet", systemImage: "clock.arrow.circlepath",
                description: Text("Understanding updates will show up here as they happen."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(entries) { entry in
                        changeCard(entry)
                    }
                }
                .padding(16)
            }
        }
    }

    private func changeCard(_ entry: ModelChangeSummary) -> some View {
        DisclosureGroup(isExpanded: expandedBinding(for: entry.id)) {
            VStack(alignment: .leading, spacing: 10) {
                changeRow(label: "Previously", value: entry.before, color: .secondary)
                changeRow(label: "Now", value: entry.after, color: DesignTokens.fact)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reason")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(entry.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(DesignTokens.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Understanding updated — \(entry.title)")
                        .font(.callout.weight(.semibold))
                    Text(entry.when)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }

    private func changeRow(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(color)
        }
    }

    private func expandedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedIDs.insert(id)
                } else {
                    expandedIDs.remove(id)
                }
            })
    }
}

#Preview {
    ModelChangesView()
        .frame(width: 480, height: 400)
}
