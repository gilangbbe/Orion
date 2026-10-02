import SwiftUI

/// A badge's icon and title, tight together. Inside a list row SwiftUI gives a `Label` the row's
/// style -- the icon in a fixed-width column, the title at the row's text inset -- which pushed a
/// badge's title far from its icon and off centre in its capsule (Docs/19 M8).
struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == BadgeLabelStyle {
    static var badge: BadgeLabelStyle { BadgeLabelStyle() }
}
