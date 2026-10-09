import Foundation
import CoreFoundation

/// A shareable snapshot, not a raw log. Discard sensitive subprocess output at construction.
public struct FailureDiagnostics: Sendable, Equatable {
    public let text: String
    public let code: String

    public init(stage: String, code: String, tool: String? = nil, exitCode: Int32? = nil,
                signal: Bool = false, output: String = "", error: NSError? = nil,
                loginItemStatusBefore: Int? = nil, loginItemStatusAfter: Int? = nil,
                version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                build: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                date: Date = Date()) {
        func tag(_ value: String?) -> String {
            guard let value, value.range(of: #"\A[A-Za-z0-9_.:-]{1,80}\z"#, options: .regularExpression) != nil else { return "unknown" }
            return value
        }
        self.code = tag(code)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var lines = ["LeftOpen diagnostic v1", "time: \(ISO8601DateFormatter().string(from: date))",
                     "app: \(tag(version)) (\(tag(build)))", "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                     "architecture: \(arch)", "stage: \(tag(stage))", "code: \(tag(code))"]
        if let tool { lines.append("tool: \(tag(tool))") }
        if let exitCode { lines.append("\(signal ? "terminationSignal" : "exitCode"): \(exitCode)") }
        if let loginItemStatusBefore { lines.append("loginItemStatusBefore: \(loginItemStatusBefore)") }
        if let loginItemStatusAfter { lines.append("loginItemStatusAfter: \(loginItemStatusAfter)") }
        var native = error
        for depth in 0..<3 {
            guard let error = native else { break }
            let domains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain,
                           "SMAppServiceErrorDomain", "kSMErrorDomainFramework", "kSMErrorDomainLaunchd", "kSMErrorDomainIPC"]
            lines.append("\(depth == 0 ? "nativeError" : "underlyingError[\(depth)]"): \(domains.contains(error.domain) ? error.domain : "unknown") (\(error.code))")
            native = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        // AppleScript may prefix a line with its own location; match only bounded JSON records.
        let raw = String(output.prefix(65_536))
        let pattern = #"LEFTOPEN_DIAGNOSTIC:(\{[^\r\n]{1,512}\})"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let stages = ["launchd.inspect", "launchd.bootout", "launchd.verifyStopped", "launchd.enable", "service.install"]
        for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).prefix(12) {
            guard let range = Range(match.range(at: 1), in: raw),
                  let value = try? JSONSerialization.jsonObject(with: Data(raw[range].utf8)) as? [String: Any],
                  let event = value["stage"] as? String, stages.contains(event) else { continue }
            var fields = [event]
            if let status = value["exitCode"] as? NSNumber, CFGetTypeID(status) != CFBooleanGetTypeID(),
               status.doubleValue.rounded() == status.doubleValue, abs(status.doubleValue) <= 2_147_483_647 {
                fields.append("exitCode=\(status.intValue)")
            }
            if let code = value["errorCode"] as? String,
               ["ETIMEDOUT", "EACCES", "EPERM", "ENOENT", "EIO", "ENOBUFS", "EINVAL", "ESRCH"].contains(code) {
                fields.append("errno=\(code)")
            }
            if let signal = value["signal"] as? String,
               ["SIGTERM", "SIGKILL", "SIGABRT", "SIGSEGV", "SIGINT", "SIGHUP", "SIGPIPE"].contains(signal) {
                fields.append("signal=\(signal)")
            }
            lines.append("command: " + fields.joined(separator: " "))
        }
        // Copy numeric system codes only, never arbitrary error descriptions or path-bearing lines.
        let numeric = try! NSRegularExpression(pattern: #"(?:OSStatus(?:\s*(?:error|=|:))?\s*|NSOSStatusErrorDomain\s+Code=)(-?[0-9]{1,10})(?![0-9])|\((-?[0-9]{1,10})\)\s*$"#,
                                               options: [.anchorsMatchLines, .caseInsensitive])
        var numbers: [String] = []
        for match in numeric.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            let index = match.range(at: 1).location == NSNotFound ? 2 : 1
            if let range = Range(match.range(at: index), in: raw) {
                let number = String(raw[range])
                if !numbers.contains(number), numbers.count < 8 { numbers.append(number) }
            }
        }
        if !numbers.isEmpty { lines.append("systemCodes: " + numbers.joined(separator: ", ")) }
        lines.append("privacy: command arguments, paths, environment and certificate contents omitted")
        text = lines.joined(separator: "\n")
    }
}
