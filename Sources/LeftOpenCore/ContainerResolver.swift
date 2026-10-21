import Darwin
import Foundation
import Network

public struct ContainerMount: Sendable, Equatable {
    public let source: String
    public let destination: String
}

/// A runtime-specific, canonical local socket. Never derived from Docker's active context or
/// DOCKER_HOST. Device/inode detect replacement of the socket between discovery and confirmation.
public struct ContainerEndpoint: Sendable, Equatable, Hashable {
    public let socketPath: String
    public let device: UInt64
    public let inode: UInt64
    public var host: String { "unix://" + socketPath }
}

public struct ContainerPortBinding: Sendable, Equatable, Hashable {
    public let address: String
    public let hostPort: Int
    public let containerPort: Int
    public let transport: String

    public var description: String { "\(address):\(hostPort) → \(containerPort)/\(transport)" }
}

/// Ownership evidence, including the exact daemon and full immutable container ID.
public struct ContainerInfo: Sendable, Equatable {
    public let id: String
    public let name: String
    public let image: String
    public let composeProject: String?
    public let composeDir: String?
    public let mounts: [ContainerMount]
    public let endpoint: ContainerEndpoint?
    public let daemonID: String
    public let bindings: Set<ContainerPortBinding>

    public init(id: String = "", name: String, image: String,
                composeProject: String? = nil, composeDir: String? = nil,
                mounts: [ContainerMount] = [], endpoint: ContainerEndpoint? = nil,
                daemonID: String = "", bindings: Set<ContainerPortBinding> = []) {
        self.id = id
        self.name = name
        self.image = image
        self.composeProject = composeProject
        self.composeDir = composeDir
        self.mounts = mounts
        self.endpoint = endpoint
        self.daemonID = daemonID
        self.bindings = bindings
    }

    public var identity: String { "\(endpoint?.host ?? "unverified")|\(daemonID)|\(id)" }
    public var stopCommand: String {
        guard let endpoint, Self.isFullID(id), !daemonID.isEmpty else {
            return L("Container ownership is not verified", "尚未确认容器归属")
        }
        return "docker --host \(Self.shellQuote(endpoint.host)) stop \(id)"
    }
    public var restartDisableCommand: String {
        guard let endpoint else { return "" }
        return "docker --host \(Self.shellQuote(endpoint.host)) update --restart=no \(id)"
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func isFullID(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { "0123456789abcdef".contains($0) }
    }
    public var displayName: String {
        guard composeProject == nil, Self.isGeneratedName(name) else { return name }
        let last = (image as NSString).lastPathComponent
        if let colon = last.firstIndex(of: ":") { return String(last[..<colon]) }
        return last
    }
    static func isGeneratedName(_ name: String) -> Bool {
        let pieces = name.split(separator: "_")
        return pieces.count == 2 && pieces.allSatisfy { $0.allSatisfy(\.isLowercase) && $0.allSatisfy(\.isLetter) }
    }
}

/// A fresh inspection freezes all published protocols/addresses, restart policy and incarnation.
struct ContainerInspection: Sendable, Equatable {
    let container: ContainerInfo
    let restartPolicy: String?
    let maximumRetryCount: Int?
    let startedAt: String
    let imageID: String
}

public struct ContainerStopPlan: Sendable, Equatable {
    public let activity: Activity
    public let container: ContainerInfo
    public let restartPolicy: String?
    public let reviewedBindings: Set<ContainerPortBinding>
    /// Always contains the selected TCP port, even if later scans lose all container metadata.
    public let reviewedTCPPorts: Set<Int>
    let inspection: ContainerInspection

    init(activity: Activity, inspection: ContainerInspection) {
        self.activity = activity
        self.inspection = inspection
        self.container = inspection.container
        self.restartPolicy = inspection.restartPolicy
        self.reviewedBindings = inspection.container.bindings
        self.reviewedTCPPorts = Set(inspection.container.bindings.filter { $0.transport == "tcp" }.map(\.hostPort))
            .union([activity.listener.port])
    }
    public var resurrectsOnDaemonRestart: Bool { restartPolicy == "always" }
}

public enum ContainerStopVerification: Equatable, Sendable {
    case free
    case stillListening([Int])
    case unavailable

    public static func evaluate(_ plan: ContainerStopPlan, freshSnapshot: ScanSnapshot?) -> Self {
        guard let freshSnapshot else { return .unavailable }
        // Intentionally conservative: a new owner on any address must never become "port free".
        let remaining = Set(freshSnapshot.activities.map(\.listener.port)).intersection(plan.reviewedTCPPorts).sorted()
        return remaining.isEmpty ? .free : .stillListening(remaining)
    }
}

public enum ContainerResolver {
    /// Injected per test; production shares a lock-protected, per-endpoint/transport backoff.
    final class Backoff: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [String: Date] = [:]
        func blocked(_ key: String, now: Date) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return failures[key].map { now.timeIntervalSince($0) < 60 } ?? false
        }
        func failed(_ key: String, now: Date) {
            lock.lock(); defer { lock.unlock() }; failures[key] = now
        }
        func succeeded(_ key: String) {
            lock.lock(); defer { lock.unlock() }; failures.removeValue(forKey: key)
        }
    }
    private static let backoff = Backoff()

    struct Dependencies {
        var endpoint: (Activity) -> ContainerEndpoint? = { ContainerResolver.verifiedEndpoint(for: $0) }
        var get: (ContainerEndpoint, String) -> Data? = { endpoint, path in
            guard ContainerResolver.endpointIsCurrent(endpoint) else { return nil }
            return UnixSocketHTTP.get(endpoint.socketPath, path: path, timeout: 2)
        }
        var command: (ContainerEndpoint, [String], TimeInterval) throws -> String = ContainerResolver.runDocker
    }

    /// The listener itself must be a known forwarder; an app name or ancestor alone is not proof.
    /// Unknown helpers/profiles remain runtime-only rows, with no Stop Container action.
    static func socketCandidate(for activity: Activity, home: String = NSHomeDirectory()) -> String? {
        guard activity.process.uid == Int32(getuid()), activity.editorPreview == nil,
              let path = activity.process.executablePath else { return nil }
        let name = (path as NSString).lastPathComponent
        if name == "com.docker.backend", path.contains("/Docker.app/Contents/") {
            return home + "/.docker/run/docker.sock"
        }
        if ["OrbStack", "OrbStack Helper", "OrbStack-helper", "orbstack-helper"].contains(name),
           path.contains("/OrbStack.app/Contents/") {
            return home + "/.orbstack/run/docker.sock"
        }
        // A profile-specific forwarder path is required. Generic lima/gvproxy ancestry cannot
        // distinguish multiple local VMs and must not silently select the default Docker context.
        let prefix = home + "/.colima/_lima/"
        if path.hasPrefix(prefix), ["docker-proxy", "gvproxy"].contains(name),
           let vm = path.dropFirst(prefix.count).split(separator: "/").first {
            guard vm == "colima" || vm.hasPrefix("colima-") else { return nil }
            let profile = vm == "colima" ? "default" : String(vm.dropFirst("colima-".count))
            guard !profile.isEmpty, profile != ".", profile != "..",
                  profile.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            return home + "/.colima/\(profile)/docker.sock"
        }
        return nil
    }

    static func verifiedEndpoint(for activity: Activity) -> ContainerEndpoint? {
        guard let candidate = socketCandidate(for: activity) else { return nil }
        let canonical = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        let home = NSHomeDirectory()
        let allowedRoots: [String]
        if candidate.contains("/.docker/") {
            allowedRoots = [home + "/.docker/run/", home + "/Library/Containers/com.docker.docker/Data/"]
        } else {
            allowedRoots = [(candidate as NSString).deletingLastPathComponent + "/"]
        }
        guard allowedRoots.contains(where: canonical.hasPrefix) else { return nil }
        var stats = stat()
        guard stat(canonical, &stats) == 0, (stats.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return ContainerEndpoint(socketPath: canonical, device: UInt64(UInt32(bitPattern: stats.st_dev)), inode: UInt64(stats.st_ino))
    }

    /// Check every IO operation as well as confirmation: a replaced socket/symlink is not the
    /// endpoint that was reviewed, even if the replacement happens to expose similar containers.
    static func endpointIsCurrent(_ endpoint: ContainerEndpoint) -> Bool {
        guard URL(fileURLWithPath: endpoint.socketPath).resolvingSymlinksInPath().path == endpoint.socketPath else { return false }
        var stats = stat()
        return stat(endpoint.socketPath, &stats) == 0 && (stats.st_mode & S_IFMT) == S_IFSOCK
            && UInt64(UInt32(bitPattern: stats.st_dev)) == endpoint.device && UInt64(stats.st_ino) == endpoint.inode
    }

    public static func containers(for activities: [Activity]) -> [String: ContainerInfo] {
        resolve(activities, dependencies: Dependencies(), backoff: backoff, now: Date())
    }

    static func resolve(_ activities: [Activity], dependencies: Dependencies,
                        backoff: Backoff, now: Date) -> [String: ContainerInfo] {
        var grouped: [ContainerEndpoint: [Activity]] = [:]
        for activity in activities {
            guard let endpoint = dependencies.endpoint(activity) else { continue }
            grouped[endpoint, default: []].append(activity)
        }
        var result: [String: ContainerInfo] = [:]
        for (endpoint, members) in grouped {
            let key = "\(endpoint.host)|\(endpoint.device)|\(endpoint.inode)"
            var inventory: [ContainerInfo]?
            if !backoff.blocked(key + ":socket", now: now) {
                if let info = dependencies.get(endpoint, "/info"), let daemon = parseDaemonID(info),
                   let data = dependencies.get(endpoint, "/containers/json"),
                   let parsed = parseEngineList(data, endpoint: endpoint, daemonID: daemon) {
                    inventory = parsed
                    backoff.succeeded(key + ":socket")
                } else {
                    backoff.failed(key + ":socket", now: now)
                }
            }
            if inventory == nil, !backoff.blocked(key + ":cli", now: now) {
                inventory = try? cliInventory(endpoint, command: dependencies.command)
                if inventory == nil { backoff.failed(key + ":cli", now: now) }
                else { backoff.succeeded(key + ":cli") }
            }
            guard let inventory else { continue }
            for activity in members {
                if let owner = match(activity.listener, in: inventory) { result[activity.id] = owner }
            }
        }
        return result
    }

    /// Exact normalized TCP binds only. lsof's family-less `*` is accepted only for a wildcard
    /// mapping, with one possible container on the entire port. Never pick a first match.
    static func match(_ listener: Listener, in containers: [ContainerInfo]) -> ContainerInfo? {
        guard !listener.addresses.isEmpty,
              containers.allSatisfy({ ContainerInfo.isFullID($0.id) && $0.endpoint != nil && !$0.daemonID.isEmpty })
        else { return nil }
        var owners: [ContainerInfo] = []
        for rawAddress in listener.addresses {
            guard let address = normalizedAddress(rawAddress) else { return nil }
            let candidates = containers.filter { container in
                container.bindings.contains {
                    $0.transport == "tcp" && $0.hostPort == listener.port
                    && (address == "*" ? ["0.0.0.0", "::"].contains($0.address) : address == $0.address)
                }
            }
            let allOnPort = containers.filter { $0.bindings.contains { $0.transport == "tcp" && $0.hostPort == listener.port } }
            guard Set(candidates.map(\.identity)).count == 1, let owner = candidates.first,
                  address != "*" || Set(allOnPort.map(\.identity)).count == 1 else { return nil }
            owners.append(owner)
        }
        guard Set(owners.map(\.identity)).count == 1 else { return nil }
        return owners.first
    }

    static func normalizedAddress(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if text == "*" { return text }
        var v4 = in_addr()
        var v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, text, &v4) == 1, inet_ntop(AF_INET, &v4, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
            return String(cString: buffer)
        }
        if inet_pton(AF_INET6, text, &v6) == 1, inet_ntop(AF_INET6, &v6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
            return String(cString: buffer)
        }
        return nil
    }

    static func parseDaemonID(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["ID"] as? String, !id.isEmpty else { return nil }
        return id
    }

    static func parseEngineList(_ data: Data, endpoint: ContainerEndpoint, daemonID: String) -> [ContainerInfo]? {
        guard !daemonID.isEmpty,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var result: [ContainerInfo] = []
        for entry in entries {
            guard let id = entry["Id"] as? String, ContainerInfo.isFullID(id),
                  let names = entry["Names"] as? [String], let name = names.first,
                  let ports = entry["Ports"] as? [[String: Any]] else { return nil }
            var bindings: Set<ContainerPortBinding> = []
            for port in ports {
                guard let hostPort = port["PublicPort"] as? Int else { continue }
                guard let address = port["IP"] as? String, let normalized = normalizedAddress(address), normalized != "*",
                      let transport = port["Type"] as? String, ["tcp", "udp", "sctp"].contains(transport),
                      let privatePort = port["PrivatePort"] as? Int,
                      (1...65535).contains(hostPort), (1...65535).contains(privatePort) else { return nil }
                bindings.insert(ContainerPortBinding(address: normalized, hostPort: hostPort,
                                                      containerPort: privatePort, transport: transport))
            }
            result.append(makeInfo(entry, id: id, name: name, image: entry["Image"] as? String ?? "",
                                   labels: entry["Labels"] as? [String: String], bindings: bindings,
                                   endpoint: endpoint, daemonID: daemonID))
        }
        return result
    }

    static func parseInspection(_ entry: [String: Any], endpoint: ContainerEndpoint, daemonID: String) -> ContainerInspection? {
        guard let id = entry["Id"] as? String, ContainerInfo.isFullID(id), !daemonID.isEmpty,
              let name = entry["Name"] as? String,
              let config = entry["Config"] as? [String: Any], let image = config["Image"] as? String,
              let imageID = entry["Image"] as? String, !imageID.isEmpty,
              let state = entry["State"] as? [String: Any], state["Running"] as? Bool == true,
              let startedAt = state["StartedAt"] as? String, !startedAt.isEmpty,
              let network = entry["NetworkSettings"] as? [String: Any],
              let ports = network["Ports"] as? [String: Any] else { return nil }
        var bindings: Set<ContainerPortBinding> = []
        for (key, value) in ports {
            let parts = key.split(separator: "/")
            guard parts.count == 2, let privatePort = Int(parts[0]), (1...65535).contains(privatePort),
                  ["tcp", "udp", "sctp"].contains(String(parts[1])) else { return nil }
            if value is NSNull { continue }
            guard let published = value as? [[String: String]] else { return nil }
            for mapping in published {
                guard let raw = mapping["HostIp"], let address = normalizedAddress(raw), address != "*",
                      let host = mapping["HostPort"], let hostPort = Int(host), (1...65535).contains(hostPort) else { return nil }
                bindings.insert(ContainerPortBinding(address: address, hostPort: hostPort,
                                                      containerPort: privatePort, transport: String(parts[1])))
            }
        }
        let host = entry["HostConfig"] as? [String: Any]
        let policy = host?["RestartPolicy"] as? [String: Any]
        let policyName = (policy?["Name"] as? String).flatMap {
            ["no", "always", "unless-stopped", "on-failure"].contains($0) ? $0 : nil
        }
        let info = makeInfo(entry, id: id, name: name, image: image, labels: config["Labels"] as? [String: String],
                            bindings: bindings, endpoint: endpoint, daemonID: daemonID)
        return ContainerInspection(container: info, restartPolicy: policyName?.isEmpty == false ? policyName : nil,
                                   maximumRetryCount: policy?["MaximumRetryCount"] as? Int, startedAt: startedAt, imageID: imageID)
    }

    private static func makeInfo(_ entry: [String: Any], id: String, name: String, image: String,
                                 labels: [String: String]?, bindings: Set<ContainerPortBinding>,
                                 endpoint: ContainerEndpoint, daemonID: String) -> ContainerInfo {
        let mounts = (entry["Mounts"] as? [[String: Any]] ?? []).compactMap { mount -> ContainerMount? in
            guard mount["Type"] as? String == "bind", let source = mount["Source"] as? String,
                  let destination = mount["Destination"] as? String else { return nil }
            return ContainerMount(source: source, destination: destination)
        }.sorted { ($0.source, $0.destination) < ($1.source, $1.destination) }
        return ContainerInfo(id: id, name: name.hasPrefix("/") ? String(name.dropFirst()) : name, image: image,
                             composeProject: labels?["com.docker.compose.project"], composeDir: composeDirectory(labels: labels),
                             mounts: mounts, endpoint: endpoint, daemonID: daemonID, bindings: bindings)
    }

    static func composeDirectory(labels: [String: String]?) -> String? {
        if let file = labels?["com.docker.compose.project.config_files"]?.split(separator: ",").first.map(String.init) {
            let dir = (file as NSString).deletingLastPathComponent
            if !dir.isEmpty { return dir }
        }
        return labels?["com.docker.compose.project.working_dir"]
    }

    private static func cliInventory(_ endpoint: ContainerEndpoint,
                                     command: (ContainerEndpoint, [String], TimeInterval) throws -> String) throws -> [ContainerInfo] {
        let daemon = try command(endpoint, ["info", "--format", "{{.ID}}"], 3).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !daemon.isEmpty else { throw unavailable() }
        let ids = try command(endpoint, ["container", "ls", "--quiet", "--no-trunc"], 3)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard ids.allSatisfy(ContainerInfo.isFullID), ids.count <= 256 else { throw unavailable() }
        if ids.isEmpty { return [] }
        let output = try command(endpoint, ["container", "inspect"] + ids, 3)
        guard let entries = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]],
              entries.count == ids.count else { throw unavailable() }
        let inspections = entries.compactMap { parseInspection($0, endpoint: endpoint, daemonID: daemon) }
        guard inspections.count == ids.count, Set(inspections.map { $0.container.id }) == Set(ids) else { throw unavailable() }
        return inspections.map(\.container)
    }

    /// No action uses a current context or a mutable name. Clear inherited Docker overrides even
    /// with --host, so DOCKER_CONTEXT/TLS/API-version settings cannot redirect or alter this call.
    static func dockerEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("DOCKER_") }
    }
    static func runDocker(_ endpoint: ContainerEndpoint, _ arguments: [String], _ timeout: TimeInterval) throws -> String {
        guard endpointIsCurrent(endpoint) else { throw unavailable() }
        guard let docker = dockerExecutable() else {
            throw CloseError(L("The `docker` command is not available on this Mac.", "这台 Mac 上没有 `docker` 命令。"))
        }
        return try CommandRunner.output(docker, ["--host", endpoint.host] + arguments, timeout: timeout,
                                        environment: dockerEnvironment(ProcessInfo.processInfo.environment))
    }
    static func dockerExecutable() -> String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker", NSHomeDirectory() + "/.orbstack/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func unavailable() -> CloseError {
        CloseError(L("Local container ownership could not be verified. Refresh and review again; nothing was stopped.",
                     "无法确认本机容器归属。请刷新后重新确认，未停止任何容器。"))
    }

    static func inspect(_ container: ContainerInfo, dependencies: Dependencies = Dependencies()) throws -> ContainerInspection {
        guard let endpoint = container.endpoint, ContainerInfo.isFullID(container.id), !container.daemonID.isEmpty else { throw unavailable() }
        if let info = dependencies.get(endpoint, "/info"), let daemon = parseDaemonID(info) {
            guard daemon == container.daemonID else { throw unavailable() }
            if let data = dependencies.get(endpoint, "/containers/\(container.id)/json"),
               let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let inspection = parseInspection(entry, endpoint: endpoint, daemonID: daemon) {
                guard inspection.container.id == container.id else { throw unavailable() }
                return inspection
            }
        }
        let daemon = try dependencies.command(endpoint, ["info", "--format", "{{.ID}}"], 3).trimmingCharacters(in: .whitespacesAndNewlines)
        guard daemon == container.daemonID else { throw unavailable() }
        let output = try dependencies.command(endpoint, ["container", "inspect", container.id], 3)
        guard let entries = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]], entries.count == 1,
              let inspection = parseInspection(entries[0], endpoint: endpoint, daemonID: daemon),
              inspection.container.id == container.id else { throw unavailable() }
        return inspection
    }

    public static func prepareStop(_ activity: Activity) throws -> ContainerStopPlan {
        let snapshot = try Scanner.scan()
        guard let old = activity.container, let fresh = snapshot.activities.first(where: { $0.id == activity.id }),
              let owner = fresh.container, owner.identity == old.identity, owner.endpoint == old.endpoint,
              fresh.listener == activity.listener else { throw unavailable() }
        return try makePlan(activity: fresh, inspection: inspect(owner))
    }
    static func makePlan(activity: Activity, inspection: ContainerInspection) throws -> ContainerStopPlan {
        guard let selected = activity.container, selected.identity == inspection.container.identity,
              selected.endpoint == inspection.container.endpoint,
              match(activity.listener, in: [inspection.container])?.identity == selected.identity else { throw unavailable() }
        return ContainerStopPlan(activity: activity, inspection: inspection)
    }

    public static func stop(_ plan: ContainerStopPlan) throws -> String {
        try execute(plan, scan: Scanner.scan, inspect: { try inspect($0) },
                    endpoint: { verifiedEndpoint(for: $0) }, command: runDocker,
                    checkCancellation: { try Task.checkCancellation() })
    }
    static func execute(_ plan: ContainerStopPlan, scan: () throws -> ScanSnapshot,
                        inspect: (ContainerInfo) throws -> ContainerInspection,
                        endpoint: (Activity) -> ContainerEndpoint?,
                        command: (ContainerEndpoint, [String], TimeInterval) throws -> String,
                        checkCancellation: () throws -> Void) throws -> String {
        try checkCancellation()
        guard ContainerInfo.isFullID(plan.container.id), !plan.container.daemonID.isEmpty else { throw unavailable() }
        let fresh = try scan()
        guard let activity = fresh.activities.first(where: { $0.id == plan.activity.id }),
              activity.listener == plan.activity.listener,
              activity.process.executablePath == plan.activity.process.executablePath,
              activity.process.uid == plan.activity.process.uid,
              activity.container?.identity == plan.container.identity,
              let pinned = plan.container.endpoint, endpoint(activity) == pinned else { throw unavailable() }
        // Fresh inspection is deliberately after the fresh scan and immediately before the write.
        let current = try inspect(plan.container)
        guard current == plan.inspection else {
            throw CloseError(L("The container or its impact changed. Review it again; nothing was stopped.",
                               "容器或影响范围已改变。请重新确认，未停止任何容器。"))
        }
        try checkCancellation()
        return try command(pinned, ["stop", plan.container.id], 20)
    }
}

/// The minimal HTTP/1.1 client the Engine API needs over its unix socket. Foundation's URLSession
/// cannot speak unix sockets; `Connection: close` keeps the response framing trivial — the daemon
/// closes the socket, which ends the read.
enum UnixSocketHTTP {
    /// Blocking GET; safe off the main thread (the scan runs on a detached utility task).
    static func get(_ socketPath: String, path: String, timeout: TimeInterval) -> Data? {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        let finished = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let queue = DispatchQueue(label: "leftopen.docker.socket")
        let deadline = Date().addingTimeInterval(timeout)

        queue.asyncAfter(deadline: .now() + timeout) {
            box.cancelIfUnsettled(connection)
            finished.signal()
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if error != nil {
                        box.cancelIfUnsettled(connection)
                        finished.signal()
                    } else {
                        receive(connection, into: box, on: queue, deadline: deadline, done: finished)
                    }
                })
            case .failed, .cancelled:
                box.cancelIfUnsettled(connection)
                finished.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = finished.wait()
        guard let raw = box.data else { return nil }
        return responseBody(raw)
    }

    /// Splits status, headers and body, and decodes a chunked body — the Docker daemon chunks
    /// `/containers/json` even when asked for HTTP/1.0, so the framing has to be undone before
    /// the JSON can parse.
    static func responseBody(_ raw: Data) -> Data? {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[raw.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let status = lines.first else { return nil }
        let fields = status.split(separator: " ")
        guard fields.count >= 2, fields[1] == "200" else { return nil }
        var body = raw.subdata(in: headerEnd.upperBound..<raw.endIndex)
        let chunked = lines.dropFirst().contains { line in
            let lower = line.lowercased()
            return lower.hasPrefix("transfer-encoding:") && lower.contains("chunked")
        }
        if chunked {
            guard let decoded = dechunked(body) else { return nil }
            body = decoded
        }
        return body.isEmpty ? nil : body
    }

    /// Reassembles the payload from `<hex-size>\r\n<data>\r\n` chunks ending in a zero-size chunk.
    static func dechunked(_ data: Data) -> Data? {
        var payload = Data()
        var index = data.startIndex
        while index < data.endIndex {
            guard let lineEnd = data.range(of: Data("\r\n".utf8), in: index..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return nil }
            index = lineEnd.upperBound
            if size == 0 { return payload }
            guard data.distance(from: index, to: data.endIndex) >= size else { return nil }
            let chunkStart = index
            index = data.index(index, offsetBy: size)
            payload.append(data[chunkStart..<index])
            guard data.distance(from: index, to: data.endIndex) >= 2 else { return nil }
            index = data.index(index, offsetBy: 2)
        }
        return nil
    }

    private static func receive(_ connection: NWConnection, into box: ResultBox, on queue: DispatchQueue,
                                deadline: Date, done: DispatchSemaphore) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty { box.append(data) }
            if error != nil || isComplete || Date() >= deadline {
                box.settle(connection)
                done.signal()
                return
            }
            receive(connection, into: box, on: queue, deadline: deadline, done: done)
        }
    }

    /// One answer per request: the first terminal event wins and cancels the connection.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var settled = false

        var data: Data? {
            lock.lock(); defer { lock.unlock() }
            return settled ? buffer : nil
        }

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            guard !settled else { return }
            buffer.append(chunk)
        }

        func settle(_ connection: NWConnection) {
            lock.lock()
            if !settled { settled = true } else { lock.unlock(); return }
            lock.unlock()
            connection.cancel()
        }

        /// A timeout or failure path for requests that never produced a complete response.
        func cancelIfUnsettled(_ connection: NWConnection) {
            lock.lock()
            if settled { lock.unlock(); return }
            buffer = Data()
            settled = true
            lock.unlock()
            connection.cancel()
        }
    }
}
