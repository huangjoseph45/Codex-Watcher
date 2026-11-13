import XCTest
@testable import SessionMonitor

final class AttentionTrackerTests: XCTestCase {
    private func session(_ activity: SessionActivity, id: String = "fixture") -> CodexSession {
        CodexSession(id: id, title: "Fixture", activity: activity)
    }

    func testEachWaitingEpisodeIsAnnouncedOnlyOnce() {
        var tracker = AttentionTracker()
        XCTAssertEqual(tracker.update([session(.working)]), [])
        XCTAssertEqual(tracker.update([session(.waitingForInput)]), ["fixture"])
        XCTAssertEqual(tracker.update([session(.waitingForInput)]), [])
        XCTAssertEqual(tracker.update([session(.unknown)]), [])
        XCTAssertEqual(tracker.update([session(.waitingForInput)]), [])
        XCTAssertEqual(tracker.update([session(.idle)]), [])
        XCTAssertEqual(tracker.update([session(.waitingForInput)]), ["fixture"])
    }

    func testMultipleSessionsAndDifferentWaitingTypes() {
        var tracker = AttentionTracker()
        XCTAssertEqual(tracker.update([session(.waitingForInput), session(.waitingForApproval, id: "second")]), ["fixture", "second"])
        XCTAssertEqual(tracker.update([session(.waitingForApproval)]), ["fixture"])
        _ = tracker.update([])
        XCTAssertEqual(tracker.update([session(.waitingForApproval)]), ["fixture"])
    }

    func testNewPromptInSameWaitingEpisodeIsAnnouncedAndMissingDetailsDoNotRepeat() throws {
        var tracker = AttentionTracker()
        var waiting = session(.waitingForApproval)
        func prompt(_ request: Int) throws -> PendingPrompt {
            try XCTUnwrap(PendingPrompt.parse(["id": request, "method": "item/commandExecution/requestApproval",
                "params": ["threadId": waiting.id, "turnId": "turn", "itemId": "item", "command": "swift test"]],
                threadID: waiting.id))
        }
        waiting.pendingPrompt = try prompt(1)
        XCTAssertEqual(tracker.update([waiting]), ["fixture"])
        XCTAssertEqual(tracker.update([waiting]), [])
        let original = waiting.pendingPrompt
        waiting.pendingPrompt = nil
        XCTAssertEqual(tracker.update([waiting]), [])
        waiting.pendingPrompt = original
        XCTAssertEqual(tracker.update([waiting]), [])
        waiting.pendingPrompt = try prompt(2)
        XCTAssertEqual(tracker.update([waiting]), ["fixture"])
    }
}
