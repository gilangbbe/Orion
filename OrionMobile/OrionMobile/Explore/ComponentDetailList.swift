import SwiftUI

/// A component's sections. Members and evidence open the code; a relationship opens the component
/// it points to; a reversed claim opens the change that reversed it.
struct ComponentDetailList: View {
    let detail: ComponentDetail
    let model: ArchitectureModel
    let open: (ExploreRoute) -> Void
    let onSelectEvidence: (EvidenceDetail) -> Void

    var body: some View {
        List {
            Section {
                ComponentHeader(detail: detail)
            }
            ForEach(Self.memberGroups(detail.members), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.members) { member in
                        MemberRow(member: member) { onSelectEvidence(member.evidence) }
                    }
                }
            }
            if !detail.dependencies.isEmpty {
                Section("Relationships") {
                    ForEach(detail.dependencies) { dependency in
                        RelationshipRow(
                            dependency: dependency,
                            targetId: model.nodes.first { $0.name == dependency.targetName }?.id)
                    }
                }
            }
            if !detail.claims.isEmpty {
                Section {
                    ForEach(detail.claims) { claim in
                        ClaimRow(claim: claim, open: open, onSelectEvidence: onSelectEvidence)
                    }
                } header: {
                    Text("Claims")
                } footer: {
                    Text("What the analysis found about this component, with the code it cites.")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    struct MemberGroup {
        let title: String
        let members: [ComponentMemberDetail]
    }

    /// Members by kind -- classes first, then functions, methods, modules -- each group sorted by
    /// name.
    static func memberGroups(_ members: [ComponentMemberDetail]) -> [MemberGroup] {
        let order = ["class", "function", "method", "module", "package"]
        return Dictionary(grouping: members, by: \.kind)
            .sorted { (order.firstIndex(of: $0.key) ?? order.count, $0.key) < (order.firstIndex(of: $1.key) ?? order.count, $1.key) }
            .map { MemberGroup(title: pluralTitle($0.key), members: $0.value.sorted { $0.name < $1.name }) }
    }

    static func pluralTitle(_ kind: String) -> String {
        switch kind {
        case "class": "Classes"
        case "function": "Functions"
        case "method": "Methods"
        case "module": "Modules"
        case "package": "Packages"
        default: kind.capitalized
        }
    }
}
