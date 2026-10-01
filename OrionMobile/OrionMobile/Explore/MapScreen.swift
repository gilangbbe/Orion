import SwiftUI

/// The architecture map on its own screen (Docs/19 M8): spread wider than the Mac's, with labels on
/// a background so they stay legible, and pinch-to-zoom for when they still crowd. Grape draws on a canvas VoiceOver can't reach, so the map's
/// accessibility representation is the list of its components, each opening the component.
struct MapScreen: View {
    let model: ArchitectureModel
    let open: (ExploreRoute) -> Void

    /// The most nodes the map draws. A structural model of a large repository has thousands of
    /// modules (`transformers`: ~2,600), which a force simulation can neither lay out legibly nor
    /// afford on a phone (Docs/19 M8); the list and search take over.
    static let nodeLimit = 150

    static func canDraw(_ model: ArchitectureModel) -> Bool {
        !model.nodes.isEmpty && model.nodes.count <= nodeLimit
    }

    var body: some View {
        ArchitectureDiagramView(model: model, spread: 1.6, labelsOnMaterial: true, zoomable: true) { node in
            open(.component(id: node.id))
        }
        .accessibilityRepresentation {
            VStack {
                ForEach(model.nodes) { node in
                    Button(node.name) { open(.component(id: node.id)) }
                }
            }
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text("Tap a component to open it. Pinch to zoom, drag to move.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, DesignTokens.Spacing.sm)
                .accessibilityHidden(true)
        }
    }
}
