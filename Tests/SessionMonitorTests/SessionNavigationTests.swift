import XCTest
@testable import SessionMonitor

final class SessionNavigationTests: XCTestCase {
    func testProjectLinkEncodesSpecialCharactersAsPath() throws {
        let path = "/tmp/My Project #1?local/雪"
        let session = CodexSession(id: "test", title: "Test", workingDirectory: path, source: "vscode")
        let url = try SessionNavigation.projectURL(for: session)
        XCTAssertEqual(url.scheme, "vscode")
        XCTAssertEqual(url.host, "file")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, path + "/")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
    }

    func testUnknownHostAndMissingOrRelativeFoldersAreRejected() {
        XCTAssertThrowsError(try SessionNavigation.projectURL(for:
            CodexSession(id: "test", title: "Test", workingDirectory: "/tmp/project", source: "cli")))
        XCTAssertThrowsError(try SessionNavigation.projectURL(for:
            CodexSession(id: "test", title: "Test", source: "vscode")))
        XCTAssertThrowsError(try SessionNavigation.projectURL(for:
            CodexSession(id: "test", title: "Test", workingDirectory: "relative/project", source: "vscode")))
    }
}
