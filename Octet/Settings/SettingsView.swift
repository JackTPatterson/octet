import SwiftUI

/// Octet's Settings (⌘,), after T3 Code's: a section list with search on the
/// left, and the section as a readable column of titled cards under a 52pt
/// breadcrumb header. A page in the window, as T3 Code's settings are, with
/// `onClose`; on its own, the Settings window it falls back to with no main
/// window open.
struct SettingsView: View {
    @ObservedObject var store: SessionStore
    /// Set when it's a page in the window: its close button and Esc.
    var onClose: (() -> Void)?
    private var embedded: Bool { onClose != nil }
    @ObservedObject var motion = MotionPreferences.shared
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var integrations = AgentIntegrations.shared
    /// Remembered across openings, and set by Help › Keyboard Shortcuts.
    @AppStorage(SettingsView.sectionKey) private var section: Section = .general
    @State private var query = ""
    /// The search result Return opens; arrows move it, the pointer too.
    @State private var activeResult = 0
    /// The row a search result jumped to, pulsed so the eye finds it.
    @State private var highlighted: SettingsHighlight?
    @FocusState private var focus: Focus?

    static let sectionKey = "octet.settings.section"
    /// Asks every open Settings to focus its search: ⌘F while it's showing.
    static let focusSearch = Notification.Name("octet.settings.focusSearch")
    /// Settings showing anywhere: its own window counts, which the window
    /// registry doesn't know about.
    @MainActor private static var openCount = 0

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

    /// ⌘F (Edit › Find…) searches Settings while Settings is in front,
    /// rather than the terminal behind it. True when it was taken.
    @MainActor static func claimFind() -> Bool {
        let inWindow = WindowRegistry.shared.key?.ui.settingsVisible == true
        let ownWindow = openCount > 0
            && NSApp.keyWindow?.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
        guard inWindow || ownWindow else { return false }
        NotificationCenter.default.post(name: focusSearch, object: nil)
        return true
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.divider).frame(width: 1)
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        // T3 Code's readable page: 896pt at most, centred,
                        // 24pt in from the sides, 32pt between sections.
                        VStack(alignment: .leading, spacing: 32) {
                            ConfigProblemsBanner(settings: settings)
                            switch section {
                            case .general: GeneralSettings(store: store, settings: settings)
                            case .appearance: AppearanceSettings(settings: settings)
                            case .terminal: TerminalSettings(settings: settings)
                            case .statusBar: StatusBarSettings(settings: settings)
                            case .agents: AgentSettings(settings: settings, integrations: integrations)
                            case .plugins: PluginSettings()
                            case .motion: MotionSettings(motion: motion)
                            case .keyboard: KeyboardSettings(settings: settings)
                            case .advanced: AdvancedSettings(store: store, settings: settings)
                            }
                        }
                        .frame(maxWidth: 896, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 48)
                        .frame(maxWidth: .infinity)
                    }
                    .octetScrollIndicators()
                    .environment(\.settingsHighlight, highlighted)
                    .onChange(of: highlighted) { _, target in
                        guard let target else { return }
                        // After the section's rows exist.
                        DispatchQueue.main.async {
                            MotionPreferences.shared.perform(.palette, .easeInOut(duration: 0.25)) {
                                proxy.scrollTo(target.anchor, anchor: .center)
                            }
                        }
                    }
                }
            }
            .background(Theme.terminalBackground)
        }
        .modifier(SettingsChrome(embedded: embedded, themeKey: settings.themeKey))
        .onAppear {
            Self.openCount += 1
            settings.refreshConfigProblems()
        }
        .onDisappear { Self.openCount -= 1 }
        .defaultFocus($focus, .sidebar)
        // T3 Code's `/`: straight to search from anywhere in Settings. A
        // text field that has focus types the slash instead, since it gets
        // the key first.
        .onKeyPress(KeyEquivalent("/")) {
            guard focus != .search else { return .ignored }
            focus = .search
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.focusSearch)) { _ in focus = .search }
        .onExitCommand { if query.isEmpty { onClose?() } else { clearSearch() } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSearchField(
                query: $query, focus: $focus, focusValue: .search,
                submit: { if results.indices.contains(activeResult) { open(results[activeResult]) } },
                move: { delta in
                    guard !results.isEmpty else { return }
                    activeResult = (activeResult + delta + results.count) % results.count
                },
                clear: clearSearch
            )
            .padding(.horizontal, 8)
            .onChange(of: query) { _, _ in activeResult = 0 }
            if searching {
                searchResults
            } else {
                sectionList
            }
        }
        .padding(.top, embedded ? 12 : 44)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    private var sectionList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Section.allCases) { item in
                    SettingsNavRow(title: item.title, icon: item.symbol, selected: section == item) {
                        section = item
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.never)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .sidebar)
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    /// T3 Code's results take the section list's place: two lines each, the
    /// setting and the section it's in.
    @ViewBuilder private var searchResults: some View {
        if results.isEmpty {
            Text("No settings found")
                .font(Theme.interfaceFont(12))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            SettingsSearchResultRow(entry: entry, active: index == activeResult,
                                                    hover: { activeResult = index }) { open(entry) }
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: activeResult) { _, index in
                    if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Settings search results")
        }
    }

    // MARK: Header

    /// "Settings / General", after T3 Code's page header, with General's
    /// Restore Defaults at the far end.
    private var header: some View {
        let changed = SettingsDefaults.changed(in: settings.values)
        return HStack(spacing: 8) {
            Text("Settings").foregroundStyle(Theme.textTertiary)
            Text("/").foregroundStyle(Theme.textMuted)
            Text(section.title)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if section == .general {
                OctetButton(title: "Restore Defaults", icon: "rotate.ccw", kind: .ghost, compact: true) {
                    restoreDefaults(changed)
                }
                .disabled(changed.isEmpty)
                .help(changed.isEmpty ? "Every setting is at its default" : "Put every changed setting back")
            }
            if let onClose {
                OctetIconButton(icon: "xmark", help: "Close Settings (Esc)", action: onClose)
            }
        }
        .font(Theme.interfaceFont(13, weight: .medium))
        .padding(.horizontal, 24)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
    }

    private func restoreDefaults(_ changed: [String]) {
        guard !changed.isEmpty else { return }
        ConfirmCenter.shared.ask(
            title: "Restore default settings?",
            message: "This will reset: \(changed.joined(separator: ", ")).",
            confirmTitle: "Restore Defaults",
            destructive: true
        ) { _ in
            settings.values = SettingsDefaults.restored(settings.values)
            ToastCenter.shared.info("Settings restored to defaults")
        }
    }

    /// Arrow keys in the section list.
    private func step(_ delta: Int) {
        let all = Section.allCases
        guard let index = all.firstIndex(of: section) else { return }
        section = all[(index + delta + all.count) % all.count]
    }

    private func clearSearch() {
        query = ""
        activeResult = 0
    }

    /// Jumps from a search result to its row.
    private func open(_ entry: SettingsSearchEntry) {
        section = entry.section
        clearSearch()
        focus = .sidebar
        highlighted = SettingsHighlight(anchor: entry.anchor)
    }
}

/// The Settings search row, after T3 Code's: no box, a search icon, and the
/// `/` that focuses it, which turns into a clear button once there's a
/// query. Return opens the active result, ↑/↓ move it, Esc clears. The
/// Marketplace's search is the same row.
struct SettingsSearchField<Value: Hashable>: View {
    @Binding var query: String
    /// What VoiceOver calls it.
    var label = "Search settings"
    var focus: FocusState<Value?>.Binding
    let focusValue: Value
    let submit: () -> Void
    let move: (Int) -> Void
    let clear: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            OctetIcon("magnifyingglass", size: 16)
                .foregroundStyle(Theme.textTertiary)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search")
                        .font(Theme.interfaceFont(14, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                .font(Theme.interfaceFont(14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .focused(focus, equals: focusValue)
                .onSubmit(submit)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onExitCommand(perform: clear)
                .accessibilityLabel(label)
            }
            if query.isEmpty {
                Keycap(text: "/")
                    .accessibilityHidden(true)
            } else {
                Button {
                    clear()
                    focus.wrappedValue = focusValue
                } label: {
                    OctetIcon("xmark", size: 12)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(OctetPressStyle())
                .help("Clear Search")
                .accessibilityLabel("Clear " + label.lowercased())
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .fill(hovered ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = focusValue }
        .onHover { hovered = $0 }
    }
}

/// Where a search result landed, so its row can pulse. A fresh id each
/// jump, so the same row pulses again when it's picked twice.
struct SettingsHighlight: Equatable {
    let anchor: String
    let id = UUID()
}

private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: SettingsHighlight? = nil
}

extension EnvironmentValues {
    var settingsHighlight: SettingsHighlight? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

/// T3 Code's landing mark for a search jump: a 2pt accent ring inset in the
/// row that pulses twice, 650ms each. With Reduce Motion (or Octet's motion
/// off) it shows still for a moment instead.
private struct SettingsPulse: ViewModifier {
    let anchor: String
    var cornerRadius: CGFloat = 12
    @Environment(\.settingsHighlight) private var highlight
    @State private var ring = 0.0

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 2)
                    .opacity(ring)
                    .allowsHitTesting(false)
            }
            .task(id: highlight) {
                ring = 0
                guard let highlight, highlight.anchor == anchor else { return }
                // Let the scroll to the row land first.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if !MotionPreferences.shared.animates(.palette) {
                    ring = 1
                    try? await Task.sleep(for: .seconds(1.3))
                    ring = 0
                    return
                }
                for _ in 0..<2 {
                    withAnimation(.easeInOut(duration: 0.325)) { ring = 1 }
                    try? await Task.sleep(for: .milliseconds(325))
                    withAnimation(.easeInOut(duration: 0.325)) { ring = 0 }
                    try? await Task.sleep(for: .milliseconds(325))
                    guard !Task.isCancelled else { ring = 0; return }
                }
            }
    }
}

extension View {
    /// Pulses when a Settings search lands on `anchor`.
    func settingsPulse(_ anchor: String, cornerRadius: CGFloat = 12) -> some View {
        modifier(SettingsPulse(anchor: anchor, cornerRadius: cornerRadius))
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
                detail: "A card at the foot of the sidebar with one thing Octet does that is easy to miss. Click it for another.",
                setting: \.showTips
            ) {
                Toggle("Show tips", isOn: $settings.values.showTips).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Confirm before quitting", detail: "Quitting Octet leaves terminals and agents running in the background.", setting: \.confirmQuit) {
                Toggle("Confirm before quitting", isOn: $settings.values.confirmQuit).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Hotkey from any app",
                detail: "Brings Octet to the front from whatever you're in, and hides it again when it's already there.",
                setting: \.globalHotkey
            ) {
                OctetSelect(selection: $settings.values.globalHotkey, options: GlobalHotkey.Choice.allCases.map { ($0, $0.title) }, width: 190)
            }
            SettingsDivider()
            SettingsRow(
                title: "Drop down from the top",
                detail: "The hotkey slides a window down over the top of the screen, even over a full-screen app, and slides it away again.",
                setting: \.hotkeyDropDown,
                disabled: settings.values.globalHotkey == .off
            ) {
                Toggle("Drop down from the top", isOn: $settings.values.hotkeyDropDown)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "New panes & shells") {
            SettingsRow(title: "Start new tabs and workspaces in", detail: "Follow uses the focused pane's folder.", setting: \.newPaneDirectory) {
                OctetSelect(selection: $settings.values.newPaneDirectory, options: [(OctetSettings.NewPaneDirectory.follow, "Focused pane's folder"), (OctetSettings.NewPaneDirectory.home, "Home folder"), (OctetSettings.NewPaneDirectory.current, "The terminal's folder")], width: 190)
            }
            SettingsDivider()
            SettingsRow(title: "Shell", detail: "Leave empty to use your login shell. Applies to new panes.", setting: \.defaultShell) {
                CommittedTextField(label: "Shell", placeholder: "Login shell", value: $settings.values.defaultShell, width: 190,
                                   validate: SettingsValidation.shell)
            }
            SettingsDivider()
            SettingsRow(title: "Shell startup mode", detail: "Login shells read your profile files.", setting: \.shellMode) {
                OctetSelect(selection: $settings.values.shellMode, options: [(OctetSettings.ShellMode.auto, "Automatic"), (OctetSettings.ShellMode.login, "Login"), (OctetSettings.ShellMode.nonLogin, "Non-login")], width: 190)
            }
        }
        SettingsGroup(title: "Idle workspaces") {
            SettingsRow(
                title: "Move to Idle after",
                detail: "Unused workspaces move to the Idle shelf at the bottom of the sidebar. Pinned workspaces, the one you're in, and agents that are working or waiting on you never go idle. To set one aside until a time, snooze it: it waits under Snoozed and comes back by itself.",
                isDefault: store.idleAfter == WorkspaceActivity.defaultIdleAfter,
                reset: { store.idleAfter = WorkspaceActivity.defaultIdleAfter }
            ) {
                OctetSelect(selection: $store.idleAfter,
                            options: presets.map { ($0.1, $0.0) }
                                + (presets.contains(where: { $0.1 == store.idleAfter })
                                    ? [] : [(store.idleAfter, IdleDock.thresholdLabel(store.idleAfter))]),
                            width: 190)
            }
            SettingsDivider()
            SettingsRow(
                title: "Sleep idle workspaces after",
                detail: "A sleeping workspace's terminals are closed, so it uses nothing, and it comes back as it was when you wake it from Idle: its tabs, its folders, and its agents' conversations resumed. Only workspaces where nothing would be lost sleep by themselves: no agent working or asking, nothing running in a terminal, no server listening, not pinned. Files are never touched.",
                setting: \.sleepIdleAfterDays
            ) {
                OctetSelect(selection: $settings.values.sleepIdleAfterDays, options: [(0, "Never"), (3, "3 days"), (7, "1 week"), (14, "2 weeks"), (30, "1 month")], width: 190)
            }
            SettingsDivider()
            SettingsRow(title: "Pinned workspaces", detail: "Pin from a workspace's context menu or the command palette.") {
                HStack(spacing: 8) {
                    Text("\(store.pinnedWorkspaceIds.count)").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                    OctetButton(title: "Unpin All", compact: true) {
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
    /// Fonts added this time Settings was open, and a count that makes the
    /// pickers read the installed fonts again.
    @State private var addedFamilies: [String] = []
    @State private var fontsRevision = 0

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

    /// Fixed-width fonts, plus any added here and the one chosen, so a font
    /// macOS doesn't mark fixed-width can still be used.
    private var terminalFamilies: [String] {
        _ = fontsRevision
        let extra = addedFamilies + [settings.values.fontFamily].filter { !$0.isEmpty }
        return Array(Set(CustomFonts.monospacedFamilies + extra)).sorted()
    }

    private var interfaceFamilies: [String] {
        _ = fontsRevision
        let extra = [settings.values.interfaceFontFamily].filter { !$0.isEmpty }
        return Array(Set(CustomFonts.allFamilies + extra)).sorted()
    }

    private func addFonts() {
        CustomFonts.add { families in
            guard !families.isEmpty else { return }
            addedFamilies = Array(Set(addedFamilies + families)).sorted()
            fontsRevision += 1
            ToastCenter.shared.info("Added \(ListFormatter.localizedString(byJoining: families))",
                                    detail: "Pick it for the terminal or the interface below.")
        }
    }

    var body: some View {
        let scheme = OctetColorScheme.current(settings.values)
        SettingsGroup(title: "Theme") {
            // T3 Code's mode tiles: the row's text, then the three tiles
            // across the card under it.
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(
                    title: "Color scheme",
                    detail: "System switches between your light and dark themes when macOS does.",
                    isDefault: scheme == .default,
                    reset: { settings.values = OctetColorScheme.default.applied(to: settings.values) }
                ) { EmptyView() }
                ColorSchemeTiles(settings: settings)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            if settings.values.matchSystemAppearance {
                SettingsDivider()
                SettingsRow(title: "Light theme", setting: \.lightThemeName) {
                    OctetSelect(selection: $settings.values.lightThemeName,
                                options: TerminalTheme.selectable.filter(\.isLight).map { ($0.name, $0.name) }, width: 190)
                }
                SettingsDivider()
                SettingsRow(title: "Dark theme", setting: \.darkThemeName) {
                    OctetSelect(selection: $settings.values.darkThemeName,
                                options: TerminalTheme.selectable.filter { !$0.isLight }.map { ($0.name, $0.name) }, width: 190)
                }
            }
            SettingsDivider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(TerminalTheme.selectable) { theme in
                    ThemeSwatch(theme: theme, selected: isChosen(theme)) { choose(theme) }
                }
            }
            .padding(16)
            SettingsDivider()
            SettingsRow(title: "Follow your terminal's colours", detail: importDetail) {
                OctetButton(title: settings.values.importedTheme == nil ? "Import" : "Re-import", compact: true) { importTheme() }
            }
        }
        SettingsGroup(title: "Text") {
            SettingsRow(title: "Terminal font", detail: "Panes, the prompt editor and code.", setting: \.fontFamily) {
                OctetSelect(selection: $settings.values.fontFamily,
                            options: [("", "Default (JetBrains Mono)")] + terminalFamilies.map { ($0, $0) }, width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Interface font", detail: "The sidebar, tabs, panels and Settings.", setting: \.interfaceFontFamily) {
                OctetSelect(selection: $settings.values.interfaceFontFamily,
                            options: [("", "System (SF Pro)")] + interfaceFamilies.map { ($0, $0) }, width: 220)
            }
            SettingsDivider()
            SettingsRow(title: "Add a font", detail: "A .ttf, .otf or .ttc file. It's installed for you, as Font Book does, and works in every app.") {
                OctetButton(title: "Add Font…", compact: true, action: addFonts)
            }
            SettingsDivider()
            SettingsRow(title: "Font size", setting: \.fontSize) {
                OctetNumberField(label: "Font size", value: $settings.values.fontSize,
                                 range: SettingsStore.fontSizeRange, unit: "pt",
                                 spokenValue: { "\(Int($0)) points" })
            }
            SettingsDivider()
            SettingsRow(title: "Line height", setting: \.lineHeightPercent) {
                OctetSlider(label: "Line height", value: $settings.values.lineHeightPercent, range: 80...160, step: 5) { "\(Int($0))%" }
            }
            SettingsDivider()
            SettingsRow(title: "Thicken text", detail: "Heavier strokes, useful on non-Retina displays.", setting: \.fontThicken) {
                Toggle("Thicken text", isOn: $settings.values.fontThicken).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "Cursor") {
            SettingsRow(title: "Shape", setting: \.cursorStyle) {
                OctetSegmented(selection: $settings.values.cursorStyle, items: [(OctetSettings.CursorStyle.block, "Block"), (OctetSettings.CursorStyle.bar, "Bar"), (OctetSettings.CursorStyle.underline, "Underline")])
            }
            SettingsDivider()
            SettingsRow(title: "Blink", setting: \.cursorBlink) {
                Toggle("Cursor blink", isOn: $settings.values.cursorBlink).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "Window") {
            SettingsRow(title: "Terminal opacity", setting: \.backgroundOpacity) {
                OctetSlider(label: "Terminal opacity", value: $settings.values.backgroundOpacity, range: 0.3...1, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
            }
            SettingsDivider()
            SettingsRow(title: "Blur behind terminal", detail: "Applies when opacity is below 100%.", setting: \.backgroundBlur,
                        disabled: settings.values.backgroundOpacity >= 1) {
                Toggle("Blur behind terminal", isOn: $settings.values.backgroundBlur).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Padding", setting: \.windowPadding) {
                OctetSegmented(selection: $settings.values.windowPadding, items: [(OctetSettings.WindowPadding.compact, "Compact"), (OctetSettings.WindowPadding.normal, "Normal"), (OctetSettings.WindowPadding.roomy, "Roomy")])
            }
        }
        SettingsGroup(title: "Split panes") {
            SettingsRow(title: "Borders", setting: \.paneBorders) {
                OctetSegmented(selection: $settings.values.paneBorders, items: [(OctetSettings.PaneBorders.auto, "Splits only"), (OctetSettings.PaneBorders.always, "Always"), (OctetSettings.PaneBorders.off, "Off")])
            }
            SettingsDivider()
            SettingsRow(title: "Gaps between panes", setting: \.paneGaps) {
                Toggle("Gaps between panes", isOn: $settings.values.paneGaps).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Pane scrollbars", setting: \.paneScrollbars) {
                Toggle("Pane scrollbars", isOn: $settings.values.paneScrollbars).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
    }
}

private struct TerminalSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsGroup(title: "Scrollback & selection") {
            SettingsRow(title: "Scrollback per pane", setting: \.scrollbackMegabytes) {
                OctetSlider(label: "Scrollback per pane", value: $settings.values.scrollbackMegabytes, range: 1...100, step: 1) { "\(Int($0)) MB" }
            }
            SettingsDivider()
            SettingsRow(
                title: "Terminal text",
                detail: "Where output sits while it doesn't fill the pane. Bottom keeps the prompt where you look; Top is how a terminal normally fills.",
                setting: \.textPosition
            ) {
                OctetSegmented(selection: $settings.values.textPosition, items: OctetSettings.TextPosition.allCases.map { ($0, $0.title) })
            }
            SettingsDivider()
            SettingsRow(
                title: "Start new tabs with shortcuts",
                detail: "A new tab's empty rows offer your agents, recent folders and common shortcuts, until something runs in it.",
                setting: \.newTabSplash
            ) {
                Toggle("Start new tabs with shortcuts", isOn: $settings.values.newTabSplash)
                    .labelsHidden()
                    .toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Copy on select", detail: "Copy text as soon as you select it with the mouse.", setting: \.copyOnSelect) {
                Toggle("Copy on select", isOn: $settings.values.copyOnSelect).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Confirm copies",
                detail: "Show an Octet toast with what landed on the clipboard. Copying looks the same whether or not it worked.",
                setting: \.clipboardToasts
            ) {
                Toggle("Confirm copies", isOn: $settings.values.clipboardToasts).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Tidy text copied from agents",
                detail: "Copying from a pane running an agent leaves its layout behind: the indent under its bullets, the ⏺ and ⎿ marks, box edges and trailing spaces. Code keeps its own indentation.",
                setting: \.tidyAgentCopies
            ) {
                Toggle("Tidy text copied from agents", isOn: $settings.values.tidyAgentCopies).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Shell integration",
                detail: "zsh, bash and fish in Octet's panes mark each prompt and command (OSC 133), so ⌘↑/⌘↓ jump exactly between commands and each command's exit status and time show. Your own startup files load as usual. Applies to new panes.",
                setting: \.shellIntegration
            ) {
                Toggle("Shell integration", isOn: $settings.values.shellIntegration).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Secure input at password prompts",
                detail: "While sudo, ssh or anything else asks for a password in the pane in front, macOS Secure Keyboard Entry is on, so other apps can't read the keystrokes. It turns off as soon as the prompt ends.",
                setting: \.secureInputAtPasswords
            ) {
                Toggle("Secure input at password prompts", isOn: $settings.values.secureInputAtPasswords).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Preview long pastes into agents",
                detail: "A paste of 25 lines or more into a pane running an agent opens first, so you can read and edit it; agents fold long pastes into a line you can't open.",
                setting: \.previewLongPastes
            ) {
                Toggle("Preview long pastes into agents", isOn: $settings.values.previewLongPastes).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Lines per scroll wheel notch", setting: \.mouseScrollLines) {
                OctetNumberField(label: "Lines per scroll wheel notch", value: $settings.values.mouseScrollLines, range: 1...20)
            }
        }
        SettingsGroup(title: "Keyboard & mouse") {
            SettingsRow(title: "Use Option as Alt", detail: "Sends Alt/Meta sequences instead of typing special characters.", setting: \.optionAsAlt) {
                OctetSegmented(selection: $settings.values.optionAsAlt, items: [(OctetSettings.OptionAsAlt.off, "Off"), (OctetSettings.OptionAsAlt.left, "Left"), (OctetSettings.OptionAsAlt.right, "Right"), (OctetSettings.OptionAsAlt.both, "Both")])
            }
            SettingsDivider()
            SettingsRow(title: "Hide mouse pointer while typing", setting: \.hideMouseWhileTyping) {
                Toggle("Hide mouse pointer while typing", isOn: $settings.values.hideMouseWhileTyping).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "Clipboard & graphics") {
            SettingsRow(title: "Warn before pasting risky text", detail: "Multi-line pastes and text that could run commands.", setting: \.pasteProtection) {
                Toggle("Warn before pasting risky text", isOn: $settings.values.pasteProtection).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Programs reading the clipboard", detail: "Terminal programs requesting clipboard contents (OSC 52).", setting: \.clipboardRead) {
                OctetSegmented(selection: $settings.values.clipboardRead, items: [(OctetSettings.ClipboardAccess.ask, "Ask"), (OctetSettings.ClipboardAccess.allow, "Allow"), (OctetSettings.ClipboardAccess.deny, "Deny")])
            }
            SettingsDivider()
            SettingsRow(title: "Inline images", detail: "Kitty graphics protocol in panes.", setting: \.kittyGraphics) {
                Toggle("Inline images", isOn: $settings.values.kittyGraphics).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "Links & servers") {
            SettingsRow(title: "Open local links in the Browser plane",
                        detail: "⌘-click a localhost or local network address in a terminal to open it beside the terminal. Other links, and ⇧⌘-clicks, open in your browser.",
                        setting: \.previewTerminalLinks) {
                Toggle("Open local links in the Browser plane", isOn: $settings.values.previewTerminalLinks).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Open them with a plain click",
                        detail: "No ⌘ needed for local addresses. Clicks a program in the pane takes for itself still go to it.",
                        setting: \.previewLinksOnPlainClick, disabled: !settings.values.previewTerminalLinks) {
                Toggle("Open them with a plain click", isOn: $settings.values.previewLinksOnPlainClick).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Offer to preview new servers",
                        detail: "When a dev server starts in the workspace in front, a card offers to open it. Once per port each session.",
                        setting: \.offerServerPreviews) {
                Toggle("Offer to preview new servers", isOn: $settings.values.offerServerPreviews).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "Sidebar terminal") {
            SettingsRow(
                title: "Let agents read the sidebar terminal",
                detail: "The shell in the right panel, where you run servers, builds and tests. While this is on, an agent can read its latest output: Claude Code, Codex, Gemini, Qwen, OpenCode, Cursor and Copilot get a read_sidebar_terminal tool through the octet-terminal MCP server, and any other agent can run octet-cli terminal read. Off by default, since a terminal can hold secrets. A note shows over the terminal while it's on.",
                setting: \.agentsReadSidebarTerminal
            ) {
                Toggle("Let agents read the sidebar terminal", isOn: $settings.values.agentsReadSidebarTerminal)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Let agents suggest commands",
                detail: "An agent can open the sidebar terminal and type a command at its prompt, for example one that needs your password or that you'd rather watch. It is never run for you: you read it and press Return, or Run. It only goes in when the terminal is waiting at a prompt. Tool: suggest_sidebar_command, or octet-cli terminal suggest. Off by default.",
                setting: \.agentsSuggestSidebarCommands
            ) {
                Toggle("Let agents suggest commands", isOn: $settings.values.agentsSuggestSidebarCommands)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            if settings.values.agentsReadSidebarTerminal || settings.values.agentsSuggestSidebarCommands {
                SettingsDivider()
                SettingsRow(
                    title: "Tool in your agents",
                    detail: "Adds the octet-terminal MCP server to each installed agent's own settings, and takes it out again when this is turned off. Use Add Again if you installed an agent after turning this on."
                ) {
                    OctetButton(title: "Add Again", compact: true) { AgentMCPInstaller.shared.sync(server: TerminalMCP.serverName, force: true) }
                }
            }
        }
    }
}

private struct AgentSettings: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var integrations: AgentIntegrations
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    @State private var hookInstalled: Set<String> = []
    /// Each account's sign-in, read from its CLI when the page opens.
    @State private var accountStatus: [String: String] = [:]

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
                detail: "Open a small panel in the window corner when an agent needs a choice, answer, or permission.",
                setting: \.agentQuickAnswers
            ) {
                Toggle("Quick answers", isOn: $settings.values.agentQuickAnswers).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "When an agent finishes or needs you", setting: \.notifications) {
                OctetSelect(selection: $settings.values.notifications, options: [(OctetSettings.NotificationDelivery.system, "macOS notification"), (OctetSettings.NotificationDelivery.banner, "In Octet"), (OctetSettings.NotificationDelivery.off, "Off")], width: 190)
            }
            SettingsDivider()
            SettingsRow(title: "Wait before notifying", detail: "Skipped if you return to the agent first.", setting: \.notificationDelaySeconds) {
                OctetNumberField(label: "Wait before notifying", value: $settings.values.notificationDelaySeconds,
                                 range: 0...60, unit: "s", spokenValue: { "\(Int($0)) seconds" })
            }
            SettingsDivider()
            SettingsRow(
                title: "Recap when you come back",
                detail: "When you come back after being away (the screen locked, Octet out of sight, or the Mac untouched), a strip at the top says what every agent did meanwhile. It opens by itself only when something needs you or is stuck. View › Show Recap brings it back.",
                setting: \.recap
            ) {
                Toggle("Recap when you come back", isOn: $settings.values.recap).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Away for at least", detail: "Shorter breaks don't get a recap. Not touching the Mac this long counts as away too.", setting: \.recapAfterMinutes, disabled: !settings.values.recap) {
                OctetNumberField(label: "Away for at least", value: $settings.values.recapAfterMinutes,
                                 range: 1...120, unit: "min", spokenValue: { "\(Int($0)) minutes" })
            }
            SettingsDivider()
            SettingsRow(title: "Play sounds", detail: "When agents in other workspaces change state.", setting: \.agentSounds) {
                Toggle("Play sounds", isOn: $settings.values.agentSounds).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Subagent finished sound", detail: "Played by a subagent's tab when it finishes, so it sounds different from a main agent. Follows Play sounds.", setting: \.subagentFinishedSound,
                        disabled: !settings.values.agentSounds) {
                OctetSelect(selection: $settings.values.subagentFinishedSound,
                            options: [("", "None")] + SubagentWatch.sounds.map { ($0, $0) }, width: 140)
                .onChange(of: settings.values.subagentFinishedSound) { _, name in
                    if let path = SubagentWatch.soundPath(name), !name.isEmpty {
                        NSSound(contentsOf: URL(fileURLWithPath: path), byReference: true)?.play()
                    }
                }
            }
        }
        SettingsGroup(title: "Waits") {
            SettingsRow(
                title: "Let agents set waits",
                detail: "When work can't go on until something outside it happens (a pull request merged, a release, a deploy, a date, someone's answer), an agent writes down what it waits for and the next step. Octet checks it with nothing running and brings the work back when it happens. Claude Code, Codex, Gemini, Qwen, OpenCode, Cursor and Copilot get a wait_for tool through the octet-waits MCP server; any other agent can run octet-cli wait add. Waits show in the sidebar.",
                setting: \.agentsSetWaits
            ) {
                Toggle("Let agents set waits", isOn: $settings.values.agentsSetWaits).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            if settings.values.agentsSetWaits {
                SettingsDivider()
                SettingsRow(
                    title: "Tool in your agents",
                    detail: "Adds the octet-waits MCP server to each installed agent's own settings, and takes it out when this is off. Use Add Again if you installed an agent since."
                ) {
                    OctetButton(title: "Add Again", compact: true) { AgentMCPInstaller.shared.sync(server: WaitMCP.serverName, force: true) }
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "Offer a wait from a reply",
                detail: "When an agent ends with something like \"once the PR is merged, we can remove the old endpoint\", a banner over its composer offers to set a wait for it.",
                setting: \.suggestWaits
            ) {
                Toggle("Offer a wait from a reply", isOn: $settings.values.suggestWaits).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "Recovery") {
            SettingsRow(
                title: "Resume agents after a restart",
                detail: "When the terminal restarts (e.g. your Mac shut down), agents with an installed integration reopen their conversation.",
                setting: \.resumeAgentsOnRestore
            ) {
                Toggle("Resume agents after a restart", isOn: $settings.values.resumeAgentsOnRestore).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Offer to recover lost sessions",
                detail: "Octet records every agent's session, and every terminal that's running something with its recent output. If the terminal server stops and they end with it, Octet lists them so you can bring them back. A command is put back on the prompt, never rerun. File › Recover Sessions… reopens the list.",
                setting: \.offerRecovery
            ) {
                Toggle("Offer to recover lost sessions", isOn: $settings.values.offerRecovery).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Move agents to the project they work in",
                detail: "When a Claude or Codex agent's last 3 commands all ran in another repository (cd ~/code/api && …), Octet restarts it there once its turn ends, in the same tab with its conversation resumed. For an agent started in the wrong folder.",
                setting: \.relocateAgents
            ) {
                Toggle("Move agents to the project they work in", isOn: $settings.values.relocateAgents).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Keep the Mac awake while agents work",
                detail: "While any agent is working, the Mac doesn't go to sleep on its own, so long tasks finish. The display can still turn off, and closing the lid still sleeps. It lets go as soon as the last agent stops.",
                setting: \.keepAwake
            ) {
                OctetSelect(selection: $settings.values.keepAwake,
                            options: KeepAwake.Mode.allCases.map { ($0, $0.title) }, width: 190)
            }
            SettingsDivider()
            SettingsRow(
                title: "Checkpoint before each agent turn",
                detail: "As an agent starts working, Octet snapshots the project's files (tracked and untracked, not ignored) so the turn can be undone with Restore a Checkpoint in the command palette, including edits made through the shell. Snapshots are kept in the repository under refs/octet/checkpoints, the last 50 per worktree. Your branch, index and stash aren't touched.",
                setting: \.checkpointTurns
            ) {
                Toggle("Checkpoint before each agent turn", isOn: $settings.values.checkpointTurns).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Keep closed tabs running",
                detail: "Close a tab or pane while something runs in it and it keeps running out of sight for this long. ⌘⇧T, or Reopen on the notice, brings it back as it was.",
                setting: \.keepClosedTabsMinutes
            ) {
                OctetSelect(selection: $settings.values.keepClosedTabsMinutes, options: [(0.0, "Off"), (5.0, "5 minutes"), (15.0, "15 minutes"), (30.0, "30 minutes"), (60.0, "1 hour"), (240.0, "4 hours")], width: 190)
            }
            SettingsDivider()
            SettingsRow(
                title: "Remote Control for Claude conversations",
                detail: "Every Claude conversation in Octet is listed in claude.ai and the Claude app, to continue from your phone or another computer. What you send there shows up here. Each conversation's header also turns it on and off. Claude Code's own \"enable for all sessions\" setting turns it on too.",
                setting: \.claudeRemoteControl
            ) {
                Toggle("Remote Control for Claude conversations", isOn: $settings.values.claudeRemoteControl).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "When you run an agent in a terminal",
                detail: "Typing claude, codex or opencode on its own at a prompt opens the agent's own interface in the terminal, or Octet's conversation view. With a flag or a prompt it always runs in the terminal as typed. Octet's view needs Octet's command line, below.",
                setting: \.agentOpening
            ) {
                OctetSegmented(selection: $settings.values.agentOpening, items: OctetSettings.AgentOpening.allCases.map { ($0, $0.title) })
            }
            SettingsDivider()
            SettingsRow(
                title: "Offer Octet's view over a running agent",
                detail: "A banner above the terminal, while an agent runs in its own interface, offers to continue its session in Octet's conversation view.",
                setting: \.agentBanner
            ) {
                Toggle("Offer Octet's view over a running agent", isOn: $settings.values.agentBanner).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Octet's command line",
                detail: "At a shell prompt, Octet edits the line itself: highlighted as you type, with a suggestion from your history. Anything it doesn't handle goes straight to the shell.",
                setting: \.promptEditor
            ) {
                Toggle("Octet's command line", isOn: $settings.values.promptEditor).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Octet's Tab completions",
                detail: "Turn off to send Tab to your shell while keeping Octet's command-line editing and history suggestions. The shell takes over the current line after Tab.",
                setting: \.promptCompletions,
                disabled: !settings.values.promptEditor
            ) {
                Toggle("Octet's Tab completions", isOn: $settings.values.promptCompletions)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Accept a suggestion with",
                detail: "The key that takes the grey suggestion from your history at the end of the line. ⌥→ takes one word of it either way.",
                setting: \.suggestionAcceptKey,
                disabled: !settings.values.promptEditor
            ) {
                OctetSelect(selection: $settings.values.suggestionAcceptKey, options: OctetSettings.SuggestionAcceptKey.allCases.map { ($0, $0.title) }, width: 130)
            }
            SettingsDivider()
            SettingsRow(
                title: "Paste images as files",
                detail: "⌘V with an image on the clipboard writes it out and pastes the path, which is what agents can actually read.",
                setting: \.pasteImagesAsFiles
            ) {
                Toggle("Paste images as files", isOn: $settings.values.pasteImagesAsFiles).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Command specs",
                detail: specDetail
            ) {
                OctetButton(title: SpecCorpus.index() == nil ? "Install" : "Update", compact: true) { installSpecs() }
                    .disabled(installingSpecs)
            }
            SettingsDivider()
            SettingsRow(
                title: "Visual twin",
                detail: "⌘⇧V draws Octet's own interface over an agent's pane, read from the session the agent is already writing. What you type there goes to the real agent, so nothing about it changes.",
                setting: \.visualTwin
            ) {
                Toggle("Visual twin", isOn: $settings.values.visualTwin).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Open the twin for new agents",
                detail: "Start an agent and its pane opens in the twin rather than the terminal. Closing the twin for a pane keeps it closed.",
                setting: \.twinByDefault,
                disabled: !settings.values.visualTwin
            ) {
                Toggle("Open the twin for new agents", isOn: $settings.values.twinByDefault)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Name tabs after their work",
                detail: "Tabs follow what their pane reports it is doing, so a tab stops reading as the task you started with. A tab you rename yourself keeps its name.",
                setting: \.autoNameTabs
            ) {
                Toggle("Name tabs after their work", isOn: $settings.values.autoNameTabs).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Name workspaces after their work",
                detail: "A workspace takes the task its agents report, else what its conversation is about, else its branch. A workspace you rename yourself keeps its name.",
                setting: \.autoNameWorkspaces
            ) {
                Toggle("Name workspaces after their work", isOn: $settings.values.autoNameWorkspaces).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Hold Space to talk",
                detail: "In a conversation's message box, hold Space and speak; let go and what you said is typed in. A tap still types a space. Speech is recognized on this Mac where the language allows.",
                setting: \.holdSpaceToTalk
            ) {
                Toggle("Hold Space to talk", isOn: $settings.values.holdSpaceToTalk).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Restore recent terminal output",
                detail: "Saves pane contents so they reappear after a restart. Output can include secrets.",
                setting: \.paneHistory
            ) {
                Toggle("Restore recent terminal output", isOn: $settings.values.paneHistory).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "Usage") {
            SettingsRow(
                title: "Read live usage from your Claude account",
                detail: "Uses the sign-in Claude Code keeps in your keychain (macOS asks first) to fetch your allowance, the same way Claude Code's usage display does. The endpoint isn't documented by Anthropic and may change; this turns itself off if it stops working. Off, the chip shows Claude Code's cached usage and live numbers from conversations in Octet.",
                setting: \.readClaudeAccountUsage
            ) {
                Toggle("Read live usage from your Claude account", isOn: $settings.values.readClaudeAccountUsage)
                    .labelsHidden()
                    .toggleStyle(OctetSwitchStyle())
                    .onChange(of: settings.values.readClaudeAccountUsage) { _, on in
                        if on { AccountStore.shared.accountUsageSettingChanged() }
                    }
            }
        }
        if PhonePush.offered {
        SettingsGroup(title: "Phone") {
            SettingsRow(
                title: "Notices on your phone",
                detail: "When an agent needs you or finishes while Octet isn't in front, a push goes to this ntfy topic. Install the ntfy app and subscribe to the same topic. Anyone who knows the topic can read it, so pick something hard to guess. Only the agent, the tab and what happened are sent.",
                setting: \.phoneTopic
            ) {
                CommittedTextField(label: "ntfy topic", placeholder: "topic, e.g. octet-7fq2k", value: $settings.values.phoneTopic, width: 220,
                                   validate: { value in
                                       value.isEmpty || value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
                                           ? nil : "Letters, numbers, - and _ only" })
            }
            SettingsDivider()
            SettingsRow(title: "ntfy server", detail: "Leave empty for ntfy.sh, or your own server's address.", setting: \.phoneServer) {
                CommittedTextField(label: "ntfy server", placeholder: "https://ntfy.sh", value: $settings.values.phoneServer, width: 220,
                                   validate: { _ in nil })
            }
        }
        }
        SettingsGroup(title: "Accounts") {
            SettingsRow(
                title: "Agent accounts",
                detail: "Sign in to Claude or Codex more than once, say for work and personal, and choose which account each project uses. Each account keeps its own sign-in, settings and history in its own folder. Add one, sign in, or switch a project from the command palette: Add Claude Account, Use Account for This Project."
            ) {
                EmptyView()
            }
            ForEach(settings.values.accountProfiles) { profile in
                SettingsDivider()
                    .task(id: profile.id) {
                        let status = await Task.detached { AccountActions.status(of: profile) }.value
                        accountStatus[profile.id] = status
                    }
                let folders = settings.values.accountAssignments.filter { $0.profileId == profile.id }.map(\.folder)
                SettingsRow(
                    title: "\(AgentBrand.forAgent(profile.agent)?.displayName ?? profile.agent) · \(profile.name)",
                    detail: (accountStatus[profile.id].map { $0 + " · " } ?? "") + profile.home + " · " + (folders.isEmpty ? "No projects yet"
                        : "Used by " + folders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
                ) {
                    OctetButton(title: "Remove", compact: true) { AccountActions.remove(profile) }
                        .help("Stop using this account. Its folder and sign-in stay on disk.")
                }
            }
        }
        SettingsGroup(title: "Installed agents") {
            SettingsRow(
                title: "Prompt for agent updates",
                detail: "Once a day, check installed agent tools for newer releases. Octet asks before you run any update command.",
                setting: \.checkForAgentUpdates
            ) {
                Toggle("Prompt for agent updates", isOn: $settings.values.checkForAgentUpdates)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
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
                    OctetButton(title: hookInstalled.contains(spec.hostId) ? "Remove Hook" : "Install Hook", compact: true) {
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
                detail: "Keep its tab open until you close it, or close it two minutes after the subagent finishes. A tab you're looking at stays open, and a subagent that's sent more work starts the wait again.",
                setting: \.subagentTabClosing
            ) {
                OctetSegmented(selection: $settings.values.subagentTabClosing, items: OctetSettings.SubagentTabClosing.allCases.map { ($0, $0.title) })
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
                OctetButton(title: status.installed ? "Reinstall" : "Install", compact: true, action: install)
            }
        }
    }
}

private struct MotionSettings: View {
    @ObservedObject var motion: MotionPreferences

    var body: some View {
        SettingsGroup(title: "Animations") {
            SettingsRow(title: "Enable animations", detail: "Turn off to make every change in Octet instant.",
                        isDefault: motion.enabled, reset: { motion.enabled = true }) {
                Toggle("Enable animations", isOn: $motion.enabled).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Follow system Reduce Motion",
                detail: motion.systemReduceMotion
                    ? "Reduce Motion is on in System Settings, so animations are off."
                    : "Turns animations off whenever Reduce Motion is on in System Settings › Accessibility.",
                isDefault: motion.followSystemReduceMotion,
                reset: { motion.followSystemReduceMotion = true }
            ) {
                Toggle("Follow system Reduce Motion", isOn: $motion.followSystemReduceMotion).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "Animate") {
            ForEach(Array(MotionPreferences.Area.allCases.enumerated()), id: \.element) { index, area in
                if index > 0 { SettingsDivider() }
                SettingsRow(title: area.title, detail: area.detail,
                            isDefault: motion.isOn(area), reset: { motion.set(area, true) },
                            disabled: !motion.enabled) {
                    Toggle(area.title, isOn: motion.binding(area)).labelsHidden().toggleStyle(OctetSwitchStyle())
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
            SettingsRow(title: "Worktree folder", detail: "Where New Worktree creates <repo>/<branch> checkouts.", setting: \.worktreesDirectory) {
                CommittedTextField(label: "Worktree folder", placeholder: "~/.octet/worktrees", value: $settings.values.worktreesDirectory, width: 220,
                                   validate: SettingsValidation.folder)
            }
            SettingsDivider()
            SettingsRow(
                title: "Set up new worktrees",
                detail: "Copies the git-ignored .env files from the main checkout, then runs the project's .octet/setup (or the setup script in conductor.json) in the new worktree, with OCTET_ROOT_PATH, OCTET_WORKTREE_PATH and OCTET_PORT set. OCTET_PORT is the first of ten ports no other worktree has. Octet asks before running a project's script for the first time.",
                setting: \.worktreeSetup
            ) {
                Toggle("Set up new worktrees", isOn: $settings.values.worktreeSetup).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "Terminal engine") {
            SettingsRow(title: "Check for engine updates", setting: \.checkForEngineUpdates) {
                Toggle("Check for engine updates", isOn: $settings.values.checkForEngineUpdates).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Update channel", setting: \.updateChannel) {
                OctetSegmented(selection: $settings.values.updateChannel, items: [(OctetSettings.UpdateChannel.stable, "Stable"), (OctetSettings.UpdateChannel.preview, "Preview")])
            }
            SettingsDivider()
            SettingsRow(title: "Allow a nested session", detail: "Lets you run another terminal session inside an Octet pane.", setting: \.allowNestedSessions) {
                Toggle("Allow a nested session", isOn: $settings.values.allowNestedSessions).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Session", detail: "Octet runs its own session, separate from terminals you open elsewhere.") {
                Text(EngineSession.name).font(Theme.monoFont).foregroundStyle(Theme.textSecondary)
            }
            SettingsDivider()
            SettingsRow(title: "Generated config", detail: "Written from these settings on launch and on every change.") {
                HStack(spacing: 8) {
                    OctetButton(title: "Reveal", compact: true) {
                        if let path = EngineSession.make()?.configPath {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    .accessibilityLabel("Reveal generated config in Finder")
                    OctetButton(title: "Reload", compact: true) { store.reloadSessionConfig() }
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
                OctetButton(title: "Reset…", compact: true) {
                    ConfirmCenter.shared.ask(
                        title: "Restore default settings?",
                        message: "Appearance, terminal, agent, keyboard, and advanced settings go back to their defaults.",
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

// MARK: - Building blocks

/// A titled card of rows, after T3 Code's SettingsSection: the title in
/// 14pt at 70% outside the card, 10pt above it; the card rounded 14 with a
/// soft border, a faint fill and hairlines between rows.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.interfaceFont(14))
                .foregroundStyle(Theme.textPrimary.opacity(0.7))
                .padding(.horizontal, 16)
                .frame(minHeight: 20, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .background(Theme.card.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                // A search that lands on the whole group pulses the card.
                .settingsPulse(title, cornerRadius: 14)
        }
        // Search jumps scroll to a group by its title.
        .id(title)
    }
}

/// One setting, after T3 Code's SettingsRow: its title (with a reset to
/// default beside it once it's changed), what it does, and its control at
/// the right, or under the text, full width, when the row is narrow.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    /// A small outline label after the title, such as "Custom" on a
    /// shortcut that differs from its default.
    var badge: String?
    /// Whether the setting is at its default; the reset only shows when not.
    var isDefault = true
    /// Puts the setting back to its default. nil for rows with no default.
    var reset: (() -> Void)?
    /// Greys the whole row, not just its control, as T3 Code's rows do.
    var disabled = false
    @ViewBuilder let control: Control
    @State private var width: CGFloat = 0

    /// T3 Code's `@min-[32rem]/settings-row`: narrower than this, the
    /// control goes under the text.
    private static var stackBelow: CGFloat { 512 }
    private var stacked: Bool { width > 0 && width < Self.stackBelow }

    init(title: String, detail: String? = nil, badge: String? = nil,
         isDefault: Bool = true, reset: (() -> Void)? = nil, disabled: Bool = false,
         @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.badge = badge
        self.isDefault = isDefault
        self.reset = reset
        self.disabled = disabled
        self.control = control()
    }

    /// A row for one of OctetSettings' values, its reset wired to that
    /// value's default in `OctetSettings.defaults`.
    init<V: Equatable>(title: String, detail: String? = nil, badge: String? = nil,
                       setting key: WritableKeyPath<OctetSettings, V>, disabled: Bool = false,
                       @ViewBuilder control: () -> Control) {
        let store = SettingsStore.shared
        self.init(title: title, detail: detail, badge: badge,
                  isDefault: store.values[keyPath: key] == OctetSettings.defaults[keyPath: key],
                  reset: { store.values[keyPath: key] = OctetSettings.defaults[keyPath: key] },
                  disabled: disabled, control: control)
    }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 12) {
                    text
                    control.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .center, spacing: 32) {
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    control
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .disabled(disabled)
        .opacity(disabled ? 0.64 : 1)
        .contentShape(Rectangle())
        .settingsPulse(title)
        // Search jumps scroll to a row by its title.
        .id(title)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Theme.interfaceFont(14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                }
                // T3 Code keeps the slot when there's nothing to reset, so
                // the title doesn't shift when one appears.
                Group {
                    if let reset, !isDefault {
                        SettingResetButton(title: title, action: reset)
                    }
                }
                .frame(width: 20, height: 20)
            }
            .frame(minHeight: 20)
            if let detail {
                Text(detail)
                    .font(Theme.interfaceFont(12))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .lineSpacing(2)
                    .frame(maxWidth: 576, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// T3 Code's per-row Reset to Default: a ghost undo icon, 20pt.
private struct SettingResetButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            OctetIcon("undo", size: 12)
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help("Reset to Default")
        .accessibilityLabel("Reset \(title) to default")
        .transition(.opacity)
    }
}

/// The hairline between rows in a group.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 1)
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

    private var problem: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : validate(trimmed)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            OctetTextField(placeholder: placeholder, text: $draft, label: label,
                           invalid: problem != nil, onSubmit: commit,
                           onFocusChange: { focused in if !focused { commit() } })
                .frame(width: width)
                .onAppear { draft = value }
                .onChange(of: value) { _, new in if new != draft { draft = new } }
                .accessibilityValue(problem.map { "\(draft), \($0)" } ?? draft)
            if let problem {
                Text(problem)
                    .font(Theme.interfaceFont(11))
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

/// A section in Settings' list, after T3 Code's: a 32pt row, the icon dim
/// until hovered or chosen, the chosen one filled.
private struct SettingsNavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                OctetIcon(icon, size: 15)
                    .foregroundStyle(selected || hovered ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected || hovered ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(selected ? Theme.cardSelected : hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The Settings window's own chrome, which a page in the main window
/// doesn't want: its size, its title bar and theme, and its own toasts and
/// confirmations (the main window already shows those).
private struct SettingsChrome: ViewModifier {
    let embedded: Bool
    let themeKey: String

    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity)
                .frame(minHeight: 560, maxHeight: .infinity)
                // Errors and confirmations raised here show here, not behind it.
                .overlay(alignment: .bottomTrailing) { ToastStack(center: ToastCenter.shared) }
                .overlay { ConfirmDialog(center: ConfirmCenter.shared) }
                .ignoresSafeArea()
                .background(DarkTransparentTitleBar())
                .id(themeKey)
                .preferredColorScheme(Theme.colorScheme)
                .background(ThemedWindow(themeName: themeKey))
        }
    }
}

/// Opens Settings as a page in the front window, on a section if given.
/// Falls back to the Settings window when no main window is open.
@MainActor
enum SettingsOpener {
    static var fallback: (() -> Void)?

    static func open(_ section: SettingsView.Section? = nil) {
        if let section { UserDefaults.standard.set(section.rawValue, forKey: SettingsView.sectionKey) }
        NSApp.activate(ignoringOtherApps: true)
        if let window = WindowRegistry.shared.key ?? WindowRegistry.shared.windows.first {
            MotionPreferences.shared.perform(.palette, .easeOut(duration: 0.15)) { window.ui.settingsVisible = true }
        } else {
            fallback?()
        }
    }
}
