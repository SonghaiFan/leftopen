import AppKit
import Combine
import LeftOpenCore
import SwiftUI

/// Places in the single Settings page that other views can ask to bring into view.
enum SettingsSection: String, Hashable {
    case general, projects, about
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = SettingsWindowController()

    @Published var section: SettingsSection = .general
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

    func show(section requestedSection: SettingsSection? = nil) {
        section = requestedSection ?? .general
        // A menu bar app has no Dock presence; become a regular app while Settings is open
        // so the window can take focus and appear in ⌘-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = makeWindow()
        window.delegate = self
        window.setFrameAutosaveName("LeftOpenSettings")
        if !window.setFrameUsingName("LeftOpenSettings") { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Shared by the app and developer snapshots so previews include the real window chrome.
    func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = L("LeftOpen Settings", "LeftOpen 设置")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
