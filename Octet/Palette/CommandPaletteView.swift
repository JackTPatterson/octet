import SwiftUI

/// State for one palette session.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var chip: PaletteKind? { didSet { selection = 0 } }
    @Published var selection = 0
    /// A text field replacing the list; `detail` is the chosen row's
    /// subtitle, which says what the text is for.
    @Published var prompt: (title: String, placeholder: String, detail: String, submit: (String) -> Void)?
    @Published var promptText = ""
    /// A nested list replacing the main results (e.g. plugin logs).
    @Published var subList: (title: String, items: [PaletteItem]?)?

    private(set) var items: [PaletteItem] = []
    private var itemsById: [String: PaletteItem] = [:]
    private static let recentsKey = "octet.palette.recents"

    var recents: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.recentsKey) }
    }

    /// Reloads while open (agent state changes do this), keeping the
    /// highlight on the same item so Return runs what you see.
    func reload(items: [PaletteItem]) {
        let before = results
        let selectedId = before.indices.contains(selection) ? before[selection].item.id : nil
        objectWillChange.send()
        self.items = items
        #if DEBUG
        // A second row with an id is never shown: the first one wins.
        let duplicates = PaletteModel.duplicateIds(items.map(\.id))
        if !duplicates.isEmpty { NSLog("Octet palette: duplicate ids %@", duplicates.joined(separator: ", ")) }
        #endif
        itemsById = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = results
        if let selectedId, let index = after.firstIndex(where: { $0.item.id == selectedId }) {
            selection = index
        } else {
            selection = min(selection, max(0, after.count - 1))
        }
    }

    /// Ids that more than one row uses, in the order first seen.
    nonisolated static func duplicateIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var repeated: [String] = []
        for id in ids where !seen.insert(id).inserted && !repeated.contains(id) { repeated.append(id) }
        return repeated
    }

    /// Whether there's a page to go back from: a sub-list, a prompt, or a
    /// filter chip.
    var canGoBack: Bool { subList != nil || prompt != nil || chip != nil }

    /// Esc on a sub-page, or ⌫ in an empty field: one step back toward the
    /// main list. False when there was nowhere to go.
    @discardableResult
    func goBack() -> Bool {
        if prompt != nil {
            prompt = nil
        } else if subList != nil {
            subList = nil
            query = ""
        } else if chip != nil {
            chip = nil
        } else {
            return false
        }
        return true
    }

    func reset() {
        query = ""
        chip = nil
        selection = 0
        prompt = nil
        promptText = ""
        subList = nil
    }

    var results: [(item: PaletteItem, indices: [Int])] {
        if let subList {
            let subItems = subList.items ?? []
            let byId = Dictionary(subItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ranked = query.isEmpty
                ? subItems.map { PaletteRankedResult(id: $0.id, score: 0, titleIndices: []) }
                : PaletteRanking.rank(subItems.map(\.searchable), query: query, filter: nil, recentIds: [])
            return ranked.compactMap { r in byId[r.id].map { ($0, r.titleIndices) } }
        }
        return PaletteRanking.rank(items.map(\.searchable), query: query, filter: chip, recentIds: recents)
            .compactMap { ranked in itemsById[ranked.id].map { ($0, ranked.titleIndices) } }
    }

    /// Filter implied by a typed prefix, shown as the active chip.
    var activeFilter: PaletteKind? { PaletteKind.parse(query).filter ?? chip }

    func moveSelection(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    /// Runs the selected item. Returns true when the palette should close.
    func activate(_ item: PaletteItem) -> Bool {
        recents = PaletteRanking.recording(item.id, in: recents)
        switch item.effect {
        case .run(let run):
            run()
            return true
        case .list(let title, let load):
            subList = (title, nil)
            query = ""
            load { [weak self] items in
                guard let self, self.subList?.title == title else { return }
                self.subList = (title, items)
            }
            return false
        case .prompt(let title, let placeholder, let initial, let submit):
            prompt = (title, placeholder, item.subtitle, submit)
            promptText = initial
            return false
        }
    }

    func submitPrompt() -> Bool {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prompt, !text.isEmpty else { return false }
        prompt.submit(text)
        return true
    }
}

/// Command palette: floating panel, search field, filter chips,
/// sectioned results with fuzzy-match highlighting and shortcut keycaps.
struct CommandPaletteView: View {
    @ObservedObject var model: PaletteModel
    let onClose: () -> Void
    @FocusState private var fieldFocused: Bool
    @ObservedObject private var motion = MotionPreferences.shared
    @Namespace private var selectionSpace

    var body: some View {
        ZStack(alignment: .top) {
            Theme.scrim
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            panel
                .padding(.top, 72)
        }
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if let prompt = model.prompt {
                promptField(prompt.title, placeholder: prompt.placeholder, detail: prompt.detail)
            } else {
                if let subList = model.subList {
                    subListHeader(subList.title, loading: subList.items == nil)
                }
                searchField
                if model.subList == nil { chips }
                Rectangle().fill(Theme.divider).frame(height: 1)
                resultsList
            }
            footer
        }
        .frame(width: 576)
        .octetGlass(cornerRadius: 18)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 10) {
            OctetIcon("magnifyingglass", size: 19)
                .foregroundStyle(Theme.textSecondary)
            TextField(
                model.subList.map { "Filter \($0.title.lowercased())…" } ?? "Search actions, workspaces, tabs, agents, projects, plugins…",
                text: $model.query
            )
                .textFieldStyle(.plain)
                .font(Theme.Text.title3.weight(.regular))
                .foregroundStyle(Theme.textPrimary)
                .focused($fieldFocused)
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(keys: [.init("p"), .init("k")], phases: .down) { press in
                    press.modifiers.contains(.control) ? move(-1) : .ignored
                }
                .onKeyPress(keys: [.init("n"), .init("j")], phases: .down) { press in
                    press.modifiers.contains(.control) ? move(1) : .ignored
                }
                .onKeyPress(.tab) { cycleChip(); return .handled }
                // ⌫ in an empty field steps back, as Raycast's does.
                .onKeyPress(.delete) { model.query.isEmpty && model.goBack() ? .handled : .ignored }
                .onKeyPress(.escape) {
                    if model.subList != nil {
                        model.goBack()
                    } else {
                        onClose()
                    }
                    return .handled
                }
                .onSubmit(activateSelection)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(PaletteKind.allCases) { kind in
                let active = model.activeFilter == kind
                Button {
                    model.chip = active ? nil : kind
                    fieldFocused = true
                } label: {
                    HStack(spacing: 4) {
                        Text(kind.title)
                        Text(kind.prefix).foregroundStyle(Theme.textTertiary)
                    }
                    .font(Theme.Text.captionMedium)
                    .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(active ? Theme.accent.opacity(0.22) : Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .strokeBorder(active ? Theme.accent.opacity(0.5) : Color.clear, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: Results

    private var resultsList: some View {
        let results = model.results
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if results.isEmpty {
                        Text("No results")
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.item.id) { index, result in
                        if showsHeader(at: index, in: results) {
                            sectionHeader(for: index, in: results)
                        }
                        PaletteRow(
                            item: result.item,
                            indices: result.indices,
                            selected: index == model.selection,
                            selectionSpace: selectionSpace
                        )
                        .id(result.item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selection = index
                            activateSelection()
                        }
                    }
                }
                .padding(.vertical, 6)
                .animation(motion.animation(.palette, .smooth(duration: 0.12)), value: model.selection)
            }
            .frame(height: listHeight(results))
            .onChange(of: model.selection) { _, newValue in
                guard results.indices.contains(newValue) else { return }
                proxy.scrollTo(results[newValue].item.id)
            }
        }
    }

    /// Content height capped at 400pt, so a short list doesn't leave a gap.
    private func listHeight(_ results: [(item: PaletteItem, indices: [Int])]) -> CGFloat {
        guard !results.isEmpty else { return 70 }
        var height: CGFloat = 12
        for index in results.indices {
            if showsHeader(at: index, in: results) { height += index == 0 ? 22 : 28 }
            height += results[index].item.subtitle.isEmpty ? 32 : 42
            if height > 400 { return 400 }
        }
        return height
    }

    private func showsHeader(at index: Int, in results: [(item: PaletteItem, indices: [Int])]) -> Bool {
        guard model.subList == nil else { return false }
        guard model.query.isEmpty || PaletteKind.parse(model.query).query.isEmpty else { return false }
        if index == 0 { return true }
        let recentCount = recentPrefixCount(results)
        if index == recentCount { return true }
        return index > recentCount && results[index - 1].item.kind != results[index].item.kind
    }

    private func recentPrefixCount(_ results: [(item: PaletteItem, indices: [Int])]) -> Int {
        let recents = Set(model.recents)
        return results.prefix { recents.contains($0.item.id) }.count
    }

    private func sectionHeader(for index: Int, in results: [(item: PaletteItem, indices: [Int])]) -> some View {
        let title = index < recentPrefixCount(results) ? "Recent" : results[index].item.kind.title
        return Text(title.uppercased())
            .font(Theme.headerFont)
            .kerning(0.4)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 16)
            .padding(.top, index == 0 ? 4 : 10)
            .padding(.bottom, 4)
    }

    /// The keys, on every page: what they do changes with the page, but the
    /// strip is always there to read.
    private var footer: some View {
        HStack(spacing: 14) {
            if model.prompt != nil {
                hint("↩", "Confirm")
            } else {
                hint("↑↓", "Navigate")
                hint("↩", "Open")
                if model.subList == nil { hint("⇥", "Filter") }
            }
            if model.canGoBack { hint("⌫", "Back") }
            hint("esc", model.prompt != nil ? "Back" : "Close")
            Spacer()
            if model.prompt == nil, model.subList == nil, model.chip == nil, model.query.isEmpty {
                Text("Type > for actions only")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Keycap(text: key)
            Text(label).font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    /// The icon-only way back, for the pointer; ⌫ and Esc do the same.
    private var backButton: some View {
        OctetIconButton(icon: "chevron.left", help: "Back (⌫ or esc)") {
            model.goBack()
            fieldFocused = true
        }
    }

    private func subListHeader(_ title: String, loading: Bool) -> some View {
        HStack(spacing: 8) {
            backButton
            Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
            if loading { LoadingLine(width: 18) }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: Prompt

    private func promptField(_ title: String, placeholder: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                backButton
                Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            if !detail.isEmpty {
                Text(detail)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, Theme.Space.xs)
            }
            TextField(placeholder, text: $model.promptText)
                .textFieldStyle(.plain)
                .font(Theme.Text.title3.weight(.regular))
                .foregroundStyle(Theme.textPrimary)
                .focused($fieldFocused)
                .onKeyPress(.escape) {
                    model.goBack()
                    return .handled
                }
                .onKeyPress(.delete) { model.promptText.isEmpty && model.goBack() ? .handled : .ignored }
                .onSubmit {
                    if model.submitPrompt() { onClose() }
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .onAppear { DispatchQueue.main.async { fieldFocused = true } }
        }
    }

    // MARK: Keyboard

    private func move(_ delta: Int) -> KeyPress.Result {
        model.moveSelection(delta, count: model.results.count)
        return .handled
    }

    private func cycleChip() {
        let kinds = PaletteKind.allCases
        if let current = model.chip, let index = kinds.firstIndex(of: current) {
            model.chip = index + 1 < kinds.count ? kinds[index + 1] : nil
        } else {
            model.chip = kinds.first
        }
    }

    private func activateSelection() {
        let results = model.results
        guard results.indices.contains(model.selection) else { return }
        if model.activate(results[model.selection].item) {
            onClose()
        } else {
            fieldFocused = true
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let indices: [Int]
    let selected: Bool
    let selectionSpace: Namespace.ID

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                highlightedTitle
                    .font(Theme.Text.transcript)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                KeyCombo(keys: shortcut)
            } else if item.kind != .action {
                Text(item.kind.title.dropLast())
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: item.subtitle.isEmpty ? 32 : 42)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(Theme.cardSelected)
                    .matchedGeometryEffect(id: "paletteSelection", in: selectionSpace)
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case .symbol(let name):
            OctetIcon(name, size: 16)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
        case .agent(let brand):
            AgentLogo(brand: brand, size: 13)
        case .state(let status):
            AgentStateGlyph(status: status, size: 10)
        }
    }

    private var highlightedTitle: Text {
        let marked = Set(indices)
        var text = Text("")
        for (offset, character) in item.title.enumerated() {
            let piece = Text(String(character))
            text = text + (marked.contains(offset)
                ? piece.foregroundColor(Theme.accent).bold()
                : piece.foregroundColor(selected ? Theme.textPrimary : Theme.textMuted))
        }
        return text
    }
}
