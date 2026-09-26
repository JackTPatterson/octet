import AppKit
import Foundation

/// Every user setting, grouped by the layer that applies it. Nothing is
/// duplicated across layers: the renderer owns drawing and host input, the
/// session server owns panes, shells, scrollback, notifications and sessions, and Octet owns
/// its own window, sidebar, and recovery.
struct OctetSettings: Codable, Equatable {
    // MARK: General (Octet + session server)
    var confirmQuit = true
    /// A shortcut from any app that brings Octet forward or hides it.
    var globalHotkey: GlobalHotkey.Choice = .off
    /// The hotkey drops a window down from the top of the screen, over
    /// full-screen apps, instead of bringing Octet forward.
    var hotkeyDropDown = false
    var newPaneDirectory: NewPaneDirectory = .follow
    var defaultShell = ""
    var shellMode: ShellMode = .auto

    // MARK: Appearance (renderer + session server panes)
    var themeName = "Dark"
    /// Colours read from the user's terminal config, when they asked for it.
    var importedTheme: TerminalTheme?
    /// Follow macOS light/dark, switching between these two themes.
    var matchSystemAppearance = false
    var lightThemeName = "Light"
    var darkThemeName = "Dark"
    var fontFamily = ""
    var fontSize: Double = 13
    var lineHeightPercent: Double = 100
    var fontThicken = false
    var cursorStyle: CursorStyle = .block
    var cursorBlink = true
    var backgroundOpacity: Double = 1
    var backgroundBlur = false
    var windowPadding: WindowPadding = .normal
    var textPosition: TextPosition = .bottom
    /// A new tab's empty rows offer agents, recent folders and shortcuts
    /// until something runs in it.
    var newTabSplash = true
    var paneBorders: PaneBorders = .auto
    var paneGaps = true
    var paneScrollbars = true
    /// A strip under the terminal with the focused pane's runtime version,
    /// branch and changes while it's inside a git repo.
    var repoContextBar = true
    /// The status bar's chips in order, once someone has arranged them;
    /// until then (`statusBarCustomized` false) each chip's default applies.
    var statusBarChips: [String] = []
    var statusBarCustomized = false
    /// Every chip that existed when the bar was last arranged, so one that
    /// arrives later (a plugin turned on) can still start on.
    var statusBarSeen: [String] = []

    // MARK: Terminal (renderer input + session server panes)
    var scrollbackMegabytes: Double = 10
    var copyOnSelect = true
    var clipboardToasts = true
    /// Take an agent interface's layout off text copied from its pane.
    var tidyAgentCopies = true
    /// Show a long paste into an agent, editable, before it's sent.
    var previewLongPastes = true
    /// Turn on Secure Keyboard Entry while a pane asks for a password.
    var secureInputAtPasswords = true
    /// Prompt marks from zsh, bash and fish, through Octet's shell wrapper.
    var shellIntegration = true
    /// ntfy topic for agent notices on your phone; empty is off.
    var phoneTopic = ""
    var phoneServer = ""
    var mouseScrollLines: Double = 3
    var optionAsAlt: OptionAsAlt = .off
    var hideMouseWhileTyping = true
    var pasteProtection = true
    var clipboardRead: ClipboardAccess = .ask
    var kittyGraphics = true

    // MARK: Agents & recovery (session server + Octet)
    var notifications: NotificationDelivery = .banner
    var notificationDelaySeconds: Double = 1
    var agentSounds = true
    var resumeAgentsOnRestore = true
    var paneHistory = false
    /// Read Claude's allowance from the account itself: the OAuth token Claude
    /// Code keeps in the login keychain, sent to the endpoint Claude Code's own
    /// usage display calls. Off by default because it touches another app's
    /// credential and an endpoint Anthropic doesn't document; without it the
    /// chip reads Claude Code's cache and any conversation Octet runs.
    var readClaudeAccountUsage = false
    var offerRecovery = true
    /// How long a tab closed with something running in it keeps running,
    /// out of sight, so it can be reopened. Zero closes at once.
    var keepClosedTabsMinutes: Double = 30
    /// Keep the Mac from idle-sleeping while an agent is working.
    var keepAwake: KeepAwake.Mode = .pluggedIn
    /// Snapshot an agent's working tree as it starts each turn, to undo it.
    var checkpointTurns = true
    /// Extra agent sign-ins, and the project folders that use them.
    var accountProfiles: [AccountProfile] = []
    var accountAssignments: [AccountAssignment] = []
    /// Turn on Remote Control for every Claude conversation in Octet, so it
    /// can be continued from claude.ai or the Claude app.
    var claudeRemoteControl = false
    /// What typing `claude`, `codex` or `opencode` on its own at a prompt
    /// opens: the agent's interface in the terminal, or Octet's conversation.
    var agentOpening: AgentOpening = .terminal
    /// Octet plugins turned on by hand (installed ones start off) and
    /// bundled ones turned off (they start on), by id.
    var enabledPlugins: [String] = []
    var disabledPlugins: [String] = []
    /// The sound a subagent's tab plays when it finishes, so it's told
    /// apart from a main agent; empty for none.
    var subagentFinishedSound = DoubleDing.name
    /// Whether a subagent's tab closes itself a while after it finishes.
    var subagentTabClosing: SubagentTabClosing = .never
    /// A banner over an agent running in the terminal, offering Octet's
    /// conversation view.
    var agentBanner = true
    /// Show a compact corner panel whenever an agent is waiting for a choice,
    /// typed answer, or permission decision.
    var agentQuickAnswers = true
    var checkForAgentUpdates = true
    var promptEditor = true
    var promptCompletions = true
    var suggestionAcceptKey: SuggestionAcceptKey = .right
    var pasteImagesAsFiles = true
    var autoNameTabs = true
    var visualTwin = true
    // Native agent opening is controlled separately; terminal sessions stay in
    // their own interface unless the user explicitly enables the twin.
    var twinByDefault = false
    var showTips = true

    // MARK: Advanced (session server)
    var worktreesDirectory = "~/.octet/worktrees"
    /// Copy the main checkout's env files into a new worktree and run its
    /// `.octet/setup` (or `conductor.json` setup) there.
    var worktreeSetup = true
    /// Where the engine used to put worktrees; kept when it holds any.
    static let legacyWorktreesDirectory = EngineProtocol.legacyWorktreesDirectory
    static let doubleDingMigrationKey = "octet.subagentSound.movedToDoubleDing"
    var checkForEngineUpdates = true
    var updateChannel: UpdateChannel = .stable
    var allowNestedSessions = false

    enum NewPaneDirectory: String, Codable, CaseIterable { case follow, home, current }
    enum ShellMode: String, Codable, CaseIterable { case auto, login, nonLogin = "non_login" }
    enum CursorStyle: String, Codable, CaseIterable { case block, bar, underline }
    enum WindowPadding: String, Codable, CaseIterable { case compact, normal, roomy }
    /// Where a pane's output sits when it doesn't fill the pane.
    enum TextPosition: String, Codable, CaseIterable {
        case top, bottom
        var title: String { self == .top ? "Top" : "Bottom" }
    }
    enum PaneBorders: String, Codable, CaseIterable { case auto, always, off }
    enum OptionAsAlt: String, Codable, CaseIterable { case off, left, right, both }
    enum ClipboardAccess: String, Codable, CaseIterable { case ask, allow, deny }
    enum NotificationDelivery: String, Codable, CaseIterable {
        case off
        case system
        /// Octet's own banner in the window's top right.
        case banner

        /// Reads a stored value, including the name earlier versions saved
        /// for `banner`.
        init?(stored raw: String) {
            if let value = Self(rawValue: raw) {
                self = value
            } else if raw == Self.legacyBannerValue {
                self = .banner
            } else {
                return nil
            }
        }

        private static let legacyBannerValue = "herdr"

        var title: String {
            switch self {
            case .off: "Off"
            case .system: "System notifications"
            case .banner: "In Octet"
            }
        }
    }
    enum UpdateChannel: String, Codable, CaseIterable { case stable, preview }

    /// Which key takes the grey history suggestion at the end of the line.
    enum SuggestionAcceptKey: String, Codable, CaseIterable {
        case right
        /// Tab takes the suggestion when there is one; otherwise it completes.
        case tab
        case either

        var title: String {
            switch self {
            case .right: "→"
            case .tab: "Tab"
            case .either: "→ or Tab"
            }
        }

        var right: Bool { self != .tab }
        var tab: Bool { self != .right }
    }

    enum SubagentTabClosing: String, Codable, CaseIterable {
        /// Open until closed by hand.
        case never
        /// Two minutes after the subagent finishes, unless it's in front.
        case afterDelay

        var title: String {
            switch self {
            case .never: "Keep open"
            case .afterDelay: "Close after 2 min"
            }
        }

        var seconds: Int {
            switch self {
            case .never: 0
            case .afterDelay: 120
            }
        }
    }

    enum AgentOpening: String, Codable, CaseIterable {
        /// The agent's own interface, in the terminal.
        case terminal
        /// Octet's conversation view.
        case octet

        var title: String {
            switch self {
            case .terminal: "Its own interface"
            case .octet: "Octet"
            }
        }
    }

    /// Bumped when a stored value needs reinterpreting; see `init(from:)`.
    static let currentVersion = 2
    var version = currentVersion

    init() {}

    /// Decodes stored settings, falling back to defaults for any missing key
    /// so new settings never reset old ones.
    init(from decoder: Decoder) throws {
        self.init()
        let defaults = OctetSettings()
        let container = try decoder.container(keyedBy: DynamicKey.self)
        func value<T: Decodable>(_ key: String, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: DynamicKey(key))) ?? fallback
        }
        confirmQuit = value("confirmQuit", defaults.confirmQuit)
        globalHotkey = value("globalHotkey", defaults.globalHotkey)
        hotkeyDropDown = value("hotkeyDropDown", defaults.hotkeyDropDown)
        newPaneDirectory = value("newPaneDirectory", defaults.newPaneDirectory)
        defaultShell = value("defaultShell", defaults.defaultShell)
        shellMode = value("shellMode", defaults.shellMode)
        themeName = value("themeName", defaults.themeName)
        importedTheme = value("importedTheme", defaults.importedTheme)
        TerminalTheme.imported = importedTheme
        matchSystemAppearance = value("matchSystemAppearance", defaults.matchSystemAppearance)
        lightThemeName = value("lightThemeName", defaults.lightThemeName)
        darkThemeName = value("darkThemeName", defaults.darkThemeName)
        fontFamily = value("fontFamily", defaults.fontFamily)
        fontSize = value("fontSize", defaults.fontSize)
        lineHeightPercent = value("lineHeightPercent", defaults.lineHeightPercent)
        fontThicken = value("fontThicken", defaults.fontThicken)
        cursorStyle = value("cursorStyle", defaults.cursorStyle)
        cursorBlink = value("cursorBlink", defaults.cursorBlink)
        backgroundOpacity = value("backgroundOpacity", defaults.backgroundOpacity)
        backgroundBlur = value("backgroundBlur", defaults.backgroundBlur)
        windowPadding = value("windowPadding", defaults.windowPadding)
        textPosition = value("textPosition", defaults.textPosition)
        newTabSplash = value("newTabSplash", defaults.newTabSplash)
        paneBorders = value("paneBorders", defaults.paneBorders)
        paneGaps = value("paneGaps", defaults.paneGaps)
        paneScrollbars = value("paneScrollbars", defaults.paneScrollbars)
        repoContextBar = value("repoContextBar", defaults.repoContextBar)
        statusBarChips = value("statusBarChips", defaults.statusBarChips)
        statusBarCustomized = value("statusBarCustomized", defaults.statusBarCustomized)
        statusBarSeen = value("statusBarSeen", defaults.statusBarSeen)
        scrollbackMegabytes = value("scrollbackMegabytes", defaults.scrollbackMegabytes)
        copyOnSelect = value("copyOnSelect", defaults.copyOnSelect)
        clipboardToasts = value("clipboardToasts", defaults.clipboardToasts)
        tidyAgentCopies = value("tidyAgentCopies", defaults.tidyAgentCopies)
        previewLongPastes = value("previewLongPastes", defaults.previewLongPastes)
        secureInputAtPasswords = value("secureInputAtPasswords", defaults.secureInputAtPasswords)
        shellIntegration = value("shellIntegration", defaults.shellIntegration)
        phoneTopic = value("phoneTopic", defaults.phoneTopic)
        phoneServer = value("phoneServer", defaults.phoneServer)
        mouseScrollLines = value("mouseScrollLines", defaults.mouseScrollLines)
        optionAsAlt = value("optionAsAlt", defaults.optionAsAlt)
        hideMouseWhileTyping = value("hideMouseWhileTyping", defaults.hideMouseWhileTyping)
        pasteProtection = value("pasteProtection", defaults.pasteProtection)
        clipboardRead = value("clipboardRead", defaults.clipboardRead)
        kittyGraphics = value("kittyGraphics", defaults.kittyGraphics)
        notifications = NotificationDelivery(stored: value("notifications", ""))
            ?? defaults.notifications
        version = value("version", 1)
        if version < 2 {
            // "system" used to be the default, before Octet drew its own
            // agent banners; move that default on, keep a deliberate "off".
            if notifications == .system { notifications = .banner }
            version = Self.currentVersion
        }
        notificationDelaySeconds = value("notificationDelaySeconds", defaults.notificationDelaySeconds)
        agentSounds = value("agentSounds", defaults.agentSounds)
        resumeAgentsOnRestore = value("resumeAgentsOnRestore", defaults.resumeAgentsOnRestore)
        paneHistory = value("paneHistory", defaults.paneHistory)
        readClaudeAccountUsage = value("readClaudeAccountUsage", defaults.readClaudeAccountUsage)
        offerRecovery = value("offerRecovery", defaults.offerRecovery)
        keepClosedTabsMinutes = value("keepClosedTabsMinutes", defaults.keepClosedTabsMinutes)
        keepAwake = value("keepAwake", defaults.keepAwake)
        checkpointTurns = value("checkpointTurns", defaults.checkpointTurns)
        accountProfiles = value("accountProfiles", defaults.accountProfiles)
        accountAssignments = value("accountAssignments", defaults.accountAssignments)
        claudeRemoteControl = value("claudeRemoteControl", defaults.claudeRemoteControl)
        agentOpening = value("agentOpening", defaults.agentOpening)
        subagentTabClosing = value("subagentTabClosing", defaults.subagentTabClosing)
        subagentFinishedSound = value("subagentFinishedSound", defaults.subagentFinishedSound)
        // Glass was the default before Octet had a ding of its own: move off
        // it once, and leave it be if chosen again afterwards.
        if !UserDefaults.standard.bool(forKey: Self.doubleDingMigrationKey) {
            UserDefaults.standard.set(true, forKey: Self.doubleDingMigrationKey)
            if subagentFinishedSound == "Glass" { subagentFinishedSound = defaults.subagentFinishedSound }
        }
        enabledPlugins = value("enabledPlugins", defaults.enabledPlugins)
        disabledPlugins = value("disabledPlugins", defaults.disabledPlugins)
        agentBanner = value("agentBanner", defaults.agentBanner)
        agentQuickAnswers = value("agentQuickAnswers", defaults.agentQuickAnswers)
        checkForAgentUpdates = value("checkForAgentUpdates", defaults.checkForAgentUpdates)
        promptEditor = value("promptEditor", defaults.promptEditor)
        promptCompletions = value("promptCompletions", defaults.promptCompletions)
        suggestionAcceptKey = value("suggestionAcceptKey", defaults.suggestionAcceptKey)
        pasteImagesAsFiles = value("pasteImagesAsFiles", defaults.pasteImagesAsFiles)
        autoNameTabs = value("autoNameTabs", defaults.autoNameTabs)
        visualTwin = value("visualTwin", defaults.visualTwin)
        twinByDefault = value("twinByDefault", defaults.twinByDefault)
        showTips = value("showTips", defaults.showTips)
        worktreesDirectory = value("worktreesDirectory", defaults.worktreesDirectory)
        worktreeSetup = value("worktreeSetup", defaults.worktreeSetup)
        // Move off the old default unless worktrees already live there.
        if worktreesDirectory == Self.legacyWorktreesDirectory,
           !FileManager.default.fileExists(atPath: NSString(string: Self.legacyWorktreesDirectory).expandingTildeInPath) {
            worktreesDirectory = defaults.worktreesDirectory
        }
        checkForEngineUpdates = value("checkForEngineUpdates", value(Self.legacyUpdateCheckKey, defaults.checkForEngineUpdates))
        updateChannel = value("updateChannel", defaults.updateChannel)
        allowNestedSessions = value("allowNestedSessions", value(Self.legacyNestedKey, defaults.allowNestedSessions))
    }

    /// Keys earlier versions stored these two settings under; read once so
    /// saved choices survive, then written back under the new names.
    private static let legacyUpdateCheckKey = "checkForHerdrUpdates"
    private static let legacyNestedKey = "allowNestedHerdr"

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Reduce Transparency in System Settings wins over Octet's opacity.
    var effectiveBackgroundOpacity: Double { SystemDisplay.reduceTransparency ? 1 : backgroundOpacity }
    var effectiveBackgroundBlur: Bool { backgroundBlur && effectiveBackgroundOpacity < 1 }

    /// The theme that should be showing now.
    func resolvedThemeName(systemIsDark: Bool) -> String {
        guard matchSystemAppearance else { return themeName }
        return systemIsDark ? darkThemeName : lightThemeName
    }

    // MARK: - Generated configs

    /// Config lines for the embedded renderer.
    var rendererConfig: String {
        let theme = TerminalTheme.named(themeName)
        // Default terminal text should be unambiguously legible on every
        // theme. Programs remain free to draw their own ANSI colors; this only
        // controls cells that use the terminal's default foreground.
        let terminalForeground = theme.isLight ? "000000" : "ffffff"
        let padding: (Int, Int) = switch windowPadding {
        case .compact: (4, 2)
        case .normal: (10, 6)
        case .roomy: (18, 12)
        }
        var lines = [
            // One wheel notch is one report to the session server, which
            // scrolls "Mouse scroll lines" per report; the renderer's own
            // default of 3 made that 3 x 3 = 9 lines a notch.
            "mouse-scroll-multiplier = discrete:1",
            "background = \(theme.background)",
            "foreground = \(terminalForeground)",
            // Fractional sizes (13.5) are sizes too.
            "font-size = \(fontSize.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(fontSize)) : String(fontSize))",
            "font-thicken = \(fontThicken)",
            "adjust-cell-height = \(Int(lineHeightPercent) - 100)%",
            "cursor-style = \(cursorStyle.rawValue)",
            "cursor-style-blink = \(cursorBlink)",
            "background-opacity = \(String(format: "%.2f", effectiveBackgroundOpacity))",
            "background-blur = \(effectiveBackgroundBlur)",
            "window-padding-x = \(padding.0)",
            // Top padding stays 0: Octet clips the session server's tab row from the top edge.
            "window-padding-y = 0,\(padding.1)",
            "macos-option-as-alt = \(optionAsAlt == .off ? "false" : optionAsAlt.rawValue == "both" ? "true" : optionAsAlt.rawValue)",
            "mouse-hide-while-typing = \(hideMouseWhileTyping)",
            // Ghostty recognizes ordinary URLs and opens them with the system
            // handler on ⌘-click. Keep it explicit because Octet builds a
            // renderer config from scratch instead of loading user defaults.
            "link-url = true",
            "clipboard-paste-protection = \(pasteProtection)",
            "clipboard-read = \(clipboardRead.rawValue)",
        ]
        if !fontFamily.isEmpty { lines.append("font-family = \"\(fontFamily)\"") }
        return lines.joined(separator: "\n")
    }

    /// The shell panes start: the one chosen (or $SHELL), or Octet's wrapper
    /// around it when shell integration applies to it.
    var realShell: String {
        defaultShell.isEmpty ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") : defaultShell
    }

    /// Every shell goes through the wrapper: zsh, bash and fish for marks, all of
    /// them for the account their folder uses.
    var usesShellIntegration: Bool { shellIntegration }

    var paneShell: String {
        usesShellIntegration
            ? ShellIntegration.directory(support: EngineSession.supportDirectory).appendingPathComponent("octet-shell").path
            : defaultShell
    }

    /// Session server config for Octet's session. Octet's chrome replaces the
    /// server's own sidebar and tab row, so those stay fixed.
    var sessionConfig: String {
        let scrollbackBytes = Int(scrollbackMegabytes * 1_000_000)
        let theme = TerminalTheme.named(themeName)
        return """
        # Managed by Octet from Settings. Rewritten on launch and on every change.
        onboarding = false

        [theme]
        name = "terminal"

        [terminal]
        default_shell = \(tomlString(paneShell))
        shell_mode = "\(shellMode.rawValue)"
        new_cwd = "\(newPaneDirectory.rawValue)"
        kitty_graphics = \(kittyGraphics)

        [update]
        channel = "\(updateChannel.rawValue)"
        version_check = \(checkForEngineUpdates)

        [ui]
        sidebar_start_collapsed = true
        sidebar_collapsed_mode = "hidden"
        hide_tab_bar_when_single_tab = false
        tab_bar_position = "top"
        prompt_new_tab_name = false
        prompt_new_workspace_name = false
        confirm_close = false
        copy_on_select = \(copyOnSelect)
        mouse_scroll_lines = \(Int(mouseScrollLines))
        pane_borders = "\(paneBorders.rawValue)"
        pane_gaps = \(paneGaps)
        pane_scrollbars = \(paneScrollbars)
        pane_outer_borders = false
        accent = "#\(theme.accent)"

        [ui.toast]
        # Octet draws agent notices itself unless the system is doing it.
        delivery = "\(notifications == .system ? "system" : "off")"
        delay_seconds = \(Int(notificationDelaySeconds))

        # Octet shows its own clipboard toast; only one of the two should.
        [ui.toast.clipboard]
        enabled = \(!clipboardToasts)

        [ui.sound]
        enabled = \(agentSounds)

        [session]
        resume_agents_on_restore = \(resumeAgentsOnRestore)

        [worktrees]
        directory = \(tomlString(worktreesDirectory))

        [advanced]
        scrollback_limit_bytes = \(scrollbackBytes)

        [experimental]
        pane_history = \(paneHistory)
        allow_nested = \(allowNestedSessions)

        \(EngineNavigation.keysConfig)
        """
    }

    private func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Loads, persists, and applies `OctetSettings`.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private static let key = "octet.settings.v1"

    @Published var values: OctetSettings {
        didSet {
            guard values != oldValue else { return }
            // Match system: the showing theme follows the light/dark picks.
            let resolved = values.resolvedThemeName(systemIsDark: SystemDisplay.isDark)
            if values.themeName != resolved {
                values.themeName = resolved
                return
            }
            save()
            apply(from: oldValue)
        }
    }

    /// Changes whenever chrome colors must be recomputed: theme, Increase
    /// Contrast, Reduce Transparency. Views re-identify on it.
    @Published private(set) var themeKey = ""
    private var systemObservers: [NSObjectProtocol] = []

    /// Terminal config lines that were rejected, and a config file that
    /// couldn't be written; Settings shows these rather than failing silently.
    @Published private(set) var configProblems: [String] = []
    private var sessionConfigWriteProblem: String?

    /// Set by the app once the session is known.
    var sessionConfigPath: String?
    var reloadSession: (() -> Void)?

    private var pendingSessionReload: DispatchWorkItem?

    private init() {
        #if DEBUG
        // Debug has its own bundle ID (so macOS keeps its privacy grants
        // apart from Release's). It takes Release's settings once rather than
        // starting from defaults, which would, say, stop subagent tabs closing.
        let seededKey = "octet.settings.seededFromRelease"
        if !UserDefaults.standard.bool(forKey: seededKey) {
            if let release = UserDefaults(suiteName: "com.jpxsoftware.octet")?.data(forKey: Self.key) {
                UserDefaults.standard.set(release, forKey: Self.key)
            }
            UserDefaults.standard.set(true, forKey: seededKey)
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(OctetSettings.self, from: data) {
            values = decoded
        } else {
            values = OctetSettings()
        }
        AccountProfiles.configure(profiles: values.accountProfiles, assignments: values.accountAssignments)
        EngineClient.prepareRequest = AccountProfiles.prepare
        #if DEBUG
        // Visual QA can exercise both palettes without rewriting the user's
        // saved appearance. This is intentionally unavailable in release
        // builds and skipped by the launch-time migration save below.
        let debugThemeOverride = ProcessInfo.processInfo.environment["OCTET_THEME_OVERRIDE"]
            .flatMap { name in TerminalTheme.selectable.contains(where: { $0.name == name }) ? name : nil }
        if let debugThemeOverride {
            values.themeName = debugThemeOverride
            values.matchSystemAppearance = false
        }
        #else
        let debugThemeOverride: String? = nil
        #endif
        // Restore the imported terminal palette before resolving its name.
        // Otherwise a saved imported theme falls through to `Dark` during
        // launch, leaving the terminal surface nearly black until Settings is
        // changed once.
        TerminalTheme.imported = values.importedTheme
        values.themeName = values.resolvedThemeName(systemIsDark: SystemDisplay.isDark)
        Theme.palette = ThemePalette(theme: .named(values.themeName))
        themeKey = Self.makeThemeKey(values.themeName)
        observeSystem()
        // Rewrites settings read under older key names with the current ones.
        if debugThemeOverride == nil { save() }
        mirrorForSubagentTabs()
    }

    private static func makeThemeKey(_ themeName: String) -> String {
        "\(themeName)|\(SystemDisplay.increaseContrast)|\(SystemDisplay.reduceTransparency)"
    }

    /// macOS light/dark switches and the accessibility display options.
    private func observeSystem() {
        let refresh: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.systemAppearanceChanged() }
        }
        systemObservers = [
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main, using: refresh),
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main, using: refresh),
        ]
    }

    private func systemAppearanceChanged() {
        let resolved = values.resolvedThemeName(systemIsDark: SystemDisplay.isDark)
        if values.themeName != resolved {
            values.themeName = resolved   // applies everything through didSet
        } else {
            refreshAppearance(configChanged: true)
        }
    }

    /// Rebuilds the palette and pushes terminal config after a system
    /// display option changed without the theme changing.
    private func refreshAppearance(configChanged: Bool) {
        Theme.palette = ThemePalette(theme: .named(values.themeName))
        themeKey = Self.makeThemeKey(values.themeName)
        if configChanged {
            OctetTerminalRuntime.updateConfig(overrides: values.rendererConfig + "\n" + Theme.octetShortcutUnbinds)
            refreshConfigProblems()
        }
        OctetTerminalRuntime.setColorScheme(dark: !TerminalTheme.named(values.themeName).isLight)
    }

    func resetToDefaults() {
        values = OctetSettings()
    }

    /// The range the Font size stepper and the View menu share.
    static let fontSizeRange: ClosedRange<Double> = 8...32

    /// View › Increase/Decrease Font Size: whole points, kept in range.
    func adjustFontSize(by delta: Double) {
        let size = (values.fontSize + delta).rounded()
        values.fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    func resetFontSize() {
        values.fontSize = OctetSettings().fontSize
    }

    func writeSessionConfig() {
        guard let sessionConfigPath else { return }
        if values.usesShellIntegration {
            // Written before the config points at it.
            _ = try? ShellIntegration.install(in: ShellIntegration.directory(support: EngineSession.supportDirectory),
                                              shell: values.realShell, login: values.shellMode != .nonLogin)
            writeAccountTable()
        }
        do {
            try values.sessionConfig.write(toFile: sessionConfigPath, atomically: true, encoding: .utf8)
            sessionConfigWriteProblem = nil
        } catch {
            sessionConfigWriteProblem = "Couldn't write \(sessionConfigPath): \(error.localizedDescription)"
        }
        refreshConfigProblems()
    }

    /// The folders' agent accounts, for the pane shell wrapper.
    func writeAccountTable() {
        let (profiles, assignments) = (values.accountProfiles, values.accountAssignments)
        let directory = ShellIntegration.directory(support: EngineSession.supportDirectory)
        DispatchQueue.global(qos: .utility).async {
            let table = ShellIntegration.accountTable(profiles: profiles, assignments: assignments) { folder in
                let text = (try? Git().run(["worktree", "list", "--porcelain"], in: folder)) ?? ""
                return WorktreeCleanup.parse(text).filter { !$0.isMain }.map(\.path)
            }
            ShellIntegration.writeAccountTable(table, in: directory)
        }
    }

    /// Re-reads what the terminal engine rejected.
    func refreshConfigProblems() {
        let problems = OctetTerminalRuntime.configErrors + [sessionConfigWriteProblem].compactMap { $0 }
        if problems != configProblems { configProblems = problems }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        mirrorForSubagentTabs()
    }

    /// Subagent tabs run `octet-cli`, which can't decode these settings; it
    /// reads this one value from the app's preferences by its own key.
    private func mirrorForSubagentTabs() {
        UserDefaults.standard.set(values.subagentTabClosing.seconds, forKey: SubagentWatch.closeDelayKey)
        UserDefaults.standard.set(values.agentSounds ? values.subagentFinishedSound : "",
                                  forKey: SubagentWatch.finishedSoundKey)
    }

    private func apply(from old: OctetSettings) {
        if values.keepAwake != old.keepAwake { SleepGuard.shared.update() }
        if values.globalHotkey != old.globalHotkey { GlobalHotkey.shared.apply(values.globalHotkey) }
        if !values.hotkeyDropDown, old.hotkeyDropDown { GlobalHotkey.shared.restoreDropDown() }
        if values.accountProfiles != old.accountProfiles || values.accountAssignments != old.accountAssignments {
            AccountProfiles.configure(profiles: values.accountProfiles, assignments: values.accountAssignments)
            writeAccountTable()
        }
        if values.importedTheme != old.importedTheme {
            TerminalTheme.imported = values.importedTheme
        }
        if values.themeName != old.themeName || values.importedTheme != old.importedTheme {
            Theme.palette = ThemePalette(theme: .named(values.themeName))
            themeKey = Self.makeThemeKey(values.themeName)
            OctetTerminalRuntime.setColorScheme(dark: !TerminalTheme.named(values.themeName).isLight)
        }
        if values.rendererConfig != old.rendererConfig {
            OctetTerminalRuntime.updateConfig(overrides: values.rendererConfig + "\n" + Theme.octetShortcutUnbinds)
            refreshConfigProblems()
        }
        if values.sessionConfig != old.sessionConfig {
            writeSessionConfig()
            // Coalesce slider drags into one reload.
            pendingSessionReload?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadSession?() }
            pendingSessionReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }
}
