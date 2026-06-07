import SwiftUI

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Image(systemName: statusIcon)
            .font(.system(size: 12))
            .foregroundStyle(statusColor)
            .symbolEffect(.rotate, isActive: status == .running)
    }

    private var statusIcon: String {
        switch status {
        case .idle: "checkmark.circle"
        case .running: "arrow.trianglehead.2.clockwise.circle"
        case .stopping: "stop.circle"
        case .awaitingPermission: "lock.fill"
        case .awaitingInput: "questionmark.circle.fill"
        case .timedOut: "clock.badge.exclamationmark"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch status {
        case .idle: .green
        case .running: .blue
        case .stopping: .blue.opacity(0.6)
        case .awaitingPermission, .awaitingInput: .orange
        case .timedOut: .gray
        case .completed: .green
        case .failed: .red
        case .unknown: .gray
        }
    }
}

// MARK: - Task Status Badge

struct TaskStatusBadge: View {
    let status: TaskStatus

    var body: some View {
        Image(systemName: statusIcon)
            .font(.system(size: 12))
            .foregroundStyle(statusColor)
            .symbolEffect(.rotate, isActive: status == .running)
    }

    private var statusIcon: String {
        switch status {
        case .queued: "clock"
        case .created: "circle.dashed"
        case .running: "arrow.trianglehead.2.clockwise.circle"
        case .stopping: "stop.circle"
        case .awaitingPermission: "lock.fill"
        case .awaitingInput: "questionmark.circle.fill"
        case .timedOut: "clock.badge.exclamationmark"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .stopped: "stop.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .queued: .orange
        case .created: .gray
        case .running: .blue
        case .stopping: .blue.opacity(0.6)
        case .awaitingPermission, .awaitingInput: .orange
        case .timedOut: .gray
        case .completed: .green
        case .failed, .stopped: .red
        }
    }
}
