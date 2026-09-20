import AppKit
import LeftOpenCore
import SwiftUI

struct MenuPanel: View {
    @ObservedObject var model: MenuModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var selectedGroupID: String?
    @State private var evidenceExpanded = false
    @State private var limitationsExpanded = false
    @State private var protectedExpanded: Bool
    @FocusState private var searchFocused: Bool

    init(model: MenuModel, protectedExpanded: Bool = false) {
        self.model = model
        _protectedExpanded = State(initialValue: protectedExpanded)
    }

    private var selectedActivity: Activity? {
        model.snapshot.activities.first { $0.id == model.selectedActivityID }
    }

    private var filteredActivities: [Activity] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.snapshot.activities.filter { activity in
            guard !search.isEmpty else { return true }
            let fields = [
                String(activity.listener.port), String(activity.process.pid),
                activity.inference.label, activity.process.command,
                activity.process.user ?? "", activity.process.cwd ?? "",
                activity.listener.addresses.joined(separator: " "),
            ]
            return fields.contains { $0.lowercased().contains(search) }
        }
    }

    // Closable listeners come first (they are what you opened the panel for); apps and
    // system services LeftOpen refuses to touch are folded into a collapsed section.
    private var closableActivities: [Activity] {
        filteredActivities.filter { CloseService.protectionReason(for: $0) == nil }
    }

    private var protectedActivities: [Activity] {
        filteredActivities.filter { CloseService.protectionReason(for: $0) != nil }
    }

    private var projectGroups: [ListenerGroup] {
        listenerGroups(from: closableActivities.filter { $0.inference.category == .project })
    }
    private var serviceGroups: [ListenerGroup] {
        listenerGroups(from: closableActivities.filter { $0.inference.category != .project })
    }
    private var protectedGroups: [ListenerGroup] { listenerGroups(from: protectedActivities) }

    private var selectedProcessGroup: ListenerGroup? {
        guard let selectedGroupID else { return nil }
        return listenerGroups(from: model.snapshot.activities)
            .first { $0.id == selectedGroupID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let notice = model.notice { noticeView(notice) }
            if let plan = model.pendingPlan {
                reviewView(plan)
            } else if let activity = selectedActivity {
                detailView(activity)
            } else if let group = selectedProcessGroup {
                processDetailView(group)
            } else if model.selectedActivityID != nil || selectedGroupID != nil {
                vanishedView
            } else {
                listView
            }
            Divider()
            footer
        }
        .frame(width: 375, height: 460)
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor))
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if model.pendingPlan != nil || model.selectedActivityID != nil || selectedGroupID != nil {
                Button {
                    if model.pendingPlan != nil {
                        model.pendingPlan = nil
                    } else if model.selectedActivityID != nil {
                        model.selectedActivityID = nil
                    } else {
                        selectedGroupID = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .accessibilityLabel(model.pendingPlan == nil ? "Back to ports" : "Back to port details")
                .help(model.pendingPlan == nil ? "Back to ports" : "Back to port details")
                .disabled(model.isClosing)
            }
            DoorMark(isOpen: model.hasOpenDoors)
                .frame(width: 18, height: 30)
                .accessibilityHidden(true)
            if model.pendingPlan != nil || model.selectedActivityID != nil || selectedGroupID != nil {
                Text("LeftOpen").font(.headline)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LeftOpen").font(.headline)
                    HStack(spacing: 5) {
                        if model.hasOpenDoors {
                            Text("\(model.closablePortCount) open")
                                .fontWeight(.medium)
                            Text("•")
                        } else {
                            Text("All doors closed")
                            Text("•")
                        }
                        Text("\(model.portCount) listening")
                        if model.snapshot.lanPortCount > 0 {
                            Text("•")
                            Label("\(model.snapshot.lanPortCount) LAN", systemImage: "globe")
                                .foregroundStyle(Color(nsColor: .systemOrange))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .help("LAN-facing means a non-loopback bind address was observed. Firewall and actual reachability were not checked.")
                }
            }
            Spacer()
            if model.pendingPlan == nil {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .accessibilityLabel("Refresh listening ports")
                .help("Refresh now (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing || model.isClosing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func noticeView(_ notice: Notice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.kind.symbol)
                .foregroundStyle(notice.kind.color)
            Text(notice.text).font(.callout).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var listView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Search port, process, or PID", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                    .onAppear {
                        DispatchQueue.main.async {
                            searchFocused = true
                        }
                    }
                    .accessibilityLabel("Search listening ports")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if model.isRefreshing && model.snapshot.activities.isEmpty {
                ProgressView("Scanning this Mac…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredActivities.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !projectGroups.isEmpty {
                            groupSection("Projects", groups: projectGroups)
                        }
                        if !serviceGroups.isEmpty {
                            groupSection("Other Processes", groups: serviceGroups)
                        }
                        if !protectedGroups.isEmpty {
                            protectedSection
                        }
                        if !model.snapshot.limitations.isEmpty {
                            Divider().padding(.top, 4)
                            DisclosureGroup("Scan limitations", isExpanded: $limitationsExpanded) {
                                ForEach(model.snapshot.limitations, id: \.self) { limitation in
                                    Text(limitation)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                }
                            }
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    /// Apps and system services: not closable, so hidden behind a disclosure unless the
    /// user is searching (a search that only matches protected ports must still show them).
    private var protectedSection: some View {
        let expanded = protectedExpanded || !query.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { protectedExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("NOT CLOSABLE")
                    Text("· \(protectedGroups.count) apps & system services")
                        .fontWeight(.regular)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
            .disabled(!query.isEmpty)
            .accessibilityLabel("\(protectedGroups.count) not closable listeners, apps and system services")
            .accessibilityHint(expanded ? "Collapses the list" : "Expands the list")
            if expanded {
                groupRows(protectedGroups)
            }
        }
    }

    private func groupSection(_ title: String, groups: [ListenerGroup]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)
            groupRows(groups)
        }
    }

    private func groupRows(_ groups: [ListenerGroup]) -> some View {
        Group {
            ForEach(groups) { group in
                GroupRowItem(
                    group: group,
                    onSelect: {
                        evidenceExpanded = false
                        if group.ports.count == 1 {
                            model.selectedActivityID = group.primary.id
                        } else {
                            selectedGroupID = group.id
                        }
                    },
                    onClose: { activity in
                        Task { await model.previewClose(activity) }
                    },
                    contextMenuContent: {
                        contextMenu(for: group)
                    }
                )
                if group.id != groups.last?.id {
                    Divider().padding(.leading, 14)
                }
            }
        }
    }

    private func listenerGroups(from activities: [Activity]) -> [ListenerGroup] {
        var groups: [String: [Activity]] = [:]
        var orderedIDs: [String] = []
        for activity in activities {
            let id: String
            if let bundle = activity.applicationBundle {
                id = "app:\(bundle.path)"
            } else {
                id = "pid:\(activity.process.pid):\(activity.process.executablePath ?? activity.process.command)"
            }
            if groups[id] == nil { orderedIDs.append(id) }
            groups[id, default: []].append(activity)
        }
        return orderedIDs.compactMap { id in
            groups[id].map { ListenerGroup(id: id, activities: $0) }
        }
    }

    private var emptyView: some View {
        let scanUnavailable = model.notice?.kind == .error && model.snapshot.activities.isEmpty
        return VStack(spacing: 8) {
            Image(systemName: scanUnavailable ? "exclamationmark.triangle" :
                model.snapshot.activities.isEmpty ? "checkmark.circle" : "magnifyingglass")
                .font(.title2).foregroundStyle(.secondary)
            Text(scanUnavailable ? "Unable to scan" :
                model.snapshot.activities.isEmpty ? "No listening ports" : "No matching ports")
                .font(.headline)
            Text(scanUnavailable ? "Check the message above, then try Refresh." :
                model.snapshot.activities.isEmpty ? "No TCP listener was found on this Mac." : "Try another search.")
                .font(.callout).foregroundStyle(.secondary)
            if !model.snapshot.activities.isEmpty {
                Button("Clear Search") {
                    query = ""
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func detailView(_ activity: Activity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ProcessIconView(activity: activity, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Port \(String(activity.listener.port))")
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        Text(activity.inference.label).font(.title3.weight(.medium))
                    }
                    Spacer()
                    ScopeLabel(scope: activity.scope)
                }

                HStack(spacing: 8) {
                    Button {
                        openBrowser(port: activity.listener.port)
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("o", modifiers: .command)
                    .help("Open http://localhost:\(String(activity.listener.port)) in default browser (⌘O)")

                    Button {
                        copyToClipboard("http://localhost:\(String(activity.listener.port))")
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("c", modifiers: .command)
                    .help("Copy http://localhost:\(String(activity.listener.port)) to clipboard (⌘C)")

                    if let path = activity.projectMarker?.root ?? activity.process.cwd {
                        Button {
                            revealInFinder(path: path)
                        } label: {
                            Label("Reveal", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reveal project folder in Finder")
                    }
                }

                if let reason = CloseService.protectionReason(for: activity) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Close Unavailable")
                                .font(.system(size: 12, weight: .semibold))
                            Text(reason)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
                }

                Divider()
                infoRow("Command", activity.process.command)
                infoRow("PID", String(activity.process.pid))
                if let uptime = activity.process.uptime {
                    infoRow("Uptime", uptime)
                }
                infoRow("Executable", compactPath(activity.process.executablePath))
                infoRow("Folder", compactPath(activity.process.cwd))
                infoRow("Addresses", activity.listener.addresses.joined(separator: ", "))

                Divider()
                DisclosureGroup("Owner evidence", isExpanded: $evidenceExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("Type", activity.inference.category.accessibleName.capitalized)
                        infoRow("User", activity.process.user ?? activity.process.uid.map(String.init) ?? "Unknown")
                        if let project = activity.projectMarker {
                            infoRow("Project Marker", compactPath(project.markerPath))
                        }
                        if let bundle = activity.applicationBundle {
                            infoRow("Application", compactPath(bundle.path))
                        }
                        if !activity.parentChain.isEmpty {
                            infoRow("Parents", activity.parentChain.map { "\($0.command) (\($0.pid))" }.joined(separator: " → "))
                        }
                        infoRow("Confidence", activity.inference.confidence)
                        Text(activity.inference.reason).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 7)
                }

                if CloseService.protectionReason(for: activity) == nil {
                    Button {
                        Task { await model.previewClose(activity) }
                    } label: {
                        Text("Close Port \(String(activity.listener.port))…")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .disabled(model.isPreparingClose || model.isClosing)
                    .help("Review this one-PID SIGTERM action before confirming")
                    if model.isPreparingClose {
                        ProgressView("Checking process identity…")
                            .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
    }

    private func processDetailView(_ group: ListenerGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ProcessIconView(activity: group.primary, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.primary.inference.label)
                            .font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            if group.pids.count > 1 {
                                Text("\(group.pids.count) processes · \(group.ports.count) listening ports")
                            } else {
                                Text("PID \(group.primary.process.pid) · \(group.ports.count) listening ports")
                            }
                            if let uptime = group.primary.process.uptime {
                                Text("•")
                                Text("Up \(uptime)")
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                Text("Choose a port to inspect its listener details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                ForEach(group.activities.sorted { $0.listener.port < $1.listener.port }) { activity in
                    ProcessDetailPortRow(
                        activity: activity,
                        showCommand: group.pids.count > 1,
                        onSelect: {
                            evidenceExpanded = false
                            model.selectedActivityID = activity.id
                        },
                        onClose: { act in
                            Task { await model.previewClose(act) }
                        },
                        openBrowser: { port in
                            openBrowser(port: port)
                        },
                        copyToClipboard: { str in
                            copyToClipboard(str)
                        }
                    )
                    if activity.id != group.activities.sorted(by: { $0.listener.port < $1.listener.port }).last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var vanishedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle").font(.title2).foregroundStyle(.secondary)
            Text("No longer listening").font(.headline)
            Text("This listener disappeared during refresh. Go back to see the current ports.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Back to Ports") { model.selectedActivityID = nil }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func reviewView(_ plan: ClosePlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Label("Close PID \(plan.pid)?", systemImage: "exclamationmark.triangle")
                    .font(.title3).fontWeight(.semibold)
                Text("This sends SIGTERM to one process listening on port \(String(plan.port)). It does not kill a process tree or force-quit anything.")
                    .font(.callout)

                Divider()
                infoRow("Process", plan.activity.process.command)
                infoRow("Executable", compactPath(plan.executablePath))
                infoRow("Started", plan.startTime)

                if !plan.otherPorts.isEmpty {
                    Label("This PID also listens on \(plan.otherPorts.map(String.init).joined(separator: ", ")); those ports may close too.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
                if !plan.peerPIDs.isEmpty {
                    Label("Other PIDs share this port. Only PID \(plan.pid) will be signalled.",
                          systemImage: "person.2")
                        .font(.callout)
                }

                if model.isClosing {
                    ProgressView("Sending SIGTERM and checking the port…")
                        .padding(.top, 4)
                }

                HStack {
                    Button("Cancel") { model.pendingPlan = nil }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isClosing)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await model.confirmClose() }
                    } label: {
                        Text("Close PID \(plan.pid)")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isClosing)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func contextMenu(for group: ListenerGroup) -> some View {
        if group.ports.count == 1, let port = group.ports.first {
            Button {
                openBrowser(port: port)
            } label: {
                Label("Open in Browser (http://localhost:\(String(port)))", systemImage: "globe")
            }
            Button {
                copyToClipboard("http://localhost:\(String(port))")
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            Button {
                copyToClipboard(String(port))
            } label: {
                Label("Copy Port", systemImage: "number")
            }
        } else {
            ForEach(group.ports, id: \.self) { port in
                Button {
                    openBrowser(port: port)
                } label: {
                    Label("Open Port \(String(port)) (http://localhost:\(String(port)))", systemImage: "globe")
                }
            }
            Divider()
            Button {
                copyToClipboard(group.ports.map(String.init).joined(separator: ", "))
            } label: {
                Label("Copy Ports", systemImage: "number")
            }
        }
        Button {
            copyToClipboard(String(group.primary.process.pid))
        } label: {
            Label("Copy PID (\(group.primary.process.pid))", systemImage: "doc.on.clipboard")
        }
        if let path = group.primary.projectMarker?.root ?? group.primary.process.cwd {
            Divider()
            Button {
                revealInFinder(path: path)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }

        let closableActivities = group.activities.filter { CloseService.protectionReason(for: $0) == nil }
        if !closableActivities.isEmpty {
            Divider()
            if group.ports.count == 1 {
                Button(role: .destructive) {
                    Task { await model.previewClose(group.primary) }
                } label: {
                    Label("Close Port \(group.ports[0]) (PID \(group.primary.process.pid))…", systemImage: "xmark.circle")
                }
            } else {
                ForEach(closableActivities) { act in
                    Button(role: .destructive) {
                        Task { await model.previewClose(act) }
                    } label: {
                        Label("Close Port \(act.listener.port) (PID \(act.process.pid))…", systemImage: "xmark.circle")
                    }
                }
            }
        }
    }

    private func openBrowser(port: Int) {
        if let url = URL(string: "http://localhost:\(String(port))") {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func revealInFinder(path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private var footer: some View {
        HStack {
            Text(model.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not yet scanned")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .font(.caption)
                .help("Quit LeftOpen")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct RowButtonStyle: ButtonStyle {
    var horizontalInset: CGFloat = 6
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : (isHovered ? 0.05 : 0)))
                    .padding(.horizontal, horizontalInset)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

private struct ListenerGroup: Identifiable {
    let id: String
    let activities: [Activity]

    init(id: String, activities: [Activity]) {
        self.id = id
        self.activities = activities
    }

    var primary: Activity { activities[0] }
    var ports: [Int] { Array(Set(activities.map(\.listener.port))).sorted() }
    var pids: [Int32] { Array(Set(activities.map(\.process.pid))).sorted() }
    var scope: ListenerScope { activities.contains { $0.scope == .lan } ? .lan : .local }
}

private struct GroupRowItem<MenuContent: View>: View {
    let group: ListenerGroup
    let onSelect: () -> Void
    let onClose: (Activity) -> Void
    @ViewBuilder let contextMenuContent: () -> MenuContent

    @State private var isRowHovered = false
    @State private var isCloseBtnHovered = false

    private var isClosable: Bool {
        group.ports.count == 1 && CloseService.protectionReason(for: group.primary) == nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onSelect()
            } label: {
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Text(String(group.ports[0]))
                            .font(.system(.callout, design: .monospaced))
                            .fontWeight(.semibold)
                        if group.ports.count > 1 {
                            Text("+\(group.ports.count - 1)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 80, alignment: .leading)

                    ProcessIconView(activity: group.primary, size: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.primary.inference.label)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if group.pids.count > 1 {
                            Text("\(group.pids.count) processes · \(group.ports.count) ports")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(group.primary.inference.label == group.primary.process.command
                                ? "PID \(group.primary.process.pid)"
                                : "\(group.primary.process.command) · PID \(group.primary.process.pid)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)

                    if group.ports.count > 1 {
                        Text("\(group.ports.count) ports")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let uptime = group.primary.process.compactUptime {
                        Text(uptime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if group.scope == .lan {
                        Text("LAN")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color.orange)
                            .help("LAN-facing bind address; actual reachability was not checked")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()

            HStack(spacing: 8) {
                if isClosable && isRowHovered {
                    Button {
                        onClose(group.primary)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isCloseBtnHovered ? Color.white : Color.secondary)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle()
                                    .fill(isCloseBtnHovered ? Color(nsColor: .systemRed) : Color.secondary.opacity(0.18))
                            )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                    .help("Close port \(group.ports[0]) (SIGTERM PID \(group.primary.process.pid))")
                    .onHover { isCloseBtnHovered = $0 }
                }

                Button {
                    onSelect()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary.opacity(0.6))
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
            }
            .padding(.leading, 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isRowHovered ? 0.05 : 0))
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { isRowHovered = $0 }
        .contextMenu {
            contextMenuContent()
        }
        .accessibilityLabel("Ports \(group.ports.map(String.init).joined(separator: ", ")), \(group.primary.inference.label), \(group.primary.inference.category.accessibleName), \(group.scope == .lan ? "LAN-facing" : "local only"), PID \(group.primary.process.pid)")
        .accessibilityHint("Opens listener details")
    }
}

private struct ProcessDetailPortRow: View {
    let activity: Activity
    let showCommand: Bool
    let onSelect: () -> Void
    let onClose: (Activity) -> Void
    let openBrowser: (Int) -> Void
    let copyToClipboard: (String) -> Void

    @State private var isRowHovered = false
    @State private var isCloseBtnHovered = false

    private var isClosable: Bool {
        CloseService.protectionReason(for: activity) == nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onSelect()
            } label: {
                HStack(spacing: 10) {
                    Text(String(activity.listener.port))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                        .frame(width: 54, alignment: .leading)
                    ProcessIconView(activity: activity, size: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        if showCommand {
                            Text(activity.process.command + " (PID \(activity.process.pid))")
                                .font(.callout)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(activity.listener.addresses.joined(separator: ", "))
                                Text("•")
                                Text(activity.scope == .lan ? "LAN-facing" : "Local only")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            Text(activity.listener.addresses.joined(separator: ", "))
                                .font(.callout)
                                .lineLimit(1)
                            Text(activity.scope == .lan ? "LAN-facing" : "Local only")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()

            HStack(spacing: 8) {
                if isClosable && isRowHovered {
                    Button {
                        onClose(activity)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isCloseBtnHovered ? Color.white : Color.secondary)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle()
                                    .fill(isCloseBtnHovered ? Color(nsColor: .systemRed) : Color.secondary.opacity(0.18))
                            )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                    .help("Close port \(activity.listener.port) (SIGTERM PID \(activity.process.pid))")
                    .onHover { isCloseBtnHovered = $0 }
                }

                Button {
                    onSelect()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
            }
            .padding(.leading, 6)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isRowHovered ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isRowHovered = $0 }
        .contextMenu {
            Button {
                openBrowser(activity.listener.port)
            } label: {
                Label("Open in Browser (http://localhost:\(String(activity.listener.port)))", systemImage: "globe")
            }
            Button {
                copyToClipboard("http://localhost:\(String(activity.listener.port))")
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            Button {
                copyToClipboard(String(activity.listener.port))
            } label: {
                Label("Copy Port", systemImage: "number")
            }
            if isClosable {
                Divider()
                Button(role: .destructive) {
                    onClose(activity)
                } label: {
                    Label("Close Port \(activity.listener.port) (PID \(activity.process.pid))…", systemImage: "xmark.circle")
                }
            }
        }
        .accessibilityLabel("Port \(String(activity.listener.port)), \(activity.scope == .lan ? "LAN-facing" : "local only")")
        .accessibilityHint("Opens port details")
    }
}

private extension OwnerCategory {
    var accessibleName: String {
        switch self {
        case .project: "project"
        case .application: "application"
        case .service: "service"
        case .systemService: "system service"
        case .unknown: "unknown owner"
        }
    }
}

private struct ScopeLabel: View {
    let scope: ListenerScope

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: scope == .lan ? "wifi" : "desktopcomputer")
                .foregroundStyle(scope == .lan ? Color(nsColor: .systemOrange) : Color.secondary)
            Text(scope == .lan ? "LAN-facing" : "Local only")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .help(scope == .lan
            ? "Non-loopback bind address observed. Firewall and actual reachability were not checked."
            : "Only loopback bind addresses were observed.")
    }
}

private struct DoorMark: View {
    var isOpen: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let sx = w / 33.0
            let sy = h / 55.0

            let darkColor = colorScheme == .dark ? Color.white : Color(red: 0x21 / 255.0, green: 0x18 / 255.0, blue: 0x11 / 255.0)
            let leafColor = colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white

            ZStack {
                if isOpen {
                    // Layer 1: door-back (interior opening)
                    Path { p in
                        p.move(to: CGPoint(x: 0.74 * sx, y: 54.51 * sy))
                        p.addLine(to: CGPoint(x: 0.74 * sx, y: 16.161 * sy))
                        p.addCurve(
                            to: CGPoint(x: 16.28 * sx, y: 0.707 * sy),
                            control1: CGPoint(x: 0.74 * sx, y: 7.683 * sy),
                            control2: CGPoint(x: 7.755 * sx, y: 0.707 * sy)
                        )
                        p.addCurve(
                            to: CGPoint(x: 31.82 * sx, y: 16.161 * sy),
                            control1: CGPoint(x: 24.805 * sx, y: 0.707 * sy),
                            control2: CGPoint(x: 31.82 * sx, y: 7.683 * sy)
                        )
                        p.addLine(to: CGPoint(x: 31.82 * sx, y: 54.51 * sy))
                        p.closeSubpath()
                    }
                    .fill(darkColor)

                    // Layer 2: door leaf (swung open)
                    Path { p in
                        p.move(to: CGPoint(x: 9.9 * sx, y: 49.177 * sy))
                        p.addLine(to: CGPoint(x: 9.9 * sx, y: 18.124 * sy))
                        p.addCurve(
                            to: CGPoint(x: 27.417 * sx, y: 5.505 * sy),
                            control1: CGPoint(x: 9.9 * sx, y: 10.845 * sy),
                            control2: CGPoint(x: 19.563 * sx, y: 4.007 * sy)
                        )
                        p.addCurve(
                            to: CGPoint(x: 31.647 * sx, y: 18.981 * sy),
                            control1: CGPoint(x: 31.965 * sx, y: 9.711 * sy),
                            control2: CGPoint(x: 31.647 * sx, y: 11.702 * sy)
                        )
                        p.addLine(to: CGPoint(x: 31.647 * sx, y: 53.609 * sy))
                        p.closeSubpath()
                    }
                    .fill(leafColor)

                    // Layer 3: door-knob
                    Path { p in
                        p.addEllipse(in: CGRect(
                            x: (13.552 - 1.644) * sx,
                            y: (29.134 - 1.644) * sy,
                            width: 2 * 1.644 * sx,
                            height: 2 * 1.644 * sy
                        ))
                    }
                    .fill(darkColor)
                } else {
                    // Closed Door: interior is filled flush by door leaf
                    Path { p in
                        p.move(to: CGPoint(x: 1.501 * sx, y: 53.695 * sy))
                        p.addLine(to: CGPoint(x: 31.264 * sx, y: 53.695 * sy))
                        p.addLine(to: CGPoint(x: 31.264 * sx, y: 16.155 * sy))
                        p.addCurve(
                            to: CGPoint(x: 16.382 * sx, y: 1.358 * sy),
                            control1: CGPoint(x: 31.264 * sx, y: 8.037 * sy),
                            control2: CGPoint(x: 24.545 * sx, y: 1.358 * sy)
                        )
                        p.addCurve(
                            to: CGPoint(x: 1.501 * sx, y: 16.155 * sy),
                            control1: CGPoint(x: 8.219 * sx, y: 1.358 * sy),
                            control2: CGPoint(x: 1.501 * sx, y: 8.037 * sy)
                        )
                        p.closeSubpath()
                    }
                    .fill(leafColor)

                    // Door knob on closed door (right side)
                    Path { p in
                        p.addEllipse(in: CGRect(
                            x: (24.0 - 1.644) * sx,
                            y: (29.134 - 1.644) * sy,
                            width: 2 * 1.644 * sx,
                            height: 2 * 1.644 * sy
                        ))
                    }
                    .fill(darkColor)
                }

                // Layer 4: door-outline (frame)
                Path { p in
                    p.move(to: CGPoint(x: 0.391 * sx, y: 16.155 * sy))
                    p.addCurve(
                        to: CGPoint(x: 16.383 * sx, y: 0.248 * sy),
                        control1: CGPoint(x: 0.391 * sx, y: 7.43 * sy),
                        control2: CGPoint(x: 7.609 * sx, y: 0.248 * sy)
                    )
                    p.addCurve(
                        to: CGPoint(x: 32.375 * sx, y: 16.155 * sy),
                        control1: CGPoint(x: 25.157 * sx, y: 0.248 * sy),
                        control2: CGPoint(x: 32.375 * sx, y: 7.43 * sy)
                    )
                    p.addLine(to: CGPoint(x: 32.375 * sx, y: 54.805 * sy))
                    p.addLine(to: CGPoint(x: 0.391 * sx, y: 54.805 * sy))
                    p.closeSubpath()

                    p.move(to: CGPoint(x: 1.501 * sx, y: 53.695 * sy))
                    p.addLine(to: CGPoint(x: 31.264 * sx, y: 53.695 * sy))
                    p.addLine(to: CGPoint(x: 31.264 * sx, y: 16.155 * sy))
                    p.addCurve(
                        to: CGPoint(x: 16.382 * sx, y: 1.358 * sy),
                        control1: CGPoint(x: 31.264 * sx, y: 8.037 * sy),
                        control2: CGPoint(x: 24.545 * sx, y: 1.358 * sy)
                    )
                    p.addCurve(
                        to: CGPoint(x: 1.501 * sx, y: 16.155 * sy),
                        control1: CGPoint(x: 8.219 * sx, y: 1.358 * sy),
                        control2: CGPoint(x: 1.501 * sx, y: 8.037 * sy)
                    )
                    p.closeSubpath()
                }
                .fill(darkColor, style: FillStyle(eoFill: true))
            }
        }
        .aspectRatio(33.0 / 55.0, contentMode: .fit)
    }
}
