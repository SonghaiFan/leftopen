import AppKit
import LeftOpenCore
import SwiftUI

struct PortAllowlistInput: View {
    @ObservedObject private var settings: AppSettings
    @State private var draft = ""
    @State private var invalid = false
    @State private var selected: Int?
    @State private var highlighted: Int?
    @State private var focused = false

    init(settings: AppSettings = .shared) { self.settings = settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PortTokenLayout(spacing: 6) {
                ForEach(settings.ignoredPorts, id: \.self) { port in
                    HStack(spacing: 5) {
                        Text(String(port)).font(AppAppearance.portNumber)
                        Button {
                            settings.removeIgnoredPort(port)
                            selected = nil
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Remove port \(port)", "移除端口 \(port)"))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(selected == port || highlighted == port
                                ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 6))
                }
                PortDraftField(text: $draft, focused: $focused,
                               placeholder: L("Add ports…", "输入端口…"),
                               commit: commit, backspace: backspace)
                    .frame(width: 100, height: 24)
            }
            .padding(2)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(invalid ? Color.red : focused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            if invalid {
                Text(L("Use port numbers from 1 to 65535.", "请输入 1 到 65535 的端口号。"))
                .font(AppAppearance.secondary)
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: draft) {
            invalid = false
            selected = nil
            if draft.contains(where: { $0 == "," || $0 == "，" || $0.isWhitespace }) { commit() }
        }
    }

    private func commit() {
        let tokens = draft.split { $0 == "," || $0 == "，" || $0.isWhitespace }
        var rejected: [String] = []
        for token in tokens {
            guard token.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let port = Int(token), (1...65535).contains(port) else {
                rejected.append(String(token))
                continue
            }
            if settings.ignoredPorts.contains(port) {
                highlighted = port
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    if highlighted == port { highlighted = nil }
                }
            } else {
                settings.addIgnoredPort(port)
            }
        }
        draft = rejected.joined(separator: ",")
        // Deferred until the draft's change callback has run.
        Task { @MainActor in invalid = !rejected.isEmpty }
        selected = nil
    }

    private func backspace() {
        if let selected {
            settings.removeIgnoredPort(selected)
            self.selected = nil
        } else {
            selected = settings.ignoredPorts.last
        }
    }
}

/// Wrap tags and the insertion field together, preserving a left-to-right reading order.
private struct PortTokenLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 300).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (index, point) in arrangement.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}

/// Use the native field editor for selection, paste and keyboard input.
private struct PortDraftField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let commit: () -> Void
    let backspace: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.setAccessibilityLabel(L("Add hidden ports", "添加隐藏端口"))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = focused ? "" : placeholder
        if focused && field.currentEditor() == nil {
            DispatchQueue.main.async {
                guard context.coordinator.parent.focused else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PortDraftField
        init(_ parent: PortDraftField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.focused = false
            parent.commit()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.insertNewline(_:)) {
                parent.commit()
                return true
            }
            if command == #selector(NSResponder.deleteBackward(_:)), textView.string.isEmpty {
                parent.backspace()
                return true
            }
            return false
        }
    }
}
