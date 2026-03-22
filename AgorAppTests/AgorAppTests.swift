import XCTest
@testable import AgorApp

final class AgorAppTests: XCTestCase {
    func testAnyCodableString() throws {
        let json = #"{"key": "value"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: json)
        XCTAssertEqual(decoded["key"]?.stringValue, "value")
    }

    func testAnyCodableInt() throws {
        let json = #"{"count": 42}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: json)
        XCTAssertEqual(decoded["count"]?.intValue, 42)
    }

    func testSessionStatusDecoding() throws {
        let json = #""awaiting_permission""#.data(using: .utf8)!
        let status = try JSONDecoder().decode(SessionStatus.self, from: json)
        XCTAssertEqual(status, .awaitingPermission)
        XCTAssertTrue(status.needsAttention)
    }

    func testPermissionStatusDecoding() throws {
        let json = #""pending""#.data(using: .utf8)!
        let status = try JSONDecoder().decode(PermissionStatus.self, from: json)
        XCTAssertEqual(status, .pending)
    }

    func testPaginatedResponseDecoding() throws {
        let json = """
        {
            "total": 2,
            "limit": 10,
            "skip": 0,
            "data": [
                {"board_id": "abc", "name": "Test", "created_at": "2024-01-01T00:00:00Z", "last_updated": "2024-01-01T00:00:00Z", "created_by": "user1"}
            ]
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(PaginatedResponse<Board>.self, from: json)
        XCTAssertEqual(response.total, 2)
        XCTAssertEqual(response.data.count, 1)
        XCTAssertEqual(response.data[0].name, "Test")
    }

    func testMessageContentTextDecoding() throws {
        let json = """
        {
            "message_id": "msg1",
            "session_id": "sess1",
            "type": "assistant",
            "role": "assistant",
            "index": 0,
            "timestamp": "2024-01-01T00:00:00Z",
            "content_preview": "Hello",
            "content": [{"type": "text", "text": "Hello world"}]
        }
        """.data(using: .utf8)!
        let message = try JSONDecoder().decode(Message.self, from: json)
        if case .blocks(let blocks) = message.content {
            XCTAssertEqual(blocks.count, 1)
            if case .text(let content) = blocks[0] {
                XCTAssertEqual(content.text, "Hello world")
            } else {
                XCTFail("Expected text block")
            }
        } else {
            XCTFail("Expected blocks content")
        }
    }

    func testPermissionRequestDecoding() throws {
        let json = """
        {
            "message_id": "msg1",
            "session_id": "sess1",
            "type": "permission_request",
            "role": "system",
            "index": 1,
            "timestamp": "2024-01-01T00:00:00Z",
            "content_preview": "Permission",
            "content": {
                "request_id": "req1",
                "tool_name": "bash",
                "tool_input": {"command": "ls -la"},
                "status": "pending"
            }
        }
        """.data(using: .utf8)!
        let message = try JSONDecoder().decode(Message.self, from: json)
        if case .permissionRequest(let perm) = message.content {
            XCTAssertEqual(perm.requestId, "req1")
            XCTAssertEqual(perm.toolName, "bash")
            XCTAssertTrue(perm.isPending)
        } else {
            XCTFail("Expected permission request content")
        }
    }
}
