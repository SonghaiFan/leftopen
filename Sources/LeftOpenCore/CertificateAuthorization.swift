import Foundation

/// Trust must run directly as the GUI user; an elevated AppleScript session can
/// fail with errAuthorizationInteractionNotAllowed when trustd needs to show UI.
public enum CertificateAuthorization {
    public static func arguments(certificatePath: String, keychainPath: String) -> [String] {
        ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychainPath, certificatePath]
    }

    public static func keychainPath(from output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("\"/"), value.hasSuffix("\""), !value.contains("\n") else { return nil }
        return String(value.dropFirst().dropLast())
    }

    public enum Failure: Equatable, Sendable { case cancelled, timedOut, interactionNotAllowed, rejected }

    public static func failure(diagnostic: String) -> Failure {
        if diagnostic.contains("(-128)") || diagnostic.contains("-60006") || diagnostic.localizedCaseInsensitiveContains("user canceled") { return .cancelled }
        if diagnostic.contains("(-1712)") { return .timedOut }
        if diagnostic.contains("-60007") || diagnostic.contains("-25308")
            || diagnostic.localizedCaseInsensitiveContains("interaction is not allowed")
            || diagnostic.localizedCaseInsensitiveContains("no user interaction was possible") {
            return .interactionNotAllowed
        }
        return .rejected
    }
}
