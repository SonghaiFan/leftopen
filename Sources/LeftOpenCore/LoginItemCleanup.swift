import Foundation
import ServiceManagement

/// Idempotent login-item removal. This policy never changes certificate or daemon state.
public enum LoginItemCleanup {
    public struct Failure: Error {
        public let code: String
        public let before: Int
        public let after: Int
        public let underlying: NSError?
    }

    private static func absent(_ status: SMAppService.Status) -> Bool {
        status == .notRegistered || status == .notFound
    }

    @MainActor
    public static func remove(status: () -> SMAppService.Status,
                              unregister: () async throws -> Void) async throws {
        let before = status()
        if absent(before) { return }
        guard before == .enabled || before == .requiresApproval else {
            throw Failure(code: "loginItemStatusUnknown", before: before.rawValue, after: before.rawValue, underlying: nil)
        }
        do {
            try await unregister()
        } catch {
            let after = status(), native = error as NSError
            // Only the documented JobNotFound error plus an absent final state
            // can resolve a race. Code 1, authorization and signature errors are NOT ignored.
            if ["SMAppServiceErrorDomain", "kSMErrorDomainFramework"].contains(native.domain),
               native.code == Int(kSMErrorJobNotFound), absent(after) { return }
            throw Failure(code: "loginItemRemovalFailed", before: before.rawValue, after: after.rawValue, underlying: native)
        }
        let after = status()
        guard absent(after) else {
            throw Failure(code: "loginItemStillRegistered", before: before.rawValue, after: after.rawValue, underlying: nil)
        }
    }
}
