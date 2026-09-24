import SwiftUI

/// Octet's Settings window (⌘,), styled like the rest of the app.
struct SettingsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var motion = MotionPreferences.shared
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var integrations = AgentIntegrations.shared
    /// Remembered across openings, and set by Help › Keyboard Shortcuts.
    @AppStorage(SettingsView.sectionKey) private var section: Section = .general
    @State private var query = ""
    /// The row a search result jumped to, flashed so the eye finds it.
    @State private var highlighted: String?
    @FocusState private var focus: Focus?

    static let sectionKey = "octet.settings.section"

    private enum Focus: Hashable { case search, sidebar }

    enum Section: String, CaseIterable, Identifiable {
        case general, appearance, terminal, statusBar, agents, plugins, motion, keyboard, advanced

        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .terminal: return "Terminal"
            case .statusBar: return "Status Bar"
            case .agents: return "Agents & Recovery"
            case .plugins: return "Plugins"
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
            case .statusBar: return "list.bullet.rectangle"
            case .agents: return "sparkle.magnifyingglass"
            case .plugins: return "puzzlepiece.extension"
            case .motion: return "sparkles"
            case .keyboard: return "keyboard"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var results: [SettingsSearchEntry] { SettingsSearchIndex.search(query) }

    /// Nothing reads as selected while search results are showing; picking
    /// a section ends the search.
    private var sidebarSelection: Binding<Section?> {
        Binding(
            get: { searching ? nil : section },
            set: { picked in
                guard let picked else { return }
                section = picked
                query = ""
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.divider).frame(width: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(searching ? "Search Results" : section.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        if searching {
                            SettingsSearchResults(query: query, results: results, open: open)
                        } else {
                            ConfigProblemsBanner(settings: settings)
                            switch section {
                            case .general: GeneralSettings(store: store, settings: settings)
                            case .appearance: AppearanceSettings(settings: settings)
                            case .terminal: TerminalSettings(settings: settings)
                            case .statusBar: StatusBarSettings(settings: settings)
                            case .agents: AgentSettings(settings: settings, integrations: integrations)
                            case .plugins: PluginSettings()
                            case .motion: MotionSettings(motion: motion)
                            case .keyboard: KeyboardSettings()
                            case .advanced: AdvancedSettings(store: store, settings: settings)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 40)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.terminalBackground)
                .environment(\.settingsHighlight, highlighted)
                .onChange(of: highlighted) { _, anchor in
                    guard let anchor else { return }
                    // After the section's rows exist.
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(anchor, anchor: .center) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        if highlighted == anchor { highlighted = nil }
                    }
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity)
        .frame(minHeight: 560, maxHeight: .infinity)
        // Errors and confirmations raised here show here, not behind it.
        .overlay(alignment: .bottomTrailing) { ToastStack(center: ToastCenter.shared) }
        .overlay { ConfirmDialog(center: ConfirmCenter.shared) }
        .onAppear { settings.refreshConfigProblems() }
        .defaultFocus($focus, .sidebar)
        .ignoresSafeArea()
        .background(DarkTransparentTitleBar())
        .id(settings.themeKey)
        .preferredColorScheme(Theme.colorScheme)
        .background(ThemedWindow(themeName: settings.themeKey))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSearchField(query: $query, focus: $focus, focusValue: .search) {
                if let first = results.first { open(first) }
            }
            .padding(.horizontal, 10)
            List(selection: sidebarSelection) {
                ForEach(Section.allCases) { item in
                    let selected = !searching && section == item
                    Label { Text(item.title) } icon: { OctetIcon(item.symbol, size: 16) }
                        .font(Theme.uiFontMedium)
                        .padding(.vertical, 2)
                        .tag(item)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .sidebar)
            .accessibilityLabel("Settings sections")
        }
        .padding(.top, 40)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    /// Jumps from a search result to its row.
    private func open(_ entry: SettingsSearchEntry) {
        section = entry.section
        query = ""
        focus = .sidebar
        highlighted = entry.anchor
    }
}

/// The Settings search box. Return opens the first result; Esc clears.
private struct SettingsSearchField<Value: Hashable>: View {
    @Binding var query: String
    var focus: FocusState<Value?>.Binding
    let focusValue: Value
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            OctetIcon("magnifyingglass", size: 15)
                .foregroundStyle(Theme.textTertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textPrimary)
                .focused(focus, equals: focusValue)
                .onSubmit(submit)
                .onExitCommand { query = "" }
                .accessibilityLabel("Search settings")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    OctetIcon("xmark.circle.fill", size: 15)
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// The row title a search jumped to, if any.
private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

// MARK: - Sections

private struct GeneralSettings: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: SettingsStore

    private let presets: [(String, TimeInterval)] = [
        ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14_400),
        ("8 hours", 28_800), ("1 day", 86_400), ("3 days", 259_200),
    ]

    var body: some View {
        SettingsGroup(title: "Startup & quitting") {
            SettingsRow(
                title: "Show tips",
                detail: "A card at the foot of the sidebar with one thing Octet does that is easy to miss. Click it for another."
            ) {
                Toggle("Show tips", isOn: $settings.values.showTips).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Confirm before quitting", detail: "Quitting Octet leaves terminals and agents running in the background.") {
                Toggle("Confirm before quitting", isOn: $settings.values.confirmQuit).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "New panes & shells") {
            SettingsRow(title: "Start new tabs and workspaces in", detail: "Follow uses the focused pane's folder.") {
                Picker("Start new tabs and workspaces in", selection: $settings.values.newPaneDirectory) {
                    Text("Focused pane's folder").tag(OctetSettings.NewPaneDirectory.follow)
                    Text("Home folder").tag(OctetSettings.NewPaneDirectory.home)
                    Text("The terminal's folder").tag(OctetSettings.NewPaneDirectory.current)
                }
                .labelsHidden().frame(width: 190)
            }
            SettingsDivider()
            SettingsRow(title: "Shell", detail: "Leave empty to use your login shell. Applies to new panes.") {
                CommittedTextField(label: "Shell", placeholder: "Login shell", value: $settings.values.defaultShell, width: 190,
                                   validate: SettingsValidation.shell)
            }
            SettingsDivider()
            SettingsRow(title: "Shell startup mode", detail: "Login shells read your profile files.") {
                Picker("Shell startup mode", selection: $settings.values.shellMode) {
                    Text("Automatic").tag(OctetSettings.ShellMode.auto)
                    Text("Login").tag(OctetSettings.ShellMode.login)
                    Text("Non-login").tag(OctetSettings.ShellMode.nonLogin)
                }
                .labelsHidden().frame(width: 190)
            }
        }
        SettingsGroup(title: "Idle workspaces") {
            SettingsRow(
                title: "Move to Idle after",
                detail: "Unused workspaces drop into the Idle dock at the bottom of the sidebar. Pinned workspaces, the one you're in, and agents that are working or waiting on you never go idle."
            ) {
                Picker("Move to Idle after", selection: $store.idleAfter) {
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

    /// With Match system on, a swatch fills the light or dark slot it fits.
    /// What Octet found to follow, or how to point it at a file.
    private var importDetail: String {
        if let theme = settings.values.importedTheme {
            return "Using \(theme.name), read from your terminal config. Re-import after changing it."
        }
        return "Read the colours from your own terminal config (Ghostty, or any key = value theme file) rather than picking one of Octet's."
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
                                    detail: "Octet looks for background, foreground and palette entries")
            return
        }
        adopt(theme)
    }

    private func adopt(_ theme: TerminalTheme) {
        settings.values.importedTheme = theme
        settings.values.matchSystemAppearance = false
        settings.values.themeName = theme.name
        ToastCenter.shared.info("Now following \(theme.name)", detail: "Read from your terminal config")
    }


    private func isChosen(_ theme: TerminalTheme) -> Bool {
        let values = settings.values
        guard values.matchSystemAppearance else { return values.themeName == theme.name }
        return theme.name == (theme.isLight ? values.lightThemeName : values.darkThemeName)
    }

    private func choose(_ theme: TerminalTheme) {
        guard settings.values.matchSystemAppearance else {
            settings.values.themeName = theme.name
            return
        }
        if theme.isLight { settings.values.lightThemeName = theme.name } else { settings.values.darkThemeName = theme.name }
    }

    private var monospacedFamilies: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }.sorted()
    }

    var body: some View {
        SettingsGroup(title: "Theme") {
            SettingsRow(title: "Follow your terminal's colours", detail: importDetail) {
                Button(settings.values.importedTheme == nil ? "Import" : "Re-import") { importTheme() }
            }
            SettingsDivider()
            SettingsRow(title: "Match system appearance",
                        detail: "Switch between a light and a dark theme when macOS does.") {
                Toggle("Match system appearance", isOn: $settings.values.matchSystemAppearance)
                    .labelsHidden().toggleStyle(.switch)
            }
            if settings.values.matchSystemAppearance {
                SettingsDivider()
                SettingsRow(title: "Light theme") {
                    Picker("Light theme", selection: $settings.values.lightThemeName) {
                        ForEach(TerminalTheme.selectable.filter(\.isLight)) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden().frame(width: 190)
                }
                SettingsDivider()
                SettingsRow(title: "Dark theme") {
                    Picker("Dark theme", selection: $settings.values.darkThemeName) {
                        ForEach(TerminalTheme.selectable.filter { !$0.isLight }) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden().frame(width: 190)
                }
            }
            SettingsDivider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(TerminalTheme.selectable) { theme in
                    ThemeSwatch(theme: theme, selected: isChosen(theme)) { choose(theme) }
                }
            }
            .padding(14)
        }
        SettingsGroup(title: "Text") {
            SettingsRow(title: "Font") {
                Picker("Font", selection: $settings.values.fontFamily) {
                    Text("Default (JetBrains Mono)").tag("")
                    ForEach(monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Font size") {
                Stepper(value: $settings.values.fontSize, in: SettingsStore.fontSizeRange, step: 1) {
                    Text("\(Int(settings.values.fontSize)) pt").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Font size")
                .accessibilityValue("\(Int(settings.values.fontSize)) points")
            }
            SettingsDivider()
            SettingsRow(title: "Line height") {
                SliderControl(title: "Line height", value: $settings.values.lineHeightPercent, range: 80...160, step: 5) { "\(Int($0))%" }
            }
            SettingsDivider()
            SettingsRow(title: "Thicken text", detail: "Heavier strokes, useful on non-Retina displays.") {
                Toggle("Thicken text", isOn: $settings.values.fontThicken).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "Cursor") {
            SettingsRow(title: "Shape") {
                Picker("Cursor shape", selection: $settings.values.cursorStyle) {
                    Text("Block").tag(OctetSettings.CursorStyle.block)
                    Text("Bar").tag(OctetSettings.CursorStyle.bar)
                    Text("Underline").tag(OctetSettings.CursorStyle.underline)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Blink") {
                Toggle("Cursor blink", isOn: $settings.values.cursorBlink).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "Window") {
            SettingsRow(title: "Terminal opacity") {
                SliderControl(title: "Terminal opacity", value: $settings.values.backgroundOpacity, range: 0.3...1, step: 0.05) { "\(Int($0 * 100))%" }
            }
            SettingsDivider()
            SettingsRow(title: "Blur behind terminal", detail: "Applies when opacity is below 100%.") {
                Toggle("Blur behind terminal", isOn: $settings.values.backgroundBlur).labelsHidden().toggleStyle(.switch)
                    .disabled(settings.values.backgroundOpacity >= 1)
            }
            SettingsDivider()
            SettingsRow(title: "Padding") {
                Picker("Window padding", selection: $settings.values.windowPadding) {
                    Text("Compact").tag(OctetSettings.WindowPadding.compact)
                    Text("Normal").tag(OctetSettings.WindowPadding.normal)
                    Text("Roomy").tag(OctetSettings.WindowPadding.roomy)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
        }
        SettingsGroup(title: "Split panes") {
            SettingsRow(title: "Borders") {
                Picker("Split pane borders", selection: $settings.values.paneBorders) {
                    Text("Splits only").tag(OctetSettings.PaneBorders.auto)
                    Text("Always").tag(OctetSettings.PaneBorders.always)
                    Text("Off").tag(OctetSettings.PaneBorders.off)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Gaps between panes") {
                Toggle("Gaps between panes", isOn: $settings.values.paneGaps).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Pane scrollbars") {
                Toggle("Pane scrollbars", isOn: $settings.values.paneScrollbars).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

private struct TerminalSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsGroup(title: "Scrollback & selection") {
            SettingsRow(title: "Scrollback per pane") {
                SliderControl(title: "Scrollback per pane", value: $settings.values.scrollbackMegabytes, range: 1...100, step: 1) { "\(Int($0)) MB" }
            }
            SettingsDivider()
            SettingsRow(
                title: "Terminal text",
                detail: "Where output sits while it doesn't fill the pane. Bottom keeps the prompt where you look; Top is how a terminal normally fills."
            ) {
                Picker("Terminal text position", selection: $settings.values.textPosition) {
                    ForEach(OctetSettings.TextPosition.allCases, id: \.self) { position in
                        Text(position.title).tag(position)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            SettingsDivider()
            SettingsRow(
                title: "Start new tabs with shortcuts",
                detail: "A new tab's empty rows offer your agents, recent folders and common shortcuts, until something runs in it."
            ) {
                Toggle("Start new tabs with shortcuts", isOn: $settings.values.newTabSplash)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Copy on select", detail: "Copy text as soon as you select it with the mouse.") {
                Toggle("Copy on select", isOn: $settings.values.copyOnSelect).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Confirm copies",
                detail: "Show an Octet toast with what landed on the clipboard. Copying looks the same whether or not it worked."
            ) {
                Toggle("Confirm copies", isOn: $settings.values.clipboardToasts).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Lines per scroll wheel notch") {
                Stepper(value: $settings.values.mouseScrollLines, in: 1...20, step: 1) {
                    Text("\(Int(settings.values.mouseScrollLines))").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Lines per scroll wheel notch")
                .accessibilityValue("\(Int(settings.values.mouseScrollLines))")
            }
        }
        SettingsGroup(title: "Keyboard & mouse") {
            SettingsRow(title: "Use Option as Alt", detail: "Sends Alt/Meta sequences instead of typing special characters.") {
                Picker("Use Option as Alt", selection: $settings.values.optionAsAlt) {
                    Text("Off").tag(OctetSettings.OptionAsAlt.off)
                    Text("Left").tag(OctetSettings.OptionAsAlt.left)
                    Text("Right").tag(OctetSettings.OptionAsAlt.right)
                    Text("Both").tag(OctetSettings.OptionAsAlt.both)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Hide mouse pointer while typing") {
                Toggle("Hide mouse pointer while typing", isOn: $settings.values.hideMouseWhileTyping).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "Clipboard & graphics") {
            SettingsRow(title: "Warn before pasting risky text", detail: "Multi-line pastes and text that could run commands.") {
                Toggle("Warn before pasting risky text", isOn: $settings.values.pasteProtection).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Programs reading the clipboard", detail: "Terminal programs requesting clipboard contents (OSC 52).") {
                Picker("Programs reading the clipboard", selection: $settings.values.clipboardRead) {
                    Text("Ask").tag(OctetSettings.ClipboardAccess.ask)
                    Text("Allow").tag(OctetSettings.ClipboardAccess.allow)
                    Text("Deny").tag(OctetSettings.ClipboardAccess.deny)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Inline images", detail: "Kitty graphics protocol in panes.") {
                Toggle("Inline images", isOn: $settings.values.kittyGraphics).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

private struct AgentSettings: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var integrations: AgentIntegrations
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    @State private var hookInstalled: Set<String> = []

    /// How many agents the last scan found, and when it ran.
    private var discoveryDetail: String {
        guard let scannedAt = discovery.scannedAt else { return "Not scanned yet." }
        let count = discovery.agents.count
        return "\(count) found, \(UsageMeter.relative(scannedAt))."
    }

    @State private var installingSpecs = false
    @State private var specStatus = ""

    /// What the corpus adds, and what is installed now.
    private var specDetail: String {
        if !specStatus.isEmpty { return specStatus }
        guard let index = SpecCorpus.index() else {
            return "Subcommands, options and their descriptions for hundreds of commands, from the MIT-licensed Fig specs. Downloaded on request; Octet's own history and project sources work without it."
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
            SettingsRow(
                title: "Quick answers",
                detail: "Open a small panel in the window corner when an agent needs a choice, answer, or permission."
            ) {
                Toggle("Quick answers", isOn: $settings.values.agentQuickAnswers).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "When an agent finishes or needs you") {
                Picker("When an agent finishes or needs you", selection: $settings.values.notifications) {
                    Text("macOS notification").tag(OctetSettings.NotificationDelivery.system)
                    Text("In Octet").tag(OctetSettings.NotificationDelivery.banner)
                    Text("Off").tag(OctetSettings.NotificationDelivery.off)
                }
                .labelsHidden().frame(width: 190)
            }
            SettingsDivider()
            SettingsRow(title: "Wait before notifying", detail: "Skipped if you return to the agent first.") {
                Stepper(value: $settings.values.notificationDelaySeconds, in: 0...60, step: 1) {
                    Text("\(Int(settings.values.notificationDelaySeconds)) s").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Wait before notifying")
                .accessibilityValue("\(Int(settings.values.notificationDelaySeconds)) seconds")
            }
            SettingsDivider()
            SettingsRow(title: "Play sounds", detail: "When agents in other workspaces change state.") {
                Toggle("Play sounds", isOn: $settings.values.agentSounds).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Subagent finished sound", detail: "Played by a subagent's tab when it finishes, so it sounds different from a main agent. Follows Play sounds.") {
                Picker("Subagent finished sound", selection: $settings.values.subagentFinishedSound) {
                    Text("None").tag("")
                    ForEach(SubagentWatch.sounds, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                .disabled(!settings.values.agentSounds)
                .onChange(of: settings.values.subagentFinishedSound) { _, name in
                    if !name.isEmpty { NSSound(named: NSSound.Name(name))?.play() }
                }
            }
        }
        SettingsGroup(title: "Recovery") {
            SettingsRow(
                title: "Resume agents after a restart",
                detail: "When the terminal restarts (e.g. your Mac shut down), agents with an installed integration reopen their conversation."
            ) {
                Toggle("Resume agents after a restart", isOn: $settings.values.resumeAgentsOnRestore).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Offer to recover lost sessions",
                detail: "Octet records every agent's session. After a restart it lists any that didn't come back so you can resume them."
            ) {
                Toggle("Offer to recover lost sessions", isOn: $settings.values.offerRecovery).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "When you run an agent in a terminal",
                detail: "Typing claude, codex or opencode on its own at a prompt opens the agent's own interface in the terminal, or Octet's conversation view. With a flag or a prompt it always runs in the terminal as typed. Octet's view needs Octet's command line, below."
            ) {
                Picker("When you run an agent in a terminal", selection: $settings.values.agentOpening) {
                    ForEach(OctetSettings.AgentOpening.allCases, id: \.self) { opening in
                        Text(opening.title).tag(opening)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            SettingsDivider()
            SettingsRow(
                title: "Offer Octet's view over a running agent",
                detail: "A banner above the terminal, while an agent runs in its own interface, offers to continue its session in Octet's conversation view."
            ) {
                Toggle("Offer Octet's view over a running agent", isOn: $settings.values.agentBanner).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Octet's command line",
                detail: "At a shell prompt, Octet edits the line itself: highlighted as you type, with a suggestion from your history. Anything it doesn't handle goes straight to the shell."
            ) {
                Toggle("Octet's command line", isOn: $settings.values.promptEditor).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Octet's Tab completions",
                detail: "Turn off to send Tab to your shell while keeping Octet's command-line editing and history suggestions. The shell takes over the current line after Tab."
            ) {
                Toggle("Octet's Tab completions", isOn: $settings.values.promptCompletions)
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!settings.values.promptEditor)
            }
            SettingsDivider()
            SettingsRow(
                title: "Paste images as files",
                detail: "⌘V with an image on the clipboard writes it out and pastes the path, which is what agents can actually read."
            ) {
                Toggle("Paste images as files", isOn: $settings.values.pasteImagesAsFiles).labelsHidden().toggleStyle(.switch)
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
                title: "Visual twin",
                detail: "⌘⇧V draws Octet's own interface over an agent's pane, read from the session the agent is already writing. What you type there goes to the real agent, so nothing about it changes."
            ) {
                Toggle("Visual twin", isOn: $settings.values.visualTwin).labelsHidden().toggleStyle(.switch)
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
                Toggle("Name tabs after their work", isOn: $settings.values.autoNameTabs).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Restore recent terminal output",
                detail: "Saves pane contents so they reappear after a restart. Output can include secrets."
            ) {
                Toggle("Restore recent terminal output", isOn: $settings.values.paneHistory).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "Usage") {
            SettingsRow(
                title: "Read live usage from your Claude account",
                detail: "Uses the sign-in Claude Code keeps in your keychain (macOS asks first) to fetch your allowance, the same way Claude Code's usage display does. The endpoint isn't documented by Anthropic and may change; this turns itself off if it stops working. Off, the chip shows Claude Code's cached usage and live numbers from conversations in Octet."
            ) {
                Toggle("Read live usage from your Claude account", isOn: $settings.values.readClaudeAccountUsage)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: settings.values.readClaudeAccountUsage) { _, on in
                        if on { AccountStore.shared.accountUsageSettingChanged() }
                    }
            }
        }
        SettingsGroup(title: "Installed agents") {
            SettingsRow(
                title: "Prompt for agent updates",
                detail: "Once a day, check installed agent tools for newer releases. Octet asks before you run any update command."
            ) {
                Toggle("Prompt for agent updates", isOn: $settings.values.checkForAgentUpdates)
                    .labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Agents on this machine",
                detail: discovery.scanning
                    ? "Looking through your shell's PATH and the folders installers use…"
                    : "Found by looking for each CLI on your shell's PATH, not by what Octet drives. \(discoveryDetail)"
            ) {
                OctetButton(title: discovery.scanning ? "Scanning…" : "Scan Again", kind: .secondary, compact: true) {
                    discovery.scan()
                }
                .disabled(discovery.scanning)
            }
            ForEach(discovery.agents) { agent in
                SettingsDivider()
                DiscoveredAgentRow(agent: agent)
            }
        }
        SettingsGroup(title: "Agent integrations") {
            if integrations.statuses.isEmpty {
                SettingsRow(title: integrations.loading ? "Checking…" : "Integrations unavailable") { EmptyView() }
            }
            let ordered = integrations.statuses.sorted { lhs, rhs in
                let l = AgentIntegrations.primary.firstIndex(of: lhs.agent) ?? 99
                let r = AgentIntegrations.primary.firstIndex(of: rhs.agent) ?? 99
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
            SettingsDivider()
            SettingsRow(
                title: "When a subagent finishes",
                detail: "Keep its tab open until you close it, or close it two minutes after the subagent finishes. A tab you're looking at stays open, and a subagent that's sent more work starts the wait again."
            ) {
                Picker("When a subagent finishes", selection: $settings.values.subagentTabClosing) {
                    ForEach(OctetSettings.SubagentTabClosing.allCases, id: \.self) { closing in
                        Text(closing.title).tag(closing)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)
            }
        }
        .onAppear {
            integrations.refresh()
            refreshHooks()
        }
    }
}

/// One agent a scan found: its mark, what it calls itself, and where it is.
/// An agent with config but no executable is still listed, since its folder
/// is what Octet installs skills and prompts into.
private struct DiscoveredAgentRow: View {
    let agent: DiscoveredAgent

    var body: some View {
        let brand = AgentBrand.forAgent(agent.id)
        SettingsRow(title: agent.displayName, detail: detail) {
            HStack(spacing: 10) {
                if let version = agent.version {
                    Text(version)
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                if let brand { AgentLogo(brand: brand, size: 14) }
            }
        }
    }

    private var detail: String {
        guard let path = agent.executablePath else {
            return "Config in \(abbreviateHome(agent.configPath ?? "")), but no \(agent.command) on your PATH."
        }
        let configured = agent.isConfigured ? "" : " · not set up yet"
        return abbreviateHome(path) + configured
    }
}

private struct IntegrationRow: View {
    let status: AgentIntegrations.Status
    let install: () -> Void

    var body: some View {
        let brand = AgentBrand.forAgent(status.agent)
        SettingsRow(
            title: brand?.displayName ?? status.agent,
            detail: status.installed
                ? "Installed · \(status.detail.replacingOccurrences(of: "installed", with: "").trimmingCharacters(in: .whitespaces))"
                : AgentIntegrations.primary.contains(status.agent)
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
            SettingsRow(title: "Enable animations", detail: "Turn off to make every change in Octet instant.") {
                Toggle("Enable animations", isOn: $motion.enabled).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(
                title: "Follow system Reduce Motion",
                detail: motion.systemReduceMotion
                    ? "Reduce Motion is on in System Settings, so animations are off."
                    : "Turns animations off whenever Reduce Motion is on in System Settings › Accessibility."
            ) {
                Toggle("Follow system Reduce Motion", isOn: $motion.followSystemReduceMotion).labelsHidden().toggleStyle(.switch)
            }
        }
        SettingsGroup(title: "Animate") {
            ForEach(Array(MotionPreferences.Area.allCases.enumerated()), id: \.element) { index, area in
                if index > 0 { SettingsDivider() }
                SettingsRow(title: area.title, detail: area.detail) {
                    Toggle(area.title, isOn: motion.binding(area)).labelsHidden().toggleStyle(.switch)
                }
                .opacity(motion.enabled ? 1 : 0.45)
                .disabled(!motion.enabled)
            }
        }
    }
}

/// Lists `OctetShortcut.groups`, the values the menus bind, so this page
/// always matches the menu bar.
private struct KeyboardSettings: View {
    var body: some View {
        ForEach(OctetShortcut.groups, id: \.title) { group in
            SettingsGroup(title: group.title) {
                ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: shortcut.title) { Keycap(text: shortcut.display) }
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct AdvancedSettings: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsGroup(title: "Worktrees") {
            SettingsRow(title: "Worktree folder", detail: "Where New Worktree creates <repo>/<branch> checkouts.") {
                CommittedTextField(label: "Worktree folder", placeholder: "~/.octet/worktrees", value: $settings.values.worktreesDirectory, width: 220,
                                   validate: SettingsValidation.folder)
            }
        }
        SettingsGroup(title: "Terminal engine") {
            SettingsRow(title: "Check for engine updates") {
                Toggle("Check for engine updates", isOn: $settings.values.checkForEngineUpdates).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Update channel") {
                Picker("Update channel", selection: $settings.values.updateChannel) {
                    Text("Stable").tag(OctetSettings.UpdateChannel.stable)
                    Text("Preview").tag(OctetSettings.UpdateChannel.preview)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            SettingsDivider()
            SettingsRow(title: "Allow a nested session", detail: "Lets you run another terminal session inside an Octet pane.") {
                Toggle("Allow a nested session", isOn: $settings.values.allowNestedSessions).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "Session", detail: "Octet runs its own session, separate from terminals you open elsewhere.") {
                Text(EngineSession.name).font(Theme.monoFont).foregroundStyle(Theme.textSecondary)
            }
            SettingsDivider()
            SettingsRow(title: "Generated config", detail: "Written from these settings on launch and on every change.") {
                HStack(spacing: 8) {
                    Button("Reveal") {
                        if let path = EngineSession.make()?.configPath {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    .accessibilityLabel("Reveal generated config in Finder")
                    Button("Reload") { store.reloadSessionConfig() }
                        .accessibilityLabel("Reload generated config")
                }
            }
            SettingsDivider()
            SettingsRow(title: "Terminal engine plugins", detail: "Plugins for the terminal engine, not Octet's own (those are under Plugins). Manage them from the command palette with the ! filter.") {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityValue(theme.isLight ? "Light theme" : "Dark theme")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct SliderControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .frame(width: 160)
                .accessibilityLabel(title)
                .accessibilityValue(label(value))
            Text(label(value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Building blocks

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
        // Search jumps scroll to a group by its title.
        .id(title)
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control
    @Environment(\.settingsHighlight) private var highlighted

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
        .background(Theme.accent.opacity(highlighted == title ? 0.16 : 0))
        .animation(.easeOut(duration: 0.4), value: highlighted == title)
        // Search jumps scroll to a row by its title.
        .id(title)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 14)
    }
}


/// A text setting that applies only on Return or when focus leaves, and
/// only when valid, so a half-typed `/bin/zs` never becomes the live shell.
struct CommittedTextField: View {
    /// What VoiceOver calls the field; the row title beside it.
    var label: String?
    let placeholder: String
    @Binding var value: String
    let width: CGFloat
    /// nil when valid, else what's wrong.
    let validate: (String) -> String?

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var problem: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : validate(trimmed)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(problem == nil ? Color.clear : Theme.danger, lineWidth: 1))
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onAppear { draft = value }
                .onChange(of: value) { _, new in if !focused { draft = new } }
                .accessibilityLabel(label ?? placeholder)
                .accessibilityValue(problem.map { "\(draft), \($0)" } ?? draft)
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || validate(trimmed) == nil else { return }
        if trimmed != value { value = trimmed }
    }
}

enum SettingsValidation {
    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    static func shell(_ path: String) -> String? {
        let full = expand(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return "No file at that path"
        }
        return FileManager.default.isExecutableFile(atPath: full) ? nil : "Not an executable"
    }

    static func folder(_ path: String) -> String? {
        let full = expand(path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? nil : "That's a file, not a folder"
        }
        // Octet creates it on first use, as long as its parent exists.
        let parent = (full as NSString).deletingLastPathComponent
        return FileManager.default.fileExists(atPath: parent) ? nil : "Parent folder doesn't exist"
    }
}

/// Shows why a setting didn't take: terminal config lines the renderer rejected,
/// or a terminal config file Octet couldn't write.
private struct ConfigProblemsBanner: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        let problems = settings.configProblems
        if !problems.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                OctetIcon("exclamationmark.triangle.fill", size: 16)
                    .foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 4) {
                    Text(problems.count == 1 ? "A setting didn't apply" : "\(problems.count) settings didn't apply")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(problems, id: \.self) { problem in
                        Text(problem)
                            .font(Theme.monoFont)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.danger.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.danger.opacity(0.5), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .combine)
        }
    }
}
