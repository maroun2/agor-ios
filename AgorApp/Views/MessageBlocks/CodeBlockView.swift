import Highlightr
import SwiftUI

struct CodeBlockView: View {
    let language: String
    let code: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var isCopied = false
    @State private var highlightedCode: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if !language.isEmpty {
                    Text(language)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    UIPasteboard.general.string = code
                    isCopied = true
                    HapticFeedback.light()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isCopied = false
                    }
                } label: {
                    Label(
                        isCopied ? "Copied" : "Copy",
                        systemImage: isCopied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemBackground))

            // Code with syntax highlighting
            ScrollView(.horizontal, showsIndicators: false) {
                if let highlighted = highlightedCode {
                    Text(highlighted)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                } else {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(12)
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: code + language + colorScheme.description) {
            highlightedCode = highlightCode()
        }
    }

    private func highlightCode() -> AttributedString? {
        guard !code.isEmpty else { return nil }
        let highlightr = Highlightr()
        highlightr?.setTheme(to: colorScheme == .dark ? "atom-one-dark" : "atom-one-light")

        let lang = language.isEmpty ? nil : language
        guard let highlighted = highlightr?.highlight(code, as: lang) else { return nil }
        return try? AttributedString(highlighted, including: \.uiKit)
    }
}

private extension ColorScheme {
    var description: String {
        switch self {
        case .light: "light"
        case .dark: "dark"
        @unknown default: "unknown"
        }
    }
}
