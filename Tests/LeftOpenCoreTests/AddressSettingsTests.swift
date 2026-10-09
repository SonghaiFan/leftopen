import Foundation
import XCTest
@testable import LeftOpenCore

final class AddressSettingsTests: XCTestCase {
    func testPausePreferencePreservesPortAndBindings() throws {
        let name = "LeftOpen.AddressSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(defaults.bool(forKey: PortlessConfiguration.pausedKey))
        defaults.set(8443, forKey: PortlessConfiguration.portKey)
        let bindings = Data("saved bindings".utf8)
        defaults.set(bindings, forKey: "leftopen.fixedAddressBindings.v2")
        defaults.set(true, forKey: PortlessConfiguration.pausedKey)
        XCTAssertTrue(defaults.bool(forKey: PortlessConfiguration.pausedKey))
        XCTAssertEqual(PortlessConfiguration.savedPort(in: defaults), 8443)
        XCTAssertEqual(defaults.data(forKey: "leftopen.fixedAddressBindings.v2"), bindings)
    }

    func testConflictActionUsesSanitizedDiagnosticCode() {
        XCTAssertEqual(FailureDiagnostics(stage: "address.install", code: "portBusy").code, "portBusy")
        XCTAssertEqual(FailureDiagnostics(stage: "address.install", code: "private/path").code, "unknown")
    }
}
