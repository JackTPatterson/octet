import AppKit
import Foundation

/// Every user setting, grouped by the layer that applies it. Nothing is
/// duplicated across layers: Ghostty owns rendering and host input, herdr
/// owns panes, shells, scrollback, notifications and sessions, and Herd owns
/// its own window, sidebar, and recovery.
struct HerdSettings: Codable, Equatable {
    // MARK: General (Herd + herdr)
    var confirmQuit = true
    var newPaneDirectory: NewPaneDirectory = .follow
    var defaultShell = ""
    var shellMode: ShellMode = .auto

    // MARK: Appearance (Ghostty + herdr panes)
    var themeName = "Dark"
    /// Colours read from the user's terminal config, when they asked for it.
    var importedTheme: TerminalTheme?
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
    var paneBorders: PaneBorders = .auto
    var paneGaps = true
    var paneScrollbars = true

    // MARK: Terminal (Ghostty input + herdr panes)
    var scrollbackMegabytes: Double = 10
    var copyOnSelect = true
    var clipboardToasts = true
    var mouseScrollLines: Double = 3
    var optionAsAlt: OptionAsAlt = .off
    var hideMouseWhileTyping = true
    var pasteProtection = true
    var clipboardRead: ClipboardAccess = .ask
    var kittyGraphics = true

    // MARK: Agents & recovery (herdr + Herd)
    var notifications: NotificationDelivery = .banner
    var notificationDelaySeconds: Double = 1
    var agentSounds = true
    var resumeAgentsOnRestore = true
    var paneHistory = false
    var offerRecovery = true
    var slashMenu = true
    var slashRunsCommands = true
    var promptEditor = true
    var pasteImagesAsFiles = true
    var autoNameTabs = true
    var visualTwin = true
    var twinByDefault = false
    var showTips = true

    // MARK: Advanced (herdr)
    var worktreesDirectory = "~/.herd/worktrees"
    /// Where the engine used to put worktrees; kept when it holds any.
    static let legacyWorktreesDirectory = "~/.herdr/worktrees"
    var checkForHerdrUpdates = true
    var updateChannel: UpdateChannel = .stable
    var allowNestedHerdr = false

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
        /// Herd's own banner in the window's top right.
        case banner = "herdr"

        var title: String {
            switch self {
            case .off: "Off"
            case .system: "System notifications"
            case .banner: "In Herd"
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
        let defaults = HerdSettings()
        let container = try decoder.container(keyedBy: DynamicKey.self)
        func value<T: Decodable>(_ key: String, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: DynamicKey(key))) ?? fallback
        }
        confirmQuit = value("confirmQuit", defaults.confirmQuit)
        newPaneDirectory = value("newPaneDirectory", defaults.newPaneDirectory)
        defaultShell = value("defaultShell", defaults.defaultShell)
        shellMode = value("shellMode", defaults.shellMode)
        themeName = value("themeName", defaults.themeName)
        importedTheme = value("importedTheme", defaults.importedTheme)
        TerminalTheme.imported = importedTheme
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
        notifications = value("notifications", defaults.notifications)
        version = value("version", 1)
        if version < 2 {
            // "system" used to be the default, before Herd drew its own
            // agent banners; move that default on, keep a deliberate "off".
            if notifications == .system { notifications = .banner }
            version = Self.currentVersion
        }
        notificationDelaySeconds = value("notificationDelaySeconds", defaults.notificationDelaySeconds)
        agentSounds = value("agentSounds", defaults.agentSounds)
        resumeAgentsOnRestore = value("resumeAgentsOnRestore", defaults.resumeAgentsOnRestore)
        paneHistory = value("paneHistory", defaults.paneHistory)
        offerRecovery = value("offerRecovery", defaults.offerRecovery)
        slashMenu = value("slashMenu", defaults.slashMenu)
        slashRunsCommands = value("slashRunsCommands", defaults.slashRunsCommands)
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
        checkForHerdrUpdates = value("checkForHerdrUpdates", defaults.checkForHerdrUpdates)
        updateChannel = value("updateChannel", defaults.updateChannel)
        allowNestedHerdr = value("allowNestedHerdr", defaults.allowNestedHerdr)
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    // MARK: - Generated configs

    /// Ghostty config lines for the embedded renderer.
    var ghosttyConfig: String {
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
            "background-opacity = \(String(format: "%.2f", backgroundOpacity))",
            "background-blur = \(backgroundBlur && backgroundOpacity < 1)",
            "window-padding-x = \(padding.0)",
            // Top padding stays 0: Herd clips herdr's tab row from the top edge.
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

    /// herdr config for Herd's session. Herd's chrome replaces herdr's
    /// sidebar and tab row, so those stay fixed.
    var herdrConfig: String {
        let scrollbackBytes = Int(scrollbackMegabytes * 1_000_000)
        let theme = TerminalTheme.named(themeName)
        return """
        # Managed by Herd from Settings. Rewritten on launch and on every change;
        # edit ~/.config/herdr/config.toml for a standalone herdr instead.
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
        version_check = \(checkForHerdrUpdates)

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
        # Herd draws agent notices itself unless the system is doing it.
        delivery = "\(notifications == .system ? "system" : "off")"
        delay_seconds = \(Int(notificationDelaySeconds))

        # Herd shows its own clipboard toast; only one of the two should.
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
        allow_nested = \(allowNestedHerdr)
        """
    }

    private func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Loads, persists, and applies `HerdSettings`.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private static let key = "herd.settings.v1"

    @Published var values: HerdSettings {
        didSet {
            guard values != oldValue else { return }
            save()
            apply(from: oldValue)
        }
    }

    /// Set by the app once the herdr session is known.
    var herdrConfigPath: String?
    var reloadHerdr: (() -> Void)?

    private var pendingHerdrReload: DispatchWorkItem?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(HerdSettings.self, from: data) {
            values = decoded
        } else {
            values = HerdSettings()
        }
        Theme.palette = ThemePalette(theme: .named(values.themeName))
    }

    func resetToDefaults() {
        values = HerdSettings()
    }

    func writeHerdrConfig() {
        guard let herdrConfigPath else { return }
        try? values.herdrConfig.write(toFile: herdrConfigPath, atomically: true, encoding: .utf8)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func apply(from old: HerdSettings) {
        if values.importedTheme != old.importedTheme {
            TerminalTheme.imported = values.importedTheme
        }
        if values.themeName != old.themeName || values.importedTheme != old.importedTheme {
            Theme.palette = ThemePalette(theme: .named(values.themeName))
        }
        if values.ghosttyConfig != old.ghosttyConfig {
            HerdTerminalRuntime.updateConfig(overrides: values.ghosttyConfig + "\n" + Theme.herdShortcutUnbinds)
        }
        if values.herdrConfig != old.herdrConfig {
            writeHerdrConfig()
            // Coalesce slider drags into one reload.
            pendingHerdrReload?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadHerdr?() }
            pendingHerdrReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }
}
