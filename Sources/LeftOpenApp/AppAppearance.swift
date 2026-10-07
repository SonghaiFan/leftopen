import AppKit
import SwiftUI

/// Shared visual foundations for Settings and the compact menu bar panel.
/// System colors follow appearance, contrast and accent preferences automatically.
enum AppAppearance {
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let groupedSurface = Color(nsColor: .controlBackgroundColor)
    static let body = Font.callout
    static let secondary = Font.caption
    static let sectionTitle = Font.callout.weight(.semibold)
    static let cornerRadius: CGFloat = 8
    static let contentInset: CGFloat = 14
}
