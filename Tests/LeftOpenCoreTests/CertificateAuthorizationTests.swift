import XCTest
@testable import LeftOpenCore

final class CertificateAuthorizationTests: XCTestCase {
    func testAuthorizationUsesSystemGUIAndExistingCertificate() {
        let script = CertificateAuthorization.script(certificatePath: "/tmp/ca.pem", prompt: "Trust certificate")
        XCTAssertTrue(script.contains("'/usr/bin/security' 'add-trusted-cert' '-d' '-r' 'trustRoot'"))
        XCTAssertTrue(script.contains("'/Library/Keychains/System.keychain' '/tmp/ca.pem'"))
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("with timeout of 180 seconds"))
        XCTAssertFalse(script.contains("sudo"))
    }

    func testCancellationAndTimeoutAreNotGenericTrustFailures() {
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "User canceled. (-128)"), .cancelled)
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "AppleEvent timed out. (-1712)"), .timedOut)
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "Authorization denied. (1)"), .rejected)
    }

    func testCertificatePathIsASingleShellArgument() throws {
        let path = "/tmp/O'Brien \"quoted\" $(touch sentinel) `id` \\ ca.pem"
        let script = CertificateAuthorization.script(certificatePath: path, prompt: "Trust \"CA\"")
        // Compile, but never execute the privileged AppleScript.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".scpt")
        defer { try? FileManager.default.removeItem(at: output) }
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        compiler.arguments = ["-o", output.path, "-e", script]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        XCTAssertTrue(script.contains("O'\\\\''Brien"))
    }
}
