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
    var diagnostic: FailureDiagnostics? = nil
    var errorDescription: String? { message }
}

actor PortlessService {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LeftOpen/Portless", isDirectory: true)
    private let runtime: URL
    private let node: URL
    private var jobs: [String: Process] = [:]
    private var proxyPort = PortlessConfiguration.savedPort()

    init(runtime: URL, node: URL) { self.runtime = runtime; self.node = node }

    func hasRunningProjects() -> Bool { jobs.values.contains { $0.isRunning } }

    private var environment: [String: String] {
        ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
         "HOME": NSHomeDirectory(), "PORTLESS_STATE_DIR": Self.directory.path,
         "PORTLESS_SYNC_HOSTS": "1", "PORTLESS_LAN": "0", "NO_COLOR": "1",
         "PORTLESS_PORT": String(proxyPort), "PORTLESS_HTTPS": "1"]
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
            throw PortlessServiceError(message: L("The project address could not be prepared. Try again.", "暂时无法准备项目地址，请重试。"),
                diagnostic: FailureDiagnostics(stage: "address.command", code: data.count > 1024 * 1024 ? "outputTooLarge" : "commandFailed",
                    tool: "node", exitCode: task.terminationStatus, signal: task.terminationReason == .uncaughtSignal))
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
              arguments.count > 6, arguments[6] == String(proxyPort) else { return false }
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
        return await Self.healthy(port: proxyPort)
    }

    private static func healthy(port: Int) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let url = PortlessConfiguration.address(host: "localhost", port: port) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Portless") == "1"
        } catch { return false } // Certificate trust is verified normally, never bypassed.
    }

    private func certificateTrusted() -> Bool {
        let certificate = Self.directory.appendingPathComponent("ca.pem")
        guard AddressSetupPolicy.certificateFile(at: certificate.path) == .readable else { return false }
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
        // Trust this existing CA in the interactive user's domain. Elevated AppleScript
        // can fail in trustd when its admin session cannot display authorization UI.
        let certificate = Self.directory.appendingPathComponent("ca.pem")
        try requireReadableCertificate(certificate)
        await MainActor.run { NSApplication.shared.activate(ignoringOtherApps: true) }
        let result = try await Task.detached(priority: .utility) {
            let lookup = Process()
            lookup.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            lookup.arguments = ["default-keychain", "-d", "user"]
            lookup.standardInput = FileHandle.nullDevice
            lookup.standardError = FileHandle.nullDevice
            let output = Pipe()
            lookup.standardOutput = output
            try lookup.run()
            let keychainOutput = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            lookup.waitUntilExit()
            guard lookup.terminationStatus == 0,
                  let keychain = CertificateAuthorization.keychainPath(from: keychainOutput) else {
                throw PortlessServiceError(message: L("Your default user keychain is unavailable. Open Keychain Access, check your login keychain, then retry.",
                    "无法访问默认用户钥匙串，请在“钥匙串访问”中检查登录钥匙串后重试。"),
                    diagnostic: FailureDiagnostics(stage: "keychain.default", code: "keychainUnavailable", tool: "security", exitCode: lookup.terminationStatus))
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            task.arguments = CertificateAuthorization.arguments(certificatePath: certificate.path, keychainPath: keychain)
            // Inherit the GUI user's environment and audit session; do not elevate.
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            task.standardError = errors
            try task.run()
            let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
            defer { timeout.cancel() }
            let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            task.waitUntilExit()
            let failure: CertificateAuthorization.Failure = task.terminationReason == .uncaughtSignal && task.terminationStatus == SIGTERM
                ? .timedOut : CertificateAuthorization.failure(diagnostic: diagnostic)
            return (task.terminationStatus, failure, FailureDiagnostics(stage: "certificate.trust", code: String(describing: failure),
                tool: "security", exitCode: task.terminationStatus, signal: task.terminationReason == .uncaughtSignal, output: diagnostic))
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
            case .interactionNotAllowed:
                message = L("macOS could not display certificate authorization in this session. Open LeftOpen in your logged-in desktop session, then retry.",
                            "macOS 无法在当前会话显示证书授权，请在已登录的桌面会话中打开 LeftOpen 后重试。")
            case .rejected:
                message = L("macOS could not trust the local certificate (authorization exit \(result.0)). Retry local address setup.",
                            "macOS 未能信任本地证书（授权退出码 \(result.0)），请重试本地地址设置。")
            }
            throw PortlessServiceError(message: message, diagnostic: result.2)
        }
        guard certificateTrusted() else {
            throw PortlessServiceError(message: L("macOS has not trusted the local certificate yet. Retry and complete the certificate authorization.",
                                                  "macOS 尚未信任本地证书，请重试并完成证书授权。"),
                diagnostic: FailureDiagnostics(stage: "certificate.verifyTrust", code: "notTrusted"))
        }
    }

    func prepare(port: Int = PortlessConfiguration.savedPort()) async throws {
        guard PortlessConfiguration.validPort(port) else {
            throw PortlessServiceError(message: L("Choose a valid HTTPS proxy port.", "请选择有效的 HTTPS 代理端口。"))
        }
        let previousPort = proxyPort
        var prepared = false
        proxyPort = port
        defer { if !prepared { proxyPort = previousPort } }
        if await available() { prepared = true; return }
        // Repair only the missing step. Repeated attempts must not reinstall a working daemon.
        let certificate = Self.directory.appendingPathComponent("ca.pem")
        if AddressSetupPolicy.nextAction(installed: installedForCurrentUser(),
            certificate: AddressSetupPolicy.certificateFile(at: certificate.path),
            trusted: certificateTrusted()) == .trustExisting {
            try await trustForCurrentUser()
            if await available() { prepared = true; return }
        }
        let source = runtime
        let executable = node
        let result = try await Task.detached(priority: .utility) {
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let args = [executable.path, source.appendingPathComponent("setup.mjs").path, source.path,
                        NSHomeDirectory(), NSUserName(), String(getuid()), String(getgid()), String(port)]
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
            let code = AddressSetupPolicy.installationFailure(diagnostic)
            return (task.terminationStatus, code, FailureDiagnostics(stage: "address.install", code: code,
                tool: "osascript", exitCode: task.terminationStatus, signal: task.terminationReason == .uncaughtSignal, output: diagnostic))
        }.value
        guard result.0 == 0 else {
            let message: String
            switch result.1.split(separator: ":").first.map(String.init) ?? "failed" {
            case "cancelled": message = L("Setup was cancelled. Retry when ready.", "设置已取消，准备好后可重试。")
            case "portBusy": message = L("HTTPS port \(port) is occupied or its owner could not be confirmed. Choose another proxy port or stop the conflicting service, then retry.", "HTTPS 端口 \(port) 已被占用或无法确认归属。可更换代理端口，或停止冲突服务后重试。")
            case "invalidPort": message = L("Choose a port from 1–65535, excluding 1355–1365 reserved by LeftOpen.", "请选择 1–65535 范围内的端口，避开 LeftOpen 保留的 1355–1365。")
            case "differentOwner": message = L("The address service belongs to another user. Your project is unchanged.", "地址服务属于其他用户，项目未作改动。")
            case "unsafeService", "serviceCheckFailed", "serviceChanged": message = L("The existing address service could not be safely identified. No unrelated service was stopped. Retry setup.", "无法安全确认现有地址服务的归属，未停止其他服务。请重试设置。")
            case "serviceStopFailed": message = L("LeftOpen's previous address service could not be stopped. Retry setup.", "未能停止 LeftOpen 的旧地址服务，请重试设置。")
            case "serviceStopPending": message = L("The previous service has not finished stopping. Wait a moment, then retry.", "旧地址服务尚未完成停止，请稍候重试。")
            case "stopVerificationFailed": message = L("Could not confirm whether the previous service stopped. Copy the diagnostic info for support.", "暂时无法确认旧服务是否已停止，可复制诊断信息反馈。")
            case "portCheckFailed": message = L("The HTTPS port could not be checked. Retry setup.", "无法检查 HTTPS 端口，请重试设置。")
            case "unsafePath", "unsafeRuntime", "invalidOwner": message = L("The address service files could not be safely installed. Your project is unchanged.", "无法安全安装地址服务文件，项目未作改动。")
            case "userDirectoryRepairFailed": message = L("Could not repair access to the local address folder. Retry setup with administrator authorization.", "无法修复本地地址目录的访问权限，请重试并完成管理员授权。")
            case "launchdEnableFailed": message = L("macOS could not re-enable the address service (\(result.1)). Retry setup.", "macOS 未能重新启用地址服务（\(result.1)），请重试设置。")
            case "serviceInstallFailed": message = L("The address service could not be installed (\(result.1)). Retry setup.", "地址服务安装失败（\(result.1)），请重试设置。")
            case "setupTimedOut": message = L("Address setup timed out. Retry and complete the macOS authorization prompts.", "地址设置超时，请重试并完成 macOS 授权弹窗。")
            default: message = L("The background address service could not be installed. Retry to authorize setup.", "后台地址服务未能安装，请重试并完成系统授权。")
            }
            throw PortlessServiceError(message: message, diagnostic: result.2)
        }
        try requireReadableCertificate(certificate)
        if !certificateTrusted() { try await trustForCurrentUser() }
        for _ in 0..<20 {
            if await available() { prepared = true; return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw PortlessServiceError(message: L("HTTPS is not ready yet. Try again shortly.", "HTTPS 尚未就绪，请稍后重试。"),
            diagnostic: FailureDiagnostics(stage: "address.health", code: "notReady"))
    }

    private func requireReadableCertificate(_ certificate: URL) throws {
        let message: String
        let state = AddressSetupPolicy.certificateFile(at: certificate.path)
        switch state {
        case .readable: return
        case .missing: message = L("The local certificate is missing after setup. Retry local address setup.", "设置后仍未找到本地证书，请重试本地地址设置。")
        case .inaccessible: message = L("The local certificate cannot be read because of folder or file permissions. Retry setup to repair access.", "本地证书因目录或文件权限无法读取，请重试设置以修复访问权限。")
        case .unsafe: message = L("The local certificate path is not a regular file. Setup was stopped for safety.", "本地证书路径不是普通文件，已停止设置。")
        case .unavailable: message = L("The local certificate could not be read. Retry local address setup.", "暂时无法读取本地证书，请重试本地地址设置。")
        }
        throw PortlessServiceError(message: message,
            diagnostic: FailureDiagnostics(stage: "certificate.read", code: String(describing: state)))
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
        env["PORTLESS_PORT"] = String(proxyPort)
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
