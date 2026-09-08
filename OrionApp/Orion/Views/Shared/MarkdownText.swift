import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §8 M8.6: renders LLM-authored text (Ask's answer/rationale,
/// a claim's statement, a semantically-investigated component's Purpose) with its own inline
/// markdown actually honored -- `**bold**` reads as bold, not as literal asterisks -- instead of
/// the plain `Text(_:)` this app used everywhere that text came from before this milestone.
///
/// Built on Foundation's own `AttributedString(markdown:)` (macOS 12+), not a third-party
/// dependency: every real example seen from this app's own agent output is inline emphasis
/// (`**bold**`, occasional `` `code` ``) inside otherwise plain prose, not full documents needing
/// headers/tables/nested lists -- the standard library's own parser already covers that.
/// `.inlineOnlyPreservingWhitespace` is the deliberate choice of the two realistic parsing modes:
/// the alternative, `.full`, treats blank-line-separated text as separate block elements (Swift's
/// own docs describe it as producing "a tree of elements"), which `Text` has no way to re-render
/// with its original paragraph spacing -- `.inlineOnlyPreservingWhitespace` keeps every line break
/// exactly as the model wrote it while still parsing inline emphasis, matching what these plain
/// paragraphs of chat-style output actually need.
struct MarkdownText: View {
    let raw: String

    var body: some View {
        Text(Self.attributed(raw))
    }

    /// A pure function, not `private`, specifically so `MarkdownTextTests` can check the parsing
    /// behavior directly -- this app has no ViewInspector-style tool to assert on rendered `Text`
    /// content, so the only unit-testable surface here is what feeds it.
    static func attributed(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(raw)
    }
}

#Preview {
    MarkdownText(
        raw: "**Middleware Assembly Explained Like You're 5:**\n\nEach checkpoint does a "
            + "*little job* -- some are \"clean,\" `code`-shaped, and important."
    )
    .padding()
    .frame(width: 360)
}
