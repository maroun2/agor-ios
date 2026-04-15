import SwiftUI

struct PermissionCardView: View {
    let content: PermissionRequestContent
    let isFirstPending: Bool
    var onApprove: ((PermissionScope) -> Void)?
    var onDeny: (() -> Void)?

    @State private var showDetails = false

    var body: some View {
        if content.isResolved {
            resolvedView
        } else {
            pendingView
        }
    }

    // MARK: - Pending State

    private var pendingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: content.toolIcon)
                    .font(.body)
                    .foregroundStyle(.orange)

                Text(content.toolDisplayName)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("Permission Request")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            // Input preview
            VStack(alignment: .leading, spacing: 4) {
                Text(content.inputPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(showDetails ? nil : 3)

                if !showDetails {
                    Button("Show details") {
                        withAnimation { showDetails = true }
                    }
                    .font(.caption2)
                }
            }

            if showDetails {
                // Full input
                ScrollView {
                    Text(formatInput())
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Action buttons
            if !content.isResolved {
                HStack(spacing: 8) {
                    Button("Allow Once") {
                        HapticFeedback.light()
                        onApprove?(.once)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)

                    Button("Allow Session") {
                        HapticFeedback.light()
                        onApprove?(.project)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button("Deny") {
                        HapticFeedback.medium()
                        onDeny?()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.orange.opacity(isFirstPending ? 0.6 : 0.2), lineWidth: isFirstPending ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Resolved State

    private var resolvedView: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text(content.inputPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 6) {
                Text(content.status == .approved ? "✅" : "❌")
                    .font(.caption)
                Text(content.status == .approved ? "Allowed" : "Denied")
                    .font(.caption.weight(.medium))
                Text(content.toolDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatInput() -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: content.toolInput.mapValues(\.value),
            options: [.prettyPrinted, .sortedKeys]
        ) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
