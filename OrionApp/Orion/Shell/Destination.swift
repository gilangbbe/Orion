import SwiftUI

/// The sidebar's destinations (Docs/14 §4.1). Docs/20 R1: short titles, under the 15 characters
/// the HIG asks of a title, and the iPhone's word where both apps share the concept (Learn). Each
/// is also a View menu command with ⌘1–⌘5.
enum Destination: String, CaseIterable, Identifiable {
    case overview
    case ask
    case teaching
    case changes
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Architecture"
        case .ask: "Ask"
        case .teaching: "Learn"
        case .changes: "Model Changes"
        case .diagnostics: "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "point.3.connected.trianglepath.dotted"
        case .ask: "bubble.left.and.text.bubble.right"
        case .teaching: "graduationcap"
        case .changes: "clock.arrow.circlepath"
        case .diagnostics: "stethoscope"
        }
    }

    /// ⌘1–⌘5, in sidebar order.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character("\((Self.allCases.firstIndex(of: self) ?? 0) + 1)"))
    }

    /// Docs/14 §4.1: the first four are primary; Diagnostics sits alone under "Advanced"
    /// (Docs/05 §8 -- hidden-by-default detail, not undiscoverable).
    static let primary: [Destination] = [.overview, .ask, .teaching, .changes]
    static let advanced: [Destination] = [.diagnostics]
}
