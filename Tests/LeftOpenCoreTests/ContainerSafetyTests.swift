import Foundation
import XCTest
@testable import LeftOpenCore

/// Pure fixtures and injected IO: no Docker socket, context, process-global backoff or local daemon.
final class ContainerSafetyTests: XCTestCase {
    private let idA = String(repeating: "a", count: 64)
    private let idB = String(repeating: "b", count: 64)
    private let endpoint = ContainerEndpoint(socketPath: "/Users/test/.docker/run/docker.sock", device: 1, inode: 2)
    private let otherEndpoint = ContainerEndpoint(socketPath: "/Users/test/.orbstack/run/docker.sock", device: 1, inode: 3)

    private func binding(_ address: String = "127.0.0.1", port: Int = 5353,
                         transport: String = "tcp") -> ContainerPortBinding {
        ContainerPortBinding(address: address, hostPort: port, containerPort: 80, transport: transport)
    }
    private func container(id: String? = nil, name: String = "web", endpoint: ContainerEndpoint? = nil,
                           daemon: String = "local-daemon", bindings: Set<ContainerPortBinding>? = nil) -> ContainerInfo {
        ContainerInfo(id: id ?? idA, name: name, image: "nginx", endpoint: endpoint ?? self.endpoint,
                      daemonID: daemon, bindings: bindings ?? [binding()])
    }
    private func activity(_ info: ContainerInfo? = nil, addresses: [String] = ["127.0.0.1"],
                          port: Int = 5353, pid: Int32 = 42,
                          path: String = "/Applications/Docker.app/Contents/MacOS/com.docker.backend") -> Activity {
        let listener = Listener(pid: pid, command: "fixture", uid: Int32(getuid()), user: nil, port: port, addresses: addresses)
        let process = ProcessFact(pid: pid, ppid: 1, command: "fixture", executablePath: path,
                                  uid: Int32(getuid()), user: nil, cwd: nil)
        var result = Activity(listener: listener, process: process, parentChain: [], projectMarker: nil,
                              applicationBundle: nil, scope: .local,
                              inference: OwnerInference(label: "Fixture", category: .service, confidence: "high", reason: "Fixture"))
        result.container = info
        return result
    }
    private func inspection(_ info: ContainerInfo? = nil, policy: String? = "no", started: String = "2026-10-01T00:00:00Z") -> ContainerInspection {
        ContainerInspection(container: info ?? container(), restartPolicy: policy, maximumRetryCount: nil, startedAt: started, imageID: "sha256:image")
    }
    private func snapshot(_ activities: [Activity]) -> ScanSnapshot { ScanSnapshot(activities: activities, limitations: []) }
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func engine(_ id: String, address: String, transport: String = "tcp", name: String = "web") -> [String: Any] {
        ["Id": id, "Names": ["/" + name], "Image": "nginx", "Ports": [
            ["IP": address, "PublicPort": 5353, "PrivatePort": 80, "Type": transport]
        ], "Labels": ["com.docker.compose.project": "demo",
                      "com.docker.compose.project.config_files": "/Users/test/project/compose.yaml"],
         "Mounts": [["Type": "bind", "Source": "/Users/test/project", "Destination": "/app"]]]
    }
    private func inspectJSON(id: String? = nil, name: String = "web", transport: String = "tcp") -> [String: Any] {
        ["Id": id ?? idA, "Name": "/" + name, "Image": "sha256:image", "Config": ["Image": "nginx"],
         "State": ["Running": true, "StartedAt": "2026-10-01T00:00:00Z"],
         "HostConfig": ["RestartPolicy": ["Name": "no"]],
         "NetworkSettings": ["Ports": ["80/" + transport: [["HostIp": "127.0.0.1", "HostPort": "5353"]]]]]
    }
    private func plan(_ info: ContainerInfo? = nil) throws -> ContainerStopPlan {
        let info = info ?? container()
        return try ContainerResolver.makePlan(activity: activity(info), inspection: inspection(info))
    }

    func testUDPDoesNotOwnTCPListenerAndOrderDoesNotMatter() throws {
        let udp = engine(idA, address: "127.0.0.1", transport: "udp", name: "udp-only")
        let tcp = engine(idB, address: "127.0.0.1", name: "web")
        for entries in [[udp, tcp], [tcp, udp]] {
            let parsed = try XCTUnwrap(ContainerResolver.parseEngineList(try data(entries), endpoint: endpoint, daemonID: "local"))
            XCTAssertEqual(ContainerResolver.match(activity().listener, in: parsed)?.id, idB)
        }
        let onlyUDP = try XCTUnwrap(ContainerResolver.parseEngineList(try data([udp]), endpoint: endpoint, daemonID: "local"))
        XCTAssertNil(ContainerResolver.match(activity().listener, in: onlyUDP))
    }

    func testAddressMatchingRefusesPortOnlyAndDuplicateOwners() {
        let first = container(bindings: [binding("127.0.0.1")])
        let second = container(id: idB, bindings: [binding("127.0.0.2")])
        XCTAssertEqual(ContainerResolver.match(activity().listener, in: [first, second])?.id, idA)
        XCTAssertEqual(ContainerResolver.match(activity(addresses: ["127.0.0.2"]).listener, in: [first, second])?.id, idB)
        XCTAssertNil(ContainerResolver.match(activity(addresses: ["*"]).listener, in: [first, second]))
        XCTAssertNil(ContainerResolver.match(activity().listener, in: [first, container(id: idB)]))
        XCTAssertNil(ContainerResolver.match(activity(addresses: ["127.0.0.1", "127.0.0.2"]).listener, in: [first, second]))
    }

    func testWildcardRequiresOneOwnerAcrossAllAddresses() {
        let wildcard = container(bindings: [binding("0.0.0.0"), binding("::")])
        XCTAssertEqual(ContainerResolver.match(activity(addresses: ["*"]).listener, in: [wildcard])?.id, idA)
        XCTAssertNil(ContainerResolver.match(activity(addresses: ["*"]).listener,
                                              in: [wildcard, container(id: idB, bindings: [binding("127.0.0.2")])]))
        XCTAssertNil(ContainerResolver.match(activity().listener, in: [wildcard]), "Do not guess wildcard-to-specific forwarding")
    }

    func testIPv6NormalizationAndUnknownAddresses() {
        XCTAssertEqual(ContainerResolver.normalizedAddress("[0:0:0:0:0:0:0:1]"), "::1")
        XCTAssertEqual(ContainerResolver.normalizedAddress("[::]"), "::")
        XCTAssertNil(ContainerResolver.normalizedAddress("some-host.example"))
        let owner = container(bindings: [binding("::1")])
        XCTAssertEqual(ContainerResolver.match(activity(addresses: ["[::1]"]).listener, in: [owner])?.id, idA)
    }

    func testEngineKeepsFullIdentityComposeAndBindMounts() throws {
        let parsed = try XCTUnwrap(ContainerResolver.parseEngineList(try data([engine(idA, address: "127.0.0.1")]), endpoint: endpoint, daemonID: "local"))
        let info = try XCTUnwrap(parsed.first)
        XCTAssertEqual(info.id, idA)
        XCTAssertEqual(info.endpoint, endpoint)
        XCTAssertEqual(info.daemonID, "local")
        XCTAssertEqual(info.composeProject, "demo")
        XCTAssertEqual(info.composeDir, "/Users/test/project")
        XCTAssertEqual(info.mounts, [ContainerMount(source: "/Users/test/project", destination: "/app")])
        XCTAssertEqual(info.bindings, [binding()])
    }

    func testIncompleteEngineOwnershipFailsClosed() throws {
        XCTAssertNil(ContainerResolver.parseEngineList(try data([engine("aaaaaaaaaaaa", address: "127.0.0.1")]), endpoint: endpoint, daemonID: "local"))
        var missingIP = engine(idA, address: "127.0.0.1")
        missingIP["Ports"] = [["PublicPort": 5353, "PrivatePort": 80, "Type": "tcp"]]
        XCTAssertNil(ContainerResolver.parseEngineList(try data([missingIP]), endpoint: endpoint, daemonID: "local"))
        XCTAssertNil(ContainerResolver.parseEngineList(Data("[]".utf8), endpoint: endpoint, daemonID: ""))
    }

    func testCLIInspectionDistinguishesUDPAndTCP() throws {
        let udp = try XCTUnwrap(ContainerResolver.parseInspection(inspectJSON(transport: "udp"), endpoint: endpoint, daemonID: "local"))
        let tcp = try XCTUnwrap(ContainerResolver.parseInspection(inspectJSON(id: idB), endpoint: endpoint, daemonID: "local"))
        XCTAssertEqual(ContainerResolver.match(activity().listener, in: [udp.container, tcp.container])?.id, idB)
        XCTAssertEqual(tcp.container.id, idB)
    }

    func testOnlyKnownDirectForwarderGetsEndpointCandidate() {
        XCTAssertEqual(ContainerResolver.socketCandidate(for: activity(), home: "/Users/test"), "/Users/test/.docker/run/docker.sock")
        XCTAssertEqual(ContainerResolver.socketCandidate(for: activity(path: "/Applications/OrbStack.app/Contents/MacOS/OrbStack-helper"), home: "/Users/test"), "/Users/test/.orbstack/run/docker.sock")
        XCTAssertEqual(ContainerResolver.socketCandidate(for: activity(path: "/Users/test/.colima/_lima/colima-work/docker-proxy"), home: "/Users/test"), "/Users/test/.colima/work/docker.sock")
        XCTAssertNil(ContainerResolver.socketCandidate(for: activity(path: "/opt/homebrew/bin/gvproxy"), home: "/Users/test"))
        XCTAssertNil(ContainerResolver.socketCandidate(for: activity(path: "/opt/homebrew/bin/node"), home: "/Users/test"))
        XCTAssertNil(ContainerResolver.socketCandidate(for: activity(path: "/Applications/Docker.app/Contents/MacOS/unrelated"), home: "/Users/test"))
    }

    func testScannerNeverAttachesContainerToNativeSamePortOrWrongEndpoint() {
        let runtime = activity()
        let native = activity(addresses: ["127.0.0.2"], pid: 43, path: "/opt/homebrew/bin/node")
        let owner = container()
        let resolved = Scanner.resolveContainers([runtime, native], lookup: { candidates in
            XCTAssertEqual(candidates.map(\.id), [runtime.id])
            // Even an overbroad lookup cannot smuggle metadata onto the native listener.
            return [runtime.id: owner, native.id: owner]
        }, endpoint: { $0.id == runtime.id ? self.endpoint : nil })
        XCTAssertEqual(resolved[0].container, owner)
        XCTAssertNil(resolved[1].container)
        XCTAssertEqual(resolved[1].inference, native.inference)
        let wrong = Scanner.resolveContainers([runtime], lookup: { _ in [runtime.id: self.container(endpoint: self.otherEndpoint)] }, endpoint: { _ in self.endpoint })
        XCTAssertNil(wrong[0].container)
    }

    func testSocketFailureFallbackBackoffAndRecoveryAreDeterministic() throws {
        let output = String(decoding: try data([inspectJSON()]), as: UTF8.self)
        let list = try data([engine(idA, address: "127.0.0.1")])
        var socketCalls = 0
        var cliCalls = 0
        var socketHealthy = false
        var cliHealthy = true
        let deps = ContainerResolver.Dependencies(endpoint: { _ in self.endpoint }, get: { _, path in
            socketCalls += 1
            guard socketHealthy else { return nil }
            return path == "/info" ? Data(#"{"ID":"local-daemon"}"#.utf8) : list
        }, command: { endpoint, args, _ in
            XCTAssertEqual(endpoint, self.endpoint)
            cliCalls += 1
            guard cliHealthy else { throw ContainerResolver.unavailable() }
            if args.first == "info" { return "local-daemon\n" }
            if args.contains("ls") { return self.idA + "\n" }
            return output
        })
        let backoff = ContainerResolver.Backoff()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertNotNil(ContainerResolver.resolve([activity()], dependencies: deps, backoff: backoff, now: start)[activity().id])
        XCTAssertEqual(socketCalls, 1)
        XCTAssertEqual(cliCalls, 3)
        XCTAssertNotNil(ContainerResolver.resolve([activity()], dependencies: deps, backoff: backoff, now: start.addingTimeInterval(1))[activity().id])
        XCTAssertEqual(socketCalls, 1, "Socket backoff never blocks CLI")
        cliHealthy = false
        XCTAssertTrue(ContainerResolver.resolve([activity()], dependencies: deps, backoff: backoff, now: start.addingTimeInterval(2)).isEmpty)
        let afterFailure = cliCalls
        XCTAssertTrue(ContainerResolver.resolve([activity()], dependencies: deps, backoff: backoff, now: start.addingTimeInterval(3)).isEmpty)
        XCTAssertEqual(cliCalls, afterFailure)
        socketHealthy = true
        XCTAssertNotNil(ContainerResolver.resolve([activity()], dependencies: deps, backoff: backoff, now: start.addingTimeInterval(61))[activity().id])
        XCTAssertEqual(socketCalls, 3, "Both info and inventory recover after socket delay")
        socketHealthy = false
        cliHealthy = true
        XCTAssertNotNil(ContainerResolver.resolve([activity()], dependencies: deps, backoff: backoff, now: start.addingTimeInterval(122))[activity().id])
        XCTAssertEqual(cliCalls, afterFailure + 3, "CLI also recovers after its own failure delay")
    }

    func testFailureOnOneEndpointDoesNotBackOffAnother() throws {
        let inventory = try data([engine(idA, address: "127.0.0.1")])
        let backoff = ContainerResolver.Backoff()
        var selected = endpoint
        var calls = 0
        let deps = ContainerResolver.Dependencies(endpoint: { _ in selected }, get: { endpoint, path in
            calls += 1
            guard endpoint == self.otherEndpoint else { return nil }
            return path == "/info" ? Data(#"{"ID":"other-local"}"#.utf8) : inventory
        }, command: { _, _, _ in throw ContainerResolver.unavailable() })
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(ContainerResolver.resolve([activity()], dependencies: deps, backoff: backoff, now: now).isEmpty)
        selected = otherEndpoint
        XCTAssertNotNil(ContainerResolver.resolve([activity()], dependencies: deps, backoff: backoff, now: now)[activity().id])
        XCTAssertEqual(calls, 3)
    }

    func testUnresolvedEndpointNeverInvokesSocketOrCLI() {
        let deps = ContainerResolver.Dependencies(endpoint: { _ in nil }, get: { _, _ in XCTFail("No endpoint"); return nil },
                                                 command: { _, _, _ in XCTFail("No endpoint"); return "" })
        XCTAssertTrue(ContainerResolver.resolve([activity()], dependencies: deps, backoff: ContainerResolver.Backoff(), now: Date()).isEmpty)
    }

    func testInheritedRemoteContextAndTLSAreNotPassedToCLI() {
        let env = ContainerResolver.dockerEnvironment(["DOCKER_HOST": "ssh://remote", "DOCKER_CONTEXT": "production",
                                                       "DOCKER_TLS_VERIFY": "1", "DOCKER_CONFIG": "/other", "PATH": "/bin", "HOME": "/Users/test"])
        XCTAssertEqual(env, ["PATH": "/bin", "HOME": "/Users/test"])
        let info = container(name: "same-name-as-remote")
        XCTAssertEqual(info.stopCommand, "docker --host 'unix:///Users/test/.docker/run/docker.sock' stop \(idA)")
        XCTAssertFalse(info.stopCommand.contains(info.name))
    }

    func testPinnedInspectRejectsDifferentDaemonWithoutFallback() {
        var cliCalls = 0
        let deps = ContainerResolver.Dependencies(endpoint: { _ in self.endpoint },
            get: { _, _ in Data(#"{"ID":"other-daemon"}"#.utf8) },
            command: { _, _, _ in cliCalls += 1; return "" })
        XCTAssertThrowsError(try ContainerResolver.inspect(container(), dependencies: deps))
        XCTAssertEqual(cliCalls, 0)
    }

    func testPinnedCLIInspectUsesIDNotNameAndRejectsReplacement() throws {
        let replacement = String(decoding: try data([inspectJSON(id: idB)]), as: UTF8.self)
        var commands: [[String]] = []
        let deps = ContainerResolver.Dependencies(endpoint: { _ in self.endpoint }, get: { _, _ in nil }, command: { endpoint, args, _ in
            XCTAssertEqual(endpoint, self.endpoint)
            commands.append(args)
            return args.first == "info" ? "local-daemon" : replacement
        })
        XCTAssertThrowsError(try ContainerResolver.inspect(container(), dependencies: deps))
        XCTAssertEqual(commands, [["info", "--format", "{{.ID}}"], ["container", "inspect", idA]])
    }

    func testUnchangedConfirmedPlanStopsExactlyOnceByPinnedID() throws {
        let plan = try plan()
        var writes = 0
        let result = try ContainerResolver.execute(plan, scan: { self.snapshot([self.activity(self.container())]) },
            inspect: { _ in self.inspection() }, endpoint: { _ in self.endpoint }, command: { endpoint, args, _ in
                writes += 1
                XCTAssertEqual(endpoint, self.endpoint)
                XCTAssertEqual(args, ["stop", self.idA])
                return self.idA
            }, checkCancellation: {})
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(result, idA)
    }

    func testIdentityEndpointMetadataAndScanFailuresNeverStop() throws {
        let plan = try plan()
        let changedOwners: [ContainerInfo?] = [nil, container(id: idB), container(daemon: "other-daemon"), container(endpoint: otherEndpoint)]
        for owner in changedOwners {
            var writes = 0
            XCTAssertThrowsError(try ContainerResolver.execute(plan, scan: { self.snapshot([self.activity(owner)]) },
                inspect: { _ in self.inspection() }, endpoint: { _ in self.endpoint },
                command: { _, _, _ in writes += 1; return "" }, checkCancellation: {}))
            XCTAssertEqual(writes, 0)
        }
        var writes = 0
        XCTAssertThrowsError(try ContainerResolver.execute(plan, scan: { throw ContainerResolver.unavailable() },
            inspect: { _ in self.inspection() }, endpoint: { _ in self.endpoint },
            command: { _, _, _ in writes += 1; return "" }, checkCancellation: {}))
        XCTAssertThrowsError(try ContainerResolver.execute(plan, scan: { self.snapshot([self.activity(self.container())]) },
            inspect: { _ in self.inspection() }, endpoint: { _ in self.otherEndpoint },
            command: { _, _, _ in writes += 1; return "" }, checkCancellation: {}))
        XCTAssertEqual(writes, 0)
    }

    func testChangedImpactRenameRestartOrPolicyNeverStops() throws {
        let plan = try plan()
        let changed = [inspection(container(name: "renamed")), inspection(container(bindings: [binding("127.0.0.2")])), inspection(container(bindings: [binding(), binding(port: 8080)])),
                       inspection(container(bindings: [binding(), binding(port: 5353, transport: "udp")])),
                       inspection(policy: "always"), inspection(started: "2026-10-02T00:00:00Z")]
        for value in changed {
            var writes = 0
            XCTAssertThrowsError(try ContainerResolver.execute(plan, scan: { self.snapshot([self.activity(self.container())]) },
                inspect: { _ in value }, endpoint: { _ in self.endpoint },
                command: { _, _, _ in writes += 1; return "" }, checkCancellation: {}))
            XCTAssertEqual(writes, 0)
        }
    }

    func testCancellationBeforeAndAfterRevalidationNeverStops() throws {
        let plan = try plan()
        for cancelAt in [1, 2] {
            var checks = 0
            var writes = 0
            XCTAssertThrowsError(try ContainerResolver.execute(plan, scan: { self.snapshot([self.activity(self.container())]) },
                inspect: { _ in self.inspection() }, endpoint: { _ in self.endpoint },
                command: { _, _, _ in writes += 1; return "" }, checkCancellation: {
                    checks += 1
                    if checks == cancelAt { throw CancellationError() }
                }))
            XCTAssertEqual(writes, 0)
        }
    }

    func testFrozenImpactSurvivesMissingMetadataAndNewOwnership() throws {
        let plan = try plan(container(bindings: [binding(), binding(port: 8080), binding(port: 9999, transport: "udp")]))
        XCTAssertEqual(plan.reviewedTCPPorts, [5353, 8080])
        XCTAssertEqual(plan.reviewedBindings.count, 3, "Review includes UDP impact even though scanner observes TCP")
        XCTAssertEqual(ContainerStopVerification.evaluate(plan, freshSnapshot: snapshot([activity(nil)])), .stillListening([5353]))
        XCTAssertEqual(ContainerStopVerification.evaluate(plan, freshSnapshot: snapshot([activity(container(id: idB))])), .stillListening([5353]))
        XCTAssertEqual(ContainerStopVerification.evaluate(plan, freshSnapshot: snapshot([activity(nil, port: 8080, pid: 44)])), .stillListening([8080]))
        XCTAssertEqual(ContainerStopVerification.evaluate(plan, freshSnapshot: nil), .unavailable)
        XCTAssertEqual(ContainerStopVerification.evaluate(plan, freshSnapshot: snapshot([])), .free)
    }

    func testSelectedPortCannotDisappearFromAnEmptyImpactSet() {
        // Even a defensive/internal plan with no mappings cannot claim the selected port is free.
        let info = container(bindings: [])
        let plan = ContainerStopPlan(activity: activity(info), inspection: inspection(info))
        XCTAssertEqual(plan.reviewedTCPPorts, [5353])
        XCTAssertEqual(ContainerStopVerification.evaluate(plan, freshSnapshot: snapshot([activity()])), .stillListening([5353]))
        XCTAssertThrowsError(try ContainerResolver.makePlan(activity: activity(info), inspection: inspection(info)))
    }

    func testUnknownRestartPolicyIsPreservedAndAlwaysPolicyIsFlagged() throws {
        let noPolicy = try ContainerResolver.makePlan(activity: activity(container()), inspection: inspection(policy: nil))
        XCTAssertNil(noPolicy.restartPolicy)
        XCTAssertFalse(noPolicy.resurrectsOnDaemonRestart)
        let always = try ContainerResolver.makePlan(activity: activity(container()), inspection: inspection(policy: "always"))
        XCTAssertTrue(always.resurrectsOnDaemonRestart)
    }
}
