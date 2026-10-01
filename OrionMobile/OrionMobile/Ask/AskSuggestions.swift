/// Starter questions for an empty conversation (Docs/19 M8), drawn from the repository's own
/// architecture -- the HIG's "provide clear next steps on any blank screens". Each is something
/// Ask answers well on the phone: one component's role, or how two related ones work together.
enum AskSuggestions {
    static let limit = 3

    /// For a whole-repository conversation: the largest components, then the most connected pair.
    static func make(model: ArchitectureModel?) -> [String] {
        guard let model, !model.nodes.isEmpty, case .semantic = model.layer else {
            return ["What are the main parts of this codebase?", "Where does a program using it start?"]
        }
        let largest = model.nodes.sorted { ($0.size, $1.name) > ($1.size, $0.name) }
        var out = ["What are the main parts of this codebase?"]
        if let first = largest.first { out.append("What does \(first.name) do?") }
        let names = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.id, $0.name) })
        if let edge = model.edges.first(where: { names[$0.sourceId] != nil && names[$0.targetId] != nil }),
           let source = names[edge.sourceId], let target = names[edge.targetId]
        {
            out.append("How does \(source) use \(target)?")
        } else if largest.count > 1 {
            out.append("What does \(largest[1].name) do?")
        }
        return Array(out.prefix(limit))
    }

    /// For a conversation scoped to one component ("Ask About This").
    static func make(component name: String) -> [String] {
        ["What does \(name) do?", "Which classes make up \(name)?", "What depends on \(name)?"]
    }
}
