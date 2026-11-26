import Darwin
import Foundation

/// A dedicated temporary browser session, not evidence that its automation task has finished.
public struct AutomationBrowser: Sendable, Equatable, Identifiable {
    public let process: ProcessFact
    public let profilePath: String
    public let startTime: String
    public let startedAt: Date
    public var id: String { "browser:\(process.pid):\(startTime)" }
}

public enum AutomationBrowserScanner {
    static func isChromeExecutable(_ path: String) -> Bool {
        ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
         NSHomeDirectory() + "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"].contains(path)
    }

    /// Use kernel argv boundaries, never whitespace-split `ps` output or substring matches.
    static func profile(executable: String, arguments: [String], temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> String? {
        guard isChromeExecutable(executable), arguments.first == executable,
              arguments.filter({ $0 == "--no-startup-window" }).count == 1,
              arguments.filter({ $0 == "--remote-debugging-pipe" }).count == 1,
              !arguments.contains(where: { $0 == "--type" || $0.hasPrefix("--type=") }) else { return nil }
        let profiles = arguments.filter { $0 == "--user-data-dir" || $0.hasPrefix("--user-data-dir=") }
        guard profiles.count == 1, profiles[0].hasPrefix("--user-data-dir=") else { return nil }
        let path = String(profiles[0].dropFirst("--user-data-dir=".count))
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let prefix = "playwright_chromiumdev_profile-"
        guard name.hasPrefix(prefix), !name.dropFirst(prefix.count).isEmpty,
              name.dropFirst(prefix.count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              url.deletingLastPathComponent().resolvingSymlinksInPath().path == temporaryDirectory.resolvingSymlinksInPath().path,
              url.resolvingSymlinksInPath().lastPathComponent == name,
              url.resolvingSymlinksInPath().deletingLastPathComponent().path == temporaryDirectory.resolvingSymlinksInPath().path else { return nil }
        return url.resolvingSymlinksInPath().path
    }

    static func identity(_ pid: Int32) throws -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if read == size { return info }
        if errno == ESRCH { return nil }
        throw CloseError(L("Cannot verify browser process identity.", "无法核实浏览器进程身份。"))
    }

    static func start(_ info: proc_bsdinfo) -> String { "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)" }

    static func arguments(_ pid: Int32) throws -> (String, [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 4 * 1024 * 1024 else {
            throw CloseError(L("Browser launch arguments are unavailable.", "无法读取浏览器启动参数。"))
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else {
            throw CloseError(L("Browser launch arguments are unavailable.", "无法读取浏览器启动参数。"))
        }
        bytes = Array(bytes.prefix(size))
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 65536 else { throw CloseError("Invalid browser argv.") }
        var cursor = MemoryLayout<Int32>.size
        func string() -> String? {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            defer { cursor = end + 1 }
            return String(bytes: bytes[cursor..<end], encoding: .utf8)
        }
        guard let executable = string() else { throw CloseError("Invalid browser executable.") }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        var args: [String] = []
        for _ in 0..<count {
            guard let value = string() else { throw CloseError("Incomplete browser argv.") }
            args.append(value)
        }
        // Never parse, retain or display the environment entries following argv.
        return (executable, args)
    }

    static func read(_ pid: Int32) throws -> AutomationBrowser? {
        guard let before = try identity(pid), before.pbi_uid == getuid(), before.pbi_status != SZOMB else { return nil }
        let (executable, argv) = try arguments(pid)
        guard let profile = profile(executable: executable, arguments: argv),
              let after = try identity(pid), start(before) == start(after), before.pbi_uid == after.pbi_uid else { return nil }
        let startedAt = Date(timeIntervalSince1970: Double(before.pbi_start_tvsec))
        return AutomationBrowser(process: ProcessFact(pid: pid, ppid: Int32(before.pbi_ppid), command: "Google Chrome",
            executablePath: executable, uid: Int32(before.pbi_uid), user: nil, cwd: nil,
            uptime: nil), profilePath: profile, startTime: start(before), startedAt: startedAt)
    }

    static func scan(processTable: [Int32: ProcessFact]) -> (browsers: [AutomationBrowser], incomplete: Bool) {
        var browsers: [AutomationBrowser] = []
        var incomplete = false
        for process in processTable.values where isChromeExecutable(process.executablePath ?? "") {
            do { if let browser = try read(process.pid) { browsers.append(browser) } }
            catch { incomplete = true }
        }
        return (browsers.sorted { $0.process.pid < $1.process.pid }, incomplete)
    }

    /// Exit is verified independently of sockets and recognition (losing flags is not an exit).
    static func isRunning(_ browser: AutomationBrowser) throws -> Bool {
        guard let info = try identity(browser.process.pid) else { return false }
        return start(info) == browser.startTime && info.pbi_status != SZOMB
    }
}
