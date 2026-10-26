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
    /// The Octet Notch: an island at the top of the screen (see Octet/Notch).
    var notch = NotchSettings()
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
    /// Octet's own text: the sidebar, tabs, panels and settings. Empty is
    /// the system font.
    var interfaceFontFamily = ""
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
    /// Off: the split's rounded cards draw its separation, and the engine's
    /// own border lines would show through them as the terminal resizes.
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
    /// ⌘-clicking a localhost or LAN address in a terminal opens it in the
    /// Browser plane rather than the system browser.
    var previewTerminalLinks = true
    /// …and so does a plain click, with `previewTerminalLinks` on.
    var previewLinksOnPlainClick = false
    /// A card offering to preview a dev server that starts in the
    /// workspace in front.
    var offerServerPreviews = true

    // MARK: Agents & recovery (session server + Octet)
    var notifications: NotificationDelivery = .banner
    var notificationDelaySeconds: Double = 1
    /// Recap: a card of what every agent did while you were away, when you
    /// come back after at least `recapAfterMinutes`.
    var recap = true
    var recapAfterMinutes: Double = 5
    var agentSounds = true
    /// Which agent notices to raise: one that finished, one waiting on
    /// you, one whose turn failed (see AgentNoticeFilter).
    var notifyFinished = true
    var notifyNeedsInput = true
    var notifyFailed = true
    /// No notice for an agent whose tab is on screen while Octet is in
    /// front; off, every one is announced.
    var notifySuppressWhileVisible = true
    /// The terminal bell (BEL): a sound, or a bounce when Octet is behind.
    var terminalBell = true
    /// The agent a new conversation starts with when none is named
    /// (AgentSession.Engine's raw value).
    var defaultAgent = "claude"
    var resumeAgentsOnRestore = true
    /// Restart an agent in the repository its commands keep `cd`ing into,
    /// with its conversation resumed. Off by default: it restarts agents.
    var relocateAgents = false
    var paneHistory = false
    /// Read Claude's allowance from the account itself: the OAuth token Claude
    /// Code keeps in the login keychain, sent to the endpoint Claude Code's own
    /// usage display calls. Off by default because it touches another app's
    /// credential and an endpoint Anthropic doesn't document; without it the
    /// chip reads Claude Code's cache and any conversation Octet runs.
    var readClaudeAccountUsage = false
    /// Settings › Other Macs: pair with Octets on the network so agents on
    /// each can message the other's and hand them tasks. Off by default.
    var peersEnabled = false
    /// Agent Delegation: agents here can ask each other to review or work.
    var delegationEnabled = false
    /// Browser Control: agents drive the Browser plane with chrome-devtools
    /// MCP's tools. Off by default: the plane holds the person's sign-ins.
    var browserControlEnabled = false
    /// Agents can read the sidebar terminal (read only): a socket the app
    /// listens on and an MCP server in each agent's settings, both only
    /// while this is on. Off by default: a terminal can hold secrets.
    var agentsReadIssues = false
    var agentsReadSidebarTerminal = false
    var agentsSuggestSidebarCommands = false
    /// Waits: agents can set one (an MCP tool and `octet-cli wait`) when work
    /// can't go on until something outside it happens. On by default: it
    /// only writes a note Octet checks, and is shown in the sidebar.
    var agentsSetWaits = true
    /// Offer to turn "once X happens, we can Y" in an agent's reply into a wait.
    var suggestWaits = true
    /// Long-haul check-ins: nothing comes round while this is on.
    var checkInsPaused = false
    /// What a new check-in does by default: `CheckInMode`.
    var checkInDefaultMode = "both"
    /// Say so when a session marked working has done nothing for this long.
    var stallDetection = true
    var stallHours: Double = 6
    /// No prompts sent to agents during these hours; they wait for the end.
    var quietHours = false
    var quietStartMinute = 22 * 60
    var quietEndMinute = 7 * 60
    /// Schedule macOS notifications for upcoming check-ins, so the reminder
    /// comes even when Octet isn't running.
    var checkInsNotifyWhenClosed = true
    /// Put Idle workspaces to sleep (terminals closed, brought back as they
    /// were) after this many days unused; zero never does. Only those where
    /// nothing would be lost: no agent working, nothing running, no server.
    var sleepIdleAfterDays = 14
    /// When to ask before a delegation starts: `DelegationCenter.Approval`.
    var delegationApproval = "reviews"
    /// What other Macs call this one; empty is the computer's name.
    var peerName = ""
    var offerRecovery = true
    /// How long a tab closed with something running in it keeps running,
    /// out of sight, so it can be reopened. Zero closes at once.
    var keepClosedTabsMinutes: Double = 30
    /// Ask before closing a tab, pane or drawer terminal when that would
    /// stop an agent or a running command.
    var confirmCloseRunning = true
    /// Keep the Mac from idle-sleeping while an agent is working.
    var keepAwake: KeepAwake.Mode = .pluggedIn
    /// Snapshot an agent's working tree as it starts each turn, to undo it.
    var checkpointTurns = true
    /// Extra agent sign-ins, and the project folders that use them.
    var accountProfiles: [AccountProfile] = []
    var accountAssignments: [AccountAssignment] = []
    /// Credential profiles (Supabase, GitHub…): environment per project folder. Secrets are in the Keychain.
    var credentialProfiles: [CredentialProfile] = []
    var credentialAssignments: [CredentialAssignment] = []
    /// Turn on Remote Control for every Claude conversation in Octet, so it
    /// can be continued from claude.ai or the Claude app.
    var claudeRemoteControl = false
    /// What typing `claude`, `codex` or `opencode` on its own at a prompt
    /// opens: the agent's interface in the terminal, or Octet's conversation.
    var agentOpening: AgentOpening = .terminal
    /// Octet plugins turned on by hand (installed ones start off) and
    /// bundled ones turned off (they start on), by id.
    var enabledPlugins: [String] = []
    /// Install newer versions of registry plugins as they're published.
    var autoUpdatePlugins = true
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
    /// Vim's keys in the editor: Normal, Insert and Visual modes, operators and motions.
    var vimMode = false
    /// A cursor for each agent working in a file beside you or driving the Browser plane.
    var showAgentCursors = true
    var suggestionAcceptKey: SuggestionAcceptKey = .right
    var pasteImagesAsFiles = true
    var autoNameTabs = true
    /// Workspaces take the name of the work in them until renamed by hand.
    var autoNameWorkspaces = true
    /// Holding Space in a conversation's message box talks instead of typing.
    var holdSpaceToTalk = true
    var visualTwin = true
    // Native agent opening is controlled separately; terminal sessions stay in
    // their own interface unless the user explicitly enables the twin.
    var twinByDefault = false
    var showTips = true

    // MARK: Keyboard (Octet's menus + renderer pass-through)
    /// Settings › Keyboard: shortcut id to `ShortcutBinding.encoded`, with an
    /// empty string for one the person unassigned. Only changes are kept,
    /// so a new default reaches everyone who hasn't chosen otherwise.
    var shortcutOverrides: [String: String] = [:]

    // MARK: Advanced (session server)
    var worktreesDirectory = "~/.octet/worktrees"
    /// Copy the main checkout's env files into a new worktree and run its
    /// `.octet/setup` (or `conductor.json` setup) there.
    var worktreeSetup = true
    /// Where the engine used to put worktrees; kept when it holds any.
    static let legacyWorktreesDirectory = EngineProtocol.legacyWorktreesDirectory
    static let doubleDingMigrationKey = "octet.subagentSound.movedToDoubleDing"
    /// No longer used: the engine updates with the app (see `[update]` in
    /// `sessionConfig`). Kept, and still read and saved, for compatibility
    /// with settings older versions stored.
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
        // Tells the store what loading changed, so it saves only when needed.
        let report = decoder.userInfo[LoadReport.key] as? LoadReport
        func value<T: Decodable>(_ key: String, _ fallback: T) -> T {
            do {
                return try container.decodeIfPresent(T.self, forKey: DynamicKey(key)) ?? fallback
            } catch {
                report?.unreadableKeys.append(key)
                return fallback
            }
        }
        /// A list keeps the entries it can read; one bad one doesn't lose the rest.
        func list<T: Decodable>(_ key: String, _ fallback: [T]) -> [T] {
            do {
                guard let lossy = try container.decodeIfPresent(LossyList<T>.self, forKey: DynamicKey(key)) else { return fallback }
                if lossy.dropped > 0 { report?.unreadableKeys.append(key) }
                return lossy.elements
            } catch {
                report?.unreadableKeys.append(key)
                return fallback
            }
        }
        for legacy in [Self.legacyUpdateCheckKey, Self.legacyNestedKey] where container.contains(DynamicKey(legacy)) {
            report?.migrated = true
        }
        confirmQuit = value("confirmQuit", defaults.confirmQuit)
        globalHotkey = value("globalHotkey", defaults.globalHotkey)
        hotkeyDropDown = value("hotkeyDropDown", defaults.hotkeyDropDown)
        notch = value("notch", defaults.notch)
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
        interfaceFontFamily = value("interfaceFontFamily", defaults.interfaceFontFamily)
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
        previewTerminalLinks = value("previewTerminalLinks", defaults.previewTerminalLinks)
        previewLinksOnPlainClick = value("previewLinksOnPlainClick", defaults.previewLinksOnPlainClick)
        offerServerPreviews = value("offerServerPreviews", defaults.offerServerPreviews)
        let storedNotifications = value("notifications", "")
        notifications = NotificationDelivery(stored: storedNotifications) ?? defaults.notifications
        if !storedNotifications.isEmpty, NotificationDelivery(stored: storedNotifications) == nil {
            report?.unreadableKeys.append("notifications")
        }
        version = value("version", 1)
        if version < 2 {
            // "system" used to be the default, before Octet drew its own
            // agent banners. Every key was saved, so a stored "system" can't
            // be told apart from a deliberate pick: keep it as chosen.
            version = Self.currentVersion
            report?.migrated = true
        }
        notificationDelaySeconds = value("notificationDelaySeconds", defaults.notificationDelaySeconds)
        agentSounds = value("agentSounds", defaults.agentSounds)
        notifyFinished = value("notifyFinished", defaults.notifyFinished)
        notifyNeedsInput = value("notifyNeedsInput", defaults.notifyNeedsInput)
        notifyFailed = value("notifyFailed", defaults.notifyFailed)
        notifySuppressWhileVisible = value("notifySuppressWhileVisible", defaults.notifySuppressWhileVisible)
        terminalBell = value("terminalBell", defaults.terminalBell)
        defaultAgent = value("defaultAgent", defaults.defaultAgent)
        recap = value("recap", defaults.recap)
        recapAfterMinutes = value("recapAfterMinutes", defaults.recapAfterMinutes)
        resumeAgentsOnRestore = value("resumeAgentsOnRestore", defaults.resumeAgentsOnRestore)
        relocateAgents = value("relocateAgents", defaults.relocateAgents)
        paneHistory = value("paneHistory", defaults.paneHistory)
        readClaudeAccountUsage = value("readClaudeAccountUsage", defaults.readClaudeAccountUsage)
        peersEnabled = value("peersEnabled", defaults.peersEnabled)
        delegationEnabled = value("delegationEnabled", defaults.delegationEnabled)
        browserControlEnabled = value("browserControlEnabled", defaults.browserControlEnabled)
        agentsReadIssues = value("agentsReadIssues", defaults.agentsReadIssues)
        agentsReadSidebarTerminal = value("agentsReadSidebarTerminal", defaults.agentsReadSidebarTerminal)
        agentsSuggestSidebarCommands = value("agentsSuggestSidebarCommands", defaults.agentsSuggestSidebarCommands)
        agentsSetWaits = value("agentsSetWaits", defaults.agentsSetWaits)
        suggestWaits = value("suggestWaits", defaults.suggestWaits)
        checkInsPaused = value("checkInsPaused", defaults.checkInsPaused)
        checkInDefaultMode = value("checkInDefaultMode", defaults.checkInDefaultMode)
        stallDetection = value("stallDetection", defaults.stallDetection)
        stallHours = value("stallHours", defaults.stallHours)
        quietHours = value("quietHours", defaults.quietHours)
        quietStartMinute = value("quietStartMinute", defaults.quietStartMinute)
        quietEndMinute = value("quietEndMinute", defaults.quietEndMinute)
        checkInsNotifyWhenClosed = value("checkInsNotifyWhenClosed", defaults.checkInsNotifyWhenClosed)
        sleepIdleAfterDays = value("sleepIdleAfterDays", defaults.sleepIdleAfterDays)
        delegationApproval = value("delegationApproval", defaults.delegationApproval)
        peerName = value("peerName", defaults.peerName)
        offerRecovery = value("offerRecovery", defaults.offerRecovery)
        keepClosedTabsMinutes = value("keepClosedTabsMinutes", defaults.keepClosedTabsMinutes)
        confirmCloseRunning = value("confirmCloseRunning", defaults.confirmCloseRunning)
        keepAwake = value("keepAwake", defaults.keepAwake)
        checkpointTurns = value("checkpointTurns", defaults.checkpointTurns)
        accountProfiles = list("accountProfiles", defaults.accountProfiles)
        accountAssignments = list("accountAssignments", defaults.accountAssignments)
        credentialProfiles = list("credentialProfiles", defaults.credentialProfiles)
        credentialAssignments = list("credentialAssignments", defaults.credentialAssignments)
        claudeRemoteControl = value("claudeRemoteControl", defaults.claudeRemoteControl)
        agentOpening = value("agentOpening", defaults.agentOpening)
        subagentTabClosing = value("subagentTabClosing", defaults.subagentTabClosing)
        subagentFinishedSound = value("subagentFinishedSound", defaults.subagentFinishedSound)
        // Glass was the default before Octet had a ding of its own: move off
        // it once, and leave it be if chosen again afterwards.
        if !UserDefaults.standard.bool(forKey: Self.doubleDingMigrationKey) {
            UserDefaults.standard.set(true, forKey: Self.doubleDingMigrationKey)
            if subagentFinishedSound == "Glass" {
                subagentFinishedSound = defaults.subagentFinishedSound
                report?.migrated = true
            }
        }
        enabledPlugins = value("enabledPlugins", defaults.enabledPlugins)
        autoUpdatePlugins = value("autoUpdatePlugins", defaults.autoUpdatePlugins)
        disabledPlugins = value("disabledPlugins", defaults.disabledPlugins)
        agentBanner = value("agentBanner", defaults.agentBanner)
        agentQuickAnswers = value("agentQuickAnswers", defaults.agentQuickAnswers)
        checkForAgentUpdates = value("checkForAgentUpdates", defaults.checkForAgentUpdates)
        promptEditor = value("promptEditor", defaults.promptEditor)
        promptCompletions = value("promptCompletions", defaults.promptCompletions)
        vimMode = value("vimMode", defaults.vimMode)
        showAgentCursors = value("showAgentCursors", defaults.showAgentCursors)
        suggestionAcceptKey = value("suggestionAcceptKey", defaults.suggestionAcceptKey)
        pasteImagesAsFiles = value("pasteImagesAsFiles", defaults.pasteImagesAsFiles)
        autoNameTabs = value("autoNameTabs", defaults.autoNameTabs)
        autoNameWorkspaces = value("autoNameWorkspaces", defaults.autoNameWorkspaces)
        holdSpaceToTalk = value("holdSpaceToTalk", defaults.holdSpaceToTalk)
        visualTwin = value("visualTwin", defaults.visualTwin)
        twinByDefault = value("twinByDefault", defaults.twinByDefault)
        showTips = value("showTips", defaults.showTips)
        shortcutOverrides = value("shortcutOverrides", defaults.shortcutOverrides)
        worktreesDirectory = value("worktreesDirectory", defaults.worktreesDirectory)
        worktreeSetup = value("worktreeSetup", defaults.worktreeSetup)
        // Move off the old default unless worktrees already live there.
        if worktreesDirectory == Self.legacyWorktreesDirectory,
           !FileManager.default.fileExists(atPath: NSString(string: Self.legacyWorktreesDirectory).expandingTildeInPath) {
            worktreesDirectory = defaults.worktreesDirectory
            report?.migrated = true
        }
        checkForEngineUpdates = value("checkForEngineUpdates", value(Self.legacyUpdateCheckKey, defaults.checkForEngineUpdates))
        updateChannel = value("updateChannel", defaults.updateChannel)
        allowNestedSessions = value("allowNestedSessions", value(Self.legacyNestedKey, defaults.allowNestedSessions))
    }

    /// Keys earlier versions stored these two settings under; read once so
    /// saved choices survive, then written back under the new names.
    private static let legacyUpdateCheckKey = "checkForHerdrUpdates"
    private static let legacyNestedKey = "allowNestedHerdr"

    /// What decoding had to do: settings it couldn't read (left at their
    /// defaults) and older values it rewrote. Passed in through `userInfo`.
    final class LoadReport {
        static let key = CodingUserInfoKey(rawValue: "octet.settings.loadReport")!
        var unreadableKeys: [String] = []
        var migrated = false
    }

    /// An array decoded entry by entry, skipping the ones that don't decode.
    private struct LossyList<Element: Decodable>: Decodable {
        var elements: [Element] = []
        var dropped = 0

        private struct Skip: Decodable {
            init(from decoder: Decoder) {}
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            while !container.isAtEnd {
                if let element = try? container.decode(Element.self) {
                    elements.append(element)
                } else {
                    // Step past the bad entry; a failed decode doesn't move on.
                    guard (try? container.decode(Skip.self)) != nil else { throw DecodingError.dataCorruptedError(
                        in: container, debugDescription: "Couldn't step past a bad entry") }
                    dropped += 1
                }
            }
        }
    }

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
            // Each pane's terminal scrolls its own scrollback now.
            "mouse-scroll-multiplier = discrete:\(Int(mouseScrollLines))",
            "copy-on-select = \(copyOnSelect ? "clipboard" : "false")",
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
            "window-padding-y = \(padding.1)",
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

    /// Session server config for Octet's session: what the engine itself
    /// does with panes. Octet draws them and all the chrome around them.
    var sessionConfig: String {
        let scrollbackBytes = Int(scrollbackMegabytes * 1_000_000)
        return """
        # Managed by Octet from Settings. Rewritten on launch and on every change.

        [theme]
        name = "terminal"

        [terminal]
        default_shell = \(tomlString(paneShell))
        shell_mode = "\(shellMode.rawValue)"
        new_cwd = "\(newPaneDirectory.rawValue)"
        kitty_graphics = \(kittyGraphics)

        # Octet ships its own patched engine and updates it with the app: the
        # engine's own check (curl to herdr.dev) would only ever offer a stock
        # build without Octet's patches.
        [update]
        channel = "stable"
        version_check = false

        [ui]
        confirm_close = false
        # Octet draws each pane's card, gutters and scrollbar: the engine
        # keeps no cells back for its own, so a pane is sized as Octet's grid.
        pane_borders = false
        pane_gaps = false
        pane_scrollbars = false

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
            // Set here, this doesn't come back through didSet: carry on to
            // save and apply it in this pass.
            if values.themeName != resolved {
                values.themeName = resolved
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
        let stored = UserDefaults.standard.data(forKey: Self.key)
        let loaded = Self.load(stored)
        values = loaded.values
        // Something didn't read (a newer build's value, a damaged entry):
        // keep the original aside once, since the next change saves over it.
        if loaded.unreadable, let stored, UserDefaults.standard.data(forKey: Self.unreadableBackupKey) == nil {
            UserDefaults.standard.set(stored, forKey: Self.unreadableBackupKey)
        }
        AccountProfiles.configure(profiles: values.accountProfiles, assignments: values.accountAssignments)
        CredentialProfiles.readSecret = { CredentialKeychain.get($0) }
        CredentialProfiles.configure(profiles: values.credentialProfiles, assignments: values.credentialAssignments)
        // Before the app builds its menus and terminal config from them.
        ShortcutOverrides.shared.update(values.shortcutOverrides)
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
        Theme.interfaceFamily = values.interfaceFontFamily
        themeKey = Self.makeThemeKey(values.themeName)
        observeSystem()
        // Rewrites settings read under older key names with the current ones.
        if debugThemeOverride == nil, loaded.shouldSave { save() }
        mirrorForSubagentTabs()
    }

    private static let unreadableBackupKey = "octet.settings.v1.unreadable"

    /// Decodes stored settings. Saving is only worth it when loading
    /// rewrote something (older key names, a migrated value), and never
    /// when part of it couldn't be read: that would replace what's stored
    /// with defaults for good.
    nonisolated static func load(_ data: Data?) -> (values: OctetSettings, shouldSave: Bool, unreadable: Bool) {
        guard let data else { return (OctetSettings(), false, false) }
        let report = OctetSettings.LoadReport()
        let decoder = JSONDecoder()
        decoder.userInfo[OctetSettings.LoadReport.key] = report
        guard let decoded = try? decoder.decode(OctetSettings.self, from: data) else {
            return (OctetSettings(), false, true)
        }
        let unreadable = !report.unreadableKeys.isEmpty
        return (decoded, report.migrated && !unreadable, unreadable)
    }

    private static func makeThemeKey(_ themeName: String) -> String {
        "\(themeName)|\(SystemDisplay.increaseContrast)|\(SystemDisplay.reduceTransparency)|\(Theme.interfaceFamily)"
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
            // Back from editing the terminal config: follow what changed.
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshImportedTheme() }
            },
        ]
        refreshImportedTheme()
    }

    /// An imported theme follows its terminal config: re-read on launch and
    /// whenever Octet comes back to the front, so an edit there (a new
    /// cursor colour, a different theme) shows without re-importing.
    private func refreshImportedTheme() {
        guard let current = values.importedTheme,
              let fresh = TerminalThemeImport.importFromConfig(),
              fresh.name == current.name, fresh != current else { return }
        values.importedTheme = fresh
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

    /// Advanced › Reset: the same reset as General's Restore Defaults, so
    /// accounts, plugins, paired Macs and the like survive it.
    func resetToDefaults() {
        values = SettingsDefaults.restored(values)
    }

    /// The range the Font size stepper and the View menu share.
    static let fontSizeRange: ClosedRange<Double> = 8...32

    /// What the zoom keys just did, for the on-screen indicator.
    struct ZoomIndicator: Equatable {
        let id = UUID()
        let size: Double
        let atDefault: Bool
        let atLimit: Bool
    }
    @Published private(set) var zoomIndicator: ZoomIndicator?
    /// The size the keys have asked for, applied once they pause so holding
    /// ⌘+ reflows the terminal once, not on every step.
    private var targetFontSize: Double?
    private var applyFontSize: DispatchWorkItem?
    private var hideZoom: DispatchWorkItem?

    /// View › Increase/Decrease Font Size: whole points, kept in range.
    func adjustFontSize(by delta: Double) {
        let requested = ((targetFontSize ?? values.fontSize) + delta).rounded()
        let size = min(max(requested, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        setZoom(size, atLimit: size != requested)
    }

    func resetFontSize() {
        setZoom(OctetSettings().fontSize, atLimit: false)
    }

    private func setZoom(_ size: Double, atLimit: Bool) {
        targetFontSize = size
        zoomIndicator = ZoomIndicator(size: size, atDefault: size == OctetSettings().fontSize, atLimit: atLimit)
        applyFontSize?.cancel()
        let apply = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let size = self.targetFontSize else { return }
                self.targetFontSize = nil
                self.values.fontSize = size
            }
        }
        applyFontSize = apply
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: apply)
        hideZoom?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.zoomIndicator = nil }
        }
        hideZoom = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hide)
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
            // Unchanged, as it is most launches: left alone.
            let config = values.sessionConfig
            if (try? String(contentsOfFile: sessionConfigPath, encoding: .utf8)) != config {
                try config.write(toFile: sessionConfigPath, atomically: true, encoding: .utf8)
            }
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
        if values.notch != old.notch { NotchController.shared.apply() }
        // Each feature's tools go into the agents' own settings only while it's on.
        if values.peersEnabled != old.peersEnabled {
            PeerCenter.shared.apply()
            AgentMCPInstaller.shared.sync(server: PeerMCP.serverName)
        }
        if values.delegationEnabled != old.delegationEnabled {
            DelegationCenter.shared.apply()
            AgentMCPInstaller.shared.sync(server: DelegationMCP.serverName)
        }
        if values.browserControlEnabled != old.browserControlEnabled {
            BrowserAgentCenter.shared.apply()
            AgentMCPInstaller.shared.sync(server: BrowserMCP.serverName)
        }
        if values.agentsSetWaits != old.agentsSetWaits {
            WaitCenter.shared.applyServer()
            AgentMCPInstaller.shared.sync(server: WaitMCP.serverName)
        }
        if values.checkInsPaused != old.checkInsPaused || values.checkInsNotifyWhenClosed != old.checkInsNotifyWhenClosed {
            CheckInCenter.shared.syncNotifications()
        }
        if values.agentsReadIssues != old.agentsReadIssues {
            AgentMCPInstaller.shared.sync(server: IssueMCP.serverName)
        }
        if values.agentsReadSidebarTerminal != old.agentsReadSidebarTerminal
            || values.agentsSuggestSidebarCommands != old.agentsSuggestSidebarCommands {
            TerminalAccessCenter.shared.apply()
            AgentMCPInstaller.shared.sync(server: TerminalMCP.serverName)
        }
        // A new name is advertised by starting again.
        if values.peerName != old.peerName, values.peersEnabled { PeerCenter.shared.restart() }
        if !values.hotkeyDropDown, old.hotkeyDropDown { GlobalHotkey.shared.restoreDropDown() }
        if values.accountProfiles != old.accountProfiles || values.accountAssignments != old.accountAssignments {
            AccountProfiles.configure(profiles: values.accountProfiles, assignments: values.accountAssignments)
            writeAccountTable()
        }
        if values.credentialProfiles != old.credentialProfiles || values.credentialAssignments != old.credentialAssignments {
            CredentialProfiles.configure(profiles: values.credentialProfiles, assignments: values.credentialAssignments)
        }
        if values.importedTheme != old.importedTheme {
            TerminalTheme.imported = values.importedTheme
        }
        if values.interfaceFontFamily != old.interfaceFontFamily {
            // Views read Theme's fonts as they draw; a new key redraws them all.
            Theme.interfaceFamily = values.interfaceFontFamily
            themeKey = Self.makeThemeKey(values.themeName)
        }
        if values.themeName != old.themeName || values.importedTheme != old.importedTheme {
            Theme.palette = ThemePalette(theme: .named(values.themeName))
            themeKey = Self.makeThemeKey(values.themeName)
            OctetTerminalRuntime.setColorScheme(dark: !TerminalTheme.named(values.themeName).isLight)
        }
        if values.shortcutOverrides != old.shortcutOverrides {
            // Before the terminal config below, which is derived from it.
            ShortcutOverrides.shared.update(values.shortcutOverrides)
        }
        // A rebound shortcut changes which keys the terminal lets through to
        // the menus, so it's reapplied live like any renderer setting.
        if values.rendererConfig != old.rendererConfig || values.shortcutOverrides != old.shortcutOverrides {
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
