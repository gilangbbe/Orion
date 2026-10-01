import OrionCore
import SwiftUI

/// The concept to practise next, then every concept grouped by kind -- each group in the planner's
/// order, most useful first.
struct LearnConceptList: View {
    let model: LearnModel
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if let next = model.concepts.first {
                Section {
                    UpNextCard(concept: next) { selection = next.id }
                } header: {
                    Text("Up Next")
                } footer: {
                    if !LearnModel.isCalibrated {
                        SelfCheckNote()
                    }
                }
            }
            ForEach(Self.sections(model.concepts), id: \.kind) { section in
                Section(Self.sectionTitle(section.kind)) {
                    ForEach(section.rows) { row in
                        NavigationLink(value: row.id) {
                            LearnConceptRow(row: row)
                        }
                        .accessibilityIdentifier("learn.concept")
                    }
                }
            }
        }
        .refreshable { model.refresh() }
    }

    struct KindSection {
        let kind: String
        let rows: [TeachingConceptRow]
    }

    /// Concepts grouped by kind; groups ordered by their best-ranked concept, rows by rank.
    static func sections(_ rows: [TeachingConceptRow]) -> [KindSection] {
        var order: [String] = []
        var byKind: [String: [TeachingConceptRow]] = [:]
        for row in rows {
            if byKind[row.kind] == nil { order.append(row.kind) }
            byKind[row.kind, default: []].append(row)
        }
        return order.map { KindSection(kind: $0, rows: byKind[$0] ?? []) }
    }

    static func sectionTitle(_ kind: String) -> String {
        switch kind {
        case TeachingConceptKind.component.rawValue: "Components"
        case TeachingConceptKind.claim.rawValue: "Claims"
        case TeachingConceptKind.relationship.rawValue: "Relationships"
        case TeachingConceptKind.role.rawValue: "Roles"
        case TeachingConceptKind.dataflow.rawValue: "Data Flows"
        default: kind.capitalized
        }
    }
}
