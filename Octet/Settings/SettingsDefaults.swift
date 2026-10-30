import Foundation

extension OctetSettings {
    /// Every setting's built-in value, for Restore Defaults and each row's
    /// Reset to Default.
    static let defaults = OctetSettings()
}

/// One thing Restore Defaults can put back, named as the person knows it in
/// Settings. Several keys can share a name ("Theme" covers the scheme, both
/// picks and an imported theme) so the confirmation lists what they'd see
/// change, not field names.
struct SettingDefault {
    let label: String
    let isDefault: (OctetSettings) -> Bool
    let reset: (inout OctetSettings) -> Void

    init<V: Equatable>(_ label: String, _ key: WritableKeyPath<OctetSettings, V>) {
        self.label = label
        isDefault = { $0[keyPath: key] == OctetSettings.defaults[keyPath: key] }
        reset = { $0[keyPath: key] = OctetSettings.defaults[keyPath: key] }
    }

    init(_ label: String, _ parts: [SettingDefault]) {
        self.label = label
        isDefault = { values in parts.allSatisfy { $0.isDefault(values) } }
        reset = { values in parts.forEach { $0.reset(&values) } }
    }
}

/// What Settings › General's Restore Defaults covers, in page order. Left
/// out on purpose: things the person made rather than chose (accounts,
/// plugins, other Macs, the phone topic), which a reset would lose for good,
/// and status-bar bookkeeping that isn't a choice at all.
enum SettingsDefaults {
    static let all: [SettingDefault] = [
        // General
        .init("Default mode", \.defaultMode),
        .init("Confirm before quitting", \.confirmQuit),
        .init("Hotkey from any app", \.globalHotkey),
        .init("Drop down from the top", \.hotkeyDropDown),
        .init("Octet Notch", \.notch),
        .init("Start new tabs and workspaces in", \.newPaneDirectory),
        .init("Shell", \.defaultShell),
        .init("Shell startup mode", \.shellMode),
        .init("Sleep idle workspaces after", \.sleepIdleAfterDays),
        .init("Show tips", \.showTips),
        // Appearance
        .init("Theme", [
            .init("", \.matchSystemAppearance), .init("", \.themeName), .init("", \.lightThemeName),
            .init("", \.darkThemeName), .init("", \.importedTheme),
        ]),
        .init("Terminal font", \.fontFamily),
        .init("Interface font", \.interfaceFontFamily),
        .init("Font size", \.fontSize),
        .init("Line height", \.lineHeightPercent),
        .init("Thicken text", \.fontThicken),
        .init("Cursor shape", \.cursorStyle),
        .init("Cursor blink", \.cursorBlink),
        .init("Terminal opacity", \.backgroundOpacity),
        .init("Blur behind terminal", \.backgroundBlur),
        .init("Window padding", \.windowPadding),
        // Terminal
        .init("Scrollback per pane", \.scrollbackMegabytes),
        .init("Terminal text", \.textPosition),
        .init("Start new tabs with shortcuts", \.newTabSplash),
        .init("Copy on select", \.copyOnSelect),
        .init("Confirm copies", \.clipboardToasts),
        .init("Tidy text copied from agents", \.tidyAgentCopies),
        .init("Shell integration", \.shellIntegration),
        .init("Secure input at password prompts", \.secureInputAtPasswords),
        .init("Preview long pastes into agents", \.previewLongPastes),
        .init("Lines per scroll wheel notch", \.mouseScrollLines),
        .init("Use Option as Alt", \.optionAsAlt),
        .init("Hide mouse pointer while typing", \.hideMouseWhileTyping),
        .init("Warn before pasting risky text", \.pasteProtection),
        .init("Programs reading the clipboard", \.clipboardRead),
        .init("Inline images", \.kittyGraphics),
        .init("Open local links in the Browser plane", \.previewTerminalLinks),
        .init("Open them with a plain click", \.previewLinksOnPlainClick),
        .init("Offer to preview new servers", \.offerServerPreviews),
        .init("Let agents read the sidebar terminal", \.agentsReadSidebarTerminal),
        .init("Let agents suggest commands", \.agentsSuggestSidebarCommands),
        // Status bar
        .init("Status bar", [.init("", \.repoContextBar), .init("", \.statusBarChips), .init("", \.statusBarCustomized)]),
        // Agents & Recovery
        .init("Quick answers", \.agentQuickAnswers),
        .init("Agent notifications", \.notifications),
        .init("Wait before notifying", \.notificationDelaySeconds),
        .init("Recap when you come back", \.recap),
        .init("Away for at least", \.recapAfterMinutes),
        .init("Play sounds", \.agentSounds),
        .init("Agent finished", \.notifyFinished),
        .init("Agent needs input", \.notifyNeedsInput),
        .init("Agent failed", \.notifyFailed),
        .init("Suppress while the agent is on screen", \.notifySuppressWhileVisible),
        .init("Terminal bell", \.terminalBell),
        .init("Default agent", \.defaultAgent),
        .init("Subagent finished sound", \.subagentFinishedSound),
        .init("Let agents set waits", \.agentsSetWaits),
        .init("Offer a wait from a reply", \.suggestWaits),
        .init("Pause all check-ins", \.checkInsPaused),
        .init("New check-ins", \.checkInDefaultMode),
        .init("Say when a session looks stalled", [.init("", \.stallDetection), .init("", \.stallHours)]),
        .init("Quiet hours", [.init("", \.quietHours), .init("", \.quietStartMinute), .init("", \.quietEndMinute)]),
        .init("Remind me when Octet is closed", \.checkInsNotifyWhenClosed),
        .init("Resume agents after a restart", \.resumeAgentsOnRestore),
        .init("Offer to recover lost sessions", \.offerRecovery),
        .init("Move agents to the project they work in", \.relocateAgents),
        .init("Keep the Mac awake while agents work", \.keepAwake),
        .init("Checkpoint before each agent turn", \.checkpointTurns),
        .init("Keep closed tabs running", \.keepClosedTabsMinutes),
        .init("Ask before stopping running terminals", \.confirmCloseRunning),
        .init("Remote Control for Claude conversations", \.claudeRemoteControl),
        .init("When you run an agent in a terminal", \.agentOpening),
        .init("Offer Octet's view over a running agent", \.agentBanner),
        .init("Octet's command line", \.promptEditor),
        .init("Octet's Tab completions", \.promptCompletions),
        .init("Vim keys in the editor", \.vimMode),
        .init("Show agent cursors", \.showAgentCursors),
        .init("Accept a suggestion with", \.suggestionAcceptKey),
        .init("Paste images as files", \.pasteImagesAsFiles),
        .init("Visual twin", \.visualTwin),
        .init("Open the twin for new agents", \.twinByDefault),
        .init("Name tabs after their work", \.autoNameTabs),
        .init("Name workspaces after their work", \.autoNameWorkspaces),
        .init("Hold Space to talk", \.holdSpaceToTalk),
        .init("Restore recent terminal output", \.paneHistory),
        .init("Read live usage from your Claude account", \.readClaudeAccountUsage),
        .init("Prompt for agent updates", \.checkForAgentUpdates),
        .init("When a subagent finishes", \.subagentTabClosing),
        // Keyboard
        .init("Keyboard shortcuts", \.shortcutOverrides),
        // Advanced
        .init("Worktree folder", \.worktreesDirectory),
        .init("Set up new worktrees", \.worktreeSetup),
        .init("Allow a nested session", \.allowNestedSessions),
    ]

    /// The names of everything that differs from its default, for the
    /// confirmation and to disable the button when there's nothing to do.
    static func changed(in values: OctetSettings) -> [String] {
        all.filter { !$0.isDefault(values) }.map(\.label)
    }

    /// `values` with everything in `all` put back; the rest kept.
    static func restored(_ values: OctetSettings) -> OctetSettings {
        var copy = values
        for entry in all where !entry.isDefault(copy) { entry.reset(&copy) }
        return copy
    }
}
