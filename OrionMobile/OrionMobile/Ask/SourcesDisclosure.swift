import SwiftUI

/// "3 sources": the code an answer's claims cite, each opening the evidence sheet.
struct SourcesDisclosure: View {
    let evidence: [EvidenceDetail]
    let onSelect: (EvidenceDetail) -> Void
    @State private var expanded = false

    var body: some View {
        if !evidence.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(evidence) { item in
                        Button(item.anchor) { onSelect(item) }
                            .font(.footnote.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(minHeight: 44)
                    }
                }
                .padding(.top, DesignTokens.Spacing.xs)
            } label: {
                Text("^[\(evidence.count) source](inflect: true)")
                    .font(.subheadline)
            }
        }
    }
}
