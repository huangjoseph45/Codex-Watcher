import Foundation

public struct AppConfiguration: Codable, Sendable {
    public let refreshIntervalSeconds: Double
    public let refreshIntervalOptionsSeconds: [Double]?
    public let codexHome: String?
    public let databaseBusyTimeoutMilliseconds: Int32
    public let liveStatusTimeoutMilliseconds: Int?
    public let showMenuBarSessionCount: Bool?
    public let fontSize: Double?
    public let attention: AttentionConfiguration?
    public let sounds: SoundConfiguration?
    public let window: Window

    public var interfaceScale: Double { window.scale ?? Self.bundled.window.scale! }
    public var menuBarShowsCount: Bool { showMenuBarSessionCount ?? Self.bundled.showMenuBarSessionCount! }
    public var textSize: Double { fontSize ?? Self.bundled.fontSize! }
    public var statusTimeout: Int { liveStatusTimeoutMilliseconds ?? Self.bundled.liveStatusTimeoutMilliseconds! }
    public var attentionSettings: AttentionConfiguration { attention ?? Self.bundled.attention! }
    public var refreshOptions: [Double] { refreshIntervalOptionsSeconds ?? Self.bundled.refreshIntervalOptionsSeconds! }
    public var soundSettings: SoundConfiguration { sounds ?? Self.bundled.sounds! }

    public struct SoundConfiguration: Codable, Sendable {
        public let actionRequiredEnabled: Bool
        public let turnFinishedEnabled: Bool
        public let volume: Double
        public let volumeOptions: [Double]
    }

    public struct AttentionConfiguration: Codable, Sendable {
        public let enabled: Bool
        public let autoShowBubble: Bool
        public let bubbleWidth: Double
        public let requestTimeoutMilliseconds: Int
        public let notificationWidth: Double?
        public let notificationHeight: Double?
        public let autoDismissSeconds: Double?

        public var previewWidth: Double { notificationWidth ?? AppConfiguration.bundled.attention!.notificationWidth! }
        public var previewHeight: Double { notificationHeight ?? AppConfiguration.bundled.attention!.notificationHeight! }
        public var dismissalDelay: Double { autoDismissSeconds ?? AppConfiguration.bundled.attention!.autoDismissSeconds! }
    }

    public struct Window: Codable, Sendable {
        public let width: Double
        public let height: Double
        public let minimumWidth: Double
        public let minimumHeight: Double
        public let scale: Double?
    }

    // The checked-in JSON is the single source of default settings.
    public static let bundled: AppConfiguration = {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "json")
                ?? Bundle.module.url(forResource: "config", withExtension: "json"),
              let config = try? read(from: url),
              config.window.scale != nil, config.showMenuBarSessionCount != nil, config.fontSize != nil,
              config.liveStatusTimeoutMilliseconds != nil,
              config.attention?.notificationWidth != nil, config.attention?.notificationHeight != nil,
              config.attention?.autoDismissSeconds != nil, config.refreshIntervalOptionsSeconds != nil,
              config.sounds != nil else {
            fatalError("The bundled config.json is missing or invalid.")
        }
        return config
    }()

    public static var userConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SessionScout/config.json")
    }

    public static var legacyUserConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexWatcher/config.json")
    }

    public static func read(from url: URL) throws -> AppConfiguration {
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        if let sounds = config.sounds {
            guard sounds.volume.isFinite, (0...1).contains(sounds.volume), !sounds.volumeOptions.isEmpty,
                  sounds.volumeOptions.count <= 12, Set(sounds.volumeOptions).count == sounds.volumeOptions.count,
                  sounds.volumeOptions.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ConfigurationError() }
        }
        if let intervals = config.refreshIntervalOptionsSeconds {
            guard !intervals.isEmpty, intervals.count <= 12, Set(intervals).count == intervals.count,
                  intervals.allSatisfy({ $0.isFinite && (1...3600).contains($0) }) else { throw ConfigurationError() }
        }
        if let alert = config.attention {
            guard alert.bubbleWidth.isFinite, (300...700).contains(alert.bubbleWidth),
                  alert.notificationWidth.map({ $0.isFinite && (260...500).contains($0) }) ?? true,
                  alert.notificationHeight.map({ $0.isFinite && (120...240).contains($0) }) ?? true,
                  alert.autoDismissSeconds.map({ $0.isFinite && (2...30).contains($0) }) ?? true,
                  (100...10_000).contains(alert.requestTimeoutMilliseconds) else {
                throw ConfigurationError()
            }
        }
        guard config.refreshIntervalSeconds.isFinite, config.refreshIntervalSeconds >= 1,
              config.databaseBusyTimeoutMilliseconds >= 0,
              config.liveStatusTimeoutMilliseconds.map({ (100...10_000).contains($0) }) ?? true,
              config.fontSize.map({ $0.isFinite && (10...24).contains($0) }) ?? true,
              config.window.minimumWidth.isFinite, config.window.minimumWidth > 0,
              config.window.minimumHeight.isFinite, config.window.minimumHeight > 0,
              config.window.width.isFinite, config.window.width >= config.window.minimumWidth,
              config.window.height.isFinite, config.window.height >= config.window.minimumHeight,
              config.window.scale.map({ $0.isFinite && (0.5...1.5).contains($0) }) ?? true,
              config.codexHome.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true else {
            throw ConfigurationError()
        }
        return config
    }
}

private struct ConfigurationError: LocalizedError {
    var errorDescription: String? {
        "Config values are invalid. Refresh must be at least 1 second, database timeout must be nonnegative, and live status timeout must be between 100 and 10000 milliseconds. Window dimensions must be positive with default dimensions at least their minimums. Window scale must be between 0.5 and 1.5, and font size between 10 and 24 points. Codex home must be null or a nonempty path."
    }
}
