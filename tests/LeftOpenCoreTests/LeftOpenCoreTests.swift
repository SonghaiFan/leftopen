import Darwin
import XCTest
@testable import LeftOpenCore

final class LeftOpenCoreTests: XCTestCase {
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
            otherPorts: [], peerPIDs: [])
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
            otherPorts: [], peerPIDs: [])
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
