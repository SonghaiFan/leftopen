import AppKit
import Combine
import LeftOpenCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, projects, behavior, about
    var id: Self { self }
    var toolbarID: NSToolbarItem.Identifier { .init(rawValue) }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .projects: "folder"
        case .behavior: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
    var title: String {
        switch self {
        case .general: L("General", "通用")
        case .projects: L("Projects", "项目")
        case .behavior: L("Behavior", "行为")
        case .about: L("About", "关于")
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, ObservableObject {
    static let shared = SettingsWindowController()

    @Published var section: SettingsSection = SettingsSection(rawValue:
        UserDefaults.standard.string(forKey: "leftopen.settingsSection") ?? "general") ?? .general {
        didSet {
            if ProcessInfo.processInfo.environment["LEFTOPEN_SETTINGS_SNAPSHOT"] == nil {
                UserDefaults.standard.set(section.rawValue, forKey: "leftopen.settingsSection")
            }
            updateNavigation()
        }
    }
    private var window: NSWindow?
    private var languageObserver: AnyCancellable?

    private override init() {
        super.init()
        languageObserver = AppSettings.shared.$language
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateNavigation()
                }
            }
    }

    func show(section requestedSection: SettingsSection? = nil) {
        if let requestedSection { section = requestedSection }
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
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.title = section.title
        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: "LeftOpenSettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = section.toolbarID
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: 440, height: min(390, (NSScreen.main?.visibleFrame.height ?? 600) - 150)))
        return window
    }

    private func updateNavigation() {
        window?.title = section.title
        window?.toolbar?.selectedItemIdentifier = section.toolbarID
        for item in window?.toolbar?.items ?? [] {
            guard let pane = SettingsSection(rawValue: item.itemIdentifier.rawValue) else { continue }
            item.label = pane.title
            item.paletteLabel = pane.title
            item.toolTip = pane.title
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsSection.allCases.map(\.toolbarID)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsSection(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.toolTip = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsSection(rawValue: sender.itemIdentifier.rawValue) else { return }
        section = pane
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
