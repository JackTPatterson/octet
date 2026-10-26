import SwiftUI
import AppKit

/// Saving, removing and assigning credential profiles. Secrets go to the
/// Keychain; settings keep only names, plain values and the folders using them.
@MainActor
enum CredentialActions {
    private static var settings: SettingsStore { .shared }

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var secret: Bool
        /// A plain variable's value, or what's typed for a secret (blank keeps the saved one).
        var value: String
        /// The name it had when the editor opened, to carry a secret across a rename.
        var originalName: String?
    }

    static func save(existing: CredentialProfile?, name: String, rows: [Row], folders: [String]) {
        let id = existing?.id ?? UUID().uuidString
        var variables: [CredentialVariable] = []
        for row in rows {
            let variable = row.name.trimmingCharacters(in: .whitespaces)
            guard !variable.isEmpty else { continue }
            let account = CredentialProfiles.keychainAccount(profileId: id, variable: variable)
            if row.secret {
                if !row.value.isEmpty {
                    CredentialKeychain.set(row.value, for: account)
                } else if let old = row.originalName, old != variable {
                    // Renamed with nothing typed: the saved secret moves with it.
                    let oldAccount = CredentialProfiles.keychainAccount(profileId: id, variable: old)
                    if let saved = CredentialKeychain.get(oldAccount) { CredentialKeychain.set(saved, for: account) }
                }
                variables.append(CredentialVariable(name: variable, secret: true, value: ""))
            } else {
                CredentialKeychain.delete(account)
                variables.append(CredentialVariable(name: variable, secret: false, value: row.value))
            }
        }
        // Whatever the profile held that it no longer has.
        let kept = Set(variables.map(\.name))
        for old in existing?.variables ?? [] where !kept.contains(old.name) {
            CredentialKeychain.delete(CredentialProfiles.keychainAccount(profileId: id, variable: old.name))
        }
        let profile = CredentialProfile(id: id, name: name.trimmingCharacters(in: .whitespaces), variables: variables)
        if let index = settings.values.credentialProfiles.firstIndex(where: { $0.id == id }) {
            settings.values.credentialProfiles[index] = profile
        } else {
            settings.values.credentialProfiles.append(profile)
        }
        var assignments = settings.values.credentialAssignments.filter { $0.profileId != id }
        assignments += folders.map { CredentialAssignment(folder: $0, profileId: id) }
        settings.values.credentialAssignments = assignments
    }

    static func remove(_ profile: CredentialProfile) {
        CredentialKeychain.delete(profile)
        settings.values.credentialProfiles.removeAll { $0.id == profile.id }
        settings.values.credentialAssignments.removeAll { $0.profileId == profile.id }
    }

    static func uses(_ profile: CredentialProfile, folder: String) -> Bool {
        settings.values.credentialAssignments.contains { $0.profileId == profile.id && $0.folder == folder }
    }

    /// Starts or stops `folder` using `profile`.
    static func toggle(_ profile: CredentialProfile, folder: String) {
        if uses(profile, folder: folder) {
            settings.values.credentialAssignments.removeAll { $0.profileId == profile.id && $0.folder == folder }
            ToastCenter.shared.info("\(profile.name) credentials off", detail: (folder as NSString).abbreviatingWithTildeInPath)
        } else {
            settings.values.credentialAssignments.append(CredentialAssignment(folder: folder, profileId: profile.id))
            ToastCenter.shared.info("\(profile.name) credentials on",
                                    detail: "New terminals and agents in \((folder as NSString).abbreviatingWithTildeInPath) use them")
        }
    }
}

struct CredentialDraft: Identifiable {
    let id = UUID()
    var profile: CredentialProfile?
    var template: CredentialProfiles.Template?
}

/// Settings › Accounts › Credentials.
struct CredentialsSettingsGroup: View {
    @ObservedObject var settings: SettingsStore
    @State private var draft: CredentialDraft?
    @State private var templateId = "supabase"

    var body: some View {
        SettingsGroup(title: "Credentials") {
            SettingsRow(
                title: "Credential profiles",
                detail: "Keep more than one sign-in for a command-line tool, say an Aventix and a JPX Supabase token, and choose which one each project folder uses. A profile is a set of environment variables: tokens go in your Keychain, never in settings. Terminals, the terminal drawer, agents and ! commands started in a folder get its profile, so supabase db push in an Aventix project uses Aventix without logging in or out."
            ) { EmptyView() }
            ForEach(settings.values.credentialProfiles) { profile in
                SettingsDivider()
                let folders = settings.values.credentialAssignments.filter { $0.profileId == profile.id }.map(\.folder)
                SettingsRow(
                    title: profile.name,
                    detail: profile.variables.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ") + " · "
                        + (folders.isEmpty ? "No projects yet"
                           : "Used by " + folders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
                ) {
                    HStack(spacing: 6) {
                        OctetButton(title: "Edit", compact: true) { draft = CredentialDraft(profile: profile) }
                        OctetButton(title: "Remove", compact: true) { CredentialActions.remove(profile) }
                            .help("Delete this profile and its saved secrets. Nothing else changes.")
                    }
                }
            }
            SettingsDivider()
            SettingsRow(title: "Add a profile", detail: "Start from a tool's usual variables, or add your own.") {
                HStack(spacing: 8) {
                    OctetSelect(selection: $templateId,
                                options: CredentialProfiles.templates.map { ($0.id, $0.title) }, width: 150)
                    OctetButton(title: "New Profile…", compact: true) {
                        draft = CredentialDraft(template: CredentialProfiles.templates.first { $0.id == templateId })
                    }
                }
            }
        }
        .sheet(item: $draft) { draft in
            CredentialProfileSheet(draft: draft, currentFolder: WindowRegistry.shared.key.flatMap { AccountActions.projectFolder(window: $0) }) { self.draft = nil }
        }
    }
}

struct CredentialProfileSheet: View {
    let draft: CredentialDraft
    let currentFolder: String?
    let close: () -> Void
    @State private var name: String
    @State private var rows: [CredentialActions.Row]
    @State private var folders: [String]

    init(draft: CredentialDraft, currentFolder: String?, close: @escaping () -> Void) {
        self.draft = draft
        self.currentFolder = currentFolder
        self.close = close
        if let profile = draft.profile {
            _name = State(initialValue: profile.name)
            _rows = State(initialValue: profile.variables.map {
                CredentialActions.Row(name: $0.name, secret: $0.secret, value: $0.secret ? "" : $0.value, originalName: $0.name)
            })
            _folders = State(initialValue: SettingsStore.shared.values.credentialAssignments
                .filter { $0.profileId == profile.id }.map(\.folder))
        } else {
            _name = State(initialValue: "")
            _rows = State(initialValue: (draft.template?.variables ?? [CredentialVariable(name: "")]).map {
                CredentialActions.Row(name: $0.name, secret: $0.secret, value: "", originalName: nil)
            })
            _folders = State(initialValue: [])
        }
    }

    private static func validName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }

    private var namesValid: Bool {
        let names = rows.map { $0.name.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return !names.isEmpty && names.allSatisfy(Self.validName) && Set(names).count == names.count
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && namesValid }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.profile == nil ? "New credential profile" : "Edit credential profile")
                    .font(Theme.Text.title3).foregroundStyle(Theme.textPrimary)
                Text("Set for new terminals, agents and ! commands in the folders below. Secrets are kept in your Keychain.")
                    .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
            }
            .padding(16)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name") { OctetTextField(placeholder: "Aventix", text: $name) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Variables").font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
                        ForEach($rows) { $row in variableRow($row) }
                        OctetButton(title: "Add Variable", icon: "plus", kind: .secondary, compact: true) {
                            rows.append(CredentialActions.Row(name: "", secret: true, value: "", originalName: nil))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Used by").font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
                        if folders.isEmpty {
                            Text("No project folders yet. Everything inside a folder uses it, and a deeper folder's profile wins.")
                                .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                        }
                        ForEach(folders, id: \.self) { folder in
                            HStack {
                                Text((folder as NSString).abbreviatingWithTildeInPath)
                                    .font(Theme.Text.mono(11.5)).foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                OctetIconButton(icon: "xmark", help: "Stop using it here", compact: true) {
                                    folders.removeAll { $0 == folder }
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            if let currentFolder, !folders.contains(currentFolder) {
                                OctetButton(title: "Add This Project", icon: "plus", kind: .secondary, compact: true) {
                                    folders.append(currentFolder)
                                }
                            }
                            OctetButton(title: "Add Folder…", icon: "folder", kind: .secondary, compact: true, action: pickFolder)
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 420)
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack {
                Spacer()
                OctetButton(title: "Cancel", kind: .secondary, compact: true, action: close).keyboardShortcut(.cancelAction)
                OctetButton(title: "Save", kind: .primary, compact: true) {
                    CredentialActions.save(existing: draft.profile, name: name, rows: rows, folders: folders)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 520)
        .background(Theme.chrome)
        .hostsOctetDialogs()
    }

    private func variableRow(_ row: Binding<CredentialActions.Row>) -> some View {
        let saved = row.wrappedValue.originalName.map {
            CredentialKeychain.has(CredentialProfiles.keychainAccount(profileId: draft.profile?.id ?? "", variable: $0))
        } ?? false
        return HStack(spacing: 8) {
            OctetTextField(placeholder: "VARIABLE_NAME", text: row.name,
                           invalid: !row.wrappedValue.name.isEmpty && !Self.validName(row.wrappedValue.name.trimmingCharacters(in: .whitespaces)))
                .frame(width: 190)
            OctetTextField(placeholder: row.wrappedValue.secret ? (saved ? "Saved · leave blank to keep" : "Secret value") : "Value",
                           text: row.value, secure: row.wrappedValue.secret)
            Toggle("Secret", isOn: row.secret)
                .toggleStyle(.checkbox)
                .font(Theme.captionFont)
                .help("A secret is kept in the Keychain and hidden here")
            OctetIconButton(icon: "trash", help: "Remove this variable", compact: true) {
                rows.removeAll { $0.id == row.wrappedValue.id }
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Here"
        if panel.runModal() == .OK, let url = panel.url, !folders.contains(url.path) { folders.append(url.path) }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}
