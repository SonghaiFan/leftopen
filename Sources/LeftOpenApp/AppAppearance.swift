import AppKit
import SwiftUI

/// Shared visual foundations for Settings and the compact menu bar panel.
/// System colors follow appearance, contrast and accent preferences automatically.
enum AppAppearance {
    /// White in light mode, the window colour in dark mode: the panel, its opaque row cards and Settings.
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .windowBackgroundColor : .controlBackgroundColor
    })
    /// A faint fill for fields and notes that sit on the surface.
    static let fill = Color.primary.opacity(0.05)
    static let body = Font.callout
    static let portNumber = Font.system(.callout, design: .monospaced).weight(.semibold)
    static let secondary = Font.caption
    static let sectionTitle = Font.callout.weight(.semibold)
    static let cornerRadius: CGFloat = 8
    static let contentInset: CGFloat = 14
}
