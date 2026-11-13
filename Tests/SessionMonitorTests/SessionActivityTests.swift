import XCTest
@testable import SessionMonitor

final class SessionActivityTests: XCTestCase {
    func testLiveStatusMappingAndWaitingPrecedence() {
        XCTAssertEqual(SessionActivity.parse(["type": "active", "activeFlags": []]), .working)
        XCTAssertEqual(SessionActivity.parse(["type": "idle"]), .idle)
        XCTAssertEqual(SessionActivity.parse(["type": "active", "activeFlags": ["waitingOnUserInput"]]), .waitingForInput)
        XCTAssertEqual(SessionActivity.parse(["type": "active", "activeFlags": ["waitingOnApproval", "waitingOnUserInput"]]), .waitingForApproval)
        XCTAssertEqual(SessionActivity.parse(["type": "systemError"]), .systemError)
        XCTAssertEqual(SessionActivity.parse(["type": "notLoaded"]), .unknown)
        XCTAssertEqual(SessionActivity.parse(["type": "futureStatus"]), .unknown)
    }

    func testFragmentedResponseWithNotificationsAndPing() throws {
        let reply = Data(#"{"id":2,"result":{"thread":{"status":{"type":"active","activeFlags":["waitingOnUserInput"]}}}}"#.utf8)
        let halfway = reply.count / 2
        let bytes = frame(Data(#"{"method":"thread/status/changed","params":{}}"#.utf8))
            + frame(Data(reply.prefix(halfway)), final: false)
            + frame(Data("ping".utf8), opcode: 9)
            + frame(Data(reply.suffix(reply.count - halfway)), opcode: 0)
        let stream = MemoryStream(bytes: bytes)
        let client = LocalWebSocket(stream: stream)
        let result = try client.request(id: 2, method: "thread/read", params: ["threadId": "fixture"])
        let thread = try XCTUnwrap(result["thread"] as? [String: Any])
        let status = try XCTUnwrap(thread["status"] as? [String: Any])
        XCTAssertEqual(SessionActivity.parse(status), .waitingForInput)
        XCTAssertEqual(stream.writes.count, 2) // Request and pong, both client-masked.
        XCTAssertEqual((stream.writes.first?[1] ?? 0) & 0x80, 0x80)
        XCTAssertEqual(stream.writes.last?[0], 0x8a)
    }

    func testExtendedLengthResponse() throws {
        let reply: [String: Any] = ["id": 7, "result": ["padding": String(repeating: "x", count: 300)]]
        let stream = MemoryStream(bytes: frame(try JSONSerialization.data(withJSONObject: reply)))
        let response = try LocalWebSocket(stream: stream).request(id: 7, method: "thread/read", params: [:])
        XCTAssertEqual((response["padding"] as? String)?.count, 300)
    }

    func testClosedMalformedAndOversizedFramesFail() {
        for bytes in [frame(Data(), opcode: 8), Data([0x81, 0x80]), Data([0x81, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])] {
            XCTAssertThrowsError(try LocalWebSocket(stream: MemoryStream(bytes: bytes))
                .request(id: 2, method: "thread/read", params: [:]))
        }
    }

    private func frame(_ payload: Data, opcode: UInt8 = 1, final: Bool = true) -> Data {
        var data = Data([(final ? 0x80 : 0) | opcode])
        if payload.count < 126 { data.append(UInt8(payload.count)) }
        else {
            data.append(126)
            data.append(UInt8(payload.count >> 8)); data.append(UInt8(payload.count & 255))
        }
        data.append(payload)
        return data
    }
}

private final class MemoryStream: WebSocketByteStream {
    var bytes: Data
    var writes: [Data] = []
    init(bytes: Data) { self.bytes = bytes }
    func write(_ data: Data) throws { writes.append(data) }
    func readExactly(_ count: Int) throws -> Data {
        guard bytes.count >= count else { throw CocoaError(.fileReadCorruptFile) }
        let result = Data(bytes.prefix(count))
        bytes.removeFirst(count)
        return result
    }
}
