import Foundation

@Observable
final class AppLogger {
    static let shared = AppLogger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let category: String
        let message: String

        enum Level: String, CaseIterable {
            case info, warning, error, debug

            var symbol: String {
                switch self {
                case .info: "info.circle"
                case .warning: "exclamationmark.triangle"
                case .error: "xmark.circle"
                case .debug: "ant"
                }
            }
        }
    }

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 500

    func log(_ message: String, level: LogEntry.Level = .info, category: String = "General") {
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message)
        if Thread.isMainThread {
            append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.append(entry)
            }
        }
    }

    private func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    static func scrub(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #""password"\s*:\s*"[^"]*""#, with: "\"password\":\"***\"", options: .regularExpression)
        out = out.replacingOccurrences(of: #""(accessToken|refreshToken|token)"\s*:\s*"[^"]*""#, with: "\"$1\":\"***\"", options: .regularExpression)
        out = out.replacingOccurrences(of: #"Bearer\s+[A-Za-z0-9\-_\.]+"#, with: "Bearer ***", options: .regularExpression)
        // JWT-shaped strings (header.payload.signature)
        out = out.replacingOccurrences(of: #"\b[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, with: "***JWT***", options: .regularExpression)
        // emails
        out = out.replacingOccurrences(of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, with: "***@***", options: .regularExpression)
        return out
    }

    func export() -> String {
        let formatter = ISO8601DateFormatter()
        return entries.map { entry in
            let ts = formatter.string(from: entry.timestamp)
            return "[\(ts)] [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(Self.scrub(entry.message))"
        }.joined(separator: "\n")
    }
}
