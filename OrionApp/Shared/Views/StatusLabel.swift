import SwiftUI

/// A status: a coloured symbol and its words in a label colour. Orange or green *text* on a light
/// background falls well short of the 4.5:1 contrast the HIG asks of text up to 17 pt -- Xcode's
/// accessibility audit failed "Not independently checked" (Docs/19 M8) -- so the colour goes on the
/// symbol, which carries the state alongside its shape, and the text stays legible.
struct StatusLabel: View {
    let text: String
    let systemImage: String
    let tint: Color
    var textStyle: HierarchicalShapeStyle = .primary

    init(_ text: String, systemImage: String, tint: Color, textStyle: HierarchicalShapeStyle = .primary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.textStyle = textStyle
    }

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(textStyle)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}
