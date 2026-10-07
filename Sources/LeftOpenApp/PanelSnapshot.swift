import AppKit
import LeftOpenCore
import SwiftUI
import UniformTypeIdentifiers

/// Developer hook for marketing assets: launched with `LEFTOPEN_SNAPSHOT=/path/out.png`
/// the app scans, lets icons resolve, renders the panel at 2x (independent of the
/// display's scale factor) and exits. `LEFTOPEN_SETTINGS_SNAPSHOT` renders Settings instead. `LEFTOPEN_SNAPSHOT_DARK=1` renders the dark variant.
@MainActor
enum PanelSnapshot {
    private static var gesturePreviewWindow: NSWindow?
    static func runIfRequested(model: MenuModel) {
        if ProcessInfo.processInfo.environment["LEFTOPEN_SHORTCUT_GESTURE_TEST"] == "1" {
            Task {
                NSApp.setActivationPolicy(.regular)
                let hosting = NSHostingController(rootView: ShortcutGesturePreview())
                let window = NSWindow(contentViewController: hosting)
                window.title = "LeftOpen Shortcut Gesture Test"
                window.styleMask = [.titled, .closable]
                window.isReleasedWhenClosed = false
                window.setContentSize(NSSize(width: 347, height: 340))
                window.center()
                gesturePreviewWindow = window
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        let settingsPath = ProcessInfo.processInfo.environment["LEFTOPEN_SETTINGS_SNAPSHOT"]
        guard let path = settingsPath ?? ProcessInfo.processInfo.environment["LEFTOPEN_SNAPSHOT"], !path.isEmpty else { return }
        let isSettings = settingsPath != nil
        let width = isSettings ? 420 : 375
        let height = isSettings ? 500 : 460
        let dark = ProcessInfo.processInfo.environment["LEFTOPEN_SNAPSHOT_DARK"] == "1"
        Task {
            if isSettings {
                SettingsWindowController.shared.section = SettingsSection(rawValue:
                    ProcessInfo.processInfo.environment["LEFTOPEN_SETTINGS_SECTION"] ?? "general") ?? .general
                await FixedAddressManager.shared.refreshAddressSetup()
            }
            else { await model.refresh() }
            // Kick off favicon probes for everything the panel would probe, then give them a moment.
            for activity in model.snapshot.activities where ProcessIconResolver.shouldProbeFavicon(for: activity) {
                if case .symbol = ProcessIconResolver.resolve(for: activity) {
                    ProcessIconCache.shared.loadDynamicFaviconIfNeeded(for: activity)
                }
            }
            try? await Task.sleep(for: .seconds(4))

            // ImageRenderer only draws pure SwiftUI (AppKit-backed controls become placeholders),
            // so host the panel in an invisible window and let AppKit rasterise it at 2x.
            let content = Group {
                if isSettings { SettingsView() }
                else { MenuPanel(model: model, expandAllSections: true) }
            }
                .frame(width: CGFloat(width), height: CGFloat(height))
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            let window: NSWindow
            if isSettings {
                window = SettingsWindowController.shared.makeWindow()
            } else {
                window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = hosting
            }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.alphaValue = 0
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1))
            guard let renderedView = isSettings ? window.contentView?.superview : window.contentView else { exit(1) }
            renderedView.layoutSubtreeIfNeeded()
            let width = Int(renderedView.bounds.width)
            let height = Int(renderedView.bounds.height)

            let scale = 2
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { exit(1) }
            rep.size = renderedView.bounds.size
            renderedView.cacheDisplay(in: renderedView.bounds, to: rep)

            // Round the corners like the real MenuBarExtra window, staying at 2x.
            guard let rounded = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { exit(1) }
            rounded.size = renderedView.bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rounded)
            NSBezierPath(roundedRect: renderedView.bounds, xRadius: 12, yRadius: 12).addClip()
            rep.draw(in: renderedView.bounds)
            NSGraphicsContext.restoreGraphicsState()
            guard let image = rounded.cgImage,
                  let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
                exit(1)
            }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("snapshot: wrote \(path) (\(image.width)x\(image.height))")
            exit(0)
        }
    }
}

/// Neutral fixtures exercise the same pointer gesture without changing saved projects.
private struct ShortcutGesturePreview: View {
    @State private var order = ["A", "B", "C", "D", "E", "F", "G", "H", "I"]
    @State private var frames: [String: CGRect] = [:]
    @StateObject private var drag = ShortcutDragState()
    @State private var opens = 0

    var body: some View {
        VStack(spacing: 16) {
            ProjectShortcutGrid() {
                ForEach(order, id: \.self) { id in
                    Button {
                        if drag.id == nil { opens += 1 }
                    } label: {
                        Text(id).font(.title2).frame(width: 68, height: 76)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ProjectShortcutFrames.self,
                                value: [id: geometry.frame(in: .named("projectDock"))])
                        }
                    }
                    .modifier(ShortcutDragGesture(id: id, frames: frames, drag: drag, landingFrame: { frames[$0] }) { source, target in
                        order = ProjectShortcutOrder.moving(source, to: target, in: order)
                    })
                    .opacity(drag.id == id ? 0 : 1)
                }
            }
            .animation(drag.reorderAnimation, value: order)
            .overlay(alignment: .topLeading) {
                if let id = drag.id, let center = drag.center {
                    Text(id).font(.title2).frame(width: 68, height: 76)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .scaleEffect(drag.settling ? 1 : 1.07)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                        .position(center).allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "projectDock")
            .onPreferenceChange(ProjectShortcutFrames.self) { frames = $0 }
            Text("Order: " + order.joined() + " · Opens: \(opens)")
        }
        .padding(20)
    }
}
