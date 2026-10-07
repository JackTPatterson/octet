import Foundation

/// One set of instructions for every agent. Codex, OpenCode and Pi read
/// `AGENTS.md`; Claude Code reads `CLAUDE.md` and not `AGENTS.md`. A project
/// with only one of them leaves the other agents without its instructions,
/// and one with both drifts. The fix is one file the others import: the
/// instructions in `AGENTS.md`, and a `CLAUDE.md` that is just `@AGENTS.md`.
enum AgentInstructions {
    /// The two files' contents, where there are any.
    struct Files: Equatable {
        var agents: String?
        var claude: String?
        /// `CLAUDE.md` is a symbolic link to `AGENTS.md`.
        var claudeLinksToAgents = false

        init(agents: String? = nil, claude: String? = nil, claudeLinksToAgents: Bool = false) {
            self.agents = agents
            self.claude = claude
            self.claudeLinksToAgents = claudeLinksToAgents
        }
    }

    enum State: Equatable {
        /// Neither file, or nothing in them.
        case none
        /// Only `AGENTS.md`: Claude Code doesn't see it.
        case agentsOnly
        /// Only `CLAUDE.md`: Codex, OpenCode and Pi don't see it.
        case claudeOnly
        /// `CLAUDE.md` pulls in `AGENTS.md`, or is a link to it.
        case linked
        /// Both, and `CLAUDE.md` doesn't pull in the other.
        case split

        /// Worth offering the one-click fix.
        var needsAction: Bool { self == .agentsOnly || self == .claudeOnly || self == .split }

        var summary: String {
            switch self {
            case .none: "No instructions file yet."
            case .agentsOnly: "Only AGENTS.md. Claude Code reads CLAUDE.md, so it never sees these instructions."
            case .claudeOnly: "Only CLAUDE.md. Codex, OpenCode and Pi read AGENTS.md, so they never see these instructions."
            case .linked: "Shared: CLAUDE.md imports AGENTS.md, so every agent reads the same instructions."
            case .split: "CLAUDE.md and AGENTS.md both exist and are kept apart, so the agents are following different instructions."
            }
        }
    }

    static let importLine = "@AGENTS.md"

    /// A `CLAUDE.md` whose only content is the import.
    static let importFile = importLine + "\n"

    static func state(of files: Files) -> State {
        let agents = clean(files.agents)
        let claude = clean(files.claude)
        if files.claudeLinksToAgents, agents != nil { return .linked }
        switch (agents, claude) {
        case (nil, nil): return .none
        case (.some, nil): return .agentsOnly
        case (nil, .some(let claude)): return importsAgents(claude) ? .none : .claudeOnly
        case (.some, .some(let claude)): return importsAgents(claude) ? .linked : .split
        }
    }

    /// Whether a `CLAUDE.md` pulls in `AGENTS.md`: a line that is just the
    /// import, which Claude Code follows.
    static func importsAgents(_ claude: String) -> Bool {
        claude.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "@AGENTS.md" || trimmed == "@./AGENTS.md"
        }
    }

    /// What making the instructions shared would write.
    struct Plan: Equatable {
        /// `AGENTS.md`'s new contents; nil leaves it as it is.
        var agents: String?
        /// `CLAUDE.md`'s new contents.
        var claude: String
        /// The old `CLAUDE.md`, kept beside it, when its words went into the merge.
        var backupOfClaude: String?
        /// What it does, in a sentence for the confirmation.
        var summary: String
    }

    static func plan(for files: Files) -> Plan? {
        let agents = clean(files.agents)
        let claude = clean(files.claude)
        switch state(of: files) {
        case .none, .linked:
            return nil
        case .agentsOnly:
            return Plan(agents: nil, claude: importFile, backupOfClaude: nil,
                        summary: "CLAUDE.md is added and imports AGENTS.md. Nothing in AGENTS.md changes.")
        case .claudeOnly:
            // The words move; nothing is lost, and relative imports in them still resolve.
            return Plan(agents: (claude ?? "") + "\n", claude: importFile, backupOfClaude: nil,
                        summary: "CLAUDE.md's instructions move into a new AGENTS.md, and CLAUDE.md imports it.")
        case .split:
            if agents == claude {
                return Plan(agents: nil, claude: importFile, backupOfClaude: nil,
                            summary: "They already say the same thing. CLAUDE.md becomes an import of AGENTS.md.")
            }
            // Merge, keeping the old CLAUDE.md as a backup in case the merge needs another look.
            let merged = (agents ?? "") + "\n\n## Also from CLAUDE.md\n\n" + (claude ?? "") + "\n"
            return Plan(agents: merged, claude: importFile, backupOfClaude: files.claude,
                        summary: "CLAUDE.md's instructions are added to the end of AGENTS.md, and CLAUDE.md imports it. The old CLAUDE.md is kept as CLAUDE.md.octet-backup.")
        }
    }

    /// Trimmed contents, or nil for a file with nothing in it.
    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
