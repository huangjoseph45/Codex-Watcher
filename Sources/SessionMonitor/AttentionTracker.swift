import Foundation

/// Announces each waiting episode once. Unknown readings do not clear an episode.
public struct AttentionTracker {
    private var announced: [String: String] = [:]
    public init() {}

    public mutating func update(_ sessions: [CodexSession]) -> [String] {
        let activeIDs = Set(sessions.map(\.id))
        announced = announced.filter { activeIDs.contains($0.key) }
        var newIDs: [String] = []
        for session in sessions {
            guard session.activity.needsAttention else {
                if session.activity != .unknown { announced.removeValue(forKey: session.id) }
                continue
            }
            if session.pendingPrompt == nil, let previous = announced[session.id], !previous.hasPrefix("status:") { continue }
            let identity = session.pendingPrompt?.id ?? "status:\(session.activity.rawValue)"
            if announced[session.id] != identity {
                announced[session.id] = identity
                newIDs.append(session.id)
            }
        }
        return newIDs
    }
}
