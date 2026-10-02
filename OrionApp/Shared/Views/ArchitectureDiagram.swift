import Grape
import SwiftUI

/// The architecture map: a Grape force-directed diagram of `ArchitectureModel`'s nodes and edges.
/// Extracted from `ArchitectureOverviewView` (Docs/19 M4) so the iOS companion's Explore tab draws
/// the identical map; each app decides what a tap does (`onSelect`).
///
/// Grape's own docs are explicit that linking to a node id absent from the diagram crashes the
/// view -- `ArchitectureModelLoader` already guarantees every edge's endpoints exist among
/// `model.nodes` (filtered at load time, unit-tested), so this view never re-checks that.
struct ArchitectureDiagramView: View {
    let model: ArchitectureModel
    /// How far apart nodes settle; above 1 on a phone, where the default packs labels on top of
    /// each other (Docs/19 M8). The Mac keeps 1.
    var spread: Double = 1
    /// Labels on a background capsule, legible where they cross edges or each other (Docs/19 M8).
    var labelsOnMaterial = false
    /// Pinch to zoom and drag to pan (or move a node) -- Grape's own gestures, for a phone where
    /// the whole map doesn't fit at a legible size (Docs/19 M8).
    var zoomable = false
    let onSelect: (ArchitectureNode) -> Void

    var body: some View {
        ForceDirectedGraph {
            if labelsOnMaterial {
                // The view-annotation overload: a `Text` with a background isn't a `Text`, which
                // the text-annotation overload requires. A solid colour, not a material: Grape
                // draws annotations into a canvas, where a material renders as a black box.
                Series(model.nodes) { node in
                    NodeMark(id: node.id)
                        .foregroundStyle(Self.color(for: node))
                        .symbolSize(radius: Self.radius(for: node))
                        .annotation(node.id, alignment: .bottom, offset: CGVector(dx: 0, dy: Self.radius(for: node) + 8)) {
                            Text(node.name)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Self.labelBackground, in: Capsule())
                        }
                }
            } else {
                Series(model.nodes) { node in
                    NodeMark(id: node.id)
                        .foregroundStyle(Self.color(for: node))
                        .symbolSize(radius: Self.radius(for: node))
                        // An explicit `Text`, not `.annotation(node.name, ...)`: Grape's `String?`
                        // overload drops the string and annotates with `nil` (true of the tagged
                        // 1.1.0 release too), so the map drew no labels at all until Docs/19 M4
                        // caught it. Pushed below the circle: Grape anchors the label near the
                        // node's center.
                        .annotation(alignment: .bottom, offset: CGVector(dx: 0, dy: Self.radius(for: node) + 8)) {
                            Text(node.name).font(.caption2)
                        }
                }
            }
            Series(model.edges) { edge in
                LinkMark(from: edge.sourceId, to: edge.targetId)
                    .stroke(
                        edge.confidenceTier == "high" ? Color.secondary.opacity(0.6) : Color.orange,
                        StrokeStyle(
                            lineWidth: 1.5,
                            dash: edge.confidenceTier == "high" ? [] : [4, 3])
                    )
            }
        } force: {
            // Docs/14 §8 M8.5 item 2: tuned for spacing -- the library's own defaults
            // (`manyBody(strength: -30)`, `link(originalLength: 30)`, no collision force at all)
            // are what produced the cramped, overlapping cluster this milestone exists to fix,
            // confirmed against the vendored Grape package source (`ForceDescriptor.swift`).
            // `.collide()` is new here: previously nothing stopped two nodes from overlapping
            // regardless of repulsion strength; sizing its radius from each node's own
            // `radius(for:)` (plus fixed padding) makes overlap structurally impossible rather
            // than just less likely.
            .manyBody(strength: repulsion)
            .link(originalLength: .constant(linkLength))
            .center()
            .collide(
                radius: .varied { (id: String) in
                    guard let node = model.nodes.first(where: { $0.id == id }) else { return 16 }
                    return Self.radius(for: node) + collisionGap
                })
        }
        .graphOverlay { proxy in
            let tappable = Rectangle().fill(.clear).contentShape(Rectangle())
                .onTapGesture { location in
                    if let id = proxy.node(of: String.self, at: location),
                        let node = model.nodes.first(where: { $0.id == id })
                    {
                        onSelect(node)
                    }
                }
            #if os(iOS)
            if zoomable {
                tappable
                    .withGraphDragGesture(proxy, of: String.self)
                    .withGraphMagnifyGesture(proxy)
            } else {
                tappable
            }
            #else
            tappable
            #endif
        }
    }

    /// Docs/14 §8 M8.5 item 2: a per-node-identity color, not confidence-tier-based (that stays
    /// visible via `ConfidenceBadge` in the inspector and in the node list's own row badge, so
    /// nothing is lost, just relocated -- a deliberate trade-off, since this diagram's node fill
    /// was previously the one place confidence was visible without opening a node). Hashed from
    /// `node.id` into a fixed palette rather than `Int.random`, so a given node is always the same
    /// color across reloads instead of reshuffling every re-render -- "randomly assigned" in the
    /// sense the palette has nothing to do with confidence, not literally nondeterministic.
    /// `String.hashValue` itself is seeded per-process (Swift's hash-flooding protection), so a
    /// small deterministic hash is used here instead, to keep the mapping stable across launches
    /// too, not just within one running session.
    static func color(for node: ArchitectureNode) -> Color {
        let palette: [Color] = [
            .blue, .green, .orange, .purple, .pink, .teal, .mint, .cyan, .brown, .indigo, .red,
            .yellow,
        ]
        return palette[stableHash(node.id) % palette.count]
    }

    /// FNV-1a, chosen only for being tiny and dependency-free -- this has no correctness
    /// requirements beyond "deterministic across runs," not cryptographic ones.
    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash % UInt64(Int.max))
    }

    /// The page's background, slightly translucent, in either appearance.
    private static var labelBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground).opacity(0.88)
        #else
        Color(nsColor: .windowBackgroundColor).opacity(0.88)
        #endif
    }

    // Typed separately: inline, `spread` arithmetic inside the force builder is too much for the
    // type checker.
    private var repulsion: Double { -220 * spread }
    private var linkLength: Double { 90 * spread }
    private var collisionGap: CGFloat { 12 * spread }

    static func radius(for node: ArchitectureNode) -> CGFloat {
        node.confidenceTier == nil ? 8 : min(24, 8 + sqrt(Double(node.size)) * 3)
    }
}
