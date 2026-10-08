import Darwin
import Foundation

public enum AddressSetupPolicy {
    public enum CertificateFile: Equatable, Sendable {
        case readable, missing, inaccessible, unsafe, unavailable
    }

    /// Unlike fileExists, open preserves the difference between ENOENT and EACCES.
    public static func certificateFile(at path: String) -> CertificateFile {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: return .missing
            case EACCES, EPERM: return .inaccessible
            case ELOOP, ENOTDIR: return .unsafe
            default: return .unavailable
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unavailable }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return .unsafe }
        return .readable
    }

    public enum Action: Equatable, Sendable { case trustExisting, repairInstallation }

    public static func nextAction(installed: Bool, certificate: CertificateFile, trusted: Bool) -> Action {
        // Missing or inaccessible certificates must reach elevated directory/install repair.
        installed && certificate == .readable && !trusted ? .trustExisting : .repairInstallation
    }

    public static func installationFailure(_ diagnostic: String) -> String {
        if diagnostic.contains("(-128)") { return "cancelled" }
        let stages = ["portBusy", "differentOwner", "unsafePath", "unsafeRuntime", "invalidOwner",
                      "userDirectoryRepairFailed", "launchdEnableFailed", "serviceInstallFailed"]
        for stage in stages where diagnostic.contains(stage) {
            // Accept only an allowlisted code and bounded numeric exit status; no raw diagnostics.
            if let range = diagnostic.range(of: stage + #":(?:timeout|failed|exit_[0-9]{1,3})(?![0-9])"#,
                                            options: .regularExpression) {
                return String(diagnostic[range])
            }
            return stage
        }
        return diagnostic.contains("(-1712)") ? "setupTimedOut" : "failed"
    }
}
