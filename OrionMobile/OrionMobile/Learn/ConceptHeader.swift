import SwiftUI

/// The concept being practised: its mastery and open misconceptions, and its label kept to a few
/// lines -- a claim concept's label is a whole paragraph, and it used to push the question off the
/// first screen. "More" shows the rest.
struct ConceptHeader: View {
    let concept: TeachingConceptRow
    @State private var expanded = false

    private static let collapsedLines = 3

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(concept.label)
                .font(.headline)
                .scaledLineLimit(expanded ? 1_000 : Self.collapsedLines)
                .textSelection(.enabled)
            if concept.label.count > 140 {
                Button {
                    expanded.toggle()
                } label: {
                    // The frame inside the label: outside a borderless button it doesn't grow
                    // what's tappable (the audit's "hit area is too small").
                    Text(expanded ? "Less" : "More")
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
            // Padded inside its own accessibility element: the bare meter was a tiny element the
            // audit flagged ("hit area is too small", Docs/19 M8).
            HStack {
                MasteryMeter(pMastered: concept.pMastered, band: concept.confidenceBand)
            }
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)
            ForEach(concept.openMisconceptions, id: \.self) { statement in
                Label("Earlier you suggested: \(statement)", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(DesignTokens.contradicted)
            }
        }
    }
}
