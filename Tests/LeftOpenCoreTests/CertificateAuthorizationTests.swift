import XCTest
@testable import LeftOpenCore

final class CertificateAuthorizationTests: XCTestCase {
    func testTrustUsesUserDomainAndOnlySSL() {
        let args = CertificateAuthorization.arguments(certificatePath: "/tmp/ca.pem", keychainPath: "/user/login.keychain-db")
        XCTAssertEqual(args, ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", "/user/login.keychain-db", "/tmp/ca.pem"])
        XCTAssertFalse(args.contains("-d"))
        XCTAssertFalse(args.contains("/Library/Keychains/System.keychain"))
    }

    func testCancellationAndTimeoutAreNotGenericTrustFailures() {
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "User canceled. (-128)"), .cancelled)
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "AppleEvent timed out. (-1712)"), .timedOut)
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "Authorization denied. (1)"), .rejected)
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "error -60006"), .cancelled)
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "The user canceled this operation."), .cancelled)
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "SecTrustSettingsSetTrustSettings: The authorization was denied since no user interaction was possible. (-60007)"), .interactionNotAllowed)
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "User interaction is not allowed."), .interactionNotAllowed)
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "SecTrustSettingsSetTrustSettings: The authorization was denied since no user interaction was possible."), .interactionNotAllowed)
        XCTAssertEqual(CertificateAuthorization.failure(diagnostic: "error -25308"), .interactionNotAllowed)
    }

    func testCertificatePathIsPassedLiterallyWithoutAShell() {
        let path = "/tmp/O'Brien \"quoted\" $(touch sentinel) `id` \\ ca.pem"
        let args = CertificateAuthorization.arguments(certificatePath: path, keychainPath: "/user/custom keychain.keychain-db")
        XCTAssertEqual(args.last, path)
        XCTAssertEqual(args[6], "/user/custom keychain.keychain-db")
    }

    func testDefaultKeychainOutputRequiresOneAbsoluteQuotedPath() {
        XCTAssertEqual(CertificateAuthorization.keychainPath(from: "    \"/user/custom keychain.keychain-db\"\n"), "/user/custom keychain.keychain-db")
        for output in ["", "permission denied", "\"relative\"", "\"/one\"\n\"/two\""] {
            XCTAssertNil(CertificateAuthorization.keychainPath(from: output))
        }
    }
}
