import SwiftUI

/// Docs/14_phase4_5_ui_ux_redesign.md §8 M8.6: renders LLM-authored text (Ask's answer/rationale,
/// a claim's statement, a semantically-investigated component's Purpose) with its own markdown
/// actually honored, instead of the plain `Text(_:)` this app used everywhere that text came from
/// before this milestone.
///
/// **Revised from this milestone's original scope**: that first version deliberately parsed with
/// `.inlineOnlyPreservingWhitespace` -- inline emphasis (`**bold**`, `` `code` ``) only, reasoning
/// that "every real example seen from this app's own agent output is inline emphasis... not full
/// documents needing headers/tables/nested lists." A real, live depth-3 (Claude-delegated) answer
/// falsified that: full `###` headers, `---` thematic breaks, and numbered/bulleted lists showed
/// up verbatim (literal `#`/`-`/`1.` characters), not rendered. Headers/lists are exactly the
/// block-level constructs `.inlineOnlyPreservingWhitespace` was chosen to *not* parse.
///
/// Still built on Foundation's own `AttributedString(markdown:)` (macOS 12+), not a third-party
/// dependency -- `.full` `interpretedSyntax` parses the same block structure (headers, lists,
/// thematic breaks, code blocks) a full CommonMark document has, attaching a `PresentationIntent`
/// per run describing which block it belongs to (Apple's own docs: "a header run carries
/// `.header(level:)`, a list item carries `.listItem(ordinal:)`"). `Text` can't render that intent
/// with any distinct visual treatment on its own -- it treats an `AttributedString` as one flat
/// run of characters regardless of block structure -- so this view does the one thing `Text` can't:
/// groups `.full`-parsed runs back into contiguous blocks wherever their `presentationIntent`
/// changes, then renders each block as its own `Text`/row (a header with a larger/bold font, a
/// list item with its own bullet or number, a thematic break as a `Divider()`), while every run's
/// *inline* emphasis (bold/italic/code) -- already resolved correctly by the same `.full` parse --
/// carries straight through into each block's `Text`, unchanged.
struct MarkdownText: View {
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(raw).enumerated()), id: \.offset) { _, block in
                Self.render(block)
            }
        }
        // A real reported bug: this content rendered past its container's visible right edge
        // instead of wrapping once the caller stopped constraining it tightly by coincidence
        // (`AskView`'s `detail` pane). Nothing about a bare `VStack` of `Text` views pins them to
        // whatever width the caller actually has available -- `Text` wraps correctly only when
        // it's actually offered a bounded width, and a `VStack` with no `frame` of its own can end
        // up proposing its *content's* ideal (unwrapped) width back up the layout chain instead.
        // `maxWidth: .infinity` here makes this view always claim the full width it's given,
        // regardless of what that caller happens to be, so every `Text` inside wraps against it.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One markdown block, already split out of a `.full`-parsed `AttributedString` by
    /// `blocks(_:)`. Its own inline emphasis (bold/italic/code) is preserved in `text` wherever a
    /// case carries one -- only the *block*-level shape (heading level, list marker, ...) is
    /// pulled out into the case itself, since that's the part `Text` can't infer on its own.
    enum Block: Equatable {
        case heading(level: Int, text: AttributedString)
        case listItem(ordered: Bool, ordinal: Int, indentationLevel: Int, text: AttributedString)
        case codeBlock(String)
        case blockQuote(AttributedString)
        case thematicBreak
        case paragraph(AttributedString)
    }

    /// A pure function, not `private`, specifically so `MarkdownTextTests` can check the parsing
    /// behavior directly -- this app has no ViewInspector-style tool to assert on rendered `Text`
    /// content, so the only unit-testable surface here is what feeds it.
    static func blocks(_ raw: String) -> [Block] {
        let attributed = Self.fullyParsed(raw)
        var groups: [(intent: PresentationIntent?, text: AttributedString)] = []
        for run in attributed.runs {
            let intent = run.presentationIntent
            if let lastIndex = groups.indices.last, groups[lastIndex].intent == intent {
                groups[lastIndex].text += AttributedString(attributed[run.range])
            } else {
                groups.append((intent, AttributedString(attributed[run.range])))
            }
        }
        return groups.compactMap { Self.block(forIntent: $0.intent, text: $0.text) }
    }

    /// Kept from before this revision, still real and tested on its own: the plain
    /// inline-emphasis-only parse, used wherever a caller wants a single flat run rather than a
    /// full block breakdown (`blocks(_:)` above no longer routes through this internally -- `.full`
    /// parsing already resolves the identical inline emphasis within each block, so re-parsing a
    /// block's own text with this a second time would be redundant, not additive).
    static func attributed(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(raw)
    }

    private static func fullyParsed(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full))
        ) ?? AttributedString(raw)
    }

    /// `PresentationIntent.components` documents no fixed outermost-vs-innermost ordering
    /// contract, so this searches the whole chain for the specific `Kind` cases that matter here
    /// rather than indexing into it positionally.
    private static func block(forIntent intent: PresentationIntent?, text: AttributedString) -> Block? {
        guard let intent else {
            return text.characters.isEmpty ? nil : .paragraph(text)
        }
        let kinds = intent.components.map(\.kind)

        if kinds.contains(where: {
            if case .thematicBreak = $0 { return true }
            return false
        }) {
            return .thematicBreak
        }
        for kind in kinds {
            if case .header(let level) = kind { return .heading(level: level, text: text) }
        }
        if kinds.contains(where: {
            if case .codeBlock = $0 { return true }
            return false
        }) {
            return .codeBlock(String(text.characters))
        }
        for kind in kinds {
            if case .listItem(let ordinal) = kind {
                let ordered = kinds.contains {
                    if case .orderedList = $0 { return true }
                    return false
                }
                return .listItem(
                    ordered: ordered, ordinal: ordinal, indentationLevel: intent.indentationLevel, text: text)
            }
        }
        if kinds.contains(where: {
            if case .blockQuote = $0 { return true }
            return false
        }) {
            return .blockQuote(text)
        }
        return text.characters.isEmpty ? nil : .paragraph(text)
    }

    @ViewBuilder
    private static func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text).font(Self.headingFont(level: level)).fontWeight(.bold)
        case .listItem(let ordered, let ordinal, let indentationLevel, let text):
            HStack(alignment: .top, spacing: 6) {
                Text(ordered ? "\(ordinal)." : "•")
                    .foregroundStyle(.secondary)
                Text(text)
            }
            .padding(.leading, CGFloat(max(0, indentationLevel - 1)) * 16)
        case .codeBlock(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .blockQuote(let text):
            Text(text)
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2)
                }
        case .thematicBreak:
            Divider()
        case .paragraph(let text):
            Text(text)
        }
    }

    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        default: return .headline
        }
    }
}

#Preview {
    MarkdownText(
        raw: """
            ### Core Features
            1. **ASGI Compliance**
               - Starlette is built on top of ASGI.
            2. **Middleware**

            ---

            Each checkpoint does a *little job* -- some are "clean," `code`-shaped, and important.
            """
    )
    .padding()
    .frame(width: 360)
}
