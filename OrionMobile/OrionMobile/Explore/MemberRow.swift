import SwiftUI

/// A member symbol; tapping it opens its code.
struct MemberRow: View {
    let member: ComponentMemberDetail
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(member.name)
                    .font(.body.monospaced())
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: Self.symbol(for: member.kind))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHint("Shows its code")
        .accessibilityIdentifier("component.member")
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case "class": "c.square"
        case "function": "f.square"
        case "method": "m.square"
        case "module": "doc.text"
        case "package": "folder"
        default: "number.square"
        }
    }
}
