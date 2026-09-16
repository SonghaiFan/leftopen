import AppKit
import LeftOpenCore
import SwiftUI

struct MenuPanel: View {
    @ObservedObject var model: MenuModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var selectedProcessPID: Int32?
    @State private var evidenceExpanded = false
    @State private var limitationsExpanded = false

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

    private var projectActivities: [Activity] {
        filteredActivities.filter { $0.inference.category == .project }
    }

    private var otherActivities: [Activity] {
        filteredActivities.filter { $0.inference.category != .project }
    }

    private var projectGroups: [ListenerGroup] { listenerGroups(from: projectActivities) }
    private var otherGroups: [ListenerGroup] { listenerGroups(from: otherActivities) }

    private var selectedProcessGroup: ListenerGroup? {
        guard let selectedProcessPID else { return nil }
        return listenerGroups(from: model.snapshot.activities)
            .first { $0.primary.process.pid == selectedProcessPID }
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
            } else if model.selectedActivityID != nil || selectedProcessPID != nil {
                vanishedView
            } else {
                listView
            }
            Divider()
            footer
        }
        .frame(width: 320, height: 380)
        .background(panelBackground)
        .task { await model.refresh() }
    }

    private var panelBackground: Color {
        Color(nsColor: colorScheme == .dark ? .textBackgroundColor : .windowBackgroundColor)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if model.pendingPlan != nil || model.selectedActivityID != nil || selectedProcessPID != nil {
                Button {
                    if model.pendingPlan != nil {
                        model.pendingPlan = nil
                    } else if model.selectedActivityID != nil {
                        model.selectedActivityID = nil
                    } else {
                        selectedProcessPID = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.pendingPlan == nil ? "Back to ports" : "Back to port details")
                .help(model.pendingPlan == nil ? "Back to ports" : "Back to port details")
                .disabled(model.isClosing)
            }
            DoorMark()
            .frame(width: 22, height: 28)
                .accessibilityHidden(true)
            if model.pendingPlan != nil || model.selectedActivityID != nil || selectedProcessPID != nil {
                Text("LeftOpen").font(.headline)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LeftOpen").font(.headline)
                    HStack(spacing: 6) {
                        Text("\(model.portCount) listening ports")
                        if model.snapshot.lanPortCount > 0 {
                            Text("•")
                            Label("\(model.snapshot.lanPortCount) LAN-facing", systemImage: "globe")
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
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search port, owner or PID", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search listening ports")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
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
                        if !otherGroups.isEmpty {
                            groupSection("Other Processes", groups: otherGroups)
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

    private func groupSection(_ title: String, groups: [ListenerGroup]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 5)
                .padding(.bottom, 3)
            ForEach(groups) { group in
                Button {
                    evidenceExpanded = false
                    if group.ports.count == 1 {
                        model.selectedActivityID = group.primary.id
                    } else {
                        selectedProcessPID = group.primary.process.pid
                    }
                } label: {
                    PortRow(group: group)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ports \(group.ports.map(String.init).joined(separator: ", ")), \(group.primary.inference.label), \(group.primary.inference.category.accessibleName), \(group.scope == .lan ? "LAN-facing" : "local only"), PID \(group.primary.process.pid)")
                .accessibilityHint("Opens listener details")
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
            let id = "\(activity.process.pid):\(activity.process.executablePath ?? activity.process.command)"
            if groups[id] == nil { orderedIDs.append(id) }
            groups[id, default: []].append(activity)
        }
        return orderedIDs.compactMap { id in
            groups[id].map(ListenerGroup.init)
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
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Port \(activity.listener.port)")
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        Text(activity.inference.label).font(.title3)
                    }
                    Spacer()
                    ScopeLabel(scope: activity.scope)
                }

                if let reason = CloseService.protectionReason(for: activity) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Close unavailable", systemImage: "lock")
                            .font(.callout).fontWeight(.medium)
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                }

                Divider()
                infoRow("Command", activity.process.command)
                infoRow("PID", String(activity.process.pid))
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
                    Button("Close Port \(activity.listener.port)…") {
                        Task { await model.previewClose(activity) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
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
                Text(group.primary.inference.label)
                    .font(.title3.weight(.semibold))
                Text("PID \(group.primary.process.pid) · \(group.ports.count) listening ports")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Choose a port to inspect its listener details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                ForEach(group.activities.sorted { $0.listener.port < $1.listener.port }) { activity in
                    Button {
                        model.selectedActivityID = activity.id
                    } label: {
                        HStack(spacing: 10) {
                            Text(String(activity.listener.port))
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                                .frame(width: 54, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activity.listener.addresses.joined(separator: ", "))
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(activity.scope == .lan ? "LAN-facing" : "Local only")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Port \(activity.listener.port), \(activity.scope == .lan ? "LAN-facing" : "local only")")
                    .accessibilityHint("Opens port details")
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
                Text("This sends SIGTERM to one process listening on port \(plan.port). It does not kill a process tree or force-quit anything.")
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
                    .disabled(model.isClosing)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            Text(model.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not yet scanned")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .help("Quit LeftOpen")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct ListenerGroup: Identifiable {
    let activities: [Activity]

    init(_ activities: [Activity]) { self.activities = activities }

    var id: String { "\(primary.process.pid):\(ports.map(String.init).joined(separator: ","))" }
    var primary: Activity { activities[0] }
    var ports: [Int] { Array(Set(activities.map(\.listener.port))).sorted() }
    var scope: ListenerScope { activities.contains { $0.scope == .lan } ? .lan : .local }
}

private struct PortRow: View {
    let group: ListenerGroup

    var body: some View {
        HStack(spacing: 9) {
            Text(group.ports.map(String.init).joined(separator: " · "))
                .font(.system(.callout, design: .monospaced)).fontWeight(.semibold)
                .frame(width: 66, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.primary.inference.label).font(.callout).lineLimit(1)
                Text(group.primary.inference.label == group.primary.process.command
                    ? "PID \(group.primary.process.pid)"
                    : "\(group.primary.process.command) · PID \(group.primary.process.pid)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if group.ports.count > 1 {
                Text("\(group.ports.count) ports")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if group.scope == .lan {
                Text("LAN")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help("LAN-facing bind address; actual reachability was not checked")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private extension OwnerCategory {
    var accessibleName: String {
        switch self {
        case .project: "project"
        case .application: "application"
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
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: width * 0.08, y: height))
                    path.addLine(to: CGPoint(x: width * 0.08, y: height * 0.30))
                    path.addCurve(
                        to: CGPoint(x: width * 0.92, y: height * 0.38),
                        control1: CGPoint(x: width * 0.08, y: 0),
                        control2: CGPoint(x: width * 0.92, y: 0)
                    )
                    path.addLine(to: CGPoint(x: width * 0.92, y: height))
                    path.closeSubpath()
                }
                .fill(Color(nsColor: .labelColor))

                Path { path in
                    path.move(to: CGPoint(x: width * 0.31, y: height * 0.82))
                    path.addLine(to: CGPoint(x: width * 0.31, y: height * 0.34))
                    path.addCurve(
                        to: CGPoint(x: width * 0.69, y: height * 0.39),
                        control1: CGPoint(x: width * 0.31, y: height * 0.17),
                        control2: CGPoint(x: width * 0.69, y: height * 0.17)
                    )
                    path.addLine(to: CGPoint(x: width * 0.69, y: height * 0.77))
                    path.closeSubpath()
                }
                .fill(Color(nsColor: .windowBackgroundColor))

                Circle()
                    .fill(Color(nsColor: .labelColor))
                    .frame(width: max(2, width * 0.09), height: max(2, width * 0.09))
                    .position(x: width * 0.42, y: height * 0.54)
            }
        }
        .aspectRatio(0.72, contentMode: .fit)
    }
}
