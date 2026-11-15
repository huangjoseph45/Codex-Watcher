import Foundation
import Darwin
import CSQLite

public struct CodexSession: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var workingDirectory: String?
    public var source: String?
    public var updatedAt: Date?
    public var activity: SessionActivity = .unknown
    public var pendingPrompt: PendingPrompt?
    public var promptNotice: String?
    public var reviewQuestion: ReviewQuestion?
    public var reviewQuestionChecked = false

    public var needsAttention: Bool { activity.needsAttention || reviewQuestion != nil }
    public var attentionIdentity: String? { pendingPrompt?.id ?? reviewQuestion?.id }
}

public struct SessionSnapshot: Sendable {
    public let sessions: [CodexSession]
    public let notice: String?
}

public struct SessionScanner: Sendable {
    public let home: URL
    public let configuration: AppConfiguration

    public init(home: URL = SessionScanner.defaultHome, configuration: AppConfiguration = .bundled) {
        self.home = home
        self.configuration = configuration
    }

    public static var defaultHome: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public func scan() throws -> SessionSnapshot {
        let directory = home.appendingPathComponent("thread-writer-locks")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return SessionSnapshot(sessions: [], notice: "No session lock directory found. Start a local session with a current version of Codex, or choose its Codex home folder.")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var sessions: [CodexSession] = []
        for file in files where file.pathExtension == "lock" {
            let id = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil, try isHeld(file) else { continue }
            sessions.append(CodexSession(id: id, title: "Untitled session"))
        }
        guard !sessions.isEmpty else { return SessionSnapshot(sessions: [], notice: nil) }
        var notice: String?
        do {
            let metadata = try loadMetadata(ids: sessions.map(\.id))
            sessions = sessions.map { metadata[$0.id] ?? $0 }
        } catch {
            notice = "Active sessions detected, but their details are unavailable: \(error.localizedDescription)"
        }
        let live = LiveStatusReader(home: home, timeoutMilliseconds: configuration.statusTimeout)
            .read(ids: sessions.map(\.id))
        for index in sessions.indices {
            sessions[index].activity = live.statuses[sessions[index].id] ?? .unknown
            if configuration.attentionSettings.enabled, sessions[index].activity.needsAttention {
                do {
                    sessions[index].pendingPrompt = try PromptClient(home: home,
                        timeoutMilliseconds: configuration.attentionSettings.requestTimeoutMilliseconds)
                        .fetch(threadID: sessions[index].id)
                    if sessions[index].pendingPrompt == nil {
                        sessions[index].promptNotice = "The pending prompt is unavailable here. Open the session to respond."
                    }
                } catch {
                    sessions[index].promptNotice = "Couldn’t retrieve this prompt. Open the session to review it."
                }
            }
        }
        if configuration.attentionSettings.enabled {
            let candidates = sessions.filter { $0.activity == .working || $0.activity == .idle }.map(\.id)
            let questions = ReviewQuestionReader(home: home, timeoutMilliseconds: configuration.statusTimeout).read(ids: candidates)
            for index in sessions.indices {
                sessions[index].reviewQuestion = questions.questions[sessions[index].id]
                sessions[index].reviewQuestionChecked = questions.checkedIDs.contains(sessions[index].id)
            }
        }
        if let statusNotice = live.notice {
            notice = [notice, statusNotice].compactMap { $0 }.joined(separator: "\n")
        }
        sessions.sort {
            if $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            return $0.id < $1.id
        }
        return SessionSnapshot(sessions: sessions, notice: notice)
    }

    private func isHeld(_ file: URL) throws -> Bool {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return false } // A session closed during this scan.
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        // A shared, nonblocking probe conflicts with Codex's exclusive writer lock.
        // Never create, remove, or alter a Codex file.
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        let code = errno
        if code == EWOULDBLOCK || code == EAGAIN { return true }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private func loadMetadata(ids: [String]) throws -> [String: CodexSession] {
        let files = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        let candidates = files.compactMap { url -> (URL, Int)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("state_"),
                  let version = Int(name.dropFirst(6)) else { return nil }
            return (url, version)
        }.sorted { $0.1 > $1.1 }
        guard let databaseURL = candidates.first?.0 else { throw ScanError("No Codex state database found.") }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK, let database else { throw ScanError("Cannot read the Codex state database.") }
        sqlite3_busy_timeout(database, configuration.databaseBusyTimeoutMilliseconds)
        var statement: OpaquePointer?
        let sql = "SELECT id, title, cwd, source, updated_at FROM threads WHERE id = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ScanError("Unsupported Codex database schema.")
        }
        defer { sqlite3_finalize(statement) }
        func string(_ column: Int32) -> String? {
            guard let value = sqlite3_column_text(statement, column) else { return nil }
            let text = String(cString: value)
            return text.isEmpty ? nil : text
        }
        var sessions: [String: CodexSession] = [:]
        for id in ids {
            sqlite3_reset(statement)
            let status = id.withCString { pointer in
                sqlite3_bind_text(statement, 1, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard status == SQLITE_OK else { throw ScanError("Cannot query session details.") }
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                sessions[id] = CodexSession(id: id, title: string(1) ?? "Untitled session",
                    workingDirectory: string(2), source: string(3),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))
            } else if step != SQLITE_DONE {
                throw ScanError("Cannot read session details while the database is busy.")
            }
        }
        return sessions
    }
}

private struct ScanError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
