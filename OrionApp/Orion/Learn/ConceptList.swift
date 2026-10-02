import SwiftUI

/// Every concept in planner order, with mastery, and how it's going overall.
struct ConceptList: View {
    let session: TeachingSession
    let search: String
    let outputDirectory: URL

    @State private var selection: String?

    var body: some View {
        let concepts = Self.filter(session.concepts, by: search)
        List(selection: $selection) {
            if !session.overview.isEmpty {
                Section {
                    ForEach(concepts) { row in
                        ConceptRow(row: row)
                            .tag(row.id)
                    }
                } header: {
                    Text(Self.overviewText(session.overview))
                }
            }
        }
        .overlay {
            if session.concepts.isEmpty {
                ContentUnavailableView {
                    Label(session.loadError == nil ? "No Concepts Yet" : "Couldn't Load Concepts", systemImage: "graduationcap")
                } description: {
                    Text(session.loadError ?? "Build an Architecture Model first. Learn turns its components and claims into concepts to practise.")
                }
            } else if concepts.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .onChange(of: selection) { _, id in select(id) }
        .onChange(of: session.selectedConceptId) { _, id in selection = id }
        .onAppear { selection = session.selectedConceptId }
    }

    private func select(_ id: String?) {
        guard let id, id != session.selectedConceptId else { return }
        session.select(conceptId: id, outputDirectory: outputDirectory)
    }

    static func filter(_ concepts: [TeachingConceptRow], by search: String) -> [TeachingConceptRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return concepts }
        return concepts.filter { $0.label.localizedStandardContains(query) }
    }

    /// "60 concepts · 3 solid · 2 shaky · 1 misconception" (Docs/17 §11's sidebar strip, moved here).
    static func overviewText(_ overview: TeachingOverview) -> String {
        var parts = ["\(overview.total) concepts"]
        if overview.solid > 0 { parts.append("\(overview.solid) solid") }
        if overview.shaky > 0 { parts.append("\(overview.shaky) shaky") }
        if overview.misconceptionConcepts > 0 {
            parts.append(overview.misconceptionConcepts == 1 ? "1 misconception" : "\(overview.misconceptionConcepts) misconceptions")
        }
        return parts.joined(separator: " · ")
    }
}
