import SwiftUI

/// Purpose, Members, Dependencies, and Claims & Evidence, each only when there's something in it.
struct ComponentSections: View {
    let detail: ComponentDetail
    let showEvidence: (EvidenceDetail) -> Void
    let showRevision: (String) -> Void

    var body: some View {
        if let subtitle = detail.subtitle {
            InspectorSection("Purpose") {
                MarkdownText(raw: subtitle)
            }
        }
        if !detail.members.isEmpty {
            InspectorSection("Members (\(detail.members.count))") {
                ComponentMembersList(members: detail.members, showEvidence: showEvidence)
            }
        }
        if !detail.dependencies.isEmpty {
            InspectorSection("Dependencies") {
                ForEach(detail.dependencies) { dependency in
                    ComponentDependencyRow(dependency: dependency)
                }
            }
        }
        if !detail.claims.isEmpty {
            InspectorSection("Claims & Evidence") {
                ForEach(detail.claims) { claim in
                    ComponentClaimRow(claim: claim, showEvidence: showEvidence, showRevision: showRevision)
                    if claim.id != detail.claims.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}
