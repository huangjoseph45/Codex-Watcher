import XCTest
@testable import SessionMonitor

final class PendingPromptTests: XCTestCase {
    private let thread = "thread-fixture"

    private func approval(id: Int = 42, command: String = "swift test") -> [String: Any] {
        ["id": id, "method": "item/commandExecution/requestApproval", "params": [
            "threadId": thread, "turnId": "turn-1", "itemId": "item-1", "command": command, "cwd": "/tmp/project"
        ]]
    }

    private func question() -> [String: Any] {
        ["id": "question-1", "method": "item/tool/requestUserInput", "params": [
            "threadId": thread, "turnId": "turn-1", "itemId": "item-2", "isBlocking": true,
            "questions": [["id": "choice", "header": "Direction", "question": "Which direction?",
                "options": [["label": "Left", "description": "Turn left"], ["label": "Right", "description": "Turn right"]]],
                ["id": "text", "header": "Name", "question": "What name?", "isSecret": true]]
        ]]
    }

    func testPromptIdentityBindsExactRequestAndContent() throws {
        let prompt = try XCTUnwrap(PendingPrompt.parse(approval(), threadID: thread))
        XCTAssertEqual(prompt.id, PendingPrompt.parse(approval(), threadID: thread)?.id)
        XCTAssertNotEqual(prompt.id, PendingPrompt.parse(approval(id: 43), threadID: thread)?.id)
        XCTAssertNotEqual(prompt.id, PendingPrompt.parse(approval(command: "other command"), threadID: thread)?.id)
        XCTAssertNil(PendingPrompt.parse(approval(), threadID: "different-thread"))
        XCTAssertNil(PromptRequestID(true))
        XCTAssertTrue(prompt.canApproveHere)
        let response = try prompt.response(for: .approval(.accept))
        XCTAssertEqual((response["result"] as? [String: String])?["decision"], "accept")
        XCTAssertEqual(response["id"] as? Int64, 42)
    }

    func testUserInputRequiresEveryQuestionAndOnlyValidChoices() throws {
        let prompt = try XCTUnwrap(PendingPrompt.parse(question(), threadID: thread))
        XCTAssertFalse(prompt.accepts([:]))
        XCTAssertFalse(prompt.accepts(["choice": "Left"]))
        XCTAssertFalse(prompt.accepts(["choice": "Anything", "text": "name"]))
        XCTAssertFalse(prompt.accepts(["choice": "Left", "text": " "]))
        XCTAssertTrue(prompt.accepts(["choice": "Right", "text": "name"]))
        XCTAssertTrue(prompt.questions[1].isSecret)
        XCTAssertThrowsError(try prompt.response(for: .approval(.accept)))
        let response = try prompt.response(for: .answers(["choice": "Left", "text": "name"]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let answers = try XCTUnwrap(result["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["choice"]?["answers"], ["Left"])
    }

    func testMissingCommandAndFileChangesCannotBeBlindlyApproved() throws {
        var message = approval()
        var params = message["params"] as! [String: Any]
        params.removeValue(forKey: "command")
        message["params"] = params
        let missing = try XCTUnwrap(PendingPrompt.parse(message, threadID: thread))
        XCTAssertThrowsError(try missing.response(for: .approval(.accept)))
        message["method"] = "item/fileChange/requestApproval"
        let file = try XCTUnwrap(PendingPrompt.parse(message, threadID: thread))
        XCTAssertFalse(file.canApproveHere)
        XCTAssertThrowsError(try file.response(for: .approval(.accept)))
        XCTAssertNoThrow(try file.response(for: .approval(.decline)))
    }

    func testResolutionReplaysAndConfirmsExactRequestIncludingIDCollision() throws {
        let message = approval(id: 3) // Server and client RPC IDs can overlap.
        let expected = try XCTUnwrap(PendingPrompt.parse(message, threadID: thread))
        let stream = PromptFixtureStream(messages: [metadata(waiting: true), message, ["id": 3, "result": [:]],
            ["method": "serverRequest/resolved", "params": ["threadId": thread, "requestId": 3]]])
        let client = PromptClient(home: URL(fileURLWithPath: "/unused"), timeoutMilliseconds: 100)
        let result = try client.resolve(expected, with: .approval(.decline), connection: LocalWebSocket(stream: stream))
        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(stream.writes.count, 3)
        let outgoing = try stream.decodedLastWrite()
        XCTAssertEqual(outgoing["id"] as? Int, 3)
        XCTAssertEqual((outgoing["result"] as? [String: String])?["decision"], "decline")
    }

    func testStalePromptNeverSendsDecision() throws {
        let expected = try XCTUnwrap(PendingPrompt.parse(approval(command: "old command"), threadID: thread))
        let stream = PromptFixtureStream(messages: [metadata(waiting: true), approval(command: "new command"), ["id": 3, "result": [:]]])
        let client = PromptClient(home: URL(fileURLWithPath: "/unused"), timeoutMilliseconds: 100)
        XCTAssertThrowsError(try client.resolve(expected, with: .approval(.accept), connection: LocalWebSocket(stream: stream)))
        XCTAssertEqual(stream.writes.count, 2) // Only metadata and resume requests.
    }

    func testCompletedSessionDoesNotResumeOrSendDecision() throws {
        let expected = try XCTUnwrap(PendingPrompt.parse(approval(), threadID: thread))
        let stream = PromptFixtureStream(messages: [metadata(waiting: false)])
        let client = PromptClient(home: URL(fileURLWithPath: "/unused"), timeoutMilliseconds: 100)
        XCTAssertThrowsError(try client.resolve(expected, with: .approval(.accept), connection: LocalWebSocket(stream: stream)))
        XCTAssertEqual(stream.writes.count, 1)
    }

    func testLostConfirmationIsSentRatherThanAutomaticallyRetried() throws {
        let expected = try XCTUnwrap(PendingPrompt.parse(approval(), threadID: thread))
        let stream = PromptFixtureStream(messages: [metadata(waiting: true), approval(), ["id": 3, "result": [:]]])
        let client = PromptClient(home: URL(fileURLWithPath: "/unused"), timeoutMilliseconds: 100)
        XCTAssertEqual(try client.resolve(expected, with: .approval(.decline), connection: LocalWebSocket(stream: stream)), .sent)
        XCTAssertEqual(stream.writes.count, 3)
    }

    func testResolvedPromptIsRemovedBeforeResumeCompletes() throws {
        var inbox = PromptInbox(threadID: thread)
        inbox.ingest(approval())
        XCTAssertNotNil(inbox.first)
        inbox.ingest(["method": "serverRequest/resolved", "params": ["threadId": thread, "requestId": 42]])
        XCTAssertNil(inbox.first)
    }

    private func metadata(waiting: Bool) -> [String: Any] {
        ["id": 2, "result": ["thread": ["status": waiting
            ? ["type": "active", "activeFlags": ["waitingOnApproval"]] as [String: Any]
            : ["type": "idle"] as [String: Any]]]]
    }
}

private final class PromptFixtureStream: WebSocketByteStream {
    var bytes = Data()
    var writes: [Data] = []
    init(messages: [[String: Any]]) {
        for message in messages {
            let payload = try! JSONSerialization.data(withJSONObject: message)
            bytes.append(0x81)
            if payload.count < 126 { bytes.append(UInt8(payload.count)) }
            else { bytes.append(126); bytes.append(UInt8(payload.count >> 8)); bytes.append(UInt8(payload.count & 255)) }
            bytes.append(payload)
        }
    }
    func write(_ data: Data) throws { writes.append(data) }
    func readExactly(_ count: Int) throws -> Data {
        guard bytes.count >= count else { throw CocoaError(.fileReadCorruptFile) }
        let result = Data(bytes.prefix(count)); bytes.removeFirst(count); return result
    }
    func decodedLastWrite() throws -> [String: Any] {
        let bytes = Array(try XCTUnwrap(writes.last))
        var offset = 2
        var length = Int(bytes[1] & 127)
        if length == 126 { length = Int(bytes[2]) << 8 | Int(bytes[3]); offset += 2 }
        let mask = Array(bytes[offset..<(offset + 4)]); offset += 4
        let payload = Data((0..<length).map { bytes[offset + $0] ^ mask[$0 % 4] })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    }
}
