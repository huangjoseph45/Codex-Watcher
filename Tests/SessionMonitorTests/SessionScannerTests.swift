import XCTest
import Darwin
import CSQLite
@testable import SessionMonitor

final class SessionScannerTests: XCTestCase {
    private var home: URL!
    private let activeID = "01a1d583-1c5b-7750-b901-61cf479e4d5c"
    private let staleID = "01a108de-e68c-78a1-b7f3-e2a96ac6f8ef"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("thread-writer-locks"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func lockFile(_ id: String, held: Bool) throws -> Int32 {
        let path = home.appendingPathComponent("thread-writer-locks/\(id).lock").path
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        if held { XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0) }
        return fd
    }

    private func createDatabase() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, cwd TEXT, source TEXT, updated_at INTEGER);
            INSERT INTO threads VALUES ('\(activeID)', 'Build a macOS app', '/tmp/project', 'cli', 1700000000);
            INSERT INTO threads VALUES ('\(staleID)', 'Old session', '/tmp/old', 'cli', 1700000001);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testOnlyHeldLocksAreActiveAndMetadataIsLoaded() throws {
        try createDatabase()
        let active = try lockFile(activeID, held: true)
        let stale = try lockFile(staleID, held: false)
        let coordination = try lockFile(".coordination", held: true)
        defer { close(active); close(stale); close(coordination) }
        let snapshot = try SessionScanner(home: home).scan()
        XCTAssertTrue(snapshot.notice?.contains("Live status unavailable") == true)
        XCTAssertEqual(snapshot.sessions.first?.activity, .unknown)
        XCTAssertEqual(snapshot.sessions.map(\.id), [activeID])
        XCTAssertEqual(snapshot.sessions.first?.title, "Build a macOS app")
        XCTAssertEqual(snapshot.sessions.first?.workingDirectory, "/tmp/project")
        XCTAssertEqual(snapshot.sessions.first?.source, "cli")
        XCTAssertEqual(snapshot.sessions.first?.updatedAt, Date(timeIntervalSince1970: 1700000000))
        // A release must disappear even when the file remains on disk.
        XCTAssertEqual(flock(active, LOCK_UN), 0)
        XCTAssertTrue(try SessionScanner(home: home).scan().sessions.isEmpty)
    }

    func testMissingDatabasePreservesActiveSessions() throws {
        let active = try lockFile(activeID, held: true)
        defer { close(active) }
        let snapshot = try SessionScanner(home: home).scan()
        XCTAssertEqual(snapshot.sessions.map(\.id), [activeID])
        XCTAssertNotNil(snapshot.notice)
    }

    func testUnsupportedDatabasePreservesActiveSessions() throws {
        let active = try lockFile(activeID, held: true)
        defer { close(active) }
        FileManager.default.createFile(atPath: home.appendingPathComponent("state_9.sqlite").path, contents: Data())
        let snapshot = try SessionScanner(home: home).scan()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertTrue(snapshot.notice?.contains("Unsupported") == true)
    }

    func testEmptyAndMissingHomes() throws {
        let snapshot = try SessionScanner(home: home).scan()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertNil(snapshot.notice)
        let missing = try SessionScanner(home: home.appendingPathComponent("missing")).scan()
        XCTAssertTrue(missing.sessions.isEmpty)
        XCTAssertNotNil(missing.notice)
    }

    func testLocalSessionSmokeCheckWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["CODEX_WATCHER_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_WATCHER_LIVE_TEST=1 to inspect local active sessions.")
        }
        let snapshot = try SessionScanner().scan()
        print("Live scan: \(snapshot.sessions.count) active session(s)")
        for session in snapshot.sessions { print("Session \(session.id): \(session.activity.label)") }
        XCTAssertNil(snapshot.notice)
        XCTAssertTrue(snapshot.sessions.allSatisfy { $0.activity != .unknown })
        for session in snapshot.sessions where session.activity.needsAttention {
            XCTAssertNotNil(session.pendingPrompt, session.promptNotice ?? "Waiting requests must be readable from the local server.")
        }
        let questionCandidates = snapshot.sessions.filter { $0.activity == .working || $0.activity == .idle }
        XCTAssertTrue(questionCandidates.allSatisfy(\.reviewQuestionChecked), "Latest-turn question reads must work against the local server.")
    }

    func testLocalScannerPerformanceWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["CODEX_WATCHER_BENCHMARK"] == "1" else {
            throw XCTSkip("Set CODEX_WATCHER_BENCHMARK=1 to measure local scanning cost.")
        }
        var usage = rusage()
        func cpuTime() -> Double {
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let cpuStart = cpuTime()
        let wallStart = ProcessInfo.processInfo.systemUptime
        var sessionCount = 0
        var waitingCount = 0
        let count = 20
        for _ in 0..<count {
            let snapshot = try SessionScanner().scan()
            XCTAssertNil(snapshot.notice)
            sessionCount = snapshot.sessions.count
            waitingCount = snapshot.sessions.filter { $0.activity.needsAttention }.count
        }
        let wallMilliseconds = (ProcessInfo.processInfo.systemUptime - wallStart) * 1000 / Double(count)
        let cpuMilliseconds = (cpuTime() - cpuStart) * 1000 / Double(count)
        print(String(format: "Scanner benchmark: %d scans, %d sessions, %d waiting; mean wall %.2f ms, watcher CPU %.2f ms per scan (excludes Codex server CPU).", count, sessionCount, waitingCount, wallMilliseconds, cpuMilliseconds))
    }
}
