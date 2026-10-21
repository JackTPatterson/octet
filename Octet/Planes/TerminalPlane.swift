import SwiftUI

/// A Terminal plane, after T3 Code's terminal surface: a shell of its own in
/// the panel, started in the project in front. Each plane is its own shell,
/// so several can run side by side in the strip; like every plane it keeps
/// running behind the others.
struct TerminalPlane: View {
    @ObservedObject var ui: UIState
    let planeId: String
    let directory: String?
    /// Where it started, so a later change of tab doesn't move it.
    @State private var folder: String?
    @State private var generation = 0
    @State private var exited = false
    /// The shell is still starting. Bounded, so the skeleton can't outstay
    /// its welcome if the surface never reports a cell size.
    @State private var warming = true

    private var shown: Bool { ui.sidePanelVisible && ui.visiblePlaneIds.contains(planeId) }

    var body: some View {
        ZStack {
            Theme.terminalBackground
            if let folder {
                OctetTerminalView(
                    retainedSurface: ui.panelTerminalSurfaces[planeId],
                    command: Self.shellCommand,
                    environment: Self.environment,
                    workingDirectory: folder,
                    onTitleChange: { [weak ui, planeId] title in
                        guard let ui else { return }
                        let badge = PlaneBadge(title: title.isEmpty ? "Terminal" : title, help: title)
                        if ui.planeBadges[planeId] != badge { ui.planeBadges[planeId] = badge }
                    },
                    onExit: { [weak ui, planeId, exitState = $exited] in
                        ui?.panelTerminalExited.insert(planeId)
                        exitState.wrappedValue = true
                    },
                    onSurface: { [weak ui, planeId] in ui?.panelTerminalSurfaces[planeId] = $0 }
                )
                .id(generation)
            }
            if PlaneLoadingPreview.shows("terminal") || (warming && !exited) {
                TerminalPlaneSkeleton().allowsHitTesting(false).accessibilityLabel("Starting the terminal")
            }
            if exited {
                VStack(spacing: 8) {
                    Text("The shell exited").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                    OctetButton(title: "Start Again", kind: .secondary, compact: true) {
                        ui.panelTerminalSurfaces.removeValue(forKey: planeId)
                        ui.panelTerminalExited.remove(planeId)
                        exited = false
                        folder = directory ?? folder
                        generation += 1
                    }
                }
                .padding(16)
                .octetGlass(cornerRadius: Theme.popoverRadius, fill: Theme.chrome)
                .accessibilityElement(children: .contain)
            }
        }
        .onAppear {
            if folder == nil { folder = directory ?? NSHomeDirectory() }
            exited = ui.panelTerminalExited.contains(planeId)
        }
        .task(id: generation) {
            if ui.panelTerminalSurfaces[planeId] != nil { warming = false; return }
            warming = true
            try? await Task.sleep(for: .seconds(1.5))
            warming = false
        }
        .onChange(of: shown) { _, shown in
            // Keys belong to the main terminal again, not the one now hidden.
            if !shown { OctetTerminalRuntime.focusTerminal() }
        }
    }

    /// The person's login shell.
    private static var shellCommand: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell) + " -l"
        }
        return (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") + " -l"
    }

    private static var environment: [String: String] {
        var env = TerminalEnvironment.colorCapability
        env["OCTET_PANEL_TERMINAL"] = "1"
        return env
    }
}
