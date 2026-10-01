/// "Ask about" a component, handed from Explore to Ask (Docs/19 M6).
struct AskRequest: Equatable {
    let componentId: String?
    let componentName: String
}
