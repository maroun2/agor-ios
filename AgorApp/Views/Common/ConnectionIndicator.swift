import SwiftUI

struct ConnectionIndicator: View {
    let socketService: SocketService

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            if socketService.connectionState == .reconnecting {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .accessibilityLabel(statusText)
    }

    private var dotColor: Color {
        switch socketService.connectionState {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .disconnected: .red
        }
    }

    private var statusText: String {
        switch socketService.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case .reconnecting: "Reconnecting..."
        case .disconnected: "Disconnected"
        }
    }
}
