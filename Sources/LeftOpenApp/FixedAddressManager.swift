import AppKit
import Darwin
import Foundation
import LeftOpenCore

private struct FixedRoute: Codable, Sendable {
    let hostname: String
    let port: Int
    let pid: Int32
}

private struct EngineUpdate: Encodable {
    let token: String
    let routes: [FixedRoute]
}

private struct EngineReady: Decodable {
    let pid: Int32
    let port: Int
}

private struct FixedAddressError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Uses only the runtime shipped in this app; never installs npm packages on the user's Mac.
private actor FixedAddressEngine {
    private var process: Process?
    private var input: Pipe?
    private var port: Int?
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LeftOpen/FixedAddresses", isDirectory: true)

    static var runtime: URL {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("Portless/engine.mjs").path) {
            return resources.appendingPathComponent("Portless", isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/portless-runtime", isDirectory: true)
    }

    static var node: URL {
        #if arch(arm64)
        runtime.appendingPathComponent("node-arm64")
        #else
        runtime.appendingPathComponent("node-x64")
        #endif
    }

    func replace(_ routes: [FixedRoute]) async throws -> Int {
        if process?.isRunning != true || port == nil { try await start() }
        guard let input, let port else { throw FixedAddressError(message: "Fixed address engine is unavailable.") }
        let token = UUID().uuidString
        var data = try JSONEncoder().encode(EngineUpdate(token: token, routes: routes))
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        for _ in 0..<80 {
            try Task.checkCancellation()
            if let ack = try? String(contentsOf: directory.appendingPathComponent("ack"), encoding: .utf8), ack == token {
                return port
            }
            guard process?.isRunning == true else { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw FixedAddressError(message: L("Fixed address engine did not respond. Try again.", "固定地址引擎未响应，请重试。"))
    }

    private func start() async throws {
        stop()
        let runtime = Self.runtime
        guard FileManager.default.isExecutableFile(atPath: Self.node.path),
              FileManager.default.fileExists(atPath: runtime.appendingPathComponent("package/dist/index.js").path) else {
            throw FixedAddressError(message: L("This build is missing its fixed address engine. Rebuild the app.",
                                              "此版本缺少固定地址引擎，请重新构建 App。"))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let ready = directory.appendingPathComponent("ready.json")
        let savedPort = directory.appendingPathComponent("port.json")
        if !FileManager.default.fileExists(atPath: savedPort.path),
           let previousData = try? Data(contentsOf: ready),
           let previous = try? JSONDecoder().decode(EngineReady.self, from: previousData),
           (1355...1365).contains(previous.port) {
            try JSONEncoder().encode(previous.port).write(to: savedPort, options: .atomic)
        }
        try? FileManager.default.removeItem(at: ready)
        let child = Process()
        child.executableURL = Self.node
        child.arguments = [runtime.appendingPathComponent("engine.mjs").path, directory.path, String(getpid())]
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let pipe = Pipe()
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        child.standardInput = pipe
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        input = pipe
        do {
            for _ in 0..<100 {
                try Task.checkCancellation()
                if !child.isRunning { break }
                if let data = try? Data(contentsOf: ready),
                   let state = try? JSONDecoder().decode(EngineReady.self, from: data),
                   state.pid == child.processIdentifier, (1355...1365).contains(state.port) {
                    port = state.port
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw FixedAddressError(message: L("Fixed address engine could not start. Ports 1355–1365 may be busy.",
                                              "固定地址引擎未能启动，1355–1365 端口可能已被占用。"))
        } catch { stop(); throw error }
    }

    func stop() {
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        port = nil
    }
}

enum AddressSetupState { case checking, needsSetup, needsRepair, ready }

@MainActor
final class FixedAddressManager: ObservableObject {
    static let shared = FixedAddressManager()
    @Published private(set) var shortcutOrder = UserDefaults.standard.stringArray(forKey: "leftopen.projectShortcutOrder") ?? []
    @Published private(set) var bindings: [FixedAddressBinding] = []
    @Published private(set) var urls: [String: URL] = [:]
    @Published private(set) var error: String?
    @Published private(set) var isWorking = false
    private let engine = FixedAddressEngine()
    private let service = PortlessService(runtime: FixedAddressEngine.runtime, node: FixedAddressEngine.node)
    @Published private(set) var usesHTTPS = UserDefaults.standard.bool(forKey: "leftopen.fixedAddressHTTPS")
    @Published private(set) var launchable: Set<String> = []
    @Published private(set) var recovering = false
    @Published private(set) var addressSetupState: AddressSetupState = .checking
    @Published private(set) var setupError: String?
    @Published private(set) var setupDiagnostic: FailureDiagnostics?
    @Published private(set) var proxyHTTPSPort = PortlessConfiguration.savedPort()
    @Published private(set) var addressesPaused = UserDefaults.standard.bool(forKey: PortlessConfiguration.pausedKey)
    var bundledRuntimeVersion: String {
        guard let data = try? Data(contentsOf: FixedAddressEngine.runtime.appendingPathComponent("runtime-lock.json")),
              let lock = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = lock["portlessVersion"] as? String,
              let node = lock["nodeVersion"] as? String else { return "Unknown" }
        return "Portless \(version) · Node \(node)"
    }
    var addressesReady: Bool { !addressesPaused && addressSetupState == .ready }
    private var selectedServices: [String: Activity] = [:]
    private var consecutiveFailures = 0
    private var monitor: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var uninstalling = false
    private let storageKey = "leftopen.fixedAddressBindings.v2"

    private init() {
        // Migrate local preview opt-ins, removing any raw argument fields from the earlier format.
        let legacyKey = "leftopen.fixedAddressBindings.v1"
        if UserDefaults.standard.data(forKey: storageKey) == nil,
           let data = UserDefaults.standard.data(forKey: legacyKey),
           var records = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for index in records.indices {
                if let arguments = records[index].removeValue(forKey: "serviceArguments") as? String {
                    records[index]["serviceArgumentsHash"] = FixedAddressBinding.argumentHash(arguments)
                }
            }
            if let migrated = try? JSONSerialization.data(withJSONObject: records),
               (try? JSONDecoder().decode([FixedAddressBinding].self, from: migrated)) != nil {
                UserDefaults.standard.set(migrated, forKey: storageKey)
                UserDefaults.standard.removeObject(forKey: legacyKey)
            }
        }
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([FixedAddressBinding].self, from: data) {
            var names: Set<String> = []
            bindings = saved.filter { Portless.validName($0.name) && names.insert($0.name).inserted }
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.monitor?.cancel() }
                // stdin EOF and the parent-PID watchdog also stop the child on exit/crash.
            }
        startMonitor()
        Task { await refreshAddressSetup() }
    }

    func pauseForUninstall() async throws {
        guard !isWorking else {
            throw PortlessServiceError(message: L("Wait for the current project action to finish, then retry.", "请等待当前项目操作完成后重试。"))
        }
        uninstalling = true
        guard !(await service.hasRunningProjects()) else {
            throw PortlessServiceError(message: L("Stop projects started through LeftOpen before uninstalling.", "请先关闭通过 LeftOpen 启动的项目，再卸载。"))
        }
        monitor?.cancel()
        await monitor?.value
        monitor = nil
        await engine.stop()
    }

    func resumeAfterUninstallFailure() {
        uninstalling = false
        startMonitor()
        Task { await refreshAddressSetup() }
    }

    func refreshAddressSetup() async {
        guard !isWorking, !uninstalling else { return }
        addressSetupState = await service.available() ? .ready : (usesHTTPS ? .needsRepair : .needsSetup)
    }

    /// Only the Settings action can request system authorization.
    func pauseAddresses() async {
        guard !isWorking, !uninstalling else { return }
        isWorking = true
        setupError = nil
        setupDiagnostic = nil
        defer { isWorking = false; startMonitor() }
        do {
            guard !(await service.hasRunningProjects()) else {
                throw FixedAddressError(message: L("Stop projects started through LeftOpen before turning off fixed addresses.", "请先停止通过 LeftOpen 启动的项目，再关闭固定地址。"))
            }
            monitor?.cancel(); await monitor?.value; monitor = nil
            if usesHTTPS { try await service.replace([]) }
            await engine.stop()
            addressesPaused = true
            UserDefaults.standard.set(true, forKey: PortlessConfiguration.pausedKey)
            urls = [:]; resolvedActivities = [:]; selectedServices = [:]; launchable = []
            publishCatalog()
        } catch {
            setupError = error.localizedDescription
            setupDiagnostic = (error as? PortlessServiceError)?.diagnostic
                ?? FailureDiagnostics(stage: "address.pause", code: "failed", error: error as NSError)
        }
    }

    func configureAddresses(port: Int? = nil) async {
        guard !isWorking, !uninstalling else { return }
        isWorking = true
        setupError = nil
        setupDiagnostic = nil
        defer { isWorking = false; startMonitor() }
        do {
            let requestedPort = port ?? proxyHTTPSPort
            guard PortlessConfiguration.validPort(requestedPort) else {
                throw FixedAddressError(message: L("Choose a port from 1–65535, excluding 1355–1365 reserved by LeftOpen.", "请选择 1–65535 范围内的端口，避开 LeftOpen 保留的 1355–1365。"))
            }
            if requestedPort != proxyHTTPSPort {
                guard !(await service.hasRunningProjects()) else {
                    throw FixedAddressError(message: L("Stop projects started through LeftOpen before changing the proxy port.", "更改代理端口前，请先停止通过 LeftOpen 启动的项目。"))
                }
            }
            monitor?.cancel(); await monitor?.value; monitor = nil
            let selectedPort = try await service.prepare(port: requestedPort)
            addressesPaused = false
            UserDefaults.standard.set(false, forKey: PortlessConfiguration.pausedKey)
            proxyHTTPSPort = selectedPort
            UserDefaults.standard.set(selectedPort, forKey: PortlessConfiguration.portKey)
            addressSetupState = .ready
            usesHTTPS = true
            UserDefaults.standard.set(true, forKey: "leftopen.fixedAddressHTTPS")
            monitor?.cancel(); await monitor?.value; monitor = nil
            if let fresh = try? await Task.detached(priority: .utility, operation: { try Scanner.scan().activities }).value {
                try? await reconcile(fresh)
            }
        } catch {
            addressSetupState = await service.available() ? .ready : (usesHTTPS ? .needsRepair : .needsSetup)
            if !addressesReady { urls = [:]; publishCatalog() }
            setupError = error.localizedDescription
            setupDiagnostic = (error as? PortlessServiceError)?.diagnostic
                ?? FailureDiagnostics(stage: "address.setup", code: "failed", error: error as NSError)
        }
    }

    private func requireConfiguredAddresses() async -> Bool {
        guard !addressesPaused else {
            SettingsWindowController.shared.show(section: .projects)
            return false
        }
        if await service.available() { addressSetupState = .ready; return true }
        addressSetupState = usesHTTPS ? .needsRepair : .needsSetup
        SettingsWindowController.shared.show(section: .projects)
        return false
    }

    func binding(for activity: Activity) -> FixedAddressBinding? {
        bindings.first { $0.matches(activity) && urls[$0.id]?.host == "\($0.name).localhost" &&
            resolvedActivities[$0.id] == activity.id }
            ?? bindings.first { $0.matches(activity) && $0.preferredPort == activity.listener.port }

    }
    private var resolvedActivities: [String: String] = [:]

    func enable(_ activity: Activity, name requestedName: String) async {
        guard !isWorking, !uninstalling else { return }
        isWorking = true
        error = nil
        defer { isWorking = false; startMonitor() }
        let previous = bindings
        var changedRoutes = false
        do {
            if let blocker = FixedAddressEligibility.identityBlocker(for: activity, currentUID: Int32(getuid())) {
                throw FixedAddressError(message: blocker.message)
            }
            guard let project = activity.projectMarker, let executable = activity.process.executablePath,
                  activity.process.uid == Int32(getuid()), FixedAddressBinding.supportsLoopback(activity) else {
                throw FixedAddressError(message: L("Select a local web service with a known project.", "请选择归属明确的本地 Web 服务。"))
            }
            let existing = binding(for: activity)
            let used = Set(bindings.filter { $0.id != existing?.id }.map(\.name))
            let info = try await service.projectInfo(root: project.root)
            let baseName = requestedName.isEmpty || requestedName == existing?.name
                ? (existing?.launchName ?? existing?.name ?? info.baseName) : requestedName
            let inferred = try await service.effectiveName(base: baseName, root: project.root)
            let name: String
            if used.contains(inferred) {
                throw PortlessServiceError(message: L("Another service already uses this name. Choose a name in Address options.",
                                                      "另一个服务已使用此名称，可在地址选项中更换。"))
            } else { name = inferred }
            guard Portless.validName(name), !used.contains(name) else {
                throw FixedAddressError(message: L("Choose another address name; this one is invalid or already used.",
                                                  "此名称无效或已被使用，请更换名称。"))
            }
            let candidate = FixedAddressBinding(id: existing?.id ?? UUID().uuidString,
                projectRoot: project.root, executablePath: executable, name: name, preferredPort: activity.listener.port,
                serviceArguments: activity.process.arguments, serviceCWD: activity.process.cwd, launchName: baseName)
            var fresh = try await Task.detached(priority: .utility) { try Scanner.scan().activities }.value
            guard let target = candidate.resolve(in: fresh), target.process.pid == activity.process.pid,
                  let detected = await WebProbe.detect(target.listener), detected.scheme == "http" else {
                throw FixedAddressError(message: L("The service changed or is not an HTTP web service. Refresh and try again.",
                                                  "服务已变化或不是 HTTP Web 服务，请刷新后重试。"))
            }
            guard await requireConfiguredAddresses() else { return }
            usesHTTPS = true
            UserDefaults.standard.set(true, forKey: "leftopen.fixedAddressHTTPS")
            // Existing addresses keep renewing quietly while the system authorization is open.
            monitor?.cancel(); await monitor?.value; monitor = nil
            fresh = try await Task.detached(priority: .utility) { try Scanner.scan().activities }.value
            guard let live = candidate.resolve(in: fresh), live.process.pid == activity.process.pid,
                  let web = await WebProbe.detect(live.listener), web.scheme == "http" else {
                throw FixedAddressError(message: L("The project changed during setup. Refresh and try again.", "项目在设置期间发生变化，请刷新后重试。"))
            }
            changedRoutes = true
            // Test the actual route before saving the project opt-in.
            bindings.removeAll { $0.id == candidate.id }
            bindings.append(candidate)
            try await reconcile(fresh, publish: false)
            guard let url = urls[candidate.id] else { throw FixedAddressError(message: L("Service is not ready.", "服务尚未就绪。")) }
            try await checkRoute(url)
            save()
            publishCatalog()
        } catch {
            bindings = previous
            self.error = error.localizedDescription
            if changedRoutes {
                let current = try? await Task.detached(priority: .utility) { try Scanner.scan().activities }.value
                if let current { try? await reconcile(current) }
                else { urls = [:]; resolvedActivities = [:]; selectedServices = [:] }
                publishCatalog()
            }
        }
    }

    func disable(_ activity: Activity) async {
        guard let binding = binding(for: activity) else { return }
        await disable(binding)
    }

    /// Remove the address and launcher without stopping the project's server.
    func disable(_ binding: FixedAddressBinding) async {
        guard !isWorking, !uninstalling else { return }
        isWorking = true
        monitor?.cancel()
        await monitor?.value
        monitor = nil
        bindings.removeAll { $0.id == binding.id }
        urls.removeValue(forKey: binding.id)
        resolvedActivities.removeValue(forKey: binding.id)
        selectedServices.removeValue(forKey: binding.id)
        save()
        error = nil
        do {
            let fresh = try await Task.detached(priority: .utility) { try Scanner.scan().activities }.value
            try await reconcile(fresh)
        } catch {
            _ = try? await engine.replace([])
            if usesHTTPS { try? await service.replace([]) }
            self.error = error.localizedDescription
        }
        publishCatalog()
        isWorking = false
        startMonitor()
    }

    var orderedBindings: [FixedAddressBinding] {
        let order = ProjectShortcutOrder.normalized(current: bindings.map(\.id), preferred: shortcutOrder)
        let byID = Dictionary(bindings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    func moveShortcut(_ id: String, to target: String) {
        guard !isWorking, !uninstalling else { return }
        let order = orderedBindings.map(\.id)
        let next = ProjectShortcutOrder.moving(id, to: target, in: order)
        guard next != order else { return }
        shortcutOrder = next
        UserDefaults.standard.set(next, forKey: "leftopen.projectShortcutOrder")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    private func startMonitor() {
        monitor?.cancel()
        guard !bindings.isEmpty, !uninstalling, !addressesPaused else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let fresh = try await Task.detached(priority: .utility) { try Scanner.scan().activities }.value
                    try Task.checkCancellation()
                    try await self.reconcile(fresh)
                    self.consecutiveFailures = 0
                    if self.recovering { self.error = nil }
                    self.recovering = false
                } catch is CancellationError { return }
                catch {
                    self.urls = [:]
                    self.resolvedActivities = [:]
                    self.consecutiveFailures += 1
                    self.recovering = true
                    // Transient failures recover silently; show details only when intervention is useful.
                    if self.consecutiveFailures >= 3 { self.error = L("The address is reconnecting. Try again if it stays unavailable.", "地址正在重新连接，持续不可用时可重试。") }
                    _ = try? await self.engine.replace([])
                    if self.usesHTTPS { try? await self.service.replace([]) }
                    self.publishCatalog()
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func reconcile(_ activities: [Activity], publish: Bool = true) async throws {
        guard !uninstalling, !addressesPaused else { throw CancellationError() }
        if bindings.isEmpty {
            await engine.stop()
            if usesHTTPS { try? await service.replace([]) }
            urls = [:]; resolvedActivities = [:]; selectedServices = [:]
            if publish { publishCatalog() }
            return
        }
        var routes: [FixedRoute] = []
        var selected: [String: Activity] = [:]
        let resolved = bindings.compactMap { $0.resolve(in: activities) }
        for binding in bindings {
            guard let activity = binding.resolve(in: activities),
                  resolved.filter({ $0.id == activity.id }).count == 1, activity.process.uid == Int32(getuid()),
                  let web = await WebProbe.detect(activity.listener), web.scheme == "http" else { continue }
            try Task.checkCancellation()
            // Two saved services converging on the same endpoint must not silently share an address.
            guard !selected.values.contains(where: { $0.id == activity.id }) else { continue }
            selected[binding.id] = activity
            routes.append(FixedRoute(hostname: "\(binding.name).localhost", port: activity.listener.port, pid: activity.process.pid))
        }
        try Task.checkCancellation()
        guard !uninstalling else { throw CancellationError() }
        let proxyPort = try await engine.replace(routes) // Keep existing HTTP bookmarks usable during migration.
        if usesHTTPS {
            guard await service.available() else {
                addressSetupState = .needsRepair
                throw PortlessServiceError(message: L("The address service is reconnecting.", "地址服务正在重新连接。"))
            }
            addressSetupState = .ready
            try await service.replace(routes.map { ServiceRoute(hostname: $0.hostname, port: $0.port, pid: $0.pid) })
        }
        try Task.checkCancellation()
        urls = Dictionary(uniqueKeysWithValues: bindings.compactMap { binding in
            guard selected[binding.id] != nil,
                  let url = usesHTTPS ? PortlessConfiguration.address(host: "\(binding.name).localhost", port: proxyHTTPSPort)
                    : URL(string: "http://\(binding.name).localhost:\(proxyPort)") else { return nil }
            return (binding.id, url)
        })
        resolvedActivities = selected.mapValues(\.id)
        selectedServices = selected
        for binding in bindings where selected[binding.id] == nil {
            if let info = try? await service.projectInfo(root: binding.projectRoot), info.canStart {
                launchable.insert(binding.id)
            } else { launchable.remove(binding.id) }
        }
        if publish { publishCatalog() }
    }

    private func publishCatalog() {
        let entries = bindings.compactMap { binding -> FixedAddressCatalog.Entry? in
            guard let url = urls[binding.id], let target = selectedServices[binding.id] else { return nil }
            return .init(binding: binding, pid: target.process.pid, port: target.listener.port, url: url)
        }
        try? FixedAddressCatalog(expiresAt: Date().addingTimeInterval(15), entries: entries).write()
    }

    func start(_ binding: FixedAddressBinding) async {
        guard !isWorking, !uninstalling else { return }
        guard !addressesPaused else { SettingsWindowController.shared.show(section: .projects); return }
        isWorking = true
        error = nil
        defer { isWorking = false; startMonitor() }
        do {
            // An already-running match is never launched a second time.
            let before = try await Task.detached(priority: .utility) { try Scanner.scan().activities }.value
            if binding.resolve(in: before) != nil { try await reconcile(before); return }
            guard await requireConfiguredAddresses() else { return }
            monitor?.cancel(); await monitor?.value; monitor = nil
            usesHTTPS = true
            UserDefaults.standard.set(true, forKey: "leftopen.fixedAddressHTTPS")
            let info = try await service.projectInfo(root: binding.projectRoot)
            let jobPID = try await service.start(binding)
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(500))
                let fresh = try await Task.detached(priority: .utility) { try Scanner.scan().activities }.value
                let routes = (try? await service.registeredRoutes()) ?? []
                var adopted = false
                for route in routes where route.pid == jobPID {
                    guard route.hostname.hasSuffix(".localhost"),
                          let target = fresh.first(where: { $0.listener.port == route.port &&
                            ($0.process.pid == jobPID || $0.parentChain.contains(where: { $0.pid == jobPID })) }),
                          let marker = target.projectMarker, let executable = target.process.executablePath else { continue }
                    let effective = String(route.hostname.dropLast(".localhost".count))
                    guard Portless.validName(effective) else { continue }
                    let base = info.worktreePrefix.flatMap { prefix in
                        effective.hasPrefix(prefix + ".") ? String(effective.dropFirst(prefix.count + 1)) : nil
                    } ?? effective
                    let old = bindings.first { $0.name == effective }
                    let id = old?.id ?? (route.hostname == "\(binding.name).localhost" ? binding.id : UUID().uuidString)
                    bindings.removeAll { $0.id == id }
                    bindings.append(FixedAddressBinding(id: id, projectRoot: marker.root, executablePath: executable,
                        name: effective, preferredPort: route.port, serviceArguments: target.process.arguments,
                        serviceCWD: target.process.cwd, launchName: base))
                    adopted = true
                }
                if adopted {
                    // A workspace opt-in becomes its individual services, avoiding a duplicate root launcher.
                    if info.workspace {
                        bindings.removeAll { $0.id == binding.id && $0.projectRoot == binding.projectRoot && $0.resolve(in: fresh) == nil }
                    }
                    try await reconcile(fresh)
                    save(); publishCatalog()
                    let pending = routes.filter { $0.pid == jobPID }.contains { route in
                        !fresh.contains { $0.listener.port == route.port &&
                            ($0.process.pid == jobPID || $0.parentChain.contains { $0.pid == jobPID }) }
                    }
                    if !pending { return }
                }
            }
            throw PortlessServiceError(message: L("The project has not opened a web service yet. Open the project to check its setup.",
                                                  "项目尚未启动 Web 服务，请打开项目检查配置。"))
        } catch { self.error = error.localizedDescription }
    }

    func forget(_ binding: FixedAddressBinding) async {
        await disable(binding)
    }

    private func checkRoute(_ url: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: FixedAddressNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url.scheme == "https" ? url : URL(string: "http://127.0.0.1:\(url.port!)/")!, timeoutInterval: 3)
        request.httpMethod = "HEAD"
        if url.scheme == "http" { request.setValue(url.host! + ":\(url.port!)", forHTTPHeaderField: "Host") }
        var response: URLResponse?
        // The upstream daemon reloads route changes asynchronously; wait quietly for that transition.
        for _ in 0..<12 {
            do {
                let (_, next) = try await session.data(for: request)
                response = next
                if let http = next as? HTTPURLResponse, ![404, 502, 503, 504].contains(http.statusCode) { break }
            } catch {
                if url.scheme != "https" { throw error }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let http = response as? HTTPURLResponse, http.value(forHTTPHeaderField: "X-Portless") == "1",
              ![403, 421, 502, 503, 504].contains(http.statusCode) else {
            throw FixedAddressError(message: L("The service rejected its fixed address or could not be reached. Its development-server host settings may need adjusting.",
                                              "服务拒绝了固定地址或无法连接，可能需要调整开发服务器允许的主机名。"))
        }
    }
}

private final class FixedAddressNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
