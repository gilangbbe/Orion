import SwiftUI

/// A component's members grouped by kind, classes first, each a link to its code. Groups past a
/// handful start collapsed, so a long component doesn't push Dependencies and Claims out of
/// reach (HIG, Layout: "Use progressive disclosure").
struct ComponentMembersList: View {
    let members: [ComponentMemberDetail]
    let showEvidence: (EvidenceDetail) -> Void

    var body: some View {
        let groups = Self.groups(members)
        ForEach(groups, id: \.title) { group in
            MemberGroupDisclosure(
                title: group.title, members: group.members,
                startsExpanded: group.members.count <= Self.expandedLimit, showEvidence: showEvidence)
        }
    }

    static let expandedLimit = 8

    /// Kinds in a reading order -- the types first, then what they do, then the rest.
    static func groups(_ members: [ComponentMemberDetail]) -> [(title: String, members: [ComponentMemberDetail])] {
        let order = ["class", "function", "method", "module", "variable", "reexport"]
        let grouped = Dictionary(grouping: members, by: \.kind)
        let kinds = grouped.keys.sorted { lhs, rhs in
            let l = order.firstIndex(of: lhs) ?? order.count
            let r = order.firstIndex(of: rhs) ?? order.count
            return l == r ? lhs < rhs : l < r
        }
        return kinds.map { kind in
            let sorted = (grouped[kind] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return (title: pluralTitle(kind), members: sorted)
        }
    }

    static func pluralTitle(_ kind: String) -> String {
        switch kind {
        case "class": "Classes"
        case "reexport": "Re-exports"
        default: kind.capitalized + "s"
        }
    }
}
