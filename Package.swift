// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexWatcher",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexWatcher", targets: ["CodexWatcher"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "SessionMonitor", dependencies: ["CSQLite"], resources: [.copy("Resources/config.json")]),
        .executableTarget(name: "CodexWatcher", dependencies: ["SessionMonitor"],
                          resources: [.copy("Resources/quit.svg")]),
        .testTarget(name: "SessionMonitorTests", dependencies: ["SessionMonitor", "CSQLite"])
    ]
)
