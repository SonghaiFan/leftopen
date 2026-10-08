import ServiceManagement
import XCTest
@testable import LeftOpenCore

final class LoginItemCleanupTests: XCTestCase {
    @MainActor
    func testNativeAbsentTestHostDoesNotAttemptUnregister() async throws {
        // Read the actual framework state, but NEVER call the host's unregister API.
        let state = SMAppService.mainApp.status
        guard state == .notRegistered || state == .notFound else { throw XCTSkip("Test host has an existing login item") }
        var calls = 0
        try await LoginItemCleanup.remove(status: { state }, unregister: { calls += 1 })
        XCTAssertEqual(calls, 0)
    }
    @MainActor
    func testAbsentLoginItemSkipsUnregisterAndAllowsSubsequentCleanup() async throws {
        for state: SMAppService.Status in [.notRegistered, .notFound] {
            var calls = 0
            try await LoginItemCleanup.remove(status: { state }, unregister: { calls += 1 })
            XCTAssertEqual(calls, 0)
        }
    }

    @MainActor
    func testRegisteredAndAwaitingApprovalAreRemovedAndVerified() async throws {
        for initial: SMAppService.Status in [.enabled, .requiresApproval] {
            var state = initial, calls = 0
            try await LoginItemCleanup.remove(status: { state }, unregister: { calls += 1; state = .notRegistered })
            XCTAssertEqual(calls, 1)
            // Repeating the cleanup must not attempt an already-removed login item.
            try await LoginItemCleanup.remove(status: { state }, unregister: { calls += 1 })
            XCTAssertEqual(calls, 1)
        }
    }

    @MainActor
    func testDocumentedNotFoundRaceRequiresAbsentFinalState() async throws {
        for final: SMAppService.Status in [.notRegistered, .notFound] {
            var state: SMAppService.Status = .enabled
            try await LoginItemCleanup.remove(status: { state }, unregister: {
                state = final
                throw NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorJobNotFound))
            })
        }
        do {
            try await LoginItemCleanup.remove(status: { .enabled }, unregister: {
                throw NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorJobNotFound))
            })
            XCTFail("A still-registered login item must stop cleanup")
        } catch let failure as LoginItemCleanup.Failure {
            XCTAssertEqual(failure.code, "loginItemRemovalFailed")
            XCTAssertEqual(failure.after, SMAppService.Status.enabled.rawValue)
        }
    }

    @MainActor
    func testGenericCodeOneAuthorizationAndSignatureFailuresAreNotIgnored() async {
        for code in [1, Int(kSMErrorAuthorizationFailure), Int(kSMErrorInvalidSignature)] {
            var state: SMAppService.Status = .enabled
            var destructiveCleanupStarted = false
            do {
                try await LoginItemCleanup.remove(status: { state }, unregister: {
                    state = .notFound
                    throw NSError(domain: "SMAppServiceErrorDomain", code: code)
                })
                destructiveCleanupStarted = true
                XCTFail("Unrelated errors must not be swallowed")
            } catch let failure as LoginItemCleanup.Failure {
                XCTAssertEqual(failure.underlying?.code, code)
                XCTAssertEqual(failure.underlying?.domain, "SMAppServiceErrorDomain")
                XCTAssertEqual(failure.before, SMAppService.Status.enabled.rawValue)
                XCTAssertEqual(failure.after, SMAppService.Status.notFound.rawValue)
            } catch { XCTFail("Missing stage-specific error: \(error)") }
            XCTAssertFalse(destructiveCleanupStarted)
        }
    }

    @MainActor
    func testSameNumericCodeInAnotherDomainIsNotAccepted() async {
        var state: SMAppService.Status = .enabled
        do {
            try await LoginItemCleanup.remove(status: { state }, unregister: {
                state = .notRegistered
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(kSMErrorJobNotFound))
            })
            XCTFail("Numeric codes are domain-specific")
        } catch let failure as LoginItemCleanup.Failure {
            XCTAssertEqual(failure.underlying?.domain, NSPOSIXErrorDomain)
        } catch { XCTFail("Unexpected error") }
    }

    @MainActor
    func testSuccessfulCommandDoesNotProveRemoval() async {
        do {
            try await LoginItemCleanup.remove(status: { .enabled }, unregister: {})
            XCTFail("Must verify final state")
        } catch let failure as LoginItemCleanup.Failure {
            XCTAssertEqual(failure.code, "loginItemStillRegistered")
        } catch { XCTFail("Unexpected error") }
    }

    @MainActor
    func testUnknownStatusFailsBeforeUnregister() async {
        var calls = 0
        do {
            try await LoginItemCleanup.remove(status: { SMAppService.Status(rawValue: 99)! }, unregister: { calls += 1 })
            XCTFail("Unknown states must fail closed")
        } catch let failure as LoginItemCleanup.Failure {
            XCTAssertEqual(failure.code, "loginItemStatusUnknown")
            XCTAssertEqual(failure.before, 99)
        } catch { XCTFail("Unexpected error") }
        XCTAssertEqual(calls, 0)
    }
}
