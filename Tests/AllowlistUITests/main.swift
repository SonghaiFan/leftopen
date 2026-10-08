// Isolated native input fixture. Never starts scanners or touches standard preferences.
import AppKit
import LeftOpenCore
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let suite = "LeftOpenAllowlistUI-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
let settings = AppSettings(defaults: defaults)
Localization.current = .chinese
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 380, height: 320),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "LeftOpen Allowlist UI Test"
window.contentView = NSHostingView(rootView: Form {
    Section("端口白名单 · 隔离测试") {
        PortAllowlistInput(settings: settings)
    }
}.formStyle(.grouped).frame(width: 380, height: 320))
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
var previous: [Int] = []
let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    MainActor.assumeIsolated {
        if settings.ignoredPorts != previous {
            previous = settings.ignoredPorts
            precondition((defaults.array(forKey: "leftopen.ignoredPorts") as? [Int]) == previous)
            print("Saved test ports: \(previous)")
            fflush(stdout)
        }
        if !window.isVisible {
            defaults.removePersistentDomain(forName: suite)
            app.terminate(nil)
        }
    }
}
app.run()
