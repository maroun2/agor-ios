import SwiftUI

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(status.displayLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        }
    }
}

// MARK: - Task Status Badge

struct TaskStatusBadge: View {
    let status: TaskStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(status.displayLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch status {
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
