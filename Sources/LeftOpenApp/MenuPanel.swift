import AppKit
import LeftOpenCore
import SwiftUI

struct MenuPanel: View {
    @ObservedObject var model: MenuModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var expandedGroupIDs: Set<String> = []
    /// How many of each unfolded group's extra rows are currently shown; stepped one at a time.
    @State private var revealedCounts: [String: Int] = [:]
    @State private var foldTasks: [String: Task<Void, Never>] = [:]
    @State private var evidenceExpanded = false
    @State private var limitationsExpanded = false
    @State private var webURLs: [String: URL] = [:]
    @State private var protectedExpanded: Bool
    @FocusState private var searchFocused: Bool

    init(model: MenuModel, protectedExpanded: Bool = false) {
        self.model = model
        _protectedExpanded = State(initialValue: protectedExpanded)
    }

    // MARK: - Data

    private var selectedActivity: Activity? {
        model.snapshot.activities.first { $0.id == model.selectedActivityID }
    }

    private var webProbeIdentity: [String] {
        let minute = Int((model.lastRefresh?.timeIntervalSince1970 ?? 0) / 60)
        return [String(minute)] + model.visible.activities.map { activity in
            "\(activity.id):\(activity.listener.addresses.sorted().joined(separator: ","))"
        }.sorted()
    }

    /// Probe only while the panel is present, four ports at a time. Results are refreshed when
    /// the listener set changes or after a minute, so a recycled PID cannot keep an old URL.
    private func detectWebServices() async {
        let activities = model.visible.activities
        webURLs = [:]
        for start in stride(from: 0, to: activities.count, by: 4) {
            guard !Task.isCancelled else { return }
            let batch = Array(activities[start..<min(start + 4, activities.count)])
            await withTaskGroup(of: (String, URL?).self) { group in
                for activity in batch {
                    group.addTask {
                        (activity.id, await WebProbe.detect(activity.listener))
                    }
                }
                for await (id, url) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if let url { webURLs[id] = url }
                }
            }
        }
    }

    private var filteredActivities: [Activity] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Ignored ports stay out of the list unless a search asks for them.
        guard !search.isEmpty else { return model.visible.activities }
        return model.snapshot.activities.filter { activity in
            guard !model.closingActivityIDs.contains(activity.id) else { return false }
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

    private func listenerGroups(from activities: [Activity]) -> [ListenerGroup] {
        var groups: [String: [Activity]] = [:]
        var orderedIDs: [String] = []
        for activity in activities {
            let id = "pid:\(activity.process.pid):\(activity.process.executablePath ?? activity.process.command)"
            if groups[id] == nil { orderedIDs.append(id) }
            groups[id, default: []].append(activity)
        }
        return orderedIDs.compactMap { id in
            groups[id].map { ListenerGroup(id: id, activities: $0) }
        }
    }

    // MARK: - Navigation
    //
    // Pages stack like a navigation controller: the list is always at the bottom and each step
    // deeper (port → close review) slides in from the trailing edge. Lower pages stay
    // alive underneath, so going back keeps the list's scroll position and search.

    private enum Page: Hashable { case list, port, review }

    private var path: [Page] {
        var pages: [Page] = [.list]
        if model.selectedActivityID != nil { pages.append(.port) }
        if model.pendingPlan != nil || model.pendingBatchPlans != nil { pages.append(.review) }
        return pages
    }

    private var depth: Int { path.count - 1 }

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.32)
    }

    private var panelBackground: Color { panelSurface(colorScheme) }

    private func goBack() {
        if model.pendingBatchPlans != nil {
            model.pendingBatchPlans = nil
        } else if model.pendingPlan != nil {
            model.pendingPlan = nil
        } else {
            model.selectedActivityID = nil
        }
    }

    /// Multi-listener process headers fold open in place. Their port rows appear beneath the
    /// header one at a time, then fold back in reverse.
    private func toggle(_ group: ListenerGroup) {
        let id = group.id
        let total = group.activities.count
        let expanding = !expandedGroupIDs.contains(id)
        withAnimation(rowMotion) {
            if expanding { expandedGroupIDs.insert(id) } else { expandedGroupIDs.remove(id) }
        }
        foldTasks[id]?.cancel()
        if reduceMotion {
            withAnimation(rowMotion) { revealedCounts[id] = expanding ? total : 0 }
            return
        }
        foldTasks[id] = Task {
            var shown = revealedCounts[id] ?? 0
            let target = expanding ? total : 0
            while shown != target, !Task.isCancelled {
                shown += expanding ? 1 : -1
                withAnimation(rowMotion) { revealedCounts[id] = shown }
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    private var rowMotion: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.26)
    }

    private func showDetails(_ activity: Activity) {
        evidenceExpanded = false
        model.selectedActivityID = activity.id
    }

    private func close(_ activity: Activity) {
        Task { await model.previewClose(activity) }
    }

    private func closeNow(_ activity: Activity) {
        Task { await model.closeNow(activity) }
    }

    // MARK: - Layout

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = model.notice {
                noticeView(notice)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ZStack {
                ForEach(Array(path.enumerated()), id: \.element) { index, page in
                    let isTop = index == depth
                    pageView(page)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(panelBackground)
                        .offset(x: isTop || reduceMotion ? 0 : path.last == .review ? 56 : -56)
                        .opacity(isTop ? 1 : 0)
                        .disabled(!isTop)
                        .accessibilityHidden(!isTop)
                        .zIndex(Double(index))
                        // The close review flies in from the leading edge, like the swipe that closes.
                        .transition(reduceMotion ? .opacity : .move(edge: page == .review ? .leading : .trailing))
                }
            }
            .clipped()
            Divider()
            footer
        }
        .frame(width: 375, height: 460)
        .background(panelBackground)
        .animation(motion, value: path)
        .animation(motion, value: model.notice?.id)
        .task(id: webProbeIdentity) { await detectWebServices() }
        .onChange(of: depth) { _, newDepth in
            searchFocused = newDepth == 0
        }
        .task { await model.refresh() }
    }

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        switch page {
        case .list:
            listPage
        case .port:
            if let activity = selectedActivity { portPage(activity) } else { vanishedPage }
        case .review:
            if let plans = model.pendingBatchPlans {
                batchReviewPage(plans)
            } else if let plan = model.pendingPlan {
                reviewPage(plan)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if depth > 0 {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(QuietButtonStyle())
                .quietFocus()
                .keyboardShortcut(.cancelAction)
                .disabled(model.isClosing)
                .help("Back (Esc)")
                .accessibilityLabel("Back")
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            DoorMark(isOpen: model.hasOpenDoors)
                .frame(width: 18, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("LeftOpen").font(.headline)
                statusLine
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                ZStack {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(QuietButtonStyle())
            .quietFocus()
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isRefreshing || model.isClosing)
            .help("Refresh (⌘R)")
            .accessibilityLabel("Refresh listening ports")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            if model.hasOpenDoors {
                Text("\(model.closablePortCount) open").fontWeight(.medium)
            } else {
                Text("All doors closed")
            }
            Text("·")
            Text("\(model.portCount) listening")
            if model.lanPortCount > 0 {
                Text("·")
                Text("\(model.lanPortCount) LAN")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help("LAN-facing means a non-loopback or wildcard bind. Localhost may still work; other devices need this Mac's LAN address and firewall access.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private func noticeView(_ notice: Notice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.kind.symbol)
                .foregroundStyle(notice.kind.color)
            Text(notice.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(notice.kind.color.opacity(0.08))
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(model.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not yet scanned")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Settings…") { SettingsWindowController.shared.show() }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit LeftOpen (⌘Q)")
        }
        .buttonStyle(QuietButtonStyle())
        .quietFocus()
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: - List Page

    private var listPage: some View {
        VStack(spacing: 0) {
            searchField
            if model.isRefreshing && model.snapshot.activities.isEmpty {
                ProgressView("Scanning this Mac…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredActivities.isEmpty {
                emptyView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !projectGroups.isEmpty {
                            sectionHeader("Projects") {
                                if model.visible.closableProjectActivities.count >= 2 {
                                    Button("Close All…") {
                                        Task { await model.previewBatchCloseProjects() }
                                    }
                                    .buttonStyle(.plain)
                                    .quietFocus()
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color(nsColor: .systemRed))
                                    .disabled(model.isPreparingBatchClose || model.isClosing)
                                    .help("Review closing all \(model.visible.closableProjectPortCount) project ports")
                                }
                            }
                            groupRows(projectGroups)
                        }
                        if !serviceGroups.isEmpty {
                            sectionHeader("Other Processes") { EmptyView() }
                            groupRows(serviceGroups)
                        }
                        if !protectedGroups.isEmpty {
                            protectedHeader
                            if protectedExpanded || !query.isEmpty {
                                groupRows(protectedGroups)
                            }
                        }
                        if !model.snapshot.limitations.isEmpty {
                            DisclosureGroup("Scan limitations", isExpanded: $limitationsExpanded) {
                                ForEach(model.snapshot.limitations, id: \.self) { limitation in
                                    Text(limitation)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                }
                            }
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                    .animation(motion, value: filteredActivities.map(\.id))
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search port, process, or PID", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onAppear {
                    DispatchQueue.main.async { searchFocused = true }
                }
                .accessibilityLabel("Search listening ports")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(QuietButtonStyle())
                .quietFocus()
                .accessibilityLabel("Clear search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func sectionHeader<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// Apps and system services: not closable, so hidden behind a disclosure unless the
    /// user is searching (a search that only matches protected ports must still show them).
    private var protectedHeader: some View {
        let expanded = protectedExpanded || !query.isEmpty
        return Button {
            withAnimation(motion) { protectedExpanded.toggle() }
        } label: {
            sectionHeader("Not Closable") {
                Text(String(protectedGroups.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .quietFocus()
        .disabled(!query.isEmpty)
        .accessibilityLabel("\(protectedGroups.count) not closable apps and system services")
        .accessibilityHint(expanded ? "Collapses the list" : "Expands the list")
    }

    private func groupRows(_ groups: [ListenerGroup]) -> some View {
        ForEach(groups) { group in
            let closeTarget = group.closeTarget
            let foldable = group.activities.count > 1
            let expanded = foldable && expandedGroupIDs.contains(group.id)
            let revealed = foldable ? min(revealedCounts[group.id] ?? 0, group.activities.count) : 0
            let listeners = group.activities.sorted { $0.listener.port < $1.listener.port }
            if foldable {
                VStack(spacing: 0) {
                    if expanded {
                        Divider().padding(.horizontal, 14)
                    }

                    PortRow(
                        port: expanded ? nil : group.ports[0],
                        extraPorts: expanded ? 0 : group.ports.count - 1,
                        icon: group.primary,
                        title: group.primary.inference.label,
                        subtitle: group.subtitle,
                        isLAN: group.scope == .lan,
                        allowsSwipe: false,
                        alignIdentityWithPorts: expanded,
                        disclosure: expanded,
                        onSelect: { toggle(group) },
                        onClose: nil
                    )
                    .contextMenu { contextMenu(for: group.activities) }

                    ForEach(Array(listeners.prefix(revealed)), id: \.id) { activity in
                        listenerRow(activity)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }

                    if expanded {
                        Divider().padding(.horizontal, 14)
                    }
                }
                .animation(motion, value: revealed)
            } else if let activity = listeners.first {
                PortRow(
                    port: activity.listener.port,
                    icon: activity,
                    title: activity.inference.label,
                    subtitle: group.subtitle,
                    trailing: activity.process.compactUptime,
                    isLAN: activity.scope == .lan,
                    onSelect: { showDetails(activity) },
                    onClose: closeTarget.map { target in { closeNow(target) } }
                )
                .contextMenu { contextMenu(for: group.activities) }
            }
        }
    }

    /// A port row under its process header; process identity is inherited from the parent.
    private func listenerRow(_ activity: Activity) -> some View {
        let closeTarget = CloseService.protectionReason(for: activity) == nil ? activity : nil
        return PortRow(
            port: activity.listener.port,
            icon: nil,
            title: activity.listener.addresses.joined(separator: ", "),
            subtitle: activity.scope == .lan ? "LAN-facing" : "Local only",
            isLAN: activity.scope == .lan,
            onSelect: { showDetails(activity) },
            onClose: closeTarget.map { target in { closeNow(target) } }
        )
        .contextMenu { contextMenu(for: [activity]) }
    }

    private var emptyView: some View {
        let scanUnavailable = model.notice?.kind == .error && model.snapshot.activities.isEmpty
        let nothingListening = model.visible.activities.isEmpty && query.isEmpty
        return VStack(spacing: 6) {
            Image(systemName: scanUnavailable ? "exclamationmark.triangle"
                : nothingListening ? "door.left.hand.closed" : "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(scanUnavailable ? "Unable to scan" : nothingListening ? "Nothing left open" : "No matching ports")
                .font(.headline)
            Text(scanUnavailable ? "Check the message above, then refresh."
                : nothingListening ? "No TCP listeners on this Mac." : "Try a port number, process name, or PID.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !query.isEmpty {
                Button("Clear Search") { query = "" }
                    .controlSize(.small)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Port Page

    private func portPage(_ activity: Activity) -> some View {
        let port = activity.listener.port
        let protection = CloseService.protectionReason(for: activity)
        let webURL = browserURL(for: activity)
        let folder = revealTarget(for: activity)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ProcessIconView(activity: activity, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Port \(String(port))")
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        Text(activity.inference.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ScopeLabel(scope: activity.scope)
                }

                if webURL != nil || folder != nil || protection == nil {
                    HStack(spacing: 6) {
                        if let webURL {
                            Button {
                                NSWorkspace.shared.open(webURL)
                            } label: {
                                Label("Open", systemImage: "safari")
                            }
                            .keyboardShortcut("o", modifiers: .command)
                            .help("Open verified web endpoint: \(webURL.absoluteString) (⌘O)")
                            Button {
                                copy(webURL.absoluteString)
                            } label: {
                                Label("Copy URL", systemImage: "link")
                            }
                            .help("Copy verified URL: \(webURL.absoluteString)")
                        }
                        if let folder {
                            Button {
                                reveal(folder)
                            } label: {
                                Label("Reveal", systemImage: "folder")
                            }
                            .help("Reveal \(compactPath(folder)) in Finder")
                        }
                        Spacer(minLength: 0)
                        if protection == nil {
                            Button {
                                close(activity)
                            } label: {
                                Text("Close…").foregroundStyle(Color(nsColor: .systemRed))
                            }
                            .disabled(model.isPreparingClose || model.isClosing)
                            .help("Review closing PID \(String(activity.process.pid))")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let protection {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Can't be closed from LeftOpen")
                                .font(.callout.weight(.medium))
                            Text(protection)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    infoRow("Command", activity.process.command)
                    infoRow("PID", String(activity.process.pid))
                    if let uptime = activity.process.uptime {
                        infoRow("Uptime", uptime)
                    }
                    if let memory = activity.process.memoryUsage {
                        infoRow("Memory", memory)
                    }
                    infoRow("Executable", compactPath(activity.process.executablePath))
                    infoRow("Folder", compactPath(activity.process.cwd))
                    infoRow("Addresses", activity.listener.addresses.joined(separator: ", "))
                    if let webURL {
                        infoRow("Web URL", webURL.absoluteString)
                    }
                }

                Divider()
                DisclosureGroup("Owner evidence", isExpanded: $evidenceExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        infoRow("Type", activity.inference.category.accessibleName.capitalized)
                        infoRow("User", activity.process.user ?? activity.process.uid.map(String.init) ?? "Unknown")
                        if let project = activity.projectMarker {
                            infoRow("Marker", compactPath(project.markerPath))
                        }
                        if let bundle = activity.applicationBundle {
                            infoRow("Application", compactPath(bundle.path))
                        }
                        if !activity.parentChain.isEmpty {
                            infoRow("Parents", activity.parentChain.map { "\($0.command) (\(String($0.pid)))" }.joined(separator: " → "))
                        }
                        infoRow("Confidence", activity.inference.confidence)
                        Text(activity.inference.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
            }
            .padding(14)
        }
    }

    private var vanishedPage: some View {
        VStack(spacing: 6) {
            Image(systemName: "door.left.hand.closed")
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text("No longer listening").font(.headline)
            Text("It went away during the last refresh.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Back", action: goBack)
                .controlSize(.small)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Review Pages

    private func reviewPage(_ plan: ClosePlan) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Close port \(String(plan.port))?")
                        .font(.title3.weight(.semibold))
                    Text("LeftOpen sends SIGTERM to PID \(String(plan.pid)) only. Nothing is force-quit, and child processes are not signalled.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    infoRow("Process", plan.activity.process.command)
                    infoRow("Executable", compactPath(plan.executablePath))
                    infoRow("Started", plan.startTime)
                    if !plan.otherPorts.isEmpty {
                        caution("It also listens on \(plan.otherPorts.map(String.init).joined(separator: ", ")); those ports will close too.")
                    }
                    if !plan.peerPIDs.isEmpty {
                        caution("Other processes share this port. Only PID \(String(plan.pid)) is signalled.")
                    }
                }
                .padding(14)
            }
            confirmBar(plan.otherPorts.isEmpty ? "Close Port" : "Close Ports") {
                Task { await model.confirmClose() }
            }
        }
    }

    private func batchReviewPage(_ plans: [ClosePlan]) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Close \(plans.count) project server\(plans.count == 1 ? "" : "s")?")
                            .font(.title3.weight(.semibold))
                        Text("LeftOpen sends SIGTERM to each process below. Apps and system services are not touched.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    ForEach(plans) { plan in
                        PortRow(
                            port: plan.port,
                            icon: plan.activity,
                            title: plan.activity.inference.label,
                            subtitle: "\(plan.activity.process.command) · PID \(String(plan.pid))",
                            trailing: plan.activity.process.compactUptime
                        )
                    }
                }
            }
            confirmBar("Close All") {
                Task { await model.confirmBatchClose() }
            }
        }
    }

    /// Shared by both review pages: Cancel is the header's back button (Esc), so the bar only
    /// carries progress and the destructive default action.
    private func confirmBar(_ title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if model.isClosing {
                ProgressView().controlSize(.small)
                Text("Closing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: goBack)
                .disabled(model.isClosing)
            Button(title, role: .destructive, action: action)
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: .systemRed))
                .keyboardShortcut(.defaultAction)
                .disabled(model.isClosing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }

    private func caution(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
        }
        .font(.callout)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    @ViewBuilder
    private func contextMenu(for activities: [Activity]) -> some View {
        let ports = Array(Set(activities.map(\.listener.port))).sorted()
        let primary = activities[0]
        let webTargets = activities.compactMap { activity -> WebTarget? in
            browserURL(for: activity).map { WebTarget(activity: activity, url: $0) }
        }
        if webTargets.count == 1, let target = webTargets.first {
            Button("Open in Browser") { NSWorkspace.shared.open(target.url) }
            Button("Copy URL") { copy(target.url.absoluteString) }
        } else if webTargets.count > 1 {
            Menu("Open in Browser") {
                ForEach(webTargets) { target in
                    Button(String(target.activity.listener.port)) { NSWorkspace.shared.open(target.url) }
                }
            }
            Menu("Copy URL") {
                ForEach(webTargets) { target in
                    Button(String(target.activity.listener.port)) { copy(target.url.absoluteString) }
                }
            }
        }
        Button(ports.count == 1 ? "Copy Port" : "Copy Ports") {
            copy(ports.map(String.init).joined(separator: ", "))
        }
        Button("Copy PID") { copy(String(primary.process.pid)) }
        if let folder = revealTarget(for: primary) {
            Divider()
            Button("Reveal in Finder") { reveal(folder) }
        }
        let closable = activities
            .filter { CloseService.protectionReason(for: $0) == nil }
            .sorted { $0.listener.port < $1.listener.port }
        if !closable.isEmpty {
            Divider()
            ForEach(closable) { activity in
                Button("Close Port \(String(activity.listener.port))…") { close(activity) }
            }
        }
    }

    private func browserURL(for activity: Activity) -> URL? {
        webURLs[activity.id]
    }

    private func revealTarget(for activity: Activity) -> String? {
        let candidates = [activity.projectMarker?.root, activity.applicationBundle?.path,
                          activity.inference.category == .project ? activity.process.cwd : nil,
                          activity.process.executablePath]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - Components

private struct WebTarget: Identifiable {
    let activity: Activity
    let url: URL
    var id: String { activity.id }
}

/// The panel's surface colour, shared by the pages and the opaque row cards that sit on it.
private func panelSurface(_ colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor)
}


private struct ListenerGroup: Identifiable {
    let id: String
    let activities: [Activity]

    var primary: Activity { activities[0] }
    var ports: [Int] { Array(Set(activities.map(\.listener.port))).sorted() }
    var pids: [Int32] { Array(Set(activities.map(\.process.pid))).sorted() }
    var scope: ListenerScope { activities.contains { $0.scope == .lan } ? .lan : .local }

    /// What a swipe or ✕ closes: only offered when one closable PID owns every port in the row.
    var closeTarget: Activity? {
        pids.count == 1 && CloseService.protectionReason(for: primary) == nil ? primary : nil
    }

    var subtitle: String {
        if pids.count > 1 { return "\(pids.count) processes" }
        let pid = "PID \(primary.process.pid)"
        return primary.inference.label == primary.process.command ? pid : "\(primary.process.command) · \(pid)"
    }
}

/// One row style for every port list in the panel.
///
/// Interactive rows (with `onSelect`) are a card lying on an action layer: Close (red) under the
/// leading edge, when closable, and Details (blue) under the trailing edge. Drag right to close,
/// left for details. Dragging, by mouse
/// or two-finger trackpad swipe, slides the card across the layer, and letting go past the
/// threshold runs the uncovered action. Swiping to close is the confirmation: no review page.
private struct PortRow: View {
    let port: Int?
    var extraPorts = 0
    var icon: Activity?
    let title: String
    var subtitle: String?
    var trailing: String?
    var isLAN = false
    var allowsSwipe = true
    /// Expanded process headers put their icon in the now-vacant port column.
    var alignIdentityWithPorts = false
    /// Some(expanded) for a row that folds; the chevron is only ever a fold control.
    var disclosure: Bool?
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    @StateObject private var swipe = SwipeTracker()
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    // How much of each action is uncovered: the gap between the layer's edge and the card.
    private var leadingReveal: CGFloat { max(0, swipe.offset) }
    private var trailingReveal: CGFloat { max(0, -swipe.offset) }
    private var isLifted: Bool { swipe.offset != 0 }

    @ViewBuilder
    var body: some View {
        if !allowsSwipe, let onSelect {
            Button(action: onSelect) {
                card
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .quietFocus()
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
            .accessibilityHint(disclosure == true ? "Collapse ports" : "Expand ports")
        } else {
            swipableRow
        }
    }

    private var swipableRow: some View {
        card
            .offset(x: swipe.offset)
            .background { actionLayer }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
            .onTapGesture { onSelect?() }
            .gesture(dragGesture, including: onSelect == nil ? .none : .all)
            .onHover { hovering in
                guard onSelect != nil else { return }
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
                configureSwipe()
                swipe.setListening(hovering && isEnabled)
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { swipe.setListening(false) }
            }
            .onDisappear { swipe.setListening(false) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
            .accessibilityAction { onSelect?() }
            .accessibilityActions {
                if let onClose {
                    Button("Close Port \(port.map(String.init) ?? "")", action: onClose)
                }
            }
    }

    private var card: some View {
        HStack(spacing: 10) {
            if !alignIdentityWithPorts {
                HStack(spacing: 4) {
                    if let port {
                        Text(String(port))
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                    } else {
                        Color.clear.frame(width: 1)
                    }
                    if extraPorts > 0 {
                        Text("+\(extraPorts)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .transition(.offset(y: 10).combined(with: .opacity))
                    }
                }
                .frame(width: 76, alignment: .leading)
            }

            if let icon {
                ProcessIconView(activity: icon, size: 22)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if isLAN {
                LANBadge()
            }
            if let disclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(disclosure ? 90 : 0))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            // Opaque, so the action layer is only seen where the card has moved off it.
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            shape
                .fill(panelSurface(colorScheme))
                .overlay(shape.fill(Color.primary.opacity(isHovered || isLifted ? 0.06 : 0)))
                .shadow(color: .black.opacity(isLifted ? 0.14 : 0), radius: 1.5, y: 0.5)
        }
    }

    /// Details under the leading half, Close (or a lock, when it can't be closed) under the
    /// trailing half. Each label is centred in whatever part of its side is uncovered.
    @ViewBuilder
    private var actionLayer: some View {
        if allowsSwipe && onSelect != nil && swipe.offset != 0 {
            HStack(spacing: 0) {
                side(onClose == nil ? .locked : .close, reveal: leadingReveal, alignment: .leading)
                side(.details, reveal: trailingReveal, alignment: .trailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(.snappy(duration: 0.18), value: swipe.isArmed)
        }
    }

    private enum Action { case details, close, locked }

    private func side(_ action: Action, reveal: CGFloat, alignment: Alignment) -> some View {
        let tint = switch action {
        case .details: Color(nsColor: .systemBlue)
        case .close: Color(nsColor: .systemRed)
        case .locked: Color.secondary
        }
        let armed = swipe.isArmed && (action == .details) == (swipe.offset < 0)
        return ZStack(alignment: alignment) {
            Rectangle().fill(armed ? tint : tint.opacity(0.16))
            HStack(spacing: 5) {
                Image(systemName: action == .details ? "info.circle.fill" : action == .close ? "xmark.circle.fill" : "lock.fill")
                    .font(.system(size: reveal < 30 ? 10 : 13, weight: .semibold))
                    .scaleEffect(armed ? 1.15 : 1)
                if reveal > 78 {
                    Text(action == .details ? "Details" : "Close")
                        .font(.system(size: 11, weight: .semibold))
                        .transition(.opacity)
                }
            }
            .foregroundStyle(armed ? Color.white : tint)
            .frame(width: reveal)
            .opacity(reveal > 6 ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: reveal > 78)
        }
        .accessibilityHidden(true)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                configureSwipe()
                swipe.drag(value.translation)
            }
            .onEnded { value in
                swipe.endDrag(predicted: value.predictedEndTranslation.width)
            }
    }

    private func configureSwipe() {
        swipe.allowsLeading = onClose != nil
        swipe.onCommit = { edge in
            if edge == .leading { onClose?() } else { onSelect?() }
        }
    }
}

/// Tracks a row's horizontal pull from either a mouse drag or a trackpad two-finger swipe
/// (scroll events, watched only while the pointer is over the row). Vertical movement is left
/// alone so the list still scrolls.
@MainActor
private final class SwipeTracker: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var isArmed = false

    /// Whether the leading action (revealed by dragging right) exists; trailing always does.
    var allowsLeading = true
    var onCommit: (HorizontalEdge) -> Void = { _ in }

    private let threshold: CGFloat = 84
    private let softLimit: CGFloat = 150
    private var raw: CGFloat = 0
    private var axis: Axis = .undecided
    private var swallowMomentum = false
    nonisolated(unsafe) private var monitor: Any?

    private enum Axis { case undecided, horizontal, vertical }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: Mouse drag

    func drag(_ translation: CGSize) {
        if axis == .undecided {
            axis = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
            if axis == .horizontal { NSCursor.closedHand.push() }
        }
        guard axis == .horizontal else { return }
        raw = translation.width
        update()
    }

    func endDrag(predicted: CGFloat) {
        let wasHorizontal = axis == .horizontal
        axis = .undecided
        guard wasHorizontal else { return }
        NSCursor.pop()
        // A quick flick past twice the threshold counts, even if released short of it.
        let flicked = abs(predicted) > threshold * 2 && isAllowed(predicted) && (predicted > 0) == (raw > 0)
        finish(commit: isArmed || flicked)
    }

    // MARK: Trackpad swipe

    func setListening(_ listening: Bool) {
        if listening, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                let consumed = MainActor.assumeIsolated { self.handleScroll(event) }
                return consumed ? nil : event
            }
        } else if !listening, let monitor, axis != .horizontal {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Returns true when the event belongs to a horizontal row swipe and must not scroll the list.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.momentumPhase != [] { return swallowMomentum }
        switch event.phase {
        case .began:
            axis = .undecided
            raw = 0
            swallowMomentum = false
            return false
        case .changed:
            if axis == .undecided {
                let dx = abs(event.scrollingDeltaX), dy = abs(event.scrollingDeltaY)
                guard dx + dy > 0.5 else { return false }
                axis = dx > dy ? .horizontal : .vertical
            }
            guard axis == .horizontal else { return false }
            // Follow the fingers whichever scroll direction the user prefers.
            raw += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            update()
            return true
        case .ended, .cancelled:
            guard axis == .horizontal else { axis = .undecided; return false }
            axis = .undecided
            swallowMomentum = true
            finish(commit: isArmed)
            return true
        default:
            return axis == .horizontal
        }
    }

    // MARK: Shared

    private func isAllowed(_ direction: CGFloat) -> Bool {
        direction < 0 || allowsLeading
    }

    private func update() {
        let sign: CGFloat = raw < 0 ? -1 : 1
        let distance = abs(raw)
        if !isAllowed(raw) {
            // Nothing to reveal: a stiff pull that tops out, so it reads as "locked".
            offset = sign * min(distance * 0.25, 28)
        } else if distance > softLimit {
            offset = sign * (softLimit + (distance - softLimit) * 0.3)
        } else {
            offset = raw
        }
        let armed = isAllowed(raw) && abs(offset) >= threshold
        if armed != isArmed {
            isArmed = armed
            if armed {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    private func finish(commit: Bool) {
        let edge: HorizontalEdge = raw > 0 ? .leading : .trailing
        raw = 0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            offset = 0
            isArmed = false
        }
        if commit { onCommit(edge) }
    }
}

private struct LANBadge: View {
    var body: some View {
        Text("LAN")
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(Color(nsColor: .systemOrange))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(nsColor: .systemOrange).opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help("Bound beyond loopback. Localhost may still work, but access from another device is not verified.")
    }
}

/// Secondary until hovered, primary on hover: the one style for the panel's chrome buttons.
private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    private struct QuietButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered && isEnabled ? .primary : .secondary)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

private extension View {
    func quietFocus() -> some View {
        focusable(false).focusEffectDisabled()
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
            ? "Non-loopback or wildcard bind observed. Localhost may still work; LAN reachability depends on the actual address and firewall."
            : "Only loopback bind addresses were observed.")
    }
}

struct DoorMark: View {
    var isOpen: Bool = true
    /// One-colour cut-out for template images (the menu bar): the leaf is punched through
    /// instead of painted, so macOS can tint the mark for light and dark menu bars.
    var isTemplate = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let sx = w / 33.0
            let sy = h / 55.0

            let darkColor = isTemplate ? Color.black : colorScheme == .dark ? Color.white : Color(red: 0x21 / 255.0, green: 0x18 / 255.0, blue: 0x11 / 255.0)
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
                    .fill(isTemplate ? Color.black : leafColor)
                    .blendMode(isTemplate ? .destinationOut : .normal)

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
                    .fill(isTemplate ? Color.black : leafColor)
                    .blendMode(isTemplate ? .destinationOut : .normal)

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

                // At menu bar size the hairline frame vanishes; thicken it to SF Symbol weight,
                // keeping the outer edge where the full-size frame's is.
                if isTemplate {
                    let inset = 2.0
                    Path { p in
                        p.move(to: CGPoint(x: inset * sx, y: (54.805 - inset + 0.39) * sy))
                        p.addLine(to: CGPoint(x: inset * sx, y: 16.155 * sy))
                        p.addCurve(
                            to: CGPoint(x: 16.383 * sx, y: (0.248 + inset - 0.39) * sy),
                            control1: CGPoint(x: inset * sx, y: 8.3 * sy),
                            control2: CGPoint(x: 8.5 * sx, y: (0.248 + inset - 0.39) * sy)
                        )
                        p.addCurve(
                            to: CGPoint(x: (32.766 - inset) * sx, y: 16.155 * sy),
                            control1: CGPoint(x: 24.3 * sx, y: (0.248 + inset - 0.39) * sy),
                            control2: CGPoint(x: (32.766 - inset) * sx, y: 8.3 * sy)
                        )
                        p.addLine(to: CGPoint(x: (32.766 - inset) * sx, y: (54.805 - inset + 0.39) * sy))
                        p.closeSubpath()
                    }
                    .stroke(darkColor, lineWidth: 3.2 * sx)
                }
            }
            .compositingGroup()
        }
        .aspectRatio(33.0 / 55.0, contentMode: .fit)
    }
}

/// The door rendered once per state as a template image, sized like an SF Symbol in the menu bar.
@MainActor
enum MenuBarDoor {
    static let open = render(isOpen: true)
    static let closed = render(isOpen: false)

    private static func render(isOpen: Bool) -> NSImage {
        let renderer = ImageRenderer(content: DoorMark(isOpen: isOpen, isTemplate: true).frame(width: 10, height: 16.7))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = isOpen ? "Doors open" : "All doors closed"
        return image
    }
}
