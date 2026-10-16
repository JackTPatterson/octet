import SwiftUI

// MARK: - Drafts

struct LibraryDraft: Identifiable {
    let id = UUID()
    var kind: AgentLibrary.Kind
    var slug = ""
    var text = ""
    var hosts: Set<String> = []
    var isNew = true
    /// Reuses the editor to add a plugin marketplace instead.
    var marketplaceSource = false

    init(kind: AgentLibrary.Kind, marketplaceSource: Bool = false) {
        self.kind = kind
        self.marketplaceSource = marketplaceSource
        text = kind == .skill
            ? "---\nname: my-skill\ndescription: What this skill is for, and when to use it\n---\n\n# My Skill\n\nSteps the agent should follow.\n"
            : "---\ndescription: What this prompt does\n---\n\nWrite the prompt here.\n"
    }

    init(item: AgentLibrary.Item, text: String) {
        kind = item.kind
        slug = item.slug
        self.text = text
        hosts = item.installedIn
        isNew = false
    }
}

// MARK: - Shared parts

/// An editor's title and what it's for.
private struct EditorHeader: View {
    let title: String
    let detail: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.interfaceFont(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(Theme.interfaceFont(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            OctetIconButton(icon: "xmark", help: "Close (Esc)", action: close)
        }
    }
}

/// A field's label above it, as T3 Code's forms have them.
private struct EditorField<Content: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(Theme.interfaceFont(12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Theme.interfaceFont(11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            content()
        }
    }
}

/// A checkbox per agent, each with its logo, for where to install.
private struct HostChecklist: View {
    let hosts: [AgentHost]
    @Binding var selection: Set<String>

    var body: some View {
        if hosts.isEmpty {
            Text("No agent on this Mac can take this.")
                .font(Theme.interfaceFont(12))
                .foregroundStyle(Theme.textTertiary)
        } else {
            ChipFlowLayout(spacing: 14) {
                ForEach(hosts) { host in
                    Toggle(isOn: Binding(
                        get: { selection.contains(host.id) },
                        set: { on in if on { selection.insert(host.id) } else { selection.remove(host.id) } }
                    )) {
                        HStack(spacing: 5) {
                            if let brand = AgentBrand.forAgent(host.id) { AgentLogo(brand: brand, size: 12) }
                            Text(host.displayName)
                        }
                    }
                    .toggleStyle(OctetCheckboxStyle())
                    .fixedSize()
                }
            }
        }
    }
}

// MARK: - Library and marketplace editor

/// Writes a skill or prompt into the library, or adds a plugin marketplace.
struct LibraryEditor: View {
    @ObservedObject var store: MarketplaceStore
    @State var draft: LibraryDraft
    let close: () -> Void
    @State private var source = ""

    private var hosts: [AgentHost] {
        draft.marketplaceSource ? store.capableHosts(for: .plugins) : store.hosts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EditorHeader(title: title, detail: detail, close: close)
            if draft.marketplaceSource {
                EditorField(label: "Source", detail: "GitHub owner/repo, a URL, or a local path") {
                    OctetTextField(placeholder: "owner/repo", text: $source, label: "Marketplace source", onSubmit: save)
                }
            } else {
                EditorField(label: "Name", detail: draft.isNew ? "Lowercase, with dashes" : "Can't be changed") {
                    OctetTextField(placeholder: draft.kind == .skill ? "my-skill" : "my-prompt", text: $draft.slug, label: "Name")
                        .disabled(!draft.isNew)
                        .opacity(draft.isNew ? 1 : 0.64)
                }
                EditorField(label: draft.kind == .skill ? "SKILL.md" : "Prompt") {
                    OctetTextEditor(placeholder: "Contents", text: $draft.text, minHeight: 240, maxHeight: 360, font: Theme.monoFont)
                }
            }
            EditorField(label: draft.marketplaceSource ? "Add to" : "Install in") {
                HostChecklist(hosts: hosts, selection: $draft.hosts)
            }
            HStack(spacing: 8) {
                Spacer()
                OctetButton(title: "Cancel", kind: .ghost, compact: true, action: close)
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: draft.marketplaceSource ? "Add Marketplace" : draft.isNew ? "Create" : "Save",
                            kind: .primary, compact: true, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .onAppear {
            // A new item goes to every agent unless unticked.
            if draft.isNew, draft.hosts.isEmpty { draft.hosts = Set(hosts.map(\.id)) }
        }
    }

    private var title: String {
        if draft.marketplaceSource { return "Add a Plugin Marketplace" }
        let noun = draft.kind == .skill ? "Skill" : "Prompt"
        return draft.isNew ? "New \(noun)" : "Edit \(draft.slug)"
    }

    private var detail: String {
        if draft.marketplaceSource { return "Its plugins join Discover once every agent you pick has fetched it." }
        return draft.kind == .skill
            ? "Saved once in ~/.agents/skills and linked into each agent you pick."
            : "Saved once in ~/.agents/prompts and offered as a slash command in each agent you pick."
    }

    private var canSave: Bool {
        if draft.marketplaceSource { return !source.trimmingCharacters(in: .whitespaces).isEmpty }
        return !draft.slug.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        guard canSave else { return }
        let chosen = hosts.filter { draft.hosts.contains($0.id) }
        if draft.marketplaceSource {
            store.addMarketplace(source.trimmingCharacters(in: .whitespaces), to: chosen.isEmpty ? hosts : chosen)
            close()
            return
        }
        let slug = draft.slug.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        if store.saveLibraryItem(kind: draft.kind, slug: slug, text: draft.text, installIn: chosen) {
            // Links for agents that were unticked are removed too.
            if let item = (draft.kind == .skill ? store.skills : store.prompts).first(where: { $0.slug == slug }) {
                for host in store.hosts where !draft.hosts.contains(host.id) && item.installedIn.contains(host.id) {
                    store.setLibraryInstalled(item, host: host, installed: false)
                }
            }
            close()
        }
    }
}

// MARK: - Server editor

/// Adds an MCP server to each agent you pick, in its own syntax.
struct ServerEditor: View {
    @ObservedObject var store: MarketplaceStore
    let close: () -> Void
    @State private var name = ""
    @State private var command = ""
    @State private var hosts: Set<String> = []
    @State private var submitting = false
    @State private var error: String?

    private var capable: [AgentHost] { store.capableHosts(for: .mcp) }
    private var canAdd: Bool {
        !submitting && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty && !hosts.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EditorHeader(title: "Add an MCP Server",
                         detail: "A command to run, or an HTTP URL. Octet adds it to each agent in that agent's own syntax.",
                         close: close)
            EditorField(label: "Name") {
                OctetTextField(placeholder: "my-server", text: $name, label: "Name")
                    .disabled(submitting)
            }
            EditorField(label: "Command or URL") {
                OctetTextField(placeholder: "npx -y @acme/mcp-server  ·  https://mcp.example.com/mcp", text: $command,
                               label: "Command or URL", invalid: error != nil, onSubmit: add)
                    .disabled(submitting)
            }
            EditorField(label: "Add to") {
                HostChecklist(hosts: capable, selection: $hosts)
                    .disabled(submitting)
            }
            if let error {
                MarketplaceBanner(tone: .danger, icon: "exclamationmark.triangle.fill", title: "Couldn't add it", message: error) {
                    EmptyView()
                }
            }
            HStack(spacing: 8) {
                if submitting { BusyLabel(title: "Adding…") }
                Spacer()
                OctetButton(title: "Cancel", kind: .ghost, compact: true, action: close)
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: "Add Server", kind: .primary, compact: true, action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .onAppear { hosts = Set(capable.map(\.id)) }
    }

    /// Stays open until the agents answer, so a failed command can be fixed
    /// instead of retyped.
    private func add() {
        guard canAdd else { return }
        let targets = capable.filter { hosts.contains($0.id) }
        submitting = true
        error = nil
        store.addServer(name: name.trimmingCharacters(in: .whitespaces), command: command, into: targets) { failure in
            submitting = false
            if let failure {
                error = failure
            } else {
                close()
            }
        }
    }
}
