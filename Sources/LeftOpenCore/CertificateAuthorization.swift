import Foundation

/// A GUI authorization request must never fall back to an interactive terminal sudo.
public enum CertificateAuthorization {
    public static func script(certificatePath: String, prompt: String) -> String {
        func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        func appleScriptQuote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let command = ["/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
                       "-k", "/Library/Keychains/System.keychain", certificatePath]
            .map(shellQuote).joined(separator: " ")
        return "with timeout of 180 seconds\n do shell script " + appleScriptQuote(command)
            + " with administrator privileges with prompt " + appleScriptQuote(prompt)
            + "\nend timeout"
    }

    public enum Failure: Equatable, Sendable { case cancelled, timedOut, rejected }

    public static func failure(diagnostic: String) -> Failure {
        if diagnostic.contains("(-128)") { return .cancelled }
        if diagnostic.contains("(-1712)") { return .timedOut }
        return .rejected
    }
}
