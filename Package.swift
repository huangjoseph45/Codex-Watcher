// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SessionScout",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SessionScout", targets: ["SessionScout"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "SessionMonitor", dependencies: ["CSQLite"], resources: [.copy("Resources/config.json")]),
        .executableTarget(name: "SessionScout", dependencies: ["SessionMonitor"],
                          resources: [.copy("Resources/quit.svg"), .copy("Resources/scout.svg")]),
        .testTarget(name: "SessionMonitorTests", dependencies: ["SessionMonitor", "CSQLite"])
    ]
)
