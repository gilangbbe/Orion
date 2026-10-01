/// Where Explore can go (Docs/19 M8): the list's selections and the detail column's pushes.
enum ExploreRoute: Hashable {
    case map
    case openQuestions
    case changes(focusRevisionId: String?)
    case change(ModelChangeSummary)
    case component(id: String)
}
