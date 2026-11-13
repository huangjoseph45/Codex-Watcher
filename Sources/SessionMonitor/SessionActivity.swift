import Foundation

public enum SessionActivity: String, Sendable {
    case working, idle, waitingForInput, waitingForApproval, systemError, unknown

    public var needsAttention: Bool { self == .waitingForInput || self == .waitingForApproval }

    public var label: String {
        switch self {
        case .working: "Working"
        case .idle: "Idle"
        case .waitingForInput: "Needs input"
        case .waitingForApproval: "Approval"
        case .systemError: "Error"
        case .unknown: "Unknown"
        }
    }

    public var explanation: String {
        switch self {
        case .working: "Codex is running a turn."
        case .idle: "No turn is running; ready for the next prompt."
        case .waitingForInput: "Codex has paused to request user input."
        case .waitingForApproval: "Codex is waiting for an approval decision."
        case .systemError: "Codex reports a session error."
        case .unknown: "Live status is unavailable from the running Codex server."
        }
    }

    static func parse(_ status: [String: Any]) -> Self {
        switch status["type"] as? String {
        case "idle": return .idle
        case "systemError": return .systemError
        case "active":
            guard let flags = status["activeFlags"] as? [String] else { return .unknown }
            if flags.contains("waitingOnApproval") { return .waitingForApproval }
            if flags.contains("waitingOnUserInput") { return .waitingForInput }
            return .working
        default: return .unknown
        }
    }
}

struct LiveStatusSnapshot {
    var statuses: [String: SessionActivity] = [:]
    var notice: String?
}

struct LiveStatusReader {
    let home: URL
    let timeoutMilliseconds: Int

    func read(ids: [String]) -> LiveStatusSnapshot {
        var snapshot = LiveStatusSnapshot()
        do {
            let socket = home.appendingPathComponent("app-server-control/app-server-control.sock")
            let connection = try LocalWebSocket.connect(to: socket, timeoutMilliseconds: timeoutMilliseconds)
            _ = try connection.request(id: 1, method: "initialize", params: [
                "clientInfo": ["name": "codex_watcher", "version": "0.1.0"]
            ])
            try connection.sendJSON(["method": "initialized"])
            for (offset, id) in ids.enumerated() {
                // Metadata-only reads do not resume, subscribe to, or acknowledge a thread.
                let response = try connection.request(id: offset + 2, method: "thread/read",
                                                      params: ["threadId": id, "includeTurns": false])
                if let thread = response["thread"] as? [String: Any],
                   let status = thread["status"] as? [String: Any] {
                    snapshot.statuses[id] = SessionActivity.parse(status)
                }
            }
        } catch {
            snapshot.notice = "Live status unavailable: \(error.localizedDescription)"
        }
        if snapshot.notice == nil, ids.contains(where: { snapshot.statuses[$0] == nil || snapshot.statuses[$0] == .unknown }) {
            snapshot.notice = "Some sessions have no live status in the local Codex server."
        }
        return snapshot
    }
}
