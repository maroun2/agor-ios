import SwiftUI

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
// Uses Textual for full markdown rendering.
// Falls back to plain text if Textual is not available.

struct MarkdownTextView: View {
    let text: String

    var body: some View {
        // Render markdown using SwiftUI's built-in markdown support (iOS 15+)
        // Textual integration is added as an enhancement in Phase 7.
        // For now, use SwiftUI's native markdown + code block detection.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let content):
                    Text(LocalizedStringKey(content))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }

    // Simple markdown parser that separates code fences from text
    private func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var currentText = ""
        var inCodeBlock = false
        var codeLanguage = ""
        var codeContent = ""

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") && !inCodeBlock {
                // Start code block
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                inCodeBlock = true
                codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeContent = ""
            } else if line.hasPrefix("```") && inCodeBlock {
                // End code block
                blocks.append(.code(language: codeLanguage, code: codeContent.trimmingCharacters(in: .newlines)))
                inCodeBlock = false
                codeLanguage = ""
                codeContent = ""
            } else if inCodeBlock {
                codeContent += (codeContent.isEmpty ? "" : "\n") + line
            } else {
                currentText += (currentText.isEmpty ? "" : "\n") + line
            }
        }

        // Handle unclosed code blocks
        if inCodeBlock {
            blocks.append(.code(language: codeLanguage, code: codeContent.trimmingCharacters(in: .newlines)))
        }
        if !currentText.isEmpty {
            blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
        }

        return blocks
    }
}

private enum MarkdownBlock {
    case text(String)
    case code(language: String, code: String)
}
