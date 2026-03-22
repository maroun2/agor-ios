import Foundation

// MARK: - Input Request Status

enum InputRequestStatus: String, Codable {
    case pending
    case answered
    case timedOut = "timed_out"
}

// MARK: - Input Request Option

struct InputRequestOption: Codable, Identifiable {
    let label: String
    let description: String
    var markdown: String?

    var id: String { label }
}

// MARK: - Input Request Question

struct InputRequestQuestion: Codable, Identifiable {
    let question: String
    let header: String
    let options: [InputRequestOption]
    let multiSelect: Bool

    var id: String { question }
}

// MARK: - Input Request Content

struct InputRequestContent: Codable {
    let requestId: String
    var taskId: String?
    let questions: [InputRequestQuestion]
    var status: InputRequestStatus
    var answers: [String: String]?
    var answeredBy: String?
    var answeredAt: String?

    var isPending: Bool { status == .pending }
    var isResolved: Bool { status != .pending }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case taskId = "task_id"
        case questions, status, answers
        case answeredBy = "answered_by"
        case answeredAt = "answered_at"
    }
}

// MARK: - Input Response (for POST)

struct InputResponse: Codable {
    let requestId: String
    var taskId: String?
    let answers: [String: String]
    let respondedBy: String

    enum CodingKeys: String, CodingKey {
        case requestId = "requestId"
        case taskId = "taskId"
        case answers
        case respondedBy = "respondedBy"
    }
}
