import Foundation

/// An asynchronous question needs its original client, not an approval response.
public struct ReviewQuestion: Sendable, Equatable {
    public let id: String
    public let text: String

    static func latest(in response: [String: Any], threadID: String) -> Self? {
        guard let turn = (response["data"] as? [[String: Any]])?.first,
              !["failed", "interrupted"].contains(turn["status"] as? String ?? ""),
              let items = turn["items"] as? [[String: Any]] else { return nil }
        for item in items.reversed() {
            // Later user input supersedes earlier clarification requests.
            if item["type"] as? String == "userMessage" { return nil }
            guard item["type"] as? String == "agentMessage",
                  let id = item["id"] as? String,
                  let questions = item["questions"] as? [[String: Any]], !questions.isEmpty else { continue }
            let titles = questions.compactMap { $0["title"] as? String }
            return Self(id: "question:\(threadID):\(id)",
                        text: titles.isEmpty ? "Codex has a question for you." : titles.joined(separator: "\n\n"))
        }
        return nil
    }
}

struct ReviewQuestionSnapshot {
    var questions: [String: ReviewQuestion] = [:]
    var checkedIDs: Set<String> = []
}

struct ReviewQuestionReader {
    let home: URL
    let timeoutMilliseconds: Int

    func read(ids: [String]) -> ReviewQuestionSnapshot {
        var snapshot = ReviewQuestionSnapshot()
        guard !ids.isEmpty else { return snapshot }
        do {
            let connection = try LocalWebSocket.connect(to: home.appendingPathComponent("app-server-control/app-server-control.sock"),
                                                        timeoutMilliseconds: timeoutMilliseconds)
            _ = try connection.request(id: 1, method: "initialize", params: [
                "clientInfo": ["name": "session_scout", "version": "0.1.0"]
            ])
            try connection.sendJSON(["method": "initialized"])
            for (index, id) in ids.enumerated() {
                // Read only the latest turn. Never resume or answer async questions.
                let result = try connection.request(id: index + 2, method: "thread/turns/list", params: [
                    "threadId": id, "limit": 1, "sortDirection": "desc", "itemsView": "full"
                ])
                snapshot.questions[id] = ReviewQuestion.latest(in: result, threadID: id)
                snapshot.checkedIDs.insert(id)
            }
        } catch {
            // Older servers and bounded read failures must not break session polling.
            // The caller retains an existing question until a successful check clears it.
        }
        return snapshot
    }
}
