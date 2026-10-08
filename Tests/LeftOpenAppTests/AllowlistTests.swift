import Foundation
import XCTest
@testable import LeftOpenApp

final class AllowlistTests: XCTestCase {
    @MainActor
    func testCommaSeparatedEditingIsAtomicAndCanClearTheList() {
        let suite = "LeftOpenAllowlistTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.setIgnoredPorts(from: "4444,5555"))
        XCTAssertEqual(settings.ignoredPorts, [4444, 5555])
        XCTAssertTrue(settings.setIgnoredPorts(from: "5555，4444,5555 65535\n1,"))
        XCTAssertEqual(settings.ignoredPorts, [1, 4444, 5555, 65535])
        for invalid in ["3000,nope", "0", "65536", "-1", "3.5", "３０００"] {
            XCTAssertFalse(settings.setIgnoredPorts(from: invalid))
            XCTAssertEqual(settings.ignoredPorts, [1, 4444, 5555, 65535])
        }
        XCTAssertEqual(AppSettings(defaults: defaults).ignoredPorts, [1, 4444, 5555, 65535])
        XCTAssertTrue(settings.setIgnoredPorts(from: ""))
        XCTAssertEqual(AppSettings(defaults: defaults).ignoredPorts, [])
    }

    @MainActor
    func testRestoresLegacyPortsAndPersistsEdits() {
        let suite = "LeftOpenAllowlistTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([3000, 80, 3000, 0, 65536], forKey: "leftopen.ignoredPorts")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.ignoredPorts, [80, 3000])
        settings.addIgnoredPort(65535)
        settings.addIgnoredPort(1)
        settings.addIgnoredPort(3000)
        settings.addIgnoredPort(-1)
        settings.addIgnoredPort(65536)
        XCTAssertEqual(settings.ignoredPorts, [1, 80, 3000, 65535])
        settings.removeIgnoredPort(3000)
        XCTAssertEqual(AppSettings(defaults: defaults).ignoredPorts, [1, 80, 65535])
        for port in settings.ignoredPorts { settings.removeIgnoredPort(port) }
        XCTAssertEqual(AppSettings(defaults: defaults).ignoredPorts, [])
    }
}
