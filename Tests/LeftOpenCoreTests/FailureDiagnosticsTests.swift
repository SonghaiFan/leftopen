import XCTest
@testable import LeftOpenCore

final class FailureDiagnosticsTests: XCTestCase {
    func testServiceManagementDomainAndUnderlyingCodesSurviveWithoutDescriptions() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 13,
            userInfo: [NSLocalizedDescriptionKey: "private /Users/example/secret"])
        let native = NSError(domain: "SMAppServiceErrorDomain", code: 1,
            userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: "SECRET"])
        let report = FailureDiagnostics(stage: "uninstall.loginItem", code: "loginItemRemovalFailed", error: native,
            loginItemStatusBefore: 1, loginItemStatusAfter: 3)
        XCTAssertTrue(report.text.contains("nativeError: SMAppServiceErrorDomain (1)"))
        XCTAssertTrue(report.text.contains("underlyingError[1]: NSPOSIXErrorDomain (13)"))
        XCTAssertTrue(report.text.contains("loginItemStatusBefore: 1"))
        XCTAssertTrue(report.text.contains("loginItemStatusAfter: 3"))
        XCTAssertFalse(report.text.contains("SECRET"))
        XCTAssertFalse(report.text.contains("/Users/"))
    }

    func testUnderlyingErrorDepthIsBounded() {
        var native = NSError(domain: "kSMErrorDomainFramework", code: 6)
        for _ in 0..<10 { native = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSUnderlyingErrorKey: native]) }
        let report = FailureDiagnostics(stage: "uninstall.loginItem", code: "failed", error: native)
        XCTAssertTrue(report.text.contains("underlyingError[2]"))
        XCTAssertFalse(report.text.contains("underlyingError[3]"))
    }
    func testShareableReportKeepsRawCodesButNotRawOutput() {
        let report = FailureDiagnostics(stage: "address.install", code: "serviceStopFailed", tool: "osascript", exitCode: 1,
            output: """
            /Users/private-person/ca.pem token=SECRET -----BEGIN CERTIFICATE-----
            0:123: execution error: LEFTOPEN_DIAGNOSTIC:{"stage":"launchd.bootout","exitCode":5,"stderr":"private payload"}
            LEFTOPEN_DIAGNOSTIC:{"stage":"launchd.verifyStopped","exitCode":0}
            error: OSStatus -60007
            authorization failed (-128)
            """, version: "0.5.4", build: "1011.2", date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(report.text.contains("app: 0.5.4 (1011.2)"))
        XCTAssertTrue(report.text.contains("time: 1970-01-01T00:00:00Z"))
        XCTAssertTrue(report.text.contains("command: launchd.bootout exitCode=5"))
        XCTAssertTrue(report.text.contains("systemCodes: -60007, -128"))
        for secret in ["private-person", "SECRET", "BEGIN CERTIFICATE", "private payload", "/Users/"] {
            XCTAssertFalse(report.text.contains(secret))
        }
    }

    func testMalformedAndUnknownRecordsCannotInjectText() {
        let report = FailureDiagnostics(stage: "setup", code: "failed", output: """
        LEFTOPEN_DIAGNOSTIC:{"stage":"launchd.bootout","exitCode":"secret","signal":"SECRET","errorCode":"ETOKEN"}
        LEFTOPEN_DIAGNOSTIC:{"stage":"/Users/private","exitCode":1}
        LEFTOPEN_DIAGNOSTIC:{"stage":"launchd.inspect","exitCode":true}
        LEFTOPEN_DIAGNOSTIC:{broken}
        """, error: NSError(domain: "/Users/private", code: 13, userInfo: [NSLocalizedDescriptionKey: "SECRET"]),
            version: "name\nsecret", build: "/Users/name")
        XCTAssertTrue(report.text.contains("nativeError: unknown (13)"))
        XCTAssertTrue(report.text.contains("app: unknown (unknown)"))
        XCTAssertFalse(report.text.contains("exitCode=1"))
        for secret in ["SECRET", "secret", "ETOKEN", "/Users/"] { XCTAssertFalse(report.text.contains(secret)) }
    }

    func testTimeoutAndSignalRemainDistinctFromExitStatus() {
        let report = FailureDiagnostics(stage: "certificate.trust", code: "timedOut", tool: "security", exitCode: 15,
            signal: true, output: "LEFTOPEN_DIAGNOSTIC:{\"stage\":\"launchd.inspect\",\"errorCode\":\"ETIMEDOUT\",\"signal\":\"SIGTERM\"}")
        XCTAssertTrue(report.text.contains("terminationSignal: 15"))
        XCTAssertTrue(report.text.contains("errno=ETIMEDOUT signal=SIGTERM"))
        XCTAssertFalse(report.text.contains("exitCode: 15"))
    }

    func testBoundedDiagnosticsAndOSStatusDomain() {
        let record = "LEFTOPEN_DIAGNOSTIC:{\"stage\":\"launchd.inspect\",\"exitCode\":5}\n"
        let report = FailureDiagnostics(stage: "setup", code: "failed", output:
            "Error Domain=NSOSStatusErrorDomain Code=-25308 \"private\"\n" + String(repeating: record, count: 1000))
        XCTAssertEqual(report.text.components(separatedBy: "command: ").count - 1, 12)
        XCTAssertTrue(report.text.contains("systemCodes: -25308"))
        XCTAssertLessThan(report.text.count, 2000)
    }
}
