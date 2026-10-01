/// Markdown as plain prose -- for one-line previews where emphasis and code spans would only add
/// stray backticks.
enum PlainText {
    static func from(markdown: String) -> String {
        String(MarkdownText.attributed(markdown).characters).replacing("\n", with: " ")
    }
}
