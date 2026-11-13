import XCTest
@testable import SessionMonitor

final class AppConfigurationTests: XCTestCase {
    private func read(_ modify: (inout [String: Any]) -> Void) throws -> AppConfiguration {
        let data = try JSONEncoder().encode(AppConfiguration.bundled)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        modify(&json)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return try AppConfiguration.read(from: url)
    }

    func testCustomSettingsLoad() throws {
        let config = try read {
            $0["refreshIntervalSeconds"] = 30.5
            $0["codexHome"] = "/tmp/custom-codex"
            $0["databaseBusyTimeoutMilliseconds"] = 500
        }
        XCTAssertEqual(config.refreshIntervalSeconds, 30.5)
        XCTAssertEqual(config.codexHome, "/tmp/custom-codex")
        XCTAssertEqual(config.databaseBusyTimeoutMilliseconds, 500)
    }

    func testInvalidSettingsAreRejected() {
        XCTAssertThrowsError(try read { $0["refreshIntervalSeconds"] = 0 })
        XCTAssertThrowsError(try read { $0["refreshIntervalOptionsSeconds"] = [0, 1] })
        XCTAssertThrowsError(try read { $0["refreshIntervalOptionsSeconds"] = [1, 1] })
        XCTAssertThrowsError(try read {
            var sounds = $0["sounds"] as! [String: Any]
            sounds["volume"] = 1.1
            $0["sounds"] = sounds
        })
        XCTAssertThrowsError(try read { $0["databaseBusyTimeoutMilliseconds"] = -1 })
        XCTAssertThrowsError(try read { $0["liveStatusTimeoutMilliseconds"] = 0 })
        XCTAssertThrowsError(try read { $0["codexHome"] = " " })
        XCTAssertThrowsError(try read {
            $0["window"] = ["width": 100, "height": 100, "minimumWidth": 620, "minimumHeight": 400]
        })
    }

    func testMalformedSettingsAreRejected() {
        XCTAssertThrowsError(try read { $0["refreshIntervalSeconds"] = "fifteen" })
        XCTAssertThrowsError(try read { $0.removeValue(forKey: "window") })
    }

    func testAttentionSettingsValidation() {
        XCTAssertThrowsError(try read {
            var alert = $0["attention"] as! [String: Any]
            alert["requestTimeoutMilliseconds"] = 0
            $0["attention"] = alert
        })
        XCTAssertThrowsError(try read {
            var alert = $0["attention"] as! [String: Any]
            alert["autoDismissSeconds"] = 0
            $0["attention"] = alert
        })
    }

    func testOlderAttentionConfigUsesCompactDefaults() throws {
        let config = try read {
            var alert = $0["attention"] as! [String: Any]
            for key in ["notificationWidth", "notificationHeight", "autoDismissSeconds"] { alert.removeValue(forKey: key) }
            $0["attention"] = alert
        }
        XCTAssertEqual(config.attentionSettings.previewWidth, AppConfiguration.bundled.attentionSettings.previewWidth)
        XCTAssertEqual(config.attentionSettings.dismissalDelay, AppConfiguration.bundled.attentionSettings.dismissalDelay)
    }

    func testScaleValidationAndOlderConfigCompatibility() throws {
        let legacy = try read {
            var window = $0["window"] as! [String: Any]
            window.removeValue(forKey: "scale")
            $0["window"] = window
            $0.removeValue(forKey: "showMenuBarSessionCount")
        }
        XCTAssertEqual(legacy.interfaceScale, AppConfiguration.bundled.interfaceScale)
        XCTAssertEqual(legacy.menuBarShowsCount, AppConfiguration.bundled.menuBarShowsCount)
        XCTAssertThrowsError(try read {
            var window = $0["window"] as! [String: Any]
            window["scale"] = 0
            $0["window"] = window
        })
    }
}
