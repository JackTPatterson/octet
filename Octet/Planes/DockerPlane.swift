import SwiftUI

struct DockerPlane: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var ui: UIState
    let directory: String?
    let visible: Bool
    @StateObject private var model = DockerPanelModel()
    @State private var query = ""
    @State private var state = "all"
    @State private var project = ""
    @State private var automatic = true

    private var rows: [DockerContainer] {
        let root = directory.map { AccountProfiles.projectRoot(of: $0) ?? $0 }
        return model.containers.filter { row in
            (query.isEmpty || row.searchText.localizedCaseInsensitiveContains(query)) &&
            (state == "all" || (state == "running" ? row.running : !row.running)) &&
            (project.isEmpty || (project == "__current__" ? root.map { row.belongs(to: $0) } ?? false : row.project == project))
        }
    }
    private var projectOptions: [(value: String, title: String)] {
        [("", "All projects")] + (directory == nil ? [] : [("__current__", "This project")]) + model.projects.map { ($0, $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Containers").font(Theme.uiFontMedium)
                Text("\(model.containers.filter(\.running).count) running · \(model.containers.count) total")
                    .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
                if model.loading { ProgressView().controlSize(.small) }
                OctetIconButton(icon: automatic ? "pause.circle" : "play.circle", help: automatic ? "Pause automatic refresh" : "Refresh automatically", active: automatic) { automatic.toggle() }
                OctetIconButton(icon: "arrow.clockwise", help: "Refresh containers and Docker contexts") {
                    Task { await model.discover(); await model.refresh(); await model.loadDetails() }
                }.disabled(model.loading)
            }.padding(.horizontal, 12).frame(height: 36)
            VStack(spacing: 8) {
                HStack {
                    Text("Context").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                    OctetSelect(selection: Binding(get: { model.context }, set: { model.changeContext($0); project = "" }),
                                options: model.contexts.map { (value: $0.Name, title: $0.Name) })
                    Spacer(minLength: 0)
                }
                OctetTextField(placeholder: "Filter name, image, project or port…", text: $query)
                HStack {
                    OctetSelect(selection: $state, options: [("all", "All states"), ("running", "Running"), ("stopped", "Not running")], width: 120)
                    OctetSelect(selection: $project, options: projectOptions)
                    Spacer(minLength: 0)
                }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            if let failure = model.failure { error(failure) }
            if let failure = model.actionFailure { error(failure) }
            if model.loading && model.containers.isEmpty {
                ProgressView("Loading containers…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                PlaneMessage(icon: "containers", title: model.failure == nil ? "No containers to show" : "Docker unavailable",
                             detail: model.failure == nil ? "Try another filter, project or Docker context." : "Check the selected Docker context, then refresh.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { container in
                            OctetCollapsible(title: container.Names, open: Binding(
                                get: { model.selected == container.id },
                                set: { model.select($0 ? container.id : nil) }
                            ), trailing: {
                                Text(container.State).font(Theme.captionFont)
                                    .foregroundStyle(container.running ? Theme.accent : Theme.textSecondary)
                            }) {
                                detail(container)
                            }.padding(.horizontal, 12)
                            Divider()
                        }
                    }
                }.octetScrollIndicators()
            }
            if let updated = model.updated {
                HStack {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                    Spacer()
                    Text(automatic ? "Auto refresh · 5s" : "Refresh paused")
                }.font(Theme.captionFont).foregroundStyle(Theme.textTertiary).padding(.horizontal, 12).frame(height: 26)
            }
        }
        .background(Theme.sidebar).frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.discover() }
        .task(id: "\(visible):\(model.context):\(automatic)") {
            guard visible, !model.context.isEmpty else { return }
            repeat {
                await model.refresh()
                guard automatic, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
        .task(id: "\(visible):\(model.context):\(model.selected ?? ""):\(automatic)") {
            guard visible, model.selected != nil else { return }
            repeat {
                await model.loadDetails()
                guard automatic, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
    }

    @ViewBuilder private func detail(_ container: DockerContainer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(container.Image).font(Theme.captionFont).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            Text(container.Status).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            if !container.project.isEmpty {
                Text("\(container.project) · \(container.service)").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            }
            actions(container)
            HStack {
                OctetButton(title: "View Logs", icon: "tool.read", kind: .secondary, compact: true) { window.openContainerLogs(context: model.context, container: container) }
                if container.running {
                    OctetButton(title: "Copy shell command", icon: "terminal", kind: .ghost, compact: true) {
                        copy(DockerJSON.shellCommand(context: model.context, id: container.id))
                    }
                }
            }
            if let stats = model.stats {
                OctetShelfHeader(icon: "containers", title: "Resources", count: 5)
                info("CPU", stats.CPUPerc)
                info("Memory", "\(stats.MemUsage) (\(stats.MemPerc))")
                info("Network I/O", stats.NetIO)
                info("Disk I/O", stats.BlockIO)
                info("Processes", stats.PIDs)
            }
            if let failure = model.statsFailure { error("Resource usage: " + failure) }
            if model.detailLoading && model.inspection == nil { ProgressView().controlSize(.small) }
            if let failure = model.detailFailure { error(failure) }
            if let detail = model.inspection {
                DockerInspectionView(detail: detail, local: model.local, running: container.running, openURL: { ui.openInBrowserPlane($0) })
            }
            OctetCopyText(text: container.id, display: String(container.id.prefix(12)), help: "Copy container ID")
            if container.removable {
                OctetConfirmButton(title: "Remove container", icon: "trash", confirmTitle: "Remove this container?", kind: .destructive,
                                   busy: model.busy.contains(model.context + ":" + container.id)) { model.perform(.remove, on: container) }
                    .disabled(model.busy.contains(model.context + ":" + container.id))
            }
        }.padding(.bottom, 12)
    }

    private func actions(_ container: DockerContainer) -> some View {
        ViewThatFits(in: .horizontal) {
            actionButtons(container, iconsOnly: false)
            actionButtons(container, iconsOnly: true)
        }.disabled(model.busy.contains(model.context + ":" + container.id))
    }

    private func actionButtons(_ container: DockerContainer, iconsOnly: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(DockerAction.allCases.filter { $0 != .remove && $0.allowed(for: container) }, id: \.rawValue) { action in
                if iconsOnly {
                    OctetIconButton(icon: action.icon, help: "\(action.title) \(container.Names)") { model.perform(action, on: container) }
                } else {
                    OctetButton(title: action.title, icon: action.icon, kind: .ghost, compact: true) { model.perform(action, on: container) }
                }
            }
            if model.busy.contains(model.context + ":" + container.id) { ProgressView().controlSize(.small) }
        }.disabled(model.busy.contains(model.context + ":" + container.id))
    }

    private func error(_ text: String) -> some View {
        Text(text).font(Theme.captionFont).foregroundStyle(Theme.danger).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(value).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
        }.font(Theme.captionFont)
    }

    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

private struct DockerInspectionView: View {
    let detail: DockerInspection
    let local: Bool
    let running: Bool
    let openURL: (URL) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let health = detail.State?.Health?.Status { info("Health", health) }
            if let exit = detail.State?.ExitCode, !running { info("Exit code", String(exit)) }
            if let error = detail.State?.Error, !error.isEmpty { Text(error).font(Theme.captionFont).foregroundStyle(Theme.danger).textSelection(.enabled) }
            if let created = detail.Created { info("Created", date(created)) }
            if let started = detail.State?.StartedAt, !started.hasPrefix("0001") { info("Started", date(started)) }
            if let restarts = detail.RestartCount { info("Restarts", String(restarts)) }
            if let policy = detail.HostConfig?.RestartPolicy?.Name { info("Restart policy", policy) }
            if let work = detail.Config?.WorkingDir, !work.isEmpty { info("Working directory", work) }
            if let user = detail.Config?.User, !user.isEmpty { info("User", user) }
            let ports = detail.NetworkSettings?.Ports ?? [:]
            if !ports.isEmpty {
                OctetShelfHeader(icon: "link.badge.plus", title: "Ports", count: ports.count)
                ForEach(ports.keys.sorted(), id: \.self) { port in
                    let bindings = ports[port] ?? nil
                    if let bindings, !bindings.isEmpty {
                        ForEach(Array(bindings.enumerated()), id: \.offset) { _, binding in
                            HStack {
                                OctetCopyText(text: binding.address, display: "\(binding.HostPort) → \(port)")
                                Spacer()
                                if running, let url = binding.browserURL(containerPort: port, local: local) {
                                    OctetIconButton(icon: "arrow.up.right", help: "Open port \(binding.HostPort) in browser") { openURL(url) }
                                }
                            }
                        }
                    } else { info(port, "Not published") }
                }
            }
            let networks = detail.NetworkSettings?.Networks ?? [:]
            if !networks.isEmpty {
                OctetShelfHeader(icon: "branch", title: "Networks", count: networks.count)
                ForEach(networks.keys.sorted(), id: \.self) { name in info(name, networks[name]?.IPAddress ?? "") }
            }
            let mounts = detail.Mounts ?? []
            if !mounts.isEmpty {
                OctetShelfHeader(icon: "folder", title: "Mounts", count: mounts.count)
                ForEach(Array(mounts.enumerated()), id: \.offset) { _, mount in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(mount.Destination ?? "") · \(mount.RW == true ? "read/write" : "read-only")").font(Theme.captionFont)
                        Text(mount.Source ?? "").font(Theme.captionFont.monospaced()).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                    }
                }
            }
        }
    }
    private func info(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(value).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
        }.font(Theme.captionFont)
    }
    private func date(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}
