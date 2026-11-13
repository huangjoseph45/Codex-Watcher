import Foundation

public enum SessionNavigation {
    /// VS Code routes project links to the window for that folder.
    /// A daemon's writer PID is not the terminal client, so never activate it.
    public static func projectURL(for session: CodexSession) throws -> URL {
        guard session.source?.lowercased() == "vscode" else {
            throw NavigationError("Window switching currently supports VS Code sessions. This session does not provide a supported window reference.")
        }
        guard let directory = session.workingDirectory, !directory.isEmpty else {
            throw NavigationError("This session has no working folder to locate its VS Code window.")
        }
        let path = NSString(string: directory).expandingTildeInPath
        guard NSString(string: path).isAbsolutePath else {
            throw NavigationError("The session’s working folder must be an absolute path.")
        }
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "file"
        components.path = path.hasSuffix("/") ? path : path + "/"
        guard let url = components.url else {
            throw NavigationError("Couldn’t create a link to this session’s working folder.")
        }
        return url
    }
}

private struct NavigationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
