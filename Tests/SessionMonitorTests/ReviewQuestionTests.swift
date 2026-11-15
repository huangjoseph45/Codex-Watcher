import XCTest
@testable import SessionMonitor

final class ReviewQuestionTests: XCTestCase {
    private func message(_ id: String = "question-1") -> [String: Any] {
        ["type": "agentMessage", "id": id, "delivery": "async", "text": "Choose a design",
         "questions": [["title": "Which design do you prefer?", "options": ["Warm", "Neutral"]]]]
    }

    private func response(_ items: [[String: Any]], status: String = "inProgress") -> [String: Any] {
        ["data": [["id": "turn", "status": status, "items": items]]]
    }

    func testQuestionDuringRunningOrCompletedTurnIsReviewable() throws {
        for status in ["inProgress", "completed"] {
            let result = response([message(), ["type": "agentMessage", "id": "progress", "text": "Still working"]], status: status)
            let question = try XCTUnwrap(ReviewQuestion.latest(in: result, threadID: "session"))
            XCTAssertEqual(question.text, "Which design do you prefer?")
            var session = CodexSession(id: "session", title: "Design", activity: .working)
            session.reviewQuestion = question
            XCTAssertTrue(session.needsAttention)
            XCTAssertEqual(session.activity, .working) // Asking asynchronously does not stop the model.
            var tracker = AttentionTracker()
            XCTAssertEqual(tracker.update([session]), ["session"])
            XCTAssertEqual(tracker.update([session]), [])
            session.reviewQuestion = ReviewQuestion.latest(in: response([message("question-2")]), threadID: "session")
            XCTAssertEqual(tracker.update([session]), ["session"])
            session.reviewQuestion = nil
            XCTAssertEqual(tracker.update([session]), [])
        }
    }

    func testLaterUserInputOrNewTurnClearsOldQuestion() {
        XCTAssertNil(ReviewQuestion.latest(in: response([message(), ["type": "userMessage", "id": "answer"]]), threadID: "session"))
        XCTAssertNil(ReviewQuestion.latest(in: response([["type": "userMessage", "id": "next-turn"]]), threadID: "session"))
        XCTAssertNil(ReviewQuestion.latest(in: response([message()], status: "interrupted"), threadID: "session"))
        XCTAssertNil(ReviewQuestion.latest(in: response([message()], status: "failed"), threadID: "session"))
    }

    func testOrdinaryProseAndUnknownFormatsAreNotGuessedAsQuestions() {
        XCTAssertNil(ReviewQuestion.latest(in: response([["type": "agentMessage", "id": "prose", "text": "Any thoughts?"]]), threadID: "session"))
        XCTAssertNil(ReviewQuestion.latest(in: ["data": []], threadID: "session"))
        XCTAssertNil(ReviewQuestion.latest(in: ["future": "format"], threadID: "session"))
    }
}
