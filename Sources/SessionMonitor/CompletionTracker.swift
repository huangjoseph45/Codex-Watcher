import Foundation

public struct CompletionTracker {
    public struct Check: Sendable, Equatable {
        public let threadID: String
        public let shouldNotify: Bool
    }
    private struct Observation {
        let activity: SessionActivity
        let updatedAt: Date?
    }
    private var previous: [String: Observation] = [:]
    public init() {}

    /// Idle is only a candidate: the caller confirms the latest turn completed successfully.
    public mutating func update(_ sessions: [CodexSession]) -> [Check] {
        let active = Set(sessions.map(\.id))
        previous = previous.filter { active.contains($0.key) }
        var candidates: [Check] = []
        for session in sessions where session.activity != .unknown {
            if session.activity == .idle {
                if let old = previous[session.id] {
                    let finished = old.activity == .working || old.activity.needsAttention
                    let updated = session.updatedAt != nil && session.updatedAt != old.updatedAt
                    if finished || updated { candidates.append(Check(threadID: session.id, shouldNotify: true)) }
                } else {
                    // Seed an idle session's latest turn without announcing old work.
                    candidates.append(Check(threadID: session.id, shouldNotify: false))
                }
            }
            previous[session.id] = Observation(activity: session.activity, updatedAt: session.updatedAt)
        }
        return candidates
    }
}

public struct CompletedTurnReader: Sendable {
    public let home: URL
    public let timeoutMilliseconds: Int
    public init(home: URL, timeoutMilliseconds: Int) { self.home = home; self.timeoutMilliseconds = timeoutMilliseconds }

    public func latestCompletedTurnID(threadID: String) throws -> String? {
        let connection = try LocalWebSocket.connect(to: home.appendingPathComponent("app-server-control/app-server-control.sock"),
                                                    timeoutMilliseconds: timeoutMilliseconds)
        _ = try connection.request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "session_scout", "version": "0.1.0"]
        ])
        try connection.sendJSON(["method": "initialized"])
        let result = try connection.request(id: 2, method: "thread/turns/list", params: [
            "threadId": threadID, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"
        ])
        return Self.completedTurnID(in: result)
    }

    static func completedTurnID(in response: [String: Any]) -> String? {
        guard let turns = response["data"] as? [[String: Any]], let latest = turns.first,
              latest["status"] as? String == "completed" else { return nil }
        guard let id = latest["id"] as? String, !id.isEmpty else { return nil }
        return id
    }
}
