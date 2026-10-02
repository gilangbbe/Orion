import SwiftUI

/// One kind of member ("Functions (17)"), collapsible.
struct MemberGroupDisclosure: View {
    let title: String
    let members: [ComponentMemberDetail]
    let showEvidence: (EvidenceDetail) -> Void
    @State private var isExpanded: Bool

    init(title: String, members: [ComponentMemberDetail], startsExpanded: Bool, showEvidence: @escaping (EvidenceDetail) -> Void) {
        self.title = title
        self.members = members
        self.showEvidence = showEvidence
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                ForEach(members) { member in
                    EvidenceLinkButton(title: member.name, evidence: member.evidence, show: showEvidence)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DesignTokens.Spacing.xs)
        } label: {
            Text("\(title) (\(members.count))")
                .foregroundStyle(.secondary)
        }
    }
}
