import SwiftUI
import Textual

struct TextBlockView: View {
    let text: String
    var useMarkdown: Bool = true

    var body: some View {
        if useMarkdown {
            MarkdownTextView(text: text)
        } else {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Markdown Text View

struct MarkdownTextView: View {
    let text: String

    var body: some View {
        StructuredText(markdown: text)
            .textual.textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                UIApplication.shared.open(url)
                return .handled
            })
    }
}
