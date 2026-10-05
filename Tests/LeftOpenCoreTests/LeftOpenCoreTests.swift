import Darwin
import Network
import XCTest
@testable import LeftOpenCore

final class LeftOpenCoreTests: XCTestCase {
    private func forceFixture() throws -> (Activity, ClosePlan) {
        let activity = fixtureActivity(pid: 42, path: "/opt/local/bin/node")
        let plan = try CloseService.makePlan(activities: [activity], port: 3000, pid: 42,
            currentUID: Int32(getuid()), currentPID: getpid(), startTime: { _ in "original" })
        return (activity, plan)
    }

    private func forceOffer() throws -> (Activity, ForceCloseOffer) {
        let (activity, plan) = try forceFixture()
        let result = try CloseService.perform(plan, signal: SIGTERM,
            scan: { [activity] }, startTime: { _ in "original" }, send: { _, _ in 0 },
            listeners: { [activity.listener] }, wait: {})
        return (activity, try XCTUnwrap(result.forceCloseOffer))
    }

    func testForceCloseRequiresFailedGentleAttemptAndExplicitExecution() throws {
        let (activity, plan) = try forceFixture()
        var signals: [Int32] = []
        let send: (Int32, Int32) -> Int32 = { pid, signal in
            XCTAssertEqual(pid, 42)
            signals.append(signal)
            return 0
        }
        XCTAssertThrowsError(try CloseService.perform(plan, signal: SIGKILL,
            scan: { [activity] }, startTime: { _ in "original" }, send: send,
            listeners: { [] }, wait: {}))
        XCTAssertTrue(signals.isEmpty)
        let gentle = try CloseService.perform(plan, signal: SIGTERM,
            scan: { [activity] }, startTime: { _ in "original" }, send: send,
            listeners: { [activity.listener] }, wait: {})
        XCTAssertEqual(signals, [SIGTERM])
        let offer = try XCTUnwrap(gentle.forceCloseOffer)
        let forced = try CloseService.perform(plan, signal: SIGKILL, offer: offer,
            scan: { [activity] }, startTime: { _ in "original" }, send: send,
            listeners: { [] }, wait: {})
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
        XCTAssertTrue(forced.portFree)
        XCTAssertNil(forced.forceCloseOffer)
    }

    func testSuccessfulGentleCloseNeverOffersForce() throws {
        let (activity, plan) = try forceFixture()
        let result = try CloseService.perform(plan, signal: SIGTERM,
            scan: { [activity] }, startTime: { _ in "original" }, send: { _, _ in 0 },
            listeners: { [] }, wait: {})
        XCTAssertNil(result.forceCloseOffer)
        XCTAssertTrue(result.portFree)
        // A different PID holding the port is not eligible either.
        let peer = fixtureActivity(pid: 43, path: "/opt/local/bin/node")
        let occupied = try CloseService.perform(plan, signal: SIGTERM,
            scan: { [activity] }, startTime: { _ in "original" }, send: { _, _ in 0 },
            listeners: { [peer.listener] }, wait: {})
        XCTAssertNil(occupied.forceCloseOffer)
        XCTAssertFalse(occupied.portFree)
    }

    func testFailedSignalOrUnknownOutcomeDoesNotProduceForceOffer() throws {
        let (activity, plan) = try forceFixture()
        XCTAssertThrowsError(try CloseService.perform(plan, signal: SIGTERM,
            scan: { [activity] }, startTime: { _ in "original" }, send: { _, _ in -1 },
            listeners: { XCTFail("Should not scan after failed signal"); return [] }, wait: {}))
        XCTAssertThrowsError(try CloseService.perform(plan, signal: SIGTERM,
            scan: { [activity] }, startTime: { _ in "original" }, send: { _, _ in 0 },
            listeners: { throw CloseError("scan unavailable") }, wait: {})) { error in
                XCTAssertTrue((error as? CloseError)?.signalSent == true)
            }
    }

    func testForceCloseRejectsChangedIdentityPeersPortsAndExpiry() throws {
        let (activity, offer) = try forceOffer()
        let cases: [([Activity], String?)] = [
            ([], "original"), ([activity], "reused PID"), ([activity], nil),
            ([fixtureActivity(pid: 42, path: "/opt/local/bin/python")], "original"),
            ([fixtureActivity(pid: 42, path: "/opt/local/bin/node", uid: Int32(getuid()) + 1)], "original"),
            ([activity, fixtureActivity(pid: 43, path: "/opt/local/bin/node")], "original"),
            ([activity, fixtureActivity(pid: 42, path: "/opt/local/bin/node", port: 3001)], "original"),
            ([fixtureActivity(pid: 42, path: "/opt/local/bin/node", appBundle: true)], "original"),
        ]
        for (activities, start) in cases {
            XCTAssertThrowsError(try CloseService.perform(offer.plan, signal: SIGKILL, offer: offer,
                scan: { activities }, startTime: { _ in start },
                send: { _, _ in XCTFail("Must not send a signal"); return 0 },
                listeners: { [] }, wait: {}))
        }
        XCTAssertThrowsError(try CloseService.verifyForceClose(offer, activities: [activity],
            freshStartTime: "original", now: Date().addingTimeInterval(121)))
    }

    func testForceCloseAgainstOwnedUncooperativeListener() throws {
        // Only this test-owned child is signalled; it never uses an existing listener.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import signal,socket,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); time.sleep(30)"]
        try child.run()
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        var port: Int?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && child.isRunning {
            port = try Scanner.scanListeners().first { $0.pid == child.processIdentifier }?.port
            if port != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // The fixture uses the system Python executable, so disable path protection
        // for this explicitly owned PID only; identity checks remain enforced.
        let plan = try CloseService.prepare(port: XCTUnwrap(port), pid: child.processIdentifier,
                                            safetyProtectionEnabled: false)
        let gentle = try CloseService.execute(plan)
        XCTAssertFalse(gentle.targetStoppedListening)
        XCTAssertTrue(child.isRunning)
        let result = try CloseService.forceClose(XCTUnwrap(gentle.forceCloseOffer))
        XCTAssertTrue(result.targetStoppedListening)
        XCTAssertTrue(result.portFree)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)
    }

    func testBrowserAddressUsesObservedBindAddress() {
        func url(_ addresses: [String]) -> String? {
            let listener = Listener(pid: 42, command: "node", uid: 501, user: nil,
                                    port: 3000, addresses: addresses)
            return BrowserAddress.candidateURL(for: listener)?.absoluteString
        }

        XCTAssertEqual(url(["127.0.0.1"]), "http://127.0.0.1:3000")
        XCTAssertEqual(url(["0.0.0.0"]), "http://localhost:3000")
        XCTAssertEqual(url(["*"]), "http://localhost:3000")
        XCTAssertEqual(url(["[::]"]), "http://[::1]:3000")
        XCTAssertEqual(url(["[::1]"]), "http://[::1]:3000")
        XCTAssertEqual(url(["192.168.1.20"]), "http://192.168.1.20:3000")
        XCTAssertEqual(url(["127.0.0.1", "192.168.1.20"]), "http://192.168.1.20:3000")
        XCTAssertNil(url(["not-an-address"]))

        let listener = Listener(pid: 42, command: "service", uid: 501, user: nil,
                                port: 3000, addresses: ["192.168.1.20"])
        XCTAssertEqual(BrowserAddress.probeURLs(for: listener).map(\.absoluteString), [
            "https://192.168.1.20:3000", "http://192.168.1.20:3000",
        ])
    }

    func testWebProbeShowsOnlyRespondingHTTPService() async {
        let listener = Listener(pid: 42, command: "service", uid: 501, user: nil,
                                port: 3000, addresses: ["127.0.0.1"])
        let httpConfig = URLSessionConfiguration.ephemeral
        httpConfig.protocolClasses = [HeadOnlyHTTPProtocol.self]
        let httpSession = URLSession(configuration: httpConfig)
        let found = await WebProbe.detect(listener, using: httpSession)
        XCTAssertEqual(found?.absoluteString, "http://127.0.0.1:3000")
        httpSession.invalidateAndCancel()

        let otherConfig = URLSessionConfiguration.ephemeral
        otherConfig.protocolClasses = [NonHTTPProtocol.self]
        let otherSession = URLSession(configuration: otherConfig)
        let missing = await WebProbe.detect(listener, using: otherSession)
        XCTAssertNil(missing)
        otherSession.invalidateAndCancel()

        let untrustedConfig = URLSessionConfiguration.ephemeral
        untrustedConfig.protocolClasses = [UntrustedHTTPSProtocol.self]
        let untrustedSession = URLSession(configuration: untrustedConfig)
        let untrusted = await WebProbe.detect(listener, using: untrustedSession)
        XCTAssertNil(untrusted)
        untrustedSession.invalidateAndCancel()

        let redirectConfig = URLSessionConfiguration.ephemeral
        redirectConfig.protocolClasses = [RedirectHTTPProtocol.self]
        let redirectSession = URLSession(configuration: redirectConfig)
        let redirect = await WebProbe.detect(listener, using: redirectSession)
        XCTAssertEqual(redirect?.absoluteString, "http://127.0.0.1:3000")
        redirectSession.invalidateAndCancel()
    }

    func testWebProbeAgainstRealLoopbackHTTP() async throws {
        let server = try NWListener(using: .tcp, on: .any)
        defer { server.cancel() }
        let queue = DispatchQueue(label: "leftopen.web-probe-test")
        let ready = expectation(description: "Loopback server ready")
        server.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        server.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 5, maximumLength: 4096) { data, _, _, _ in
                guard let data, String(decoding: data, as: UTF8.self).hasPrefix("HEAD ") else {
                    connection.cancel()
                    return
                }
                let response = Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        server.start(queue: queue)
        await fulfillment(of: [ready], timeout: 2)

        let port = try XCTUnwrap(server.port.map { Int($0.rawValue) })
        let listener = Listener(pid: 42, command: "service", uid: 501, user: nil,
                                port: port, addresses: ["127.0.0.1"])
        let found = await WebProbe.detect(listener)
        XCTAssertEqual(found?.absoluteString, "http://127.0.0.1:\(port)")
    }

    func testLsofMergesIPv4AndIPv6ForSamePIDAndPort() {
        let output = """
        p42
        cnode
        u501
        Lsong
        n127.0.0.1:3000
        n[::1]:3000
        p43
        cpython
        u501
        n*:8080
        """
        let values = Scanner.parseListeners(output)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].addresses, ["127.0.0.1", "[::1]"])
        XCTAssertEqual(values[0].uid, 501)
        XCTAssertEqual(values[0].user, "song")
        XCTAssertEqual(values[1].port, 8080)
    }

    func testScopeUsesOnlyObservedBindAddresses() {
        XCTAssertEqual(Scanner.listenerScope(["127.0.0.1", "[::1]"]), .local)
        XCTAssertEqual(Scanner.listenerScope(["127.0.0.1", "*"]), .lan)
    }

    func testCloseRecheckRejectsChangedIdentity() throws {
        let activity = fixtureActivity(pid: 42, path: "/opt/local/bin/node")
        let plan = ClosePlan(port: 3000, pid: 42, uid: Int32(getuid()),
            executablePath: "/opt/local/bin/node", startTime: "start one", activity: activity,
            otherPorts: [], peerPIDs: [], safetyProtectionEnabled: true)
        XCTAssertThrowsError(try CloseService.verify(plan: plan, activities: [activity], freshStartTime: "start two"))
        XCTAssertThrowsError(try CloseService.verify(plan: plan,
            activities: [fixtureActivity(pid: 42, path: "/opt/local/bin/python")], freshStartTime: "start one"))
        XCTAssertThrowsError(try CloseService.verify(plan: plan,
            activities: [fixtureActivity(pid: 43, path: "/opt/local/bin/node")], freshStartTime: "start one"))
    }

    func testCloseRecheckRejectsNewPortPeer() throws {
        let activity = fixtureActivity(pid: 42, path: "/opt/local/bin/node")
        let plan = ClosePlan(port: 3000, pid: 42, uid: Int32(getuid()),
            executablePath: "/opt/local/bin/node", startTime: "start one", activity: activity,
            otherPorts: [], peerPIDs: [], safetyProtectionEnabled: true)
        XCTAssertThrowsError(try CloseService.verify(plan: plan,
            activities: [activity, fixtureActivity(pid: 43, path: "/opt/local/bin/node")],
            freshStartTime: "start one"))
    }

    func testLiveScanProducesEvidenceBasedActivities() throws {
        let snapshot = try Scanner.scan()
        print("Native scan: \(snapshot.portCount) ports, \(snapshot.activities.count) activities")
        for activity in snapshot.activities {
            XCTAssertTrue((1...65535).contains(activity.listener.port))
            XCTAssertGreaterThan(activity.process.pid, 0)
            XCTAssertFalse(activity.inference.reason.isEmpty)
            if activity.inference.category == .unknown {
                XCTAssertEqual(activity.inference.label, "Unknown")
            }
        }
    }

    func testClosePreviewRejectsAmbiguousAndProtectedProcesses() throws {
        let safe = fixtureActivity(pid: 42, path: "/opt/local/bin/node")
        let peer = fixtureActivity(pid: 43, path: "/opt/local/bin/node")
        let uid = Int32(getuid())
        let startTime: (Int32) -> String? = { _ in "start one" }
        XCTAssertThrowsError(try CloseService.makePlan(activities: [safe, peer], port: 3000,
            pid: nil, currentUID: uid, currentPID: 99, startTime: startTime))
        XCTAssertThrowsError(try CloseService.makePlan(activities: [safe], port: 3000,
            pid: nil, currentUID: 0, currentPID: 99, startTime: startTime))
        XCTAssertThrowsError(try CloseService.makePlan(activities: [safe], port: 3000,
            pid: nil, currentUID: uid, currentPID: 42, startTime: startTime))
        for activity in [
            fixtureActivity(pid: 42, path: nil),
            fixtureActivity(pid: 42, path: "/usr/bin/node"),
            fixtureActivity(pid: 42, path: "/opt/local/bin/node", uid: uid + 1),
            fixtureActivity(pid: 42, path: "/opt/local/bin/node", appBundle: true),
        ] {
            XCTAssertThrowsError(try CloseService.makePlan(activities: [activity], port: 3000,
                pid: nil, currentUID: uid, currentPID: 99, startTime: startTime))
        }
        XCTAssertThrowsError(try CloseService.makePlan(activities: [safe], port: 3000,
            pid: nil, currentUID: uid, currentPID: 99, startTime: { _ in nil }))
    }

    func testClosePreviewReportsOtherPortsForSamePID() throws {
        let uid = Int32(getuid())
        let plan = try CloseService.makePlan(activities: [
            fixtureActivity(pid: 42, path: "/opt/local/bin/node"),
            fixtureActivity(pid: 42, path: "/opt/local/bin/node", port: 3001),
        ], port: 3000, pid: nil, currentUID: uid, currentPID: 99,
        startTime: { _ in "start one" })
        XCTAssertEqual(plan.otherPorts, [3001])
        XCTAssertEqual(plan.peerPIDs, [])
    }

    func testUIExplainsWhyKnownProtectedTargetsCannotClose() {
        XCTAssertNil(CloseService.protectionReason(for:
            fixtureActivity(pid: 42, path: "/opt/local/bin/node")))
        XCTAssertNotNil(CloseService.protectionReason(for:
            fixtureActivity(pid: 42, path: "/usr/bin/node")))
        XCTAssertNotNil(CloseService.protectionReason(for:
            fixtureActivity(pid: 42, path: "/opt/local/bin/node", appBundle: true)))
        XCTAssertNotNil(CloseService.protectionReason(for:
            fixtureActivity(pid: 42, path: nil)))
    }

    func testSafetyProtectionCanBeDisabledWithoutSkippingIdentityChecks() throws {
        let uid = Int32(getuid())
        var keepAlive = fixtureActivity(pid: 42, path: "/opt/homebrew/bin/node")
        keepAlive.launchdJob = LaunchdJob(label: "com.example.server", pid: 42, keepAlive: true)
        let protectedActivities = [
            fixtureActivity(pid: 42, path: "/usr/bin/python"),
            fixtureActivity(pid: 42, path: "/opt/local/bin/node", appBundle: true),
            keepAlive,
        ]
        for activity in protectedActivities {
            XCTAssertNotNil(CloseService.protectionReason(for: activity))
            XCTAssertNil(CloseService.protectionReason(for: activity,
                safetyProtectionEnabled: false))
            XCTAssertNoThrow(try CloseService.makePlan(activities: [activity], port: 3000,
                pid: nil, currentUID: uid, currentPID: 99, startTime: { _ in "start one" },
                safetyProtectionEnabled: false))
        }

        XCTAssertNotNil(CloseService.protectionReason(for:
            fixtureActivity(pid: 42, path: nil), safetyProtectionEnabled: false))
        XCTAssertNotNil(CloseService.protectionReason(for:
            fixtureActivity(pid: 42, path: "/opt/local/bin/node", uid: uid + 1),
            safetyProtectionEnabled: false))
    }

    func testIndirectAppParentDoesNotOverrideConcreteProject() {
        let project = ProjectMarker(name: "token-flow", root: "/private/tmp/project",
            source: ".git", markerPath: "/private/tmp/project/.git")
        let bundle = ApplicationBundle(name: "Codex", path: "/Applications/Codex.app",
            sourcePID: 99, direct: false)
        let base = fixtureActivity(pid: 42, path: "/opt/homebrew/bin/python3.13")
        let activity = Activity(listener: base.listener, process: base.process, parentChain: [],
            projectMarker: project, applicationBundle: bundle, scope: .local,
            inference: OwnerInference(label: "token-flow", category: .project,
                confidence: "high", reason: "Concrete project root."))

        XCTAssertEqual(PortCategory.classify([activity]), .devServer)
        XCTAssertNil(CloseService.protectionReason(for: activity))
    }

    func testProjectRuntimeInsideAppDoesNotBecomeAppOwned() {
        let project = ProjectMarker(name: "site", root: "/private/tmp/site",
            source: ".git", markerPath: "/private/tmp/site/.git")
        let base = fixtureActivity(pid: 42, path: "/opt/homebrew/bin/python3")
        let runtimes = [
            ("/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python", "Python"),
            ("/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python", "Python"),
            ("/Applications/Tool.app/Contents/Resources/runtime/bin/node", "node"),
        ]
        for (path, command) in runtimes {
            let process = ProcessFact(pid: 42, ppid: 500, command: command, executablePath: path,
                uid: Int32(getuid()), user: nil, cwd: project.root)
            let bundle = Scanner.applicationBundle(for: process, parents: [], launchedPath: path, project: project)
            XCTAssertNil(bundle, "An embedded runtime is not the owner of the project listener")
            let activity = Activity(listener: base.listener, process: process, parentChain: [],
                projectMarker: project, applicationBundle: bundle, scope: .local,
                inference: OwnerInference(label: project.name, category: .project,
                    confidence: "high", reason: "Project marker."))
            XCTAssertEqual(PortCategory.classify([activity]), .devServer)
            XCTAssertNil(CloseService.protectionReason(for: activity))
        }

        let appPath = "/Applications/Editor.app/Contents/MacOS/Editor"
        let appProcess = ProcessFact(pid: 42, ppid: 500, command: "Editor", executablePath: appPath,
            uid: Int32(getuid()), user: nil, cwd: project.root)
        let appBundle = Scanner.applicationBundle(for: appProcess, parents: [], launchedPath: appPath, project: project)
        XCTAssertEqual(appBundle?.name, "Editor")
        XCTAssertEqual(appBundle?.direct, true)
        let appActivity = Activity(listener: base.listener, process: appProcess, parentChain: [],
            projectMarker: project, applicationBundle: appBundle, scope: .local,
            inference: OwnerInference(label: project.name, category: .project,
                confidence: "high", reason: "Project marker."))
        XCTAssertEqual(PortCategory.classify([appActivity]), .app)
        XCTAssertNotNil(CloseService.protectionReason(for: appActivity))
    }

    func testKeepAliveServicesAreRefusedWithAStopCommand() {
        var brew = fixtureActivity(pid: 42, path: "/opt/homebrew/opt/syncthing/bin/syncthing")
        brew.launchdJob = LaunchdJob(label: "homebrew.mxcl.syncthing", pid: 41, keepAlive: true)
        XCTAssertTrue(CloseService.protectionReason(for: brew)?.contains("brew services stop syncthing") == true)

        var agent = fixtureActivity(pid: 42, path: "/opt/homebrew/bin/node")
        agent.launchdJob = LaunchdJob(label: "com.example.gateway", pid: 42, keepAlive: true)
        XCTAssertTrue(CloseService.protectionReason(for: agent)?
            .contains("launchctl bootout gui/\(getuid())/com.example.gateway") == true)

        // Without KeepAlive a SIGTERM sticks until the next login, so it stays closable.
        var oneShot = fixtureActivity(pid: 42, path: "/opt/homebrew/bin/node")
        oneShot.launchdJob = LaunchdJob(label: "com.example.once", pid: 42, keepAlive: false)
        XCTAssertNil(CloseService.protectionReason(for: oneShot))
    }

    func testPortCategoryFollowsWhoStartedTheProcess() {
        let uid = Int32(getuid())
        func category(path: String = "/opt/homebrew/bin/node", ppid: Int32? = 500, parents: [String] = [],
                      appBundle: Bool = false, project: Bool = false, launchd: Bool = false,
                      owner: Int32 = Int32(getuid())) -> PortCategory {
            let base = fixtureActivity(pid: 42, path: path, uid: owner, appBundle: appBundle)
            let process = ProcessFact(pid: 42, ppid: ppid, command: "node", executablePath: path,
                uid: owner, user: nil, cwd: base.process.cwd)
            let chain = parents.enumerated().map { index, name in
                ProcessFact(pid: Int32(100 + index), ppid: nil, command: name, executablePath: nil, uid: uid, user: nil, cwd: nil)
            }
            var activity = Activity(listener: base.listener, process: process, parentChain: chain,
                projectMarker: project ? ProjectMarker(name: "site", root: "/p", source: ".git", markerPath: "/p/.git") : nil,
                applicationBundle: base.applicationBundle, scope: .local, inference: base.inference)
            if launchd { activity.launchdJob = LaunchdJob(label: "homebrew.mxcl.postgresql", pid: 42, keepAlive: true) }
            return PortCategory.classify([activity])
        }

        XCTAssertEqual(category(project: true), .devServer)
        XCTAssertEqual(category(parents: ["-zsh", "login"]), .devServer)
        XCTAssertEqual(category(parents: ["npm", "bash", "tmux"]), .devServer)
        XCTAssertEqual(category(ppid: 1), .devServer, "orphaned after its terminal closed")
        XCTAssertEqual(category(ppid: 1, launchd: true), .background)
        XCTAssertEqual(category(parents: ["zsh"], launchd: true), .background)
        XCTAssertEqual(category(parents: ["zsh"], appBundle: true), .app)
        XCTAssertEqual(category(appBundle: true, project: true), .app, "an editor's own server follows the editor")
        XCTAssertEqual(category(path: "/usr/libexec/rapportd", ppid: 1), .system)
        XCTAssertEqual(category(ppid: 1, owner: uid + 1), .system)
        XCTAssertEqual(category(parents: ["some-daemon"]), .other)
    }

    func testContainerRuntimesFormTheirOwnCategory() {
        func runtimeActivity(path: String, bundleName: String? = nil, parents: [String] = []) -> Activity {
            let listener = Listener(pid: 42, command: "x", uid: Int32(getuid()), user: nil,
                port: 8080, addresses: ["127.0.0.1"])
            let process = ProcessFact(pid: 42, ppid: 500, command: "x", executablePath: path,
                uid: Int32(getuid()), user: nil, cwd: nil)
            let chain = parents.enumerated().map { index, name in
                ProcessFact(pid: Int32(100 + index), ppid: nil, command: name, executablePath: nil,
                    uid: Int32(getuid()), user: nil, cwd: nil)
            }
            let bundle = bundleName.map { ApplicationBundle(name: $0, path: "/Applications/\($0).app", sourcePID: 99, direct: true) }
            return Activity(listener: listener, process: process, parentChain: chain,
                projectMarker: nil, applicationBundle: bundle, scope: .local,
                inference: OwnerInference(label: bundleName ?? "x", category: .application,
                    confidence: "high", reason: "Fixture."))
        }

        // Docker Desktop forwards through com.docker.backend inside its app bundle.
        let backend = runtimeActivity(path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", bundleName: "Docker")
        XCTAssertEqual(PortCategory.classify([backend]), .container)
        XCTAssertTrue(CloseService.protectionReason(for: backend)?.contains("docker ps") == true)

        // OrbStack's forwarders sit inside its bundle.
        XCTAssertEqual(PortCategory.classify([runtimeActivity(path: "/Applications/OrbStack.app/Contents/MacOS/OrbStack-helper", bundleName: "OrbStack")]), .container)

        // colima / a standalone daemon forward via docker-proxy, a child of the daemon.
        XCTAssertEqual(PortCategory.classify([runtimeActivity(path: "/Users/me/.colima/_lima/colima/docker-proxy", parents: ["dockerd", "colima"])]), .container)

        // Once the container is resolved, the refusal names the exact stop command.
        var resolved = backend
        resolved.container = ContainerInfo(name: "leftopen-db", image: "postgres:16")
        XCTAssertTrue(CloseService.protectionReason(for: resolved)?.contains("docker stop leftopen-db") == true)

        // An ordinary app still lands in Apps.
        XCTAssertEqual(PortCategory.classify([runtimeActivity(path: "/Applications/Editor.app/Contents/MacOS/Editor", bundleName: "Editor")]), .app)
    }

    func testContainerResolverParsesDockerPsOutput() {
        let output = """
            leftopen-db\tpostgres:16\t0.0.0.0:5432->5432/tcp, :::5432->5432/tcp
            web\tnginx:alpine\t0.0.0.0:8080->80/tcp, [::]:8080->80/tcp
            internal\tredis:7\t6379/tcp, 6379->6379/udp
            """
        let resolved = ContainerResolver.parse(output, ports: [5432, 8080, 9999])
        XCTAssertEqual(resolved[5432], ContainerInfo(name: "leftopen-db", image: "postgres:16"))
        XCTAssertEqual(resolved[8080]?.name, "web")
        XCTAssertNil(resolved[9999], "an unpublishable lookup stays unresolved")
        XCTAssertEqual(resolved.count, 2, "ports without a host mapping resolve to nothing")
    }

    func testContainerResolverParsesEngineListJSON() {
        let json = """
            [
              {"Id":"8dfafdbc3a40abcdef0123456789","Names":["/leftopen-db"],"Image":"postgres:16",
               "Ports":[{"IP":"0.0.0.0","PrivatePort":5432,"PublicPort":5432,"Type":"tcp"},
                        {"IP":"::","PrivatePort":5432,"PublicPort":5432,"Type":"tcp"}],
               "Labels":{"com.docker.compose.project":"leftopen",
                         "com.docker.compose.project.working_dir":"/Users/me/leftopen",
                         "com.docker.compose.project.config_files":"/Users/me/leftopen/compose.yaml"},
               "Mounts":[{"Source":"/Users/me/leftopen/data","Destination":"/var/lib/postgresql/data","Type":"bind"}]},
              {"Id":"9cd87474be90","Names":["/nostalgic_turing"],"Image":"docker.io/library/redis:7-alpine",
               "Ports":[{"IP":"0.0.0.0","PrivatePort":6379,"PublicPort":6379,"Type":"tcp"}],
               "Labels":{},"Mounts":[{"Source":"/Users/me/side","Destination":"/data","Type":"bind"}]},
              {"Id":"aaa","Names":["/internal-only"],"Image":"redis:7","Ports":[{"PrivatePort":6379,"Type":"tcp"}],
               "Labels":null,"Mounts":[]}
            ]
            """
        let resolved = ContainerResolver.parseEngineList(Data(json.utf8), ports: [5432, 6379])!

        let compose = resolved[5432]
        XCTAssertEqual(compose?.name, "leftopen-db")
        XCTAssertEqual(compose?.id, "8dfafdbc3a40")
        XCTAssertEqual(compose?.composeProject, "leftopen")
        XCTAssertEqual(compose?.composeDir, "/Users/me/leftopen", "the compose file's directory wins over working_dir")
        XCTAssertEqual(compose?.mounts, [ContainerMount(source: "/Users/me/leftopen/data", destination: "/var/lib/postgresql/data")])
        XCTAssertEqual(compose?.displayName, "leftopen-db")

        let generated = resolved[6379]
        XCTAssertEqual(generated?.name, "nostalgic_turing")
        XCTAssertEqual(generated?.displayName, "redis", "a generated name falls back to the image")
        XCTAssertNil(generated?.composeProject)
        XCTAssertEqual(generated?.mounts.first?.source, "/Users/me/side")
    }

    func testContainerResolverParsesRestartPolicy() {
        let always = """
            {"HostConfig":{"RestartPolicy":{"Name":"always","MaximumRetryCount":0}}}
            """
        XCTAssertEqual(ContainerResolver.parseRestartPolicy(Data(always.utf8)), "always")

        let dockerRun = """
            {"HostConfig":{"RestartPolicy":{"Name":"no","MaximumRetryCount":0}}}
            """
        XCTAssertEqual(ContainerResolver.parseRestartPolicy(Data(dockerRun.utf8)), "no")
        let activity = fixtureActivity(pid: 42, path: "/opt/homebrew/bin/docker-proxy")
        let container = ContainerInfo(name: "db", image: "postgres:16")
        XCTAssertTrue(ContainerStopPlan(activity: activity, container: container,
                                         restartPolicy: "always").resurrectsOnDaemonRestart)
        XCTAssertFalse(ContainerStopPlan(activity: activity, container: container,
                                         restartPolicy: "no").resurrectsOnDaemonRestart)
        XCTAssertFalse(ContainerStopPlan(activity: activity, container: container,
                                         restartPolicy: nil).resurrectsOnDaemonRestart)
    }

    func testContainerNamesPreferSomethingReadable() {
        XCTAssertTrue(ContainerInfo.isGeneratedName("nostalgic_turing"))
        XCTAssertFalse(ContainerInfo.isGeneratedName("leftopen-db"), "a chosen --name keeps the row")
        XCTAssertFalse(ContainerInfo.isGeneratedName("leftopen_db_2"), "compose names have three parts")
        XCTAssertFalse(ContainerInfo.isGeneratedName("LeftOpen"))
        XCTAssertEqual(ContainerInfo(name: "nostalgic_turing", image: "redis:7-alpine").displayName, "redis")
        XCTAssertEqual(ContainerInfo(name: "nostalgic_turing", image: "ghcr.io/acme/api:v2").displayName, "api")
        XCTAssertEqual(ContainerInfo(name: "chosen", image: "redis:7").displayName, "chosen")
        XCTAssertEqual(ContainerInfo(name: "proj-web-1", image: "nginx",
                                     composeProject: "proj").displayName, "proj-web-1")
    }

    func testSocketClientTalksToTheLocalDaemon() throws {
        guard let socket = ContainerResolver.daemonSocket() else {
            throw XCTSkip("No local Docker daemon socket on this machine.")
        }
        let body = UnixSocketHTTP.get(socket, path: "/version", timeout: 2)
        let json = String(decoding: try XCTUnwrap(body), as: UTF8.self)
        XCTAssertTrue(json.contains("ApiVersion") || json.contains("Version"),
                      "the daemon answered over the unix socket")

        // The production path against the daemon's real chunked response: a body that decodes
        // and parses is the whole socket story end to end.
        let list = UnixSocketHTTP.get(socket, path: "/containers/json", timeout: 2)
        XCTAssertNotNil(ContainerResolver.parseEngineList(try XCTUnwrap(list), ports: []))
    }

    /// The Docker daemon chunks `/containers/json`; an undecoded body kills every socket resolve.
    func testChunkedEngineResponseIsDecoded() throws {
        let json = #"[{"Names":["/leftopen-db"],"Image":"postgres:16","Ports":[{"PublicPort":5432,"Type":"tcp"}],"Labels":null,"Mounts":[]}]"#
        let pieces = [json.prefix(30), json.dropFirst(30).prefix(20), json.dropFirst(50)]
        var raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        for piece in pieces {
            raw.append(Data(String(piece.count, radix: 16).utf8))
            raw.append(Data("\r\n".utf8))
            raw.append(Data(piece.utf8))
            raw.append(Data("\r\n".utf8))
        }
        raw.append(Data("0\r\n\r\n".utf8))

        let body = try XCTUnwrap(UnixSocketHTTP.responseBody(raw))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), json)
        XCTAssertEqual(ContainerResolver.parseEngineList(body, ports: [5432])?[5432]?.name, "leftopen-db")

        // A truncated stream has no zero-size terminator and must not parse halfway.
        let truncated = raw.subdata(in: raw.startIndex..<raw.count - 7)
        XCTAssertNil(UnixSocketHTTP.responseBody(truncated))
    }

    /// A failing socket must never take the CLI fallback down with it.
    func testSocketFailureStillFallsBackToCLI() throws {
        guard ContainerResolver.daemonSocket() != nil else {
            throw XCTSkip("No local Docker daemon socket on this machine.")
        }
        let viaCLI = [5432: ContainerInfo(name: "from-cli", image: "postgres:16")]
        var socketAttempts = 0
        let first = ContainerResolver.resolve(for: [5432], socketFetch: { _ in
            socketAttempts += 1
            return nil
        }, cliFetch: { ports in
            XCTAssertEqual(ports, [5432])
            return viaCLI
        })
        XCTAssertEqual(first, viaCLI)

        // The socket is in backoff now; the CLI still runs.
        let second = ContainerResolver.resolve(for: [5432], socketFetch: { _ in
            XCTFail("a backoff-gated socket must not be probed again")
            return Data("[]".utf8)
        }, cliFetch: { _ in viaCLI })
        XCTAssertEqual(second, viaCLI)
        XCTAssertEqual(socketAttempts, 1)
    }

    func testCoreTextFollowsTheSelectedLanguage() {
        defer { Localization.current = .english }
        XCTAssertEqual(PortCategory.devServer.title, "Dev Servers")
        XCTAssertEqual(PortCategory.container.title, "Containers")

        Localization.current = .chinese
        XCTAssertEqual(PortCategory.devServer.title, "开发服务器")
        XCTAssertEqual(PortCategory.container.title, "容器")
        var service = fixtureActivity(pid: 42, path: "/opt/homebrew/bin/syncthing")
        service.launchdJob = LaunchdJob(label: "homebrew.mxcl.syncthing", pid: 42, keepAlive: true)
        XCTAssertEqual(CloseService.protectionReason(for: service),
                       "launchd 会让 homebrew.mxcl.syncthing 保持运行，关闭后会立即重启。请用 `brew services stop syncthing` 停止它。")
        // Callers branch on the flag, not on the wording, so the outcome is the same in any language.
        XCTAssertTrue(CloseError("已发送", signalSent: true).signalSent)
        XCTAssertFalse(CloseError("已拒绝").signalSent)
    }

    func testReleaseVersionComparesNumbersNotText() {
        func v(_ text: String) -> ReleaseVersion { ReleaseVersion(text)! }
        XCTAssertGreaterThan(v("v0.3.6"), v("0.3.5"))
        XCTAssertGreaterThan(v("0.10.0"), v("0.9.9"))
        XCTAssertEqual(v("1.2"), v("1.2.0"))
        XCTAssertFalse(v("0.3.5") > v("v0.3.5"))
        XCTAssertEqual(v("v0.3.5").description, "0.3.5")
        XCTAssertNil(ReleaseVersion("1.0.0-beta"))
        XCTAssertNil(ReleaseVersion(""))
    }

    func testLaunchctlParsing() {
        let list = "PID\tStatus\tLabel\n34135\t0\thomebrew.mxcl.syncthing\n-\t0\tcom.apple.idle\n8490\t0\tapplication.com.google.Chrome.1.2\n"
        XCTAssertEqual(Scanner.parseLaunchctlList(list),
                       [34135: "homebrew.mxcl.syncthing", 8490: "application.com.google.Chrome.1.2"])

        let keepAlive = "gui/501/x = {\n\tstate = running\n\tproperties = partial import | keepalive | runatload\n}"
        let nestedOnly = "gui/501/x = {\n\tendpoints = {\n\t\tproperties = keepalive\n\t}\n\tproperties = runatload | inferred program\n}"
        XCTAssertTrue(Scanner.launchctlPrintHasKeepAlive(keepAlive))
        XCTAssertFalse(Scanner.launchctlPrintHasKeepAlive(nestedOnly))
    }

    func testNodePackageLocatorSkipsIndirectionAndPrefersInnermostPackage() {
        let global = NodePackageLocator.locate(inArguments: "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/openclaw/dist/index.js gateway --port 18789")
        XCTAssertEqual(global?.name, "openclaw")
        XCTAssertEqual(global?.directory, "/opt/homebrew/lib/node_modules/openclaw")

        let scoped = NodePackageLocator.locate(inPath: "/x/node_modules/@scope/tool/bin/cli.js", resolvingSymlinks: false)
        XCTAssertEqual(scoped?.name, "@scope/tool")
        XCTAssertEqual(scoped?.directory, "/x/node_modules/@scope/tool")

        let pnpm = NodePackageLocator.locate(inPath: "/p/node_modules/.pnpm/vite@5.0.0/node_modules/vite/bin/vite.js", resolvingSymlinks: false)
        XCTAssertEqual(pnpm?.name, "vite")
        XCTAssertEqual(pnpm?.directory, "/p/node_modules/.pnpm/vite@5.0.0/node_modules/vite")

        XCTAssertNil(NodePackageLocator.locate(inPath: "/p/node_modules/.bin/next", resolvingSymlinks: false))
        XCTAssertNil(NodePackageLocator.locate(inArguments: "node server.js --port 3000"))
    }

    func testUptimeFormatterFormatsVariousDurations() {
        XCTAssertEqual(UptimeFormatter.format(etime: "00:15"), "< 1m")
        XCTAssertEqual(UptimeFormatter.format(etime: "00:15", compact: true), "< 1m")

        XCTAssertEqual(UptimeFormatter.format(etime: "05:30"), "5m")
        XCTAssertEqual(UptimeFormatter.format(etime: "05:30", compact: true), "5m")

        XCTAssertEqual(UptimeFormatter.format(etime: "01:15:20"), "1h 15m")
        XCTAssertEqual(UptimeFormatter.format(etime: "01:15:20", compact: true), "1h")

        XCTAssertEqual(UptimeFormatter.format(etime: "02:00:10"), "2h")
        XCTAssertEqual(UptimeFormatter.format(etime: "02:00:10", compact: true), "2h")

        XCTAssertEqual(UptimeFormatter.format(etime: "01-04:20:00"), "1d 4h")
        XCTAssertEqual(UptimeFormatter.format(etime: "01-04:20:00", compact: true), "1d")

        XCTAssertEqual(UptimeFormatter.format(etime: "02-00:10:00"), "2d")
        XCTAssertEqual(UptimeFormatter.format(etime: "02-00:10:00", compact: true), "2d")

        XCTAssertNil(UptimeFormatter.format(etime: ""))
        XCTAssertNil(UptimeFormatter.format(etime: "invalid"))
    }

    func testParseProcessTableWithAndWithoutEtime() {
        let withEtime = """
            1     0 01-16:20:00 /sbin/launchd
          500   200 02:15:30 /opt/local/bin/node
          600   500 00:30 python
        """
        let table = Scanner.parseProcessTable(withEtime)
        XCTAssertEqual(table[1]?.uptime, "1d 16h")
        XCTAssertEqual(table[1]?.compactUptime, "1d")
        XCTAssertEqual(table[1]?.rawElapsedTime, "01-16:20:00")
        XCTAssertEqual(table[500]?.uptime, "2h 15m")
        XCTAssertEqual(table[500]?.compactUptime, "2h")
        XCTAssertEqual(table[600]?.uptime, "< 1m")

        let legacyWithoutEtime = """
            1     0 /sbin/launchd
          500   200 /opt/local/bin/node
        """
        let legacyTable = Scanner.parseProcessTable(legacyWithoutEtime)
        XCTAssertEqual(legacyTable[1]?.command, "launchd")
        XCTAssertNil(legacyTable[1]?.uptime)
        XCTAssertEqual(legacyTable[500]?.command, "node")
    }

    func testParseProcessTableWithRssAndMemoryUsage() {
        let withRss = """
            1     0 01-16:20:00 12500 /sbin/launchd
          500   200 02:15:30 45000 /opt/local/bin/node
          600   500 00:30 1500000 python
        """
        let table = Scanner.parseProcessTable(withRss)
        XCTAssertEqual(table[1]?.uptime, "1d 16h")
        XCTAssertEqual(table[1]?.rssKB, 12500)
        XCTAssertEqual(table[1]?.memoryUsage, "12.2 MB")
        XCTAssertEqual(table[500]?.uptime, "2h 15m")
        XCTAssertEqual(table[500]?.rssKB, 45000)
        XCTAssertEqual(table[500]?.memoryUsage, "43.9 MB")
        XCTAssertEqual(table[600]?.rssKB, 1500000)
        XCTAssertEqual(table[600]?.memoryUsage, "1.4 GB")
    }

    func testBatchClosePlanPreparation() throws {
        // Batch preparation verifies start times with ps, so its fixture PIDs must be alive.
        let processes = [Process(), Process()]
        defer {
            for process in processes where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        for process in processes {
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            try process.run()
        }

        let uid = Int32(getuid())
        let act1 = fixtureActivity(pid: processes[0].processIdentifier, path: "/opt/local/bin/node", port: 3000, uid: uid)
        let act2 = fixtureActivity(pid: processes[1].processIdentifier, path: "/opt/local/bin/python", port: 8000, uid: uid)
        let protectedAct = fixtureActivity(pid: 103, path: "/usr/bin/python", port: 9000, uid: uid)

        let plans = try CloseService.prepareBatch(activities: [act1, act2, protectedAct])
        // protectedAct should be skipped
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(Set(plans.map(\.pid)), Set(processes.map(\.processIdentifier)))
    }

    func testCommandRunnerReturnsOutput() throws {
        XCTAssertEqual(try CommandRunner.output("/bin/echo", ["hello"]), "hello\n")
    }

    func testCommandRunnerStopsHungCommandAtDeadline() {
        let started = Date()
        XCTAssertThrowsError(try CommandRunner.output("/bin/sleep", ["30"], timeout: 0.3)) { error in
            guard case ScanError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testCommandRunnerStopsRunawayOutput() {
        XCTAssertThrowsError(try CommandRunner.output("/usr/bin/yes", [], maxOutputBytes: 64 * 1024)) { error in
            guard case ScanError.outputTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    private func fixtureActivity(pid: Int32, path: String?, port: Int = 3000,
                                 uid: Int32? = Int32(getuid()), appBundle: Bool = false) -> Activity {
        let listener = Listener(pid: pid, command: "node", uid: uid, user: nil,
            port: port, addresses: ["127.0.0.1"])
        let process = ProcessFact(pid: pid, ppid: nil, command: "node", executablePath: path,
            uid: uid, user: nil, cwd: "/private/tmp/project")
        let inference = OwnerInference(label: "Unknown", category: .unknown, confidence: "none",
            reason: "No evidence.")
        let bundle = appBundle ? ApplicationBundle(name: "Test", path: "/Applications/Test.app",
            sourcePID: pid, direct: true) : nil
        return Activity(listener: listener, process: process, parentChain: [], projectMarker: nil,
            applicationBundle: bundle, scope: .local, inference: inference)
    }
}

private final class HeadOnlyHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.scheme == "https" {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
            return
        }
        guard request.httpMethod == "HEAD",
              let response = HTTPURLResponse(url: url, statusCode: 404,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private final class NonHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        client?.urlProtocol(self, didReceive: URLResponse(url: url, mimeType: nil,
            expectedContentLength: 0, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private final class UntrustedHTTPSProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.scheme == "https" {
            client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted))
        } else if let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: "HTTP/1.1", headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { }
}

private final class RedirectHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.scheme == "https" {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: url.host == "127.0.0.1" ? 302 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.com/"])
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { }
}
