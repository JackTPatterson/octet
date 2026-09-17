import SwiftUI

/// Herd's Settings window (⌘,), styled like the rest of the app.
struct SettingsView: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject var motion = MotionPreferences.shared
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var integrations = HerdrIntegrations.shared
    @State private var section: Section = .general

    enum Section: String, CaseIterable, Identifiable {
        case general, appearance, terminal, agents, motion, keyboard, advanced

        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .terminal: return "Terminal"
            case .agents: return "Agents & Recovery"
            case .motion: return "Motion"
            case .keyboard: return "Keyboard"
            case .advanced: return "Advanced"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .terminal: return "terminal"
            case .agents: return "sparkle.magnifyingglass"
            case .motion: return "sparkles"
            case .keyboard: return "keyboard"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { item in
                    SidebarItem(title: item.title, symbol: item.symbol, selected: section == item) {
                        section = item
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 40)
            .padding(.bottom, 8)
            .frame(width: 200)
            .frame(maxHeight: .infinity)
            .background(Theme.sidebar)
            Rectangle().fill(Theme.divider).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(section.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    switch section {
                    case .general: GeneralSettings(store: store, settings: settings)
                    case .appearance: AppearanceSettings(settings: settings)
                    case .terminal: TerminalSettings(settings: settings)
                    case .agents: AgentSettings(settings: settings, integrations: integrations)
                    case .motion: MotionSettings(motion: motion)
                    case .keyboard: KeyboardSettings()
                    case .advanced: AdvancedSettings(store: store, settings: settings)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 40)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.terminalBackground)
        }
        .frame(width: 780)
        .frame(minHeight: 560, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(DarkTransparentTitleBar())
        .id(settings.values.themeName)
        .preferredColorScheme(Theme.colorScheme)
        .background(ThemedWindow(themeName: settings.values.themeName))
    }
}

// MARK: - Sections

private struct GeneralSettings: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject var settings: SettingsStore

    private let presets: [(String, TimeInterval)] = [
        ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14_400),
        ("8 hours", 28_800), ("1 day", 86_400), ("3 days", 259_200),
    ]

    var body: some View {
        SettingsGroup(title: "Startup & quitting") {
            SettingsRow(
                title: "Show tips",
                detail: "A card at the foot of the sidebar with one thing Herd does that is easy to miss. Click it for another."
            ) {
                Toggle("", isOn: $settings.values.showTips).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Confirm before quitting", detail: "Quitting Herd leaves terminals and agents running in the background.") {
                Toggle("", isOn: $settings.values.confirmQuit).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "New panes & shells") {
            SettingsRow(title: "Start new tabs and workspaces in", detail: "Follow uses the focused pane's folder.") {
                Picker("", selection: $settings.values.newPaneDirectory) {
                    Text("Focused pane's folder").tag(HerdSettings.NewPaneDirectory.follow)
                    Text("Home folder").tag(HerdSettings.NewPaneDirectory.home)
                    Text("The terminal's folder").tag(HerdSettings.NewPaneDirectory.current)
                }
                .labelsHidden().frame(width: 190)
            }
            SettingsDivider()
            SettingsRow(title: "Shell", detail: "Leave empty to use $SHELL.") {
                TextField("$SHELL", text: $settings.values.defaultShell)
                    .textFieldStyle(.roundedBorder).frame(width: 190)
            }
            SettingsDivider()
            SettingsRow(title: "Shell startup mode", detail: "Login shells read your profile files.") {
                Picker("", selection: $settings.values.shellMode) {
                    Text("Automatic").tag(HerdSettings.ShellMode.auto)
                    Text("Login").tag(HerdSettings.ShellMode.login)
                    Text("Non-login").tag(HerdSettings.ShellMode.nonLogin)
                }
                .labelsHidden().frame(width: 190)
            }
        }
        SettingsGroup(title: "Idle workspaces") {
            SettingsRow(
                title: "Move to Idle after",
                detail: "Unused workspaces drop into the Idle dock at the bottom of the sidebar. Pinned workspaces, the one you're in, and agents that are working or waiting on you never go idle."
            ) {
                Picker("", selection: $store.idleAfter) {
                    ForEach(presets, id: \.1) { label, seconds in
                        Text(label).tag(seconds)
                    }
                    if !presets.contains(where: { $0.1 == store.idleAfter }) {
                        Text(IdleDock.thresholdLabel(store.idleAfter)).tag(store.idleAfter)
                    }
                }
                .labelsHidden().frame(width: 190)
            }
            SettingsDivider()
            SettingsRow(title: "Pinned workspaces", detail: "Pin from a workspace's context menu or the command palette.") {
                HStack(spacing: 8) {
                    Text("\(store.pinnedWorkspaceIds.count)").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                    Button("Unpin All") {
                        for id in store.pinnedWorkspaceIds { store.setPinned(id, false) }
                    }
                    .disabled(store.pinnedWorkspaceIds.isEmpty)
                }
            }
        }
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var settings: SettingsStore

    private var monospacedFamilies: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// What Herd found to follow, or how to point it at a file.
    private var importDetail: String {
        if let theme = settings.values.importedTheme {
            return "Using \(theme.name), read from your terminal config. Re-import after changing it."
        }
        return "Read the colours from your own terminal config (Ghostty, or any key = value theme file) rather than picking one of Herd's."
    }

    private func importTheme() {
        if let theme = TerminalThemeImport.importFromConfig() {
            adopt(theme)
            return
        }
        // Nothing found where terminals keep it: let them point at the file.
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose a terminal config or theme file"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard let theme = TerminalThemeImport.parse(text, name: url.deletingPathExtension().lastPathComponent) else {
            ToastCenter.shared.fail(nil, "No colours in that file",
                                    detail: "Herd looks for background, foreground and palette entries")
            return
        }
        adopt(theme)
    }

    private func adopt(_ theme: TerminalTheme) {
        settings.values.importedTheme = theme
        settings.values.themeName = theme.name
        ToastCenter.shared.info("Now following \(theme.name)", detail: "Read from your terminal config")
    }

    var body: some View {
        SettingsGroup(title: "Theme") {
            SettingsRow(title: "Follow your terminal's colours", detail: importDetail) {
                Button(settings.values.importedTheme == nil ? "Import" : "Re-import") { importTheme() }
            }
            SettingsDivider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(TerminalTheme.selectable) { theme in
                    ThemeSwatch(theme: theme, selected: settings.values.themeName == theme.name) {
                        settings.values.themeName = theme.name
                    }
                }
            }
            .padding(14)
        }
        SettingsGroup(title: "Text") {
            SettingsRow(title: "Font") {
                Picker("", selection: $settings.values.fontFamily) {
                    Text("Default (JetBrains Mono)").tag("")
                    ForEach(monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Font size") {
                Stepper(value: $settings.values.fontSize, in: 8...32, step: 1) {
                    Text("\(Int(settings.values.fontSize)) pt").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                }
            }
            SettingsDivider()
            SettingsRow(title: "Line height") {
                SliderControl(value: $settings.values.lineHeightPercent, range: 80...160, step: 5) { "\(Int($0))%" }
            }
            SettingsDivider()
            SettingsRow(title: "Thicken text", detail: "Heavier strokes, useful on non-Retina displays.") {
                Toggle("", isOn: $settings.values.fontThicken).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "Cursor") {
            SettingsRow(title: "Shape") {
                Picker("", selection: $settings.values.cursorStyle) {
                    Text("Block").tag(HerdSettings.CursorStyle.block)
                    Text("Bar").tag(HerdSettings.CursorStyle.bar)
                    Text("Underline").tag(HerdSettings.CursorStyle.underline)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Blink") {
                Toggle("", isOn: $settings.values.cursorBlink).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "Window") {
            SettingsRow(title: "Terminal opacity") {
                SliderControl(value: $settings.values.backgroundOpacity, range: 0.3...1, step: 0.05) { "\(Int($0 * 100))%" }
            }
            SettingsDivider()
            SettingsRow(title: "Blur behind terminal", detail: "Applies when opacity is below 100%.") {
                Toggle("", isOn: $settings.values.backgroundBlur).labelsHidden().toggleStyle(.switch)
                    .disabled(settings.values.backgroundOpacity >= 1)
            }
            SettingsDivider()
            SettingsRow(title: "Padding") {
                Picker("", selection: $settings.values.windowPadding) {
                    Text("Compact").tag(HerdSettings.WindowPadding.compact)
                    Text("Normal").tag(HerdSettings.WindowPadding.normal)
                    Text("Roomy").tag(HerdSettings.WindowPadding.roomy)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
        }
        SettingsGroup(title: "Split panes") {
            SettingsRow(title: "Borders") {
                Picker("", selection: $settings.values.paneBorders) {
                    Text("Splits only").tag(HerdSettings.PaneBorders.auto)
                    Text("Always").tag(HerdSettings.PaneBorders.always)
                    Text("Off").tag(HerdSettings.PaneBorders.off)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Gaps between panes") {
                Toggle("", isOn: $settings.values.paneGaps).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Pane scrollbars") {
                Toggle("", isOn: $settings.values.paneScrollbars).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

private struct TerminalSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsGroup(title: "Scrollback & selection") {
            SettingsRow(title: "Scrollback per pane") {
                SliderControl(value: $settings.values.scrollbackMegabytes, range: 1...100, step: 1) { "\(Int($0)) MB" }
            }
            SettingsDivider()
            SettingsRow(
                title: "Terminal text",
                detail: "Where output sits while it doesn't fill the pane. Bottom keeps the prompt where you look; Top is how a terminal normally fills."
            ) {
                Picker("", selection: $settings.values.textPosition) {
                    ForEach(HerdSettings.TextPosition.allCases, id: \.self) { position in
                        Text(position.title).tag(position)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            SettingsDivider()
            SettingsRow(title: "Copy on select", detail: "Copy text as soon as you select it with the mouse.") {
                Toggle("", isOn: $settings.values.copyOnSelect).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Confirm copies",
                detail: "Show a Herd toast with what landed on the clipboard — copying looks the same whether or not it worked."
            ) {
                Toggle("", isOn: $settings.values.clipboardToasts).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Lines per scroll wheel notch") {
                Stepper(value: $settings.values.mouseScrollLines, in: 1...20, step: 1) {
                    Text("\(Int(settings.values.mouseScrollLines))").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        SettingsGroup(title: "Keyboard & mouse") {
            SettingsRow(title: "Use Option as Alt", detail: "Sends Alt/Meta sequences instead of typing special characters.") {
                Picker("", selection: $settings.values.optionAsAlt) {
                    Text("Off").tag(HerdSettings.OptionAsAlt.off)
                    Text("Left").tag(HerdSettings.OptionAsAlt.left)
                    Text("Right").tag(HerdSettings.OptionAsAlt.right)
                    Text("Both").tag(HerdSettings.OptionAsAlt.both)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Hide mouse pointer while typing") {
                Toggle("", isOn: $settings.values.hideMouseWhileTyping).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "Clipboard & graphics") {
            SettingsRow(title: "Warn before pasting risky text", detail: "Multi-line pastes and text that could run commands.") {
                Toggle("", isOn: $settings.values.pasteProtection).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Programs reading the clipboard", detail: "Terminal programs requesting clipboard contents (OSC 52).") {
                Picker("", selection: $settings.values.clipboardRead) {
                    Text("Ask").tag(HerdSettings.ClipboardAccess.ask)
                    Text("Allow").tag(HerdSettings.ClipboardAccess.allow)
                    Text("Deny").tag(HerdSettings.ClipboardAccess.deny)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Inline images", detail: "Kitty graphics protocol in panes.") {
                Toggle("", isOn: $settings.values.kittyGraphics).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

private struct AgentSettings: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var integrations: HerdrIntegrations
    @State private var hookInstalled: Set<String> = []

    @State private var installingSpecs = false
    @State private var specStatus = ""

    /// What the corpus adds, and what is installed now.
    private var specDetail: String {
        if !specStatus.isEmpty { return specStatus }
        guard let index = SpecCorpus.index() else {
            return "Subcommands, options and their descriptions for hundreds of commands, from the MIT-licensed Fig specs. Downloaded on request; Herd's own history and project sources work without it."
        }
        return "\(index.commands.count) commands from \(index.source), version \(index.version)."
    }

    private func installSpecs() {
        installingSpecs = true
        specStatus = "Starting…"
        SpecIngest.run { step in
            specStatus = step
        } completion: { result in
            installingSpecs = false
            switch result {
            case .success(let outcome):
                specStatus = ""
                ToastCenter.shared.info("Installed \(outcome.commands) command specs",
                                        detail: "\(SpecIngest.sourceName), version \(outcome.version)")
            case .failure(let error):
                specStatus = ""
                ToastCenter.shared.fail(nil, "Couldn't install the command specs",
                                        detail: String(describing: error))
            }
        }
    }

    private func refreshHooks() {
        hookInstalled = Set(SubagentHookInstaller.available().filter(SubagentHookInstaller.isInstalled).map(\.hostId))
    }

    var body: some View {
        SettingsGroup(title: "Notifications") {
            SettingsRow(title: "When an agent finishes or needs you") {
                Picker("", selection: $settings.values.notifications) {
                    Text("macOS notification").tag(HerdSettings.NotificationDelivery.system)
                    Text("In Herd").tag(HerdSettings.NotificationDelivery.banner)
                    Text("Off").tag(HerdSettings.NotificationDelivery.off)
                }
                .labelsHidden().frame(width: 190)
            }
            SettingsDivider()
            SettingsRow(title: "Wait before notifying", detail: "Skipped if you return to the agent first.") {
                Stepper(value: $settings.values.notificationDelaySeconds, in: 0...60, step: 1) {
                    Text("\(Int(settings.values.notificationDelaySeconds)) s").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                }
            }
            SettingsDivider()
            SettingsRow(title: "Play sounds", detail: "When agents in other workspaces change state.") {
                Toggle("", isOn: $settings.values.agentSounds).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "Recovery") {
            SettingsRow(
                title: "Resume agents after a restart",
                detail: "When the terminal restarts (e.g. your Mac shut down), agents with an installed integration reopen their conversation."
            ) {
                Toggle("", isOn: $settings.values.resumeAgentsOnRestore).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Offer to recover lost sessions",
                detail: "Herd records every agent's session. After a restart it lists any that didn't come back so you can resume them."
            ) {
                Toggle("", isOn: $settings.values.offerRecovery).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Herd's slash command menu",
                detail: "Typing / in an agent pane opens Herd's own command list instead of the agent's in-terminal one."
            ) {
                Toggle("", isOn: $settings.values.slashMenu).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Herd's command line",
                detail: "At a shell prompt, Herd edits the line itself: highlighted as you type, with a suggestion from your history. Anything it doesn't handle goes straight to the shell."
            ) {
                Toggle("", isOn: $settings.values.promptEditor).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Paste images as files",
                detail: "⌘V with an image on the clipboard writes it out and pastes the path, which is what agents can actually read."
            ) {
                Toggle("", isOn: $settings.values.pasteImagesAsFiles).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Command specs",
                detail: specDetail
            ) {
                Button(SpecCorpus.index() == nil ? "Install" : "Update") { installSpecs() }
                    .disabled(installingSpecs)
            }
            SettingsDivider()
            SettingsRow(
                title: "Run commands from the menu",
                detail: "Picking a command submits it to the agent. Off types it into the prompt instead. Commands that take arguments are always typed."
            ) {
                Toggle("", isOn: $settings.values.slashRunsCommands).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Visual twin",
                detail: "⌘⇧V draws Herd's own interface over an agent's pane, read from the session the agent is already writing. What you type there goes to the real agent, so nothing about it changes."
            ) {
                Toggle("", isOn: $settings.values.visualTwin).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Open the twin for new agents",
                detail: "Start an agent and its pane opens in the twin rather than the terminal. Closing the twin for a pane keeps it closed."
            ) {
                Toggle("", isOn: $settings.values.twinByDefault)
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!settings.values.visualTwin)
            }
            SettingsDivider()
            SettingsRow(
                title: "Name tabs after their work",
                detail: "Tabs follow what their pane reports it is doing, so a tab stops reading as the task you started with. A tab you rename yourself keeps its name."
            ) {
                Toggle("", isOn: $settings.values.autoNameTabs).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Restore recent terminal output",
                detail: "Saves pane contents so they reappear after a restart. Output can include secrets."
            ) {
                Toggle("", isOn: $settings.values.paneHistory).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "Agent integrations") {
            if integrations.statuses.isEmpty {
                SettingsRow(title: integrations.loading ? "Checking…" : "Integrations unavailable") { EmptyView() }
            }
            let ordered = integrations.statuses.sorted { lhs, rhs in
                let l = HerdrIntegrations.primary.firstIndex(of: lhs.agent) ?? 99
                let r = HerdrIntegrations.primary.firstIndex(of: rhs.agent) ?? 99
                return l == r ? lhs.agent < rhs.agent : l < r
            }
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, status in
                if index > 0 { SettingsDivider() }
                IntegrationRow(status: status) { integrations.install(status.agent) }
            }
        }
        SettingsGroup(title: "Subagent tabs") {
            ForEach(Array(SubagentHookInstaller.available().enumerated()), id: \.element.id) { index, spec in
                if index > 0 { SettingsDivider() }
                SettingsRow(
                    title: spec.displayName,
                    detail: "Open a named background tab showing each subagent's live transcript. Hook lives in \(spec.file.replacingOccurrences(of: NSHomeDirectory(), with: "~"))."
                ) {
                    Button(hookInstalled.contains(spec.hostId) ? "Remove Hook" : "Install Hook") {
                        if hookInstalled.contains(spec.hostId) {
                            SubagentHookMenu.uninstall(spec)
                        } else {
                            SubagentHookMenu.install(spec)
                        }
                        refreshHooks()
                    }
                }
            }
        }
        .onAppear {
            integrations.refresh()
            refreshHooks()
        }
    }
}

private struct IntegrationRow: View {
    let status: HerdrIntegrations.Status
    let install: () -> Void

    var body: some View {
        let brand = AgentBrand.forAgent(status.agent)
        SettingsRow(
            title: brand?.displayName ?? status.agent,
            detail: status.installed
                ? "Installed · \(status.detail.replacingOccurrences(of: "installed", with: "").trimmingCharacters(in: .whitespaces))"
                : HerdrIntegrations.primary.contains(status.agent)
                    ? "Not installed · needed to resume sessions after a restart"
                    : "Not installed"
        ) {
            HStack(spacing: 10) {
                if let brand { AgentLogo(brand: brand, size: 14) }
                Button(status.installed ? "Reinstall" : "Install", action: install)
            }
        }
    }
}

private struct MotionSettings: View {
    @ObservedObject var motion: MotionPreferences

    var body: some View {
        SettingsGroup(title: "Animations") {
            SettingsRow(title: "Enable animations", detail: "Turn off to make every change in Herd instant.") {
                Toggle("", isOn: $motion.enabled).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Follow system Reduce Motion",
                detail: motion.systemReduceMotion
                    ? "Reduce Motion is on in System Settings, so animations are off."
                    : "Turns animations off whenever Reduce Motion is on in System Settings › Accessibility."
            ) {
                Toggle("", isOn: $motion.followSystemReduceMotion).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "Animate") {
            ForEach(Array(MotionPreferences.Area.allCases.enumerated()), id: \.element) { index, area in
                if index > 0 { SettingsDivider() }
                SettingsRow(title: area.title, detail: area.detail) {
                    Toggle("", isOn: motion.binding(area)).labelsHidden().toggleStyle(.switch)
                }
                .opacity(motion.enabled ? 1 : 0.45)
                .disabled(!motion.enabled)
            }
        }
    }
}

private struct KeyboardSettings: View {
    private let groups: [(String, [(String, String)])] = [
        ("App", [("Command palette", "⌘P"), ("Settings", "⌘,"), ("Toggle sidebar", "⌘B")]),
        ("Tabs", [("New tab", "⌘T"), ("Close tab", "⌘W"), ("Tab 1–9", "⌘1…⌘9"), ("Next / previous tab", "⌘⇧] / ⌘⇧[")]),
        ("Workspaces", [("New workspace", "⌘N"), ("Open folder as workspace", "⌘O"), ("Next / previous workspace", "⌃⌘↓ / ⌃⌘↑")]),
        ("Panes", [("Split right", "⌘D"), ("Split down", "⌘⇧D"), ("Zoom pane", "⌘⇧↩"), ("Focus pane", "⌘⌥←↑→↓")]),
        ("Terminal", [("Copy / paste", "⌘C / ⌘V"), ("Terminal prefix", "⌃B")]),
    ]

    var body: some View {
        ForEach(groups, id: \.0) { title, shortcuts in
            SettingsGroup(title: title) {
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, shortcut in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: shortcut.0) { Keycap(text: shortcut.1) }
                }
            }
        }
    }
}

private struct AdvancedSettings: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsGroup(title: "Worktrees") {
            SettingsRow(title: "Worktree folder", detail: "Where New Worktree creates <repo>/<branch> checkouts.") {
                TextField("~/.herd/worktrees", text: $settings.values.worktreesDirectory)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
        }
        SettingsGroup(title: "Terminal engine") {
            SettingsRow(title: "Check for engine updates") {
                Toggle("", isOn: $settings.values.checkForHerdrUpdates).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Update channel") {
                Picker("", selection: $settings.values.updateChannel) {
                    Text("Stable").tag(HerdSettings.UpdateChannel.stable)
                    Text("Preview").tag(HerdSettings.UpdateChannel.preview)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            SettingsDivider()
            SettingsRow(title: "Allow a nested session", detail: "Lets you run another terminal session inside a Herd pane.") {
                Toggle("", isOn: $settings.values.allowNestedHerdr).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Session", detail: "Herd runs its own session, separate from terminals you open elsewhere.") {
                Text(HerdrSession.name).font(Theme.monoFont).foregroundStyle(Theme.textSecondary)
            }
            SettingsDivider()
            SettingsRow(title: "Generated config", detail: "Written from these settings on launch and on every change.") {
                HStack(spacing: 8) {
                    Button("Reveal") {
                        if let path = HerdrSession.make()?.configPath {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    Button("Reload") { store.reloadHerdrConfig() }
                }
            }
            SettingsDivider()
            SettingsRow(title: "Plugins", detail: "Manage plugins from the command palette with the ! filter.") {
                Text("\(store.plugins.count) installed").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
            }
        }
        SettingsGroup(title: "Reset") {
            SettingsRow(title: "Restore default settings", detail: "Motion, pins, and the idle threshold are kept.") {
                Button("Reset…") {
                    ConfirmCenter.shared.ask(
                        title: "Restore default settings?",
                        message: "Appearance, terminal, agent, and advanced settings go back to their defaults.",
                        confirmTitle: "Reset",
                        destructive: true
                    ) { _ in
                        settings.resetToDefaults()
                        ToastCenter.shared.info("Settings restored to defaults")
                    }
                }
            }
        }
        .onAppear { store.refreshPlugins() }
    }
}

private struct ThemeSwatch: View {
    let theme: TerminalTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("~ % ls").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(hex: theme.foreground))
                    HStack(spacing: 3) {
                        ForEach(1..<7) { index in
                            RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: theme.ansi[index])).frame(width: 12, height: 6)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: theme.background))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(theme.name).font(Theme.uiFont).foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.cardSelected : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SliderControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step).frame(width: 160)
            Text(label(value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Building blocks

private struct SidebarItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(title).font(Theme.uiFontMedium)
                Spacer()
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius)
                .fill(selected ? Theme.cardSelected : (hovered ? Theme.hover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Theme.headerFont)
                .kerning(0.4)
                .foregroundStyle(Theme.textTertiary)
            VStack(spacing: 0) { content }
                .background(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 14)
    }
}

