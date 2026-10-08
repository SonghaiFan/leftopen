import Darwin
import XCTest
@testable import LeftOpenCore

final class AddressSetupPolicyTests: XCTestCase {
    func testMissingAndInaccessibleCertificateReachInstallationRepair() {
        for state: AddressSetupPolicy.CertificateFile in [.missing, .inaccessible, .unsafe, .unavailable] {
            XCTAssertEqual(AddressSetupPolicy.nextAction(installed: true, certificate: state, trusted: false), .repairInstallation)
        }
        XCTAssertEqual(AddressSetupPolicy.nextAction(installed: true, certificate: .readable, trusted: false), .trustExisting)
        XCTAssertEqual(AddressSetupPolicy.nextAction(installed: false, certificate: .readable, trusted: false), .repairInstallation)
        // A trusted CA with an unavailable service must still reach daemon repair.
        XCTAssertEqual(AddressSetupPolicy.nextAction(installed: true, certificate: .readable, trusted: true), .repairInstallation)
    }

    func testRealFileAccessDistinguishesMissingFromDeniedAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("ca.pem")
        defer { chmod(directory.path, 0o700); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(AddressSetupPolicy.certificateFile(at: file.path), .missing)
        try Data("fixture".utf8).write(to: file)
        XCTAssertEqual(AddressSetupPolicy.certificateFile(at: file.path), .readable)
        XCTAssertEqual(AddressSetupPolicy.certificateFile(at: directory.path), .unsafe)
        let link = directory.appendingPathComponent("link.pem")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(AddressSetupPolicy.certificateFile(at: link.path), .unsafe)
        guard getuid() != 0 else { throw XCTSkip("Root bypasses POSIX access restrictions") }
        XCTAssertEqual(chmod(directory.path, 0), 0)
        XCTAssertEqual(AddressSetupPolicy.certificateFile(at: file.path), .inaccessible)
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        XCTAssertEqual(chmod(file.path, 0), 0)
        defer { chmod(file.path, 0o600) }
        XCTAssertEqual(AddressSetupPolicy.certificateFile(at: file.path), .inaccessible)
    }

    func testSetupDiagnosticsAreClassifiedWithoutLeakingRawOutput() {
        XCTAssertEqual(AddressSetupPolicy.installationFailure("serviceInstallFailed:exit_5 /private/name token=secret"), "serviceInstallFailed:exit_5")
        XCTAssertEqual(AddressSetupPolicy.installationFailure("launchdEnableFailed:timeout"), "launchdEnableFailed:timeout")
        XCTAssertEqual(AddressSetupPolicy.installationFailure("userDirectoryRepairFailed"), "userDirectoryRepairFailed")
        XCTAssertEqual(AddressSetupPolicy.installationFailure("arbitrary private data"), "failed")
        XCTAssertEqual(AddressSetupPolicy.installationFailure("User canceled (-128)"), "cancelled")
    }
}
