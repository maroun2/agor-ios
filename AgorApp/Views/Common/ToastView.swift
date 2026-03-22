import SwiftUI

// MARK: - Toast Model

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    let sessionId: String?
    let type: ToastType

    enum ToastType: Equatable {
        case permission
        case input
        case completed
        case info
    }

    var iconColor: Color {
        switch type {
        case .permission: .orange
        case .input: .blue
        case .completed: .green
        case .info: .secondary
        }
    }

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Toast Manager

@Observable
final class ToastManager {
    var currentToast: ToastMessage?
    var onTapSessionId: ((String) -> Void)?

    private var dismissTask: Task<Void, Never>?

    func show(_ toast: ToastMessage) {
        dismissTask?.cancel()
        withAnimation(.spring(duration: 0.3)) {
            currentToast = toast
        }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                currentToast = nil
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            currentToast = nil
        }
    }
}

// MARK: - Toast View

struct ToastView: View {
    let toast: ToastMessage
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: toast.icon)
                    .font(.body)
                    .foregroundStyle(toast.iconColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let subtitle = toast.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

// MARK: - Toast Overlay Modifier

struct ToastOverlay: ViewModifier {
    let toastManager: ToastManager
    let onNavigateToSession: (String) -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = toastManager.currentToast {
                ToastView(
                    toast: toast,
                    onTap: {
                        if let sessionId = toast.sessionId {
                            onNavigateToSession(sessionId)
                        }
                        toastManager.dismiss()
                    },
                    onDismiss: {
                        toastManager.dismiss()
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
            }
        }
    }
}

extension View {
    func toastOverlay(manager: ToastManager, onNavigate: @escaping (String) -> Void) -> some View {
        modifier(ToastOverlay(toastManager: manager, onNavigateToSession: onNavigate))
    }
}
