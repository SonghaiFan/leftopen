import AppKit
import LeftOpenCore
import SwiftUI
import UniformTypeIdentifiers

/// Developer hook for marketing assets: launched with `LEFTOPEN_SNAPSHOT=/path/out.png`
/// the app scans, lets icons resolve, renders the panel at 2x (independent of the
/// display's scale factor) and exits. `LEFTOPEN_SNAPSHOT_DARK=1` renders the dark variant.
@MainActor
enum PanelSnapshot {
    static func runIfRequested(model: MenuModel) {
        guard let path = ProcessInfo.processInfo.environment["LEFTOPEN_SNAPSHOT"], !path.isEmpty else { return }
        let dark = ProcessInfo.processInfo.environment["LEFTOPEN_SNAPSHOT_DARK"] == "1"
        Task {
            await model.refresh()
            // Kick off favicon probes for everything the panel would probe, then give them a moment.
            for activity in model.snapshot.activities where ProcessIconResolver.shouldProbeFavicon(for: activity) {
                if case .symbol = ProcessIconResolver.resolve(for: activity) {
                    ProcessIconCache.shared.loadDynamicFaviconIfNeeded(for: activity)
                }
            }
            try? await Task.sleep(for: .seconds(4))

            // ImageRenderer only draws pure SwiftUI (AppKit-backed controls become placeholders),
            // so host the panel in an invisible window and let AppKit rasterise it at 2x.
            let content = MenuPanel(model: model, protectedExpanded: true)
                .frame(width: 375, height: 460)
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(x: 0, y: 0, width: 375, height: 460)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.alphaValue = 0
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1))
            hosting.layoutSubtreeIfNeeded()

            let scale = 2
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 375 * scale, pixelsHigh: 460 * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { exit(1) }
            rep.size = hosting.bounds.size
            hosting.cacheDisplay(in: hosting.bounds, to: rep)

            // Round the corners like the real MenuBarExtra window, staying at 2x.
            guard let rounded = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 375 * scale, pixelsHigh: 460 * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { exit(1) }
            rounded.size = hosting.bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rounded)
            NSBezierPath(roundedRect: hosting.bounds, xRadius: 12, yRadius: 12).addClip()
            rep.draw(in: hosting.bounds)
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
