import Foundation

extension DateFormatter {
    static let iso8601Full: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

extension String {
    var asDate: Date? {
        DateFormatter.iso8601Full.date(from: self)
            ?? ISO8601DateFormatter().date(from: self)
    }

    var relativeTime: String {
        guard let date = asDate else { return self }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var shortTime: String {
        guard let date = asDate else { return self }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
