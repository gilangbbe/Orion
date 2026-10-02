/// Architecture's Diagram/List switch (Docs/14 §8 M8.5 item 3). Shell-level state, so it survives
/// leaving and coming back; Docs/20 R1 adds View > as Diagram / as List.
enum ArchitectureViewMode: String, CaseIterable, Identifiable {
    case diagram = "Diagram"
    case list = "Table"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .list: "tablecells"
        }
    }
}
