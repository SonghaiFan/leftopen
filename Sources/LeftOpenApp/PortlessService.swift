import AppKit
import Darwin
import Foundation
import LeftOpenCore

struct PortlessProjectInfo: Decodable, Sendable {
    let baseName: String
    let name: String
    let script: String
    let canStart: Bool
    let workspace: Bool
    let worktreePrefix: String?
}

struct PortlessServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor PortlessService {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LeftOpen/Portless", isDirectory: true)
    private let runtime: URL
    private let node: URL
    private var jobs: [String: Process] = [:]

    init(runtime: URL, node: URL) { self.runtime = runtime; self.node = node }

    private var environment: [String: String] {
        ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
         "HOME": NSHomeDirectory(), "PORTLESS_STATE_DIR": Self.directory.path,
         "PORTLESS_SYNC_HOSTS": "1", "PORTLESS_LAN": "0", "NO_COLOR": "1"]
    }

    private func command(_ arguments: [String], cwd: String? = nil, input: Data? = nil) throws -> Data {
        let task = Process()
        task.executableURL = node
        task.arguments = arguments
        task.environment = environment
        if let cwd { task.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        if let input {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("leftopen-input-\(UUID().uuidString)")
            try input.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let handle = try FileHandle(forReadingFrom: file)
            try? FileManager.default.removeItem(at: file)
            task.standardInput = handle
            defer { try? handle.close() }
            try task.run()
        } else {
            task.standardInput = FileHandle.nullDevice
            try task.run()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, data.count <= 1024 * 1024 else {
            throw PortlessServiceError(message: L("The project address could not be prepared. Try again.", "暂时无法准备项目地址，请重试。"))
        }
        return data
    }

    func projectInfo(root: String) throws -> PortlessProjectInfo {
        let data = try command([runtime.appendingPathComponent("package/dist/cli.js").path, "--leftopen-project-info"], cwd: root)
        let info = try JSONDecoder().decode(PortlessProjectInfo.self, from: data)
        guard Portless.validName(info.baseName), Portless.validName(info.name) else {
            throw PortlessServiceError(message: L("Choose a shorter project address name.", "请使用更短的项目地址名称。"))
        }
        return info
    }

    func effectiveName(base: String, root: String) throws -> String {
        let data = try command([runtime.appendingPathComponent("package/dist/cli.js").path, "get", base], cwd: root)
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hostname = URL(string: value)?.host, hostname.hasSuffix(".localhost") else {
            throw PortlessServiceError(message: L("The project address is unavailable.", "项目地址暂不可用。"))
        }
        let name = String(hostname.dropLast(".localhost".count))
        guard Portless.validName(name) else { throw PortlessServiceError(message: L("Choose a shorter project address name.", "请使用更短的项目地址名称。")) }
        return name
    }

    private func installedForCurrentUser() -> Bool {
        let plist = URL(fileURLWithPath: "/Library/LaunchDaemons/app.leftopen.portless.proxy.plist")
        guard let data = try? Data(contentsOf: plist),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let env = value["EnvironmentVariables"] as? [String: String], env["PORTLESS_STATE_DIR"] == Self.directory.path,
              let arguments = value["ProgramArguments"] as? [String],
              arguments.first?.hasPrefix("/Library/Application Support/LeftOpen/Portless/node-") == true,
              arguments.count > 1 else { return false }
        return true
    }

    func available() async -> Bool {
        guard installedForCurrentUser(),
              let pidText = try? String(contentsOf: Self.directory.appendingPathComponent("proxy.pid"), encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        #if arch(arm64)
        let expectedNode = "/Library/Application Support/LeftOpen/Portless/node-arm64"
        #else
        let expectedNode = "/Library/Application Support/LeftOpen/Portless/node-x64"
        #endif
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/bin/ps")
        listener.arguments = ["-p", String(pid), "-o", "comm="]
        let identity = Pipe()
        listener.standardOutput = identity
        listener.standardError = FileHandle.nullDevice
        guard (try? listener.run()) != nil else { return false }
        let executable = String(decoding: identity.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        listener.waitUntilExit()
        guard listener.terminationStatus == 0, executable == expectedNode else { return false }
        return await Self.healthy()
    }

    private static func healthy() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://localhost/")!, timeoutInterval: 2)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Portless") == "1"
        } catch { return false } // Certificate trust is verified normally, never bypassed.
    }

    private func certificateTrusted() -> Bool {
        let certificate = Self.directory.appendingPathComponent("ca.pem")
        guard FileManager.default.fileExists(atPath: certificate.path) else { return false }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        check.arguments = ["verify-cert", "-c", certificate.path, "-L", "-p", "ssl"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return false }
        check.waitUntilExit()
        return check.terminationStatus == 0
    }

    private func trustForCurrentUser() async throws {
        // Request GUI authorization explicitly. The upstream CLI can fall back to sudo,
        // which cannot read a password from this app's closed stdin. Trust only the existing
        // CA; invoking `trust` also regenerates certificates and can leave a running proxy stale.
        let certificate = Self.directory.appendingPathComponent("ca.pem")
        guard FileManager.default.fileExists(atPath: certificate.path) else {
            throw PortlessServiceError(message: L("The local certificate is missing. Retry local address setup.",
                                                  "本地证书缺失，请重试本地地址设置。"))
        }
        await MainActor.run { NSApplication.shared.activate(ignoringOtherApps: true) }
        let script = CertificateAuthorization.script(certificatePath: certificate.path,
            prompt: L("Trust LeftOpen's local HTTPS certificate for project addresses.",
                      "信任 LeftOpen 的本地 HTTPS 证书，以启用项目固定地址。"))
        let result = try await Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            task.standardError = errors
            try task.run()
            let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            task.waitUntilExit()
            return (task.terminationStatus, CertificateAuthorization.failure(diagnostic: diagnostic))
        }.value
        guard result.0 == 0 else {
            let message: String
            switch result.1 {
            case .cancelled:
                message = L("Certificate authorization was cancelled. Retry when ready. Your project is still running.",
                            "证书授权已取消，准备好后可重试。项目仍在运行。")
            case .timedOut:
                message = L("Certificate authorization timed out. Retry and complete the macOS prompt.",
                            "证书授权超时，请重试并完成 macOS 授权弹窗。")
            case .rejected:
                message = L("macOS could not trust the local certificate (authorization exit \(result.0)). Retry local address setup.",
                            "macOS 未能信任本地证书（授权退出码 \(result.0)），请重试本地地址设置。")
            }
            throw PortlessServiceError(message: message)
        }
        guard certificateTrusted() else {
            throw PortlessServiceError(message: L("macOS has not trusted the local certificate yet. Retry and complete the certificate authorization.",
                                                  "macOS 尚未信任本地证书，请重试并完成证书授权。"))
        }
    }

    func prepare() async throws {
        if await available() { return }
        // Repair only the missing step. Repeated attempts must not reinstall a working daemon.
        if installedForCurrentUser() && !certificateTrusted() {
            try await trustForCurrentUser()
            if await available() { return }
        }
        let source = runtime
        let executable = node
        let result = try await Task.detached(priority: .utility) {
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let args = [executable.path, source.appendingPathComponent("setup.mjs").path, source.path,
                        NSHomeDirectory(), NSUserName(), String(getuid()), String(getgid())]
            let command = args.map(quote).joined(separator: " ")
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            task.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges with prompt \"" +
                L("Enable local HTTPS addresses for LeftOpen. This installs a local certificate and address service; no projects are changed.",
                  "为 LeftOpen 启用本机 HTTPS 地址。将安装本地证书与地址服务，不修改项目。") + "\""]
            task.standardOutput = FileHandle.nullDevice
            let failure = Pipe()
            task.standardError = failure
            try task.run()
            let diagnostic = String(decoding: failure.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            task.waitUntilExit()
            let code = diagnostic.contains("(-128)") ? "cancelled"
                : diagnostic.contains("portBusy") ? "portBusy"
                : diagnostic.contains("unsafePath") || diagnostic.contains("unsafeRuntime") ? "unsafePath"
                : diagnostic.contains("differentOwner") ? "differentOwner" : "failed"
            return (task.terminationStatus, code)
        }.value
        guard result.0 == 0 else {
            let message: String
            switch result.1 {
            case "cancelled": message = L("Setup was cancelled. Retry when ready.", "设置已取消，准备好后可重试。")
            case "portBusy": message = L("Another service is using the HTTPS address port. Close it before retrying.", "其他服务正在占用 HTTPS 地址端口，请关闭该服务后重试。")
            case "differentOwner": message = L("The address service belongs to another user. Your project is unchanged.", "地址服务属于其他用户，项目未作改动。")
            case "unsafePath": message = L("The address service files could not be safely installed. Your project is unchanged.", "无法安全安装地址服务文件，项目未作改动。")
            default: message = L("The background address service could not be installed. Retry to authorize setup.", "后台地址服务未能安装，请重试并完成系统授权。")
            }
            throw PortlessServiceError(message: message)
        }
        if !certificateTrusted() { try await trustForCurrentUser() }
        for _ in 0..<20 {
            if await available() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw PortlessServiceError(message: L("HTTPS is not ready yet. Try again shortly.", "HTTPS 尚未就绪，请稍后重试。"))
    }

    func replace(_ routes: [ServiceRoute]) throws {
        let data = try JSONEncoder().encode(routes)
        _ = try command([runtime.appendingPathComponent("routes.mjs").path, Self.directory.path], input: data)
    }

    func registeredRoutes() throws -> [Portless.Route] {
        let file = Self.directory.appendingPathComponent("routes.json")
        let data = try Data(contentsOf: file)
        guard data.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode([Portless.Route].self, from: data)
    }

    func start(_ binding: FixedAddressBinding) throws -> Int32 {
        if let job = jobs[binding.id], job.isRunning { return job.processIdentifier }
        let info = try projectInfo(root: binding.projectRoot)
        guard info.canStart else {
            throw PortlessServiceError(message: L("This project has no configured development script. Open the project to start it.",
                                                  "此项目没有配置开发脚本，请打开项目后启动。"))
        }
        let task = Process()
        task.executableURL = node
        var arguments = [runtime.appendingPathComponent("package/dist/cli.js").path]
        if info.workspace { arguments += ["--script", info.script] }
        else { arguments += ["run", "--name", binding.launchName ?? info.baseName, "--script", info.script] }
        task.arguments = arguments
        task.currentDirectoryURL = URL(fileURLWithPath: binding.projectRoot)
        var env = environment
        // Reuse the observed runtime's bin directory, without reconstructing shell commands or persisting argv.
        env["PATH"] = URL(fileURLWithPath: binding.executablePath).deletingLastPathComponent().path + ":" + env["PATH"]!
        env["PORTLESS_PORT"] = "443"
        env["PORTLESS_HTTPS"] = "1"
        env["CI"] = "1" // No hidden terminal prompts; setup must already be complete.
        task.environment = env
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        jobs[binding.id] = task
        return task.processIdentifier
    }
}

struct ServiceRoute: Encodable, Sendable {
    let hostname: String
    let port: Int
    let pid: Int32
}
