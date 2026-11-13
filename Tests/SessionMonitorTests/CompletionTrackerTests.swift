import XCTest
@testable import SessionMonitor

final class CompletionTrackerTests: XCTestCase {
    private func session(_ activity: SessionActivity, updated: TimeInterval = 1) -> CodexSession {
        CodexSession(id: "fixture", title: "Fixture", updatedAt: Date(timeIntervalSince1970: updated), activity: activity)
    }

    func testIdleStartupSeedsWithoutNotifyingAndDoesNotRepeat() {
        var tracker = CompletionTracker()
        let first = tracker.update([session(.idle)])
        XCTAssertEqual(first.map(\.threadID), ["fixture"])
        XCTAssertEqual(first.map(\.shouldNotify), [false])
        XCTAssertEqual(tracker.update([session(.idle)]), [])
    }

    func testWorkingAndWaitingToIdleAreCandidatesDespiteUnknownGap() {
        for running in [SessionActivity.working, .waitingForInput, .waitingForApproval] {
            var tracker = CompletionTracker()
            XCTAssertEqual(tracker.update([session(running)]), [])
            XCTAssertEqual(tracker.update([session(.unknown)]), [])
            XCTAssertEqual(tracker.update([session(.idle)]).map(\.shouldNotify), [true])
            XCTAssertEqual(tracker.update([session(.idle)]), [])
        }
    }

    func testFastTurnBetweenPollsCanBeCheckedWhenMetadataChanges() {
        var tracker = CompletionTracker()
        _ = tracker.update([session(.idle, updated: 1)])
        XCTAssertEqual(tracker.update([session(.idle, updated: 2)]).map(\.shouldNotify), [true])
        XCTAssertEqual(tracker.update([session(.idle, updated: 2)]), [])
    }

    func testOnlySuccessfulLatestTurnIsReported() {
        for status in ["failed", "interrupted", "inProgress"] {
            XCTAssertNil(CompletedTurnReader.completedTurnID(in: ["data": [["id": "turn", "status": status], ["id": "old", "status": "completed"]]]))
        }
        XCTAssertEqual(CompletedTurnReader.completedTurnID(in: ["data": [["id": "turn", "status": "completed"]]]), "turn")
        XCTAssertNil(CompletedTurnReader.completedTurnID(in: ["data": []]))
    }

    func testLiveTurnStatusReadWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["CODEX_WATCHER_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_WATCHER_LIVE_TEST=1 to verify the live turn-status endpoint.")
        }
        guard let session = try SessionScanner().scan().sessions.first else { throw XCTSkip("No active sessions.") }
        let reader = CompletedTurnReader(home: SessionScanner.defaultHome, timeoutMilliseconds: AppConfiguration.bundled.statusTimeout)
        XCTAssertNoThrow(try reader.latestCompletedTurnID(threadID: session.id))
    }
}
