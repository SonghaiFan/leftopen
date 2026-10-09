import AppKit
import XCTest
@testable import LeftOpenApp

final class SettingsTaxonomyTests: XCTestCase {
    func testFourSectionsAndLegacyNavigation() {
        XCTAssertEqual(SettingsSection.allCases.map(\.rawValue), ["general", "ports", "projects", "about"])
        XCTAssertEqual(SettingsSection.restored("behavior"), .ports)
        XCTAssertEqual(SettingsSection.restored("projects"), .projects)
        XCTAssertEqual(SettingsSection.restored("unknown"), .general)
    }

    @MainActor
    func testAppearancePersistenceAndSystemInheritance() {
        let suite = "LeftOpen.AppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertNil(settings.appearance.nativeAppearance)
        for value in AppearancePreference.allCases {
            settings.appearance = value
            XCTAssertEqual(AppSettings(defaults: defaults).appearance, value)
        }
        XCTAssertEqual(AppearancePreference.light.nativeAppearance?.name, .aqua)
        XCTAssertEqual(AppearancePreference.dark.nativeAppearance?.name, .darkAqua)
        defaults.set("invalid", forKey: "leftopen.appearance")
        XCTAssertEqual(AppSettings(defaults: defaults).appearance, .system)
    }
}
