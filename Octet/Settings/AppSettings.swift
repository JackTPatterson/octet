import AppKit
import Foundation

/// Every user setting, grouped by the layer that applies it. Nothing is
/// duplicated across layers: the renderer owns drawing and host input, the
/// session server owns panes, shells, scrollback, notifications and sessions, and Octet owns
/// its own window, sidebar, and recovery.
struct OctetSettings: Codable, Equatable {
    // MARK: General (Octet + session server)
    var confirmQuit = true
    var newPaneDirectory: NewPaneDirectory = .follow
    var defaultShell = ""
    var shellMode: ShellMode = .auto

    // MARK: Appearance (renderer + session server panes)
    var themeName = "Dark"
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

    // MARK: Terminal (renderer input + session server panes)
    var scrollbackMegabytes: Double = 10
    var copyOnSelect = true
    var clipboardToasts = true
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
    var promptEditor = true
    var pasteImagesAsFiles = true
    var autoNameTabs = true
    var showTips = true

    // MARK: Advanced (session server)
    var worktreesDirectory = "~/.octet/worktrees"
    /// Where the engine used to put worktrees; kept when it holds any.
    static let legacyWorktreesDirectory = EngineProtocol.legacyWorktreesDirectory
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
        newPaneDirectory = value("newPaneDirectory", defaults.newPaneDirectory)
        defaultShell = value("defaultShell", defaults.defaultShell)
        shellMode = value("shellMode", defaults.shellMode)
        themeName = value("themeName", defaults.themeName)
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
        scrollbackMegabytes = value("scrollbackMegabytes", defaults.scrollbackMegabytes)
        copyOnSelect = value("copyOnSelect", defaults.copyOnSelect)
        clipboardToasts = value("clipboardToasts", defaults.clipboardToasts)
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
        promptEditor = value("promptEditor", defaults.promptEditor)
        pasteImagesAsFiles = value("pasteImagesAsFiles", defaults.pasteImagesAsFiles)
        autoNameTabs = value("autoNameTabs", defaults.autoNameTabs)
        showTips = value("showTips", defaults.showTips)
        worktreesDirectory = value("worktreesDirectory", defaults.worktreesDirectory)
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
        let padding: (Int, Int) = switch windowPadding {
        case .compact: (4, 2)
        case .normal: (10, 6)
        case .roomy: (18, 12)
        }
        var lines = [
            "background = \(theme.background)",
            "foreground = \(theme.foreground)",
            "cursor-color = \(theme.accent)",
            "selection-background = \(theme.accent)",
            "selection-foreground = \(theme.background)",
            "font-size = \(Int(fontSize))",
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
            "clipboard-paste-protection = \(pasteProtection)",
            "clipboard-read = \(clipboardRead.rawValue)",
        ]
        if !fontFamily.isEmpty { lines.append("font-family = \"\(fontFamily)\"") }
        for (index, color) in theme.ansi.enumerated() {
            lines.append("palette = \(index)=#\(color)")
        }
        return lines.joined(separator: "\n")
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
        default_shell = \(tomlString(defaultShell))
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
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(OctetSettings.self, from: data) {
            values = decoded
        } else {
            values = OctetSettings()
        }
        values.themeName = values.resolvedThemeName(systemIsDark: SystemDisplay.isDark)
        Theme.palette = ThemePalette(theme: .named(values.themeName))
        themeKey = Self.makeThemeKey(values.themeName)
        observeSystem()
        // Rewrites settings read under older key names with the current ones.
        save()
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
        do {
            try values.sessionConfig.write(toFile: sessionConfigPath, atomically: true, encoding: .utf8)
            sessionConfigWriteProblem = nil
        } catch {
            sessionConfigWriteProblem = "Couldn't write \(sessionConfigPath): \(error.localizedDescription)"
        }
        refreshConfigProblems()
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
    }

    private func apply(from old: OctetSettings) {
        if values.themeName != old.themeName {
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
