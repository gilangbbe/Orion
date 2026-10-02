/// What Architecture's inspector shows (Docs/14 §4.4): a selected component, or the
/// investigation-wide Open Questions -- never both. Each case carries what the inspector needs so
/// it doesn't reload the architecture model.
enum InspectorContent: Equatable {
    case node(ArchitectureNode, ArchitectureLayer)
    case openQuestions([String])
}
