import Foundation
import CryptoKit

public enum PromptRequestID: Sendable, Equatable {
    case integer(Int64), string(String)
    init?(_ value: Any?) {
        if let string = value as? String { self = .string(string) }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { self = .integer(number.int64Value) }
        else { return nil }
    }
    var json: Any {
        switch self { case .integer(let id): id; case .string(let id): id }
    }
}

public struct PendingPrompt: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable { case commandApproval, fileApproval, userInput, unsupported }
    public struct Question: Sendable, Equatable, Identifiable {
        public struct Option: Sendable, Equatable {
            public let label: String
            public let description: String
        }
        public let id: String
        public let header: String
        public let text: String
        public let options: [Option]
        public let allowsOther: Bool
        public let isSecret: Bool
    }
    public let id: String
    public let requestID: PromptRequestID
    public let threadID: String
    public let kind: Kind
    public let reason: String?
    public let command: String?
    public let workingDirectory: String?
    public let questions: [Question]

    public var canApproveHere: Bool { kind == .commandApproval && command?.isEmpty == false }

    static func parse(_ message: [String: Any], threadID: String) -> Self? {
        guard let method = message["method"] as? String, let requestID = PromptRequestID(message["id"]),
              let params = message["params"] as? [String: Any], params["threadId"] as? String == threadID,
              let canonical = try? JSONSerialization.data(withJSONObject:
                ["id": requestID.json, "method": method, "params": params], options: [.sortedKeys]) else { return nil }
        let kind: Kind
        switch method {
        case "item/commandExecution/requestApproval": kind = .commandApproval
        case "item/fileChange/requestApproval": kind = .fileApproval
        case "item/tool/requestUserInput": kind = .userInput
        default: kind = .unsupported
        }
        if kind != .unsupported {
            guard let turn = params["turnId"] as? String, !turn.isEmpty,
                  let item = params["itemId"] as? String, !item.isEmpty else { return nil }
        }
        let rawQuestions = params["questions"] as? [[String: Any]] ?? []
        let questions = rawQuestions.compactMap { question -> Question? in
            guard let id = question["id"] as? String, let text = question["question"] as? String else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> Question.Option? in
                guard let label = option["label"] as? String else { return nil }
                return Question.Option(label: label, description: option["description"] as? String ?? "")
            }
            return Question(id: id, header: question["header"] as? String ?? "Question", text: text, options: options,
                            allowsOther: question["isOther"] as? Bool ?? false,
                            isSecret: question["isSecret"] as? Bool ?? false)
        }
        // Malformed question sets must never allow a partial answer.
        let validQuestions = questions.count == rawQuestions.count && Set(questions.map(\.id)).count == questions.count
        return Self(id: SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined(),
                    requestID: requestID, threadID: threadID,
                    kind: kind == .userInput && !validQuestions ? .unsupported : kind,
                    reason: params["reason"] as? String, command: params["command"] as? String,
                    workingDirectory: params["cwd"] as? String, questions: questions)
    }

    public func accepts(_ answers: [String: String]) -> Bool {
        guard kind == .userInput, !questions.isEmpty, Set(answers.keys) == Set(questions.map(\.id)) else { return false }
        return questions.allSatisfy { question in
            guard let answer = answers[question.id], !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return question.options.isEmpty || question.allowsOther || question.options.contains { $0.label == answer }
        }
    }

    func response(for resolution: PromptResolution) throws -> [String: Any] {
        let result: [String: Any]
        switch resolution {
        case .approval(let decision):
            guard kind == .commandApproval || kind == .fileApproval,
                  decision != .accept || canApproveHere else { throw PromptError("Open this session to review the full request.") }
            result = ["decision": decision.rawValue]
        case .answers(let answers):
            guard accepts(answers) else { throw PromptError("Answer every question using a valid choice or response.") }
            result = ["answers": answers.mapValues { ["answers": [$0]] }]
        }
        return ["id": requestID.json, "result": result]
    }
}

public enum PromptResolution: Sendable {
    public enum Approval: String, Sendable { case accept, decline, cancel }
    case approval(Approval)
    case answers([String: String])
}

public enum PromptReplyOutcome: Sendable { case confirmed, sent }

public struct PromptClient: Sendable {
    public let home: URL
    public let timeoutMilliseconds: Int
    public init(home: URL, timeoutMilliseconds: Int) { self.home = home; self.timeoutMilliseconds = timeoutMilliseconds }

    func fetch(threadID: String) throws -> PendingPrompt? {
        let connection = try connect()
        return try replay(threadID: threadID, connection: connection)
    }

    public func resolve(_ expected: PendingPrompt, with resolution: PromptResolution) throws -> PromptReplyOutcome {
        let connection = try connect()
        return try resolve(expected, with: resolution, connection: connection)
    }

    func resolve(_ expected: PendingPrompt, with resolution: PromptResolution,
                 connection: LocalWebSocket) throws -> PromptReplyOutcome {
        guard let current = try replay(threadID: expected.threadID, connection: connection, matching: expected.id), current.id == expected.id else {
            throw PromptError("This prompt changed or was already answered. Refresh or open the session.")
        }
        try connection.sendJSON(current.response(for: resolution))
        // A response has no JSON-RPC acknowledgement; wait for Codex's resolved event.
        // Once sent, never retry automatically, even if the confirmation is lost.
        do {
            while true {
                let message = try connection.receiveJSON()
                guard message["method"] as? String == "serverRequest/resolved",
                      let params = message["params"] as? [String: Any],
                      params["threadId"] as? String == current.threadID,
                      PromptRequestID(params["requestId"]) == current.requestID else { continue }
                return .confirmed
            }
        } catch { return .sent }
    }

    private func connect() throws -> LocalWebSocket {
        let connection = try LocalWebSocket.connect(to: home.appendingPathComponent("app-server-control/app-server-control.sock"),
                                                     timeoutMilliseconds: timeoutMilliseconds)
        _ = try connection.request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "codex_watcher", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true, "requiredHumanApproval": true]
        ])
        try connection.sendJSON(["method": "initialized"])
        return connection
    }

    func replay(threadID: String, connection: LocalWebSocket, matching identity: String? = nil) throws -> PendingPrompt? {
        let metadata = try connection.request(id: 2, method: "thread/read", params: ["threadId": threadID, "includeTurns": false])
        guard let thread = metadata["thread"] as? [String: Any], let status = thread["status"] as? [String: Any],
              SessionActivity.parse(status).needsAttention else { return nil }
        var inbox = PromptInbox(threadID: threadID)
        // Attach to the existing waiting runtime, without changing its settings or starting a turn.
        _ = try connection.request(id: 3, method: "thread/resume", params: ["threadId": threadID, "excludeTurns": true]) {
            inbox.ingest($0)
        }
        func matchingPrompt() -> PendingPrompt? {
            if let identity { return inbox.pending.first { $0.id == identity } }
            return inbox.first
        }
        while matchingPrompt() == nil {
            inbox.ingest(try connection.receiveJSON())
            if inbox.finished { return nil }
        }
        return matchingPrompt()
    }
}

struct PromptInbox {
    let threadID: String
    var pending: [PendingPrompt] = []
    var finished = false
    var first: PendingPrompt? { pending.first }
    mutating func ingest(_ message: [String: Any]) {
        if let prompt = PendingPrompt.parse(message, threadID: threadID) {
            pending.removeAll { $0.requestID == prompt.requestID }
            pending.append(prompt)
        } else if let params = message["params"] as? [String: Any], params["threadId"] as? String == threadID {
            if message["method"] as? String == "serverRequest/resolved", let id = PromptRequestID(params["requestId"]) {
                pending.removeAll { $0.requestID == id }
            }
            if message["method"] as? String == "thread/status/changed", let status = params["status"] as? [String: Any],
               !SessionActivity.parse(status).needsAttention {
                pending = []; finished = true
            }
        }
    }
}

struct PromptError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
