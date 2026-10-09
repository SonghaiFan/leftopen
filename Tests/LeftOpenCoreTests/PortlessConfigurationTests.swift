import Foundation
import XCTest
@testable import LeftOpenCore

final class PortlessConfigurationTests: XCTestCase {
    func testDefaultAndCustomHTTPSAddresses() {
        XCTAssertEqual(PortlessConfiguration.address(host: "demo.localhost", port: 443)?.absoluteString, "https://demo.localhost")
        XCTAssertEqual(PortlessConfiguration.address(host: "demo.localhost", port: 8443)?.absoluteString, "https://demo.localhost:8443")
        XCTAssertNil(PortlessConfiguration.address(host: "demo.localhost", port: 1355))
        XCTAssertNil(PortlessConfiguration.address(host: "demo.localhost", port: 65536))
    }

    func testPreferenceRestoresCustomPortAndRejectsInvalidSavedValues() {
        let name = "leftopen.portless-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(PortlessConfiguration.savedPort(in: defaults), 443)
        defaults.set(8443, forKey: PortlessConfiguration.portKey)
        XCTAssertEqual(PortlessConfiguration.savedPort(in: defaults), 8443)
        defaults.set(1365, forKey: PortlessConfiguration.portKey)
        XCTAssertEqual(PortlessConfiguration.savedPort(in: defaults), 443)
    }
}
