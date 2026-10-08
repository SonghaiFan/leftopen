import Foundation
import XCTest
@testable import LeftOpenCore

final class FixedAddressTests: XCTestCase {
    private func activity(port: Int = 3000, pid: Int32 = 42, root: String = "/tmp/web",
                          arguments: String = "node /tmp/web/server.js --port 3000") -> Activity {
        let process = ProcessFact(pid: pid, ppid: nil, command: "node", executablePath: "/opt/bin/node",
                                  uid: Int32(getuid()), user: "test", cwd: root, arguments: arguments)
        return Activity(listener: Listener(pid: pid, command: "node", uid: Int32(getuid()), user: "test", port: port, addresses: ["127.0.0.1"]),
                        process: process, parentChain: [],
                        projectMarker: ProjectMarker(name: "web", root: root, source: "test", markerPath: root + "/package.json"),
                        applicationBundle: nil, scope: .local,
                        inference: OwnerInference(label: "web", category: .project, confidence: "high", reason: "test"))
    }

    private var binding: FixedAddressBinding {
        FixedAddressBinding(projectRoot: "/tmp/web", executablePath: "/opt/bin/node", name: "web", preferredPort: 3000,
                            serviceArguments: "node /tmp/web/server.js --port 3000", serviceCWD: "/tmp/web")
    }

    func testPortChangeFollowsSameServiceButNeverAnUnrelatedProject() {
        XCTAssertEqual(binding.resolve(in: [activity(port: 4173, arguments: "node /tmp/web/server.js --port 4173")])?.listener.port, 4173)
        XCTAssertNil(binding.resolve(in: [activity(root: "/tmp/other")]))
        XCTAssertNil(binding.resolve(in: [activity(arguments: "node /tmp/web/api.js --port 3000")]))
        XCTAssertNil(binding.resolve(in: [activity(), activity(pid: 43, root: "/tmp/other")]))
        XCTAssertNil(binding.resolve(in: []))
    }

    func testAmbiguousPortChangesPauseRatherThanGuess() {
        let one = activity(port: 4000, arguments: "node /tmp/web/server.js --port 4000")
        let two = activity(port: 5000, pid: 43, arguments: "node /tmp/web/server.js --port 5000")
        XCTAssertNil(binding.resolve(in: [one, two]))
        XCTAssertEqual(binding.resolve(in: [activity(), one])?.listener.port, 3000)
    }

    func testSavedIdentityDoesNotPersistCommandSecrets() throws {
        let saved = FixedAddressBinding(projectRoot: "/tmp/web", executablePath: "/opt/bin/node", name: "web",
            preferredPort: 3000, serviceArguments: "node server --token test-secret-do-not-store --port 3000")
        let encoded = try JSONEncoder().encode(saved)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("test-secret-do-not-store"))
        XCTAssertFalse(text.contains("--token"))
        XCTAssertEqual(try JSONDecoder().decode(FixedAddressBinding.self, from: encoded), saved)
    }

    func testCatalogRejectsExpiredReassignedAndUnrelatedAddresses() throws {
        let now = Date()
        let entry = FixedAddressCatalog.Entry(binding: binding, pid: 42, port: 3000, url: URL(string: "https://web.localhost")!)
        let live = FixedAddressCatalog(expiresAt: now.addingTimeInterval(15), entries: [entry])
        XCTAssertEqual(live.verified(in: [activity()], now: now).count, 1)
        XCTAssertTrue(live.verified(in: [activity(pid: 43)], now: now).isEmpty)
        XCTAssertTrue(live.verified(in: [activity(root: "/tmp/other")], now: now).isEmpty)
        XCTAssertTrue(live.verified(in: [activity()], now: now.addingTimeInterval(16)).isEmpty)
        for address in ["https://web.localhost.evil.test", "https://user:password@web.localhost", "file:///tmp/web"] {
            let forged = FixedAddressCatalog.Entry(binding: binding, pid: 42, port: 3000, url: URL(string: address)!)
            XCTAssertTrue(FixedAddressCatalog(expiresAt: live.expiresAt, entries: [forged]).verified(in: [activity()], now: now).isEmpty)
        }
    }

    func testNamesResolveCollisionsAndArgumentsKeepNonPortIdentity() {
        XCTAssertEqual(FixedAddressBinding.availableName(project: "My App", used: ["my-app", "my-app-2"]), "my-app-3")
        XCTAssertEqual(FixedAddressBinding.normalizedArguments("vite --port=4173 --mode 2026"), "vite --port=<port> --mode 2026")
        XCTAssertEqual(FixedAddressBinding.normalizedArguments("server -p 3000"), "server -p <port>")
        XCTAssertEqual(FixedAddressBinding.normalizedArguments("python -m http.server 3000"), "python -m http.server 3000")
        XCTAssertTrue(Portless.validName(FixedAddressBinding.availableName(project: String(repeating: "a", count: 63), used: [String(repeating: "a", count: 63)])))
    }
    func testShortcutOrderSurvivesRediscoveryAndAppendsNewProjects() {
        let stored = ["tarot", "home", "deleted", "tarot"]
        XCTAssertEqual(ProjectShortcutOrder.normalized(current: ["home", "new", "tarot"], preferred: stored),
                       ["tarot", "home", "new"])
    }

    func testShortcutMovesBothDirectionsAndRejectsForeignOrMissingTargets() {
        let order = ["home", "tarot", "docs"]
        XCTAssertEqual(ProjectShortcutOrder.moving("home", to: "docs", in: order), ["tarot", "docs", "home"])
        XCTAssertEqual(ProjectShortcutOrder.moving("docs", to: "home", in: order), ["docs", "home", "tarot"])
        XCTAssertEqual(ProjectShortcutOrder.moving("external", to: "home", in: order), order)
        XCTAssertEqual(ProjectShortcutOrder.moving("home", to: "deleted", in: order), order)
        XCTAssertEqual(ProjectShortcutOrder.moving("home", to: "home", in: order), order)
    }

    func testFixedAddressEntryExplainsGlobalPackagesWithoutRelaxingProjectRequirement() {
        let original = activity(port: 30141)
        let process = ProcessFact(pid: 42, ppid: nil, command: "next-server", executablePath: "/opt/homebrew/bin/node",
            uid: Int32(getuid()), user: "test", cwd: "/opt/homebrew/lib/node_modules/@agegr/pi-web")
        let global = Activity(listener: original.listener, process: process, parentChain: [], projectMarker: nil,
            applicationBundle: nil, scope: .local, inference: original.inference)
        let url = URL(string: "http://127.0.0.1:30141")!
        XCTAssertEqual(FixedAddressEligibility.blocker(for: global, webURL: url, currentUID: Int32(getuid())), .packageDirectory)
        XCTAssertEqual(FixedAddressEligibility.identityBlocker(for: global, currentUID: Int32(getuid())), .packageDirectory)
        XCTAssertFalse(FixedAddressEligibility.Blocker.packageDirectory.message.isEmpty)
        XCTAssertEqual(FixedAddressEligibility.blocker(for: global, webURL: url, currentUID: -1), .differentUser)
        XCTAssertNil(FixedAddressEligibility.blocker(for: original, webURL: url, currentUID: Int32(getuid())))
        XCTAssertEqual(FixedAddressEligibility.blocker(for: original, webURL: nil, currentUID: Int32(getuid())), .unverifiedHTTP)
        XCTAssertEqual(FixedAddressEligibility.blocker(for: original,
            webURL: URL(string: "https://localhost:30141"), currentUID: Int32(getuid())), .unverifiedHTTP)
    }

}
