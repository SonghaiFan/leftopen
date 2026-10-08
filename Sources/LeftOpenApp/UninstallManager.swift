import AppKit
import CryptoKit
import Darwin
import Foundation
import LeftOpenCore
import Security
import ServiceManagement

@MainActor
final class UninstallManager: ObservableObject {
    static let shared = UninstallManager()
    @Published private(set) var isWorking = false
    @Published private(set) var error: String?

    func uninstall() async {
        guard !isWorking else { return }
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", Bundle.main.bundleIdentifier == "app.leftopen.mac",
              let resources = Bundle.main.resourceURL else {
            error = L("Uninstall is available in the installed LeftOpen app.", "请在已安装的 LeftOpen App 中使用卸载功能。")
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Uninstall LeftOpen?", "卸载 LeftOpen？")
        alert.informativeText = L("Remove LeftOpen, its background address service, local certificates, saved addresses and settings. Project files stay in place. macOS may ask for authorization.",
            "将移除 LeftOpen、后台地址服务、本地证书、保存的地址和设置。项目文件会保留。macOS 可能要求授权。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Uninstall", "卸载"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        alert.buttons[1].keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await FixedAddressManager.shared.pauseForUninstall()
            let brew = UpdateChecker.shared.installedWithHomebrew
                ? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } : nil
            try await Self.cleanupInstallation(resources: resources)
            if let brew {
                // Let Homebrew remove its Caskroom entry and CLI link, not only the app bundle.
                try await Task.detached(priority: .utility) {
                    let result = try execute(brew, ["uninstall", "--cask", "--zap", "songhaifan/tap/leftopen"],
                        extraEnvironment: ["HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_AUTO_UPDATE": "1",
                            "LEFTOPEN_UNINSTALL_CLEANED": "1"])
                    guard result.status == 0 else { throw CleanupFailure(code: "packageRemovalFailed") }
                }.value
            } else {
                try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
            }
            NSApplication.shared.terminate(nil)
        } catch {
            FixedAddressManager.shared.resumeAfterUninstallFailure()
            if let failure = error as? CleanupFailure {
                switch failure.code {
                case "cancelled": self.error = L("Uninstall was cancelled. You can retry.", "卸载已取消，可以重试。")
                case "certificateUnavailable": self.error = L("The original local certificate cannot be read. Restore access before retrying. If the certificate file was deleted, its keychain entry needs manual review.", "无法读取原始本地证书，请恢复访问权限后重试。若证书文件已删除，需要手动检查钥匙串中的残留证书。")
                case "differentOwner": self.error = L("The address service belongs to another user. Uninstall stopped.", "地址服务属于其他用户，卸载已停止。")
                default: self.error = L("Uninstall could not finish (\(failure.code)). Some cleanup may already be complete. Retry to finish.", "卸载未完成（\(failure.code)）。部分清理可能已完成，请重试。")
                }
            } else if let failure = error as? PortlessServiceError {
                self.error = failure.message
            } else {
                self.error = L("Uninstall could not finish. Some cleanup may already be complete. Retry to finish.", "卸载未完成。部分清理可能已完成，请重试。")
            }
        }
    }

    /// Homebrew owns final package removal. This path never starts the UI, calls brew or trashes the app.
    static func cleanupForHomebrew() async -> Int32 {
        do {
            guard getuid() != 0, Bundle.main.bundleURL.pathExtension == "app",
                  Bundle.main.bundleIdentifier == "app.leftopen.mac", let resources = Bundle.main.resourceURL else {
                throw CleanupFailure(code: "installedUserAppRequired")
            }
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "app.leftopen.mac")
                .allSatisfy({ $0.processIdentifier == getpid() }) else {
                throw CleanupFailure(code: "quitLeftOpenFirst")
            }
            let processes = try execute("/bin/ps", ["-axww", "-o", "comm="])
            guard processes.status == 0 else { throw CleanupFailure(code: "processCheckFailed") }
            guard !HomebrewCleanupPolicy.hasAppRuntime(processTable: processes.output) else {
                throw CleanupFailure(code: "stopLeftOpenProjectsFirst")
            }
            try await cleanupInstallation(resources: resources)
            print("LeftOpen cleanup completed. Homebrew can now remove the app.")
            return 0
        } catch {
            let code = (error as? CleanupFailure)?.code ?? "cleanupFailed"
            // Only bounded codes, never command diagnostics or paths.
            FileHandle.standardError.write(Data("LeftOpen cleanup stopped (\(code)). Quit LeftOpen and stop projects launched by it, then retry. Authorization cancellation leaves the app installed.\n".utf8))
            return 1
        }
    }

    private static func cleanupInstallation(resources: URL) async throws {
        if SMAppService.mainApp.status != .notRegistered { try await SMAppService.mainApp.unregister() }
        let runtime = resources.appendingPathComponent("Portless")
        #if arch(arm64)
        let node = runtime.appendingPathComponent("node-arm64")
        #else
        let node = runtime.appendingPathComponent("node-x64")
        #endif
        let home = NSHomeDirectory(), user = NSUserName(), uid = String(getuid())
        let prompt = L("Remove LeftOpen’s local address service and certificate.", "移除 LeftOpen 的本地地址服务与证书。")
        try await Task.detached(priority: .utility) {
            let certificate = PortlessService.directory.appendingPathComponent("ca.pem")
            let fingerprint: String
            switch AddressSetupPolicy.certificateFile(at: certificate.path) {
            case .readable:
                try checkCertificateAncestors(certificate)
                let data = try Data(contentsOf: certificate)
                let text = String(decoding: data, as: UTF8.self)
                let body = text.replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                    .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                    .components(separatedBy: .whitespacesAndNewlines).joined()
                guard let der = Data(base64Encoded: body), SecCertificateCreateWithData(nil, der as CFData) != nil else {
                    throw CleanupFailure(code: "certificateUnavailable")
                }
                fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
                try removeUserCertificate(at: certificate, fingerprint: fingerprint)
            case .missing: fingerprint = "-"
            default: throw CleanupFailure(code: "certificateUnavailable")
            }
            let arguments = [node.path, runtime.appendingPathComponent("uninstall.mjs").path, home, user, uid, fingerprint]
            let command = arguments.map(shellQuote).joined(separator: " ")
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let result = try execute("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""])
            guard result.status == 0 else {
                let codes = ["differentOwner", "unsafePath", "unsafeService", "certificateChanged", "certificateUnavailable", "unsafeHosts", "serviceStopFailed", "certificateRemovalFailed", "keychainUnavailable"]
                throw CleanupFailure(code: result.diagnostic.contains("-128") ? "cancelled"
                    : codes.first { result.diagnostic.contains($0) } ?? "cleanupFailed")
            }
            for relative in ["Library/Caches/app.leftopen.mac", "Library/HTTPStorages/app.leftopen.mac",
                "Library/Saved Application State/app.leftopen.mac.savedState"] {
                let target = URL(fileURLWithPath: home).appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            }
        }.value
        UserDefaults.standard.removePersistentDomain(forName: "app.leftopen.mac")
        UserDefaults.standard.synchronize()
        let preferences = URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences/app.leftopen.mac.plist")
        if FileManager.default.fileExists(atPath: preferences.path) { try FileManager.default.removeItem(at: preferences) }
    }
}

private struct CleanupFailure: Error { let code: String }
private struct CleanupResult: Sendable { let status: Int32; let output: String; let diagnostic: String }

private func checkCertificateAncestors(_ certificate: URL) throws {
    var target = certificate
    while target.path != "/" {
        let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw CleanupFailure(code: "unsafePath") }
        target.deleteLastPathComponent()
    }
}

private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private func execute(_ command: String, _ args: [String], extraEnvironment: [String: String] = [:]) throws -> CleanupResult {
    let task = Process(), output = Pipe()
    task.executableURL = URL(fileURLWithPath: command)
    task.arguments = args
    var environment = ProcessInfo.processInfo.environment
    environment["LANG"] = "en_US.UTF-8"
    environment["LC_ALL"] = "en_US.UTF-8"
    environment.merge(extraEnvironment) { _, new in new }
    task.environment = environment
    task.standardInput = FileHandle.nullDevice
    // Drain both channels together to avoid deadlock; never display raw command output.
    task.standardOutput = output
    task.standardError = output
    try task.run()
    let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180, execute: timeout)
    defer { timeout.cancel() }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    task.waitUntilExit()
    return CleanupResult(status: task.terminationStatus, output: text, diagnostic: text)
}

private func removeUserCertificate(at certificate: URL, fingerprint: String) throws {
    let trust = try execute("/usr/bin/security", ["remove-trusted-cert", certificate.path])
    guard trust.status == 0 || trust.diagnostic.contains("specified item could not be found") else {
        throw CleanupFailure(code: "certificateRemovalFailed")
    }
    let search = try execute("/usr/bin/security", ["list-keychains", "-d", "user"])
    let defaultKeychain = try execute("/usr/bin/security", ["default-keychain", "-d", "user"])
    guard search.status == 0, defaultKeychain.status == 0 else { throw CleanupFailure(code: "keychainUnavailable") }
    let keychains = Set((search.output + "\n" + defaultKeychain.output).split(separator: "\n").compactMap { line -> String? in
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        let file = String(value.dropFirst().dropLast())
        return file.hasPrefix("/") && file != "/Library/Keychains/System.keychain" ? file : nil
    })
    guard !keychains.isEmpty else { throw CleanupFailure(code: "keychainUnavailable") }
    for keychain in keychains {
        let listing = try execute("/usr/bin/security", ["find-certificate", "-a", "-Z", keychain])
        guard listing.status == 0 else { throw CleanupFailure(code: "keychainUnavailable") }
        guard listing.output.contains("SHA-256 hash: \(fingerprint)") else { continue }
        let removal = try execute("/usr/bin/security", ["delete-certificate", "-t", "-Z", fingerprint, keychain])
        guard removal.status == 0 else { throw CleanupFailure(code: "certificateRemovalFailed") }
        let after = try execute("/usr/bin/security", ["find-certificate", "-a", "-Z", keychain])
        guard after.status == 0, !after.output.contains(fingerprint) else { throw CleanupFailure(code: "certificateRemovalFailed") }
    }
}
