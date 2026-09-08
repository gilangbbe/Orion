import AppKit
import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §3 / M0: the palette that carries meaning specific to Orion
/// -- the accent brand color, the five epistemic hues (Docs/04 §3), and the four confidence hues
/// (`ConfidenceTier`). Every other token from the prototype's CSS (window/card backgrounds,
/// borders, primary/secondary/tertiary text, sidebar/toolbar/inspector materials) deliberately has
/// NO Swift equivalent here -- macOS already has a correct, dark-mode-aware answer for all of
/// those (`Color.primary`/`.secondary`, `Color(nsColor: .separatorColor)`, and, for the glass
/// chrome itself, `NavigationSplitView`/`.toolbar`/`.inspector` already render as Liquid Glass
/// automatically on macOS 26 -- confirmed against the real SDK, not assumed: `SwiftUICore`'s
/// `glassEffect(_:in:)`/`Glass`/`GlassEffectContainer` and `SwiftUI`'s `.glass`/`.glassProminent`
/// button styles all require `macOS 26.0+`, matching `project.yml`'s deployment target exactly, and
/// exist specifically for *custom* views that want to explicitly opt into the glass material --
/// not for standard chrome, which gets it for free). Hand-porting the mockup's hex approximations
/// for any of that would be a strictly worse, harder-to-maintain copy of something the system
/// already gets right.
///
/// sRGB values below are computed, not eyeballed, from the prototype's OKLCH tokens via the
/// standard Oklab -> linear sRGB -> gamma-corrected sRGB conversion, independently for each
/// token's light and dark appearance value. `Docs/phase4_5_design/Main.dc.html`'s `:root`/`.dark`
/// blocks are the source of truth -- re-run the conversion there first if a token's OKLCH value
/// ever changes, rather than hand-editing the numbers below.
enum DesignTokens {
    /// Orion's brand/interactive tint -- deliberately not reused by any epistemic or confidence
    /// hue below (Docs/14 §3's color-collision reasoning: confidence and epistemic type are
    /// independent axes, and neither should borrow the app's own accent either).
    static let accent = dynamicColor(light: (0.000, 0.583, 0.613), dark: (0.000, 0.583, 0.613))
    static let accentStrong = dynamicColor(light: (0.000, 0.468, 0.503), dark: (0.000, 0.468, 0.503))

    // Epistemic hues (Docs/04 §3) -- same meaning as the shipped `EpistemicTag.color`
    // (green/purple/indigo/gray/red), re-expressed with a tuned light/dark pair instead of a flat
    // system color name.
    static let fact = dynamicColor(light: (0.165, 0.593, 0.330), dark: (0.302, 0.748, 0.456))
    static let interpretation = dynamicColor(
        light: (0.609, 0.296, 0.658), dark: (0.799, 0.476, 0.850))
    static let inference = dynamicColor(light: (0.353, 0.370, 0.753), dark: (0.517, 0.551, 0.952))
    static let unknown = dynamicColor(light: (0.432, 0.446, 0.469), dark: (0.583, 0.598, 0.622))
    static let contradicted = dynamicColor(light: (0.829, 0.229, 0.234), dark: (0.970, 0.365, 0.350))

    // Confidence hues (`ConfidenceTier`) -- a separate axis from epistemic type; see
    // `ConfidenceBadge`'s own doc comment for why they never reuse an epistemic hue.
    static let confidenceHigh = dynamicColor(light: (0.178, 0.435, 0.803), dark: (0.396, 0.623, 0.958))
    static let confidenceMedium = dynamicColor(
        light: (0.791, 0.617, 0.199), dark: (0.868, 0.691, 0.287))
    static let confidenceLow = dynamicColor(light: (0.878, 0.399, 0.135), dark: (0.958, 0.499, 0.276))
    static let confidenceUnresolved = dynamicColor(
        light: (0.489, 0.503, 0.527), dark: (0.512, 0.527, 0.550))

    /// Docs/14 §3's radius scale (window / panel / control -- concentric, each step smaller than
    /// the one it nests inside, per the Liquid Glass HIG note in Docs/14 §2).
    enum Radius {
        static let window: CGFloat = 16
        static let panel: CGFloat = 12
        static let control: CGFloat = 9
    }

    /// Docs/14 §3's spacing scale.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    /// Builds a `Color` that resolves to a different sRGB triple depending on the active
    /// appearance -- the code-only equivalent of an Asset Catalog color set's Any/Dark pair,
    /// without a `.colorset` folder per token.
    private static func dynamicColor(
        light: (Double, Double, Double), dark: (Double, Double, Double)
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let (r, g, b) = isDark ? dark : light
                return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            })
    }
}
