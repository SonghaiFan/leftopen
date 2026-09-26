import AppKit
import Combine
import LeftOpenCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var languageObserver: AnyCancellable?

    private override init() {
        super.init()
        languageObserver = AppSettings.shared.$language
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.window?.title = L("LeftOpen Settings", "LeftOpen 设置")
                }
            }
    }

    func show() {
        // A menu bar app has no Dock presence; become a regular app while Settings is open
        // so the window can take focus and appear in ⌘-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = L("LeftOpen Settings", "LeftOpen 设置")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("LeftOpenSettings")
        if !window.setFrameUsingName("LeftOpenSettings") { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
