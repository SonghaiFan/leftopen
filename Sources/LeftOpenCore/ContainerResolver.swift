import Foundation
import Network

/// A host directory bind-mounted into a container (`docker run -v ~/code:/app`), the strongest
/// hint of where a non-compose container was started from.
public struct ContainerMount: Sendable, Equatable {
    public let source: String
    public let destination: String
}

/// The container behind a port a runtime forwards, resolved through the Engine API or `docker ps`.
public struct ContainerInfo: Sendable, Equatable {
    public let id: String
    public let name: String
    public let image: String
    public let composeProject: String?
    /// Directory holding the compose file; `nil` for plain `docker run` containers.
    public let composeDir: String?
    public let mounts: [ContainerMount]

    public init(id: String = "", name: String, image: String,
                composeProject: String? = nil, composeDir: String? = nil,
                mounts: [ContainerMount] = []) {
        self.id = id
        self.name = name
        self.image = image
        self.composeProject = composeProject
        self.composeDir = composeDir
        self.mounts = mounts
    }

    /// The close that lasts: stopping the container, not the forwarder that merely maps its port.
    public var stopCommand: String { "docker stop \(name)" }

    /// Rows show a name a human chose. Docker's generated names (`nostalgic_turing`) say less than
    /// the image does, so a plain `docker run` without `--name` is listed by its image.
    public var displayName: String {
        guard composeProject == nil, Self.isGeneratedName(name) else { return name }
        let last = (image as NSString).lastPathComponent
        if let colon = last.firstIndex(of: ":") { return String(last[..<colon]) }
        return last
    }

    /// Docker invents names like `nostalgic_turing`: exactly two lowercase words and one underscore.
    static func isGeneratedName(_ name: String) -> Bool {
        let pieces = name.split(separator: "_")
        guard pieces.count == 2 else { return false }
        return pieces.allSatisfy { $0.allSatisfy(\.isLowercase) && $0.allSatisfy(\.isLetter) }
    }
}

/// What a stop review needs before asking the user to confirm: the plan is prepared on demand,
/// never during the polling scan.
public struct ContainerStopPlan: Sendable, Equatable {
    public let activity: Activity
    public let container: ContainerInfo
    /// From `HostConfig.RestartPolicy`: an `always` container comes back when the Docker daemon
    /// restarts even after `docker stop`. `nil` when the daemon would not say.
    public let restartPolicy: String?

    public init(activity: Activity, container: ContainerInfo, restartPolicy: String?) {
        self.activity = activity
        self.container = container
        self.restartPolicy = restartPolicy
    }

    public var resurrectsOnDaemonRestart: Bool { restartPolicy == "always" }
}

public enum ContainerResolver {
    /// Skips the socket after a daemon failure, and the CLI after it failed too, so a hung daemon
    /// costs one timeout per minute at most instead of one per scan.
    private static let backoff = Backoff()
    private static let retryDelay: TimeInterval = 60

    private final class Backoff: @unchecked Sendable {
        private let lock = NSLock()
        private var socketFailedAt: Date?
        private var cliFailedAt: Date?

        func socketBlocked(now: Date = Date()) -> Bool { isBlocked(&socketFailedAt, now: now) }
        func cliBlocked(now: Date = Date()) -> Bool { isBlocked(&cliFailedAt, now: now) }
        func markSocketFailure(_ date: Date = Date()) { mark(&socketFailedAt, date) }
        func markCLIFailure(_ date: Date = Date()) { mark(&cliFailedAt, date) }

        private func isBlocked(_ stamp: inout Date?, now: Date) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let stamp else { return false }
            return now.timeIntervalSince(stamp) < ContainerResolver.retryDelay
        }

        private func mark(_ stamp: inout Date?, _ date: Date) {
            lock.lock(); defer { lock.unlock() }
            stamp = date
        }
    }

    /// Resolves forwarded host ports to their containers once per scan. The Engine API over the
    /// daemon's unix socket is tried first (~10 ms, no process spawn); the `docker ps` CLI, which
    /// also understands contexts and remote daemons, is the fallback. Any failure simply leaves
    /// the row naming the runtime instead.
    public static func containers(for ports: Set<Int>) -> [Int: ContainerInfo] {
        resolve(for: ports, socketFetch: fetchViaSocket, cliFetch: containersViaCLI)
    }

    /// The socket's failure backoff never gates the CLI fallback: skipping it is what turns a
    /// half-second socket hiccup into a minute of rows losing their containers.
    static func resolve(for ports: Set<Int>,
                        socketFetch: (String) -> Data?,
                        cliFetch: (Set<Int>) -> [Int: ContainerInfo]) -> [Int: ContainerInfo] {
        guard !ports.isEmpty else { return [:] }
        if !backoff.socketBlocked(), let socket = daemonSocket() {
            if let body = socketFetch(socket), let parsed = parseEngineList(body, ports: ports) {
                return parsed
            }
            backoff.markSocketFailure()
        }
        return cliFetch(ports)
    }

    private static func fetchViaSocket(_ socket: String) -> Data? {
        UnixSocketHTTP.get(socket, path: "/containers/json", timeout: 2)
    }

    /// Restart policy for the stop review, fetched once per action — the scan path never calls this.
    public static func restartPolicy(of container: ContainerInfo) -> String? {
        if !backoff.socketBlocked(), let socket = daemonSocket() {
            if container.id.count == 12,
               let body = UnixSocketHTTP.get(socket, path: "/containers/\(container.id)/json", timeout: 2),
               let policy = parseRestartPolicy(body) {
                return policy
            }
            backoff.markSocketFailure()
        }
        if let docker = dockerExecutable(), !backoff.cliBlocked(),
           let output = try? CommandRunner.output(docker,
               ["inspect", "--format", "{{.HostConfig.RestartPolicy.Name}}", container.name],
               timeout: 3) {
            return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Stops the container through the CLI: a rare, user-confirmed write, which the CLI serves
    /// with all its context and authentication handling. `docker stop` gives the container ~10 s
    /// to exit gracefully, so the wait is generous.
    public static func stop(_ container: ContainerInfo) throws -> String {
        guard let docker = dockerExecutable() else {
            throw CloseError(L("The `docker` command is not available on this Mac.", "这台 Mac 上没有 `docker` 命令。"))
        }
        return try CommandRunner.output(docker, ["stop", container.name], timeout: 20)
    }

    // MARK: - Engine API

    /// One `GET /containers/json` entry per container: names, image, structured port mappings,
    /// compose labels and bind mounts — everything except the restart policy.
    static func parseEngineList(_ data: Data, ports: Set<Int>) -> [Int: ContainerInfo]? {
        guard let containers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var resolved: [Int: ContainerInfo] = [:]
        for container in containers {
            guard let names = container["Names"] as? [String], let name = names.first else { continue }
            let labels = container["Labels"] as? [String: String]
            let info = ContainerInfo(
                id: String((container["Id"] as? String ?? "").prefix(12)),
                name: name.hasPrefix("/") ? String(name.dropFirst()) : name,
                image: container["Image"] as? String ?? "",
                composeProject: labels?["com.docker.compose.project"],
                composeDir: composeDirectory(labels: labels),
                mounts: (container["Mounts"] as? [[String: Any]] ?? []).compactMap { mount in
                    guard let source = mount["Source"] as? String,
                          let destination = mount["Destination"] as? String else { return nil }
                    return ContainerMount(source: source, destination: destination)
                })
            for port in container["Ports"] as? [[String: Any]] ?? [] {
                guard let publicPort = port["PublicPort"] as? Int,
                      ports.contains(publicPort), resolved[publicPort] == nil else { continue }
                resolved[publicPort] = info
            }
        }
        return resolved
    }

    static func parseRestartPolicy(_ data: Data) -> String? {
        guard let container = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hostConfig = container["HostConfig"] as? [String: Any],
              let policy = hostConfig["RestartPolicy"] as? [String: Any],
              let name = policy["Name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    /// The compose file's directory beats the label's `working_dir`, which is where compose was
    /// invoked from (`-f` elsewhere is common enough to matter).
    static func composeDirectory(labels: [String: String]?) -> String? {
        if let configFile = labels?["com.docker.compose.project.config_files"]?
            .split(separator: ",").first.map(String.init) {
            let dir = (configFile as NSString).deletingLastPathComponent
            if !dir.isEmpty { return dir }
        }
        return labels?["com.docker.compose.project.working_dir"]
    }

    /// `DOCKER_HOST` first (it is what the CLI would use), then the sockets the bundled runtimes
    /// create. Colima's context socket is left to the CLI fallback, which reads `~/.docker/config.json`.
    static func daemonSocket() -> String? {
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"],
           host.hasPrefix("unix://"), let path = host.dropFirst("unix://".count).split(separator: ",").first {
            let socket = String(path)
            return isSocket(socket) ? socket : nil
        }
        let home = NSHomeDirectory()
        return [
            home + "/.docker/run/docker.sock",     // Docker Desktop, user-owned
            "/var/run/docker.sock",                // Docker Desktop and OrbStack symlink here
            home + "/.orbstack/run/docker.sock",
            home + "/.colima/docker.sock",
        ].first { isSocket($0) }
    }

    private static func isSocket(_ path: String) -> Bool {
        var stats = stat()
        return stat(path, &stats) == 0 && (stats.st_mode & S_IFMT) == S_IFSOCK
    }

    // MARK: - CLI fallback

    static func containersViaCLI(for ports: Set<Int>) -> [Int: ContainerInfo] {
        guard !ports.isEmpty, !backoff.cliBlocked(), let docker = dockerExecutable() else { return [:] }
        let output = try? CommandRunner.output(docker,
            ["ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Ports}}"], timeout: 3)
        guard let output else {
            backoff.markCLIFailure()
            return [:]
        }
        return parse(output, ports: ports)
    }

    /// One `docker ps` row per line: name, image and the published mappings.
    static func parse(_ output: String, ports: Set<Int>) -> [Int: ContainerInfo] {
        var resolved: [Int: ContainerInfo] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { continue }
            for hostPort in publishedHostPorts(fields[2]) {
                guard ports.contains(hostPort), resolved[hostPort] == nil else { continue }
                resolved[hostPort] = ContainerInfo(name: fields[0], image: fields[1])
            }
        }
        return resolved
    }

    /// `docker ps` renders mappings like `0.0.0.0:5432->5432/tcp, :::8080->80/tcp`; the host port is
    /// the number left of `->`. Empty string when a container publishes nothing.
    static func publishedHostPorts(_ portList: String) -> [Int] {
        portList.split(separator: ",").compactMap { mapping in
            let mapping = mapping.trimmingCharacters(in: .whitespaces)
            guard let arrow = mapping.range(of: "->") else { return nil }
            let hostSide = mapping[..<arrow.lowerBound]
            guard let colon = hostSide.lastIndex(of: ":") else { return nil }
            return Int(hostSide[hostSide.index(after: colon)...])
        }
    }

    static func dockerExecutable() -> String? {
        [
            "/usr/local/bin/docker",                   // Docker Desktop's symlink, Intel Homebrew
            "/opt/homebrew/bin/docker",                // Apple Silicon Homebrew
            "/usr/bin/docker",
            NSHomeDirectory() + "/.orbstack/bin/docker",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
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
