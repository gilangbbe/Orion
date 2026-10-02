extension ArchitectureNode {
    /// Highest confidence first when sorted ascending; structural nodes, which have none, last.
    var confidenceRank: Int {
        switch confidenceTier {
        case "high": 0
        case "medium": 1
        case "low": 2
        case "unresolved": 3
        default: 4
        }
    }
}
