import SwiftUI

/// Every model OpenCode knows, from every provider: the ones it's signed in
/// to can be picked, the rest say how to sign in. The model menu lists only
/// what's usable now; this is the whole catalog behind it.
struct OpenCodeModelBrowser: View {
    @ObservedObject var session: AgentSession
    let close: () -> Void
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var store = OpenCodeCatalogStore.shared
    @State private var query = ""
    @State private var signedInOnly = false
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            content
        }
        .frame(width: 680, height: 620)
        .background(Theme.chrome)
        .onAppear {
            store.loadEverything(cwd: session.cwd)
            searching = true
        }
    }

    private var header: some View {
        let total = store.everything?.providers.reduce(0) { $0 + $1.models.count } ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("All models").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if total > 0 {
                    Text("\(total) from \(store.everything?.providers.count ?? 0) providers")
                        .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                OctetButton(title: "Done", kind: .secondary, compact: true) { close() }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 10) {
                OctetTextField(placeholder: "Search models or providers", text: $query) {}
                    .focused($searching)
                Toggle("Signed in only", isOn: $signedInOnly)
                    .toggleStyle(.checkbox)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if let everything = store.everything {
            let sections = filtered(everything.providers, connected: everything.connected)
            if sections.isEmpty {
                Text("No models match \u{201C}\(query)\u{201D}")
                    .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { provider in
                            let usable = everything.connected.contains(provider.id)
                            Section {
                                ForEach(provider.models) { model in
                                    ModelRow(model: model, usable: usable, selected: model.id == session.model) {
                                        pick(model)
                                    }
                                }
                            } header: {
                                providerHeader(provider, usable: usable)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        } else if let error = store.everythingError {
            Text(error).font(Theme.uiFont).foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func providerHeader(_ provider: OpenCodeCatalog.Provider, usable: Bool) -> some View {
        HStack(spacing: 8) {
            Text(provider.name.uppercased())
                .font(Theme.headerFont).kerning(0.4).foregroundStyle(Theme.textTertiary)
            Text("\(provider.models.count)").font(Theme.headerFont).foregroundStyle(Theme.textTertiary)
            Spacer()
            if usable {
                Text("Signed in").font(Theme.headerFont).foregroundStyle(Theme.accent)
            } else {
                OctetButton(title: "Sign In…", kind: .ghost, compact: true) { signIn() }
                    .help("Opens `opencode auth login` in a new tab, to add a key or sign in")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Theme.chrome)
    }

    /// Providers with the models matching the search, signed-in ones first.
    private func filtered(_ providers: [OpenCodeCatalog.Provider], connected: Set<String>) -> [OpenCodeCatalog.Provider] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return providers.compactMap { provider in
            if signedInOnly, !connected.contains(provider.id) { return nil }
            guard !terms.isEmpty else { return provider }
            let models = provider.models.filter { model in
                let haystack = "\(model.name) \(model.id) \(provider.name)".lowercased()
                return terms.allSatisfy(haystack.contains)
            }
            guard !models.isEmpty else { return nil }
            var copy = provider
            copy.models = models
            return copy
        }
    }

    private func pick(_ model: OpenCodeCatalog.Model) {
        session.model = model.id
        if let effort = session.effort, !model.variants.contains(effort) { session.effort = nil }
        session.conversation.contextWindow = model.context
        close()
    }

    /// OpenCode signs in from its own prompt; a tab runs it, and the catalog
    /// is fetched again next time the menu or this list opens.
    private func signIn() {
        session.openCodeSignIn(window: window)
        close()
    }
}

private struct ModelRow: View {
    let model: OpenCodeCatalog.Model
    let usable: Bool
    let selected: Bool
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                OctetIcon("checkmark", size: 11)
                    .foregroundStyle(Theme.accent)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(Theme.uiFont)
                        .foregroundStyle(usable ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                    Text(model.modelID).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !model.variants.isEmpty {
                    tag(model.variants.count == 1 ? model.variants[0] : "\(model.variants.count) efforts")
                        .help("Reasoning: " + model.variants.joined(separator: ", "))
                }
                if model.images { tag("images") }
                if let context = model.context { tag(OpenCodeCatalog.tokens(context)) }
                tag(price).frame(minWidth: 86, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovered && usable ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .onHover { hovered = $0 }
        .help(usable ? model.id : "Sign in to \(model.providerName) to use this model")
    }

    private var price: String {
        if model.isFree { return "free" }
        guard let input = model.inputCost, let output = model.outputCost else { return "" }
        return String(format: "$%.2f / $%.2f", input, output)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
    }
}
