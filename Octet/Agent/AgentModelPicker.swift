import SwiftUI

/// The model picker, in T3 Code's popover: a provider rail, a searchable
/// list, and beside it the highlighted model's details. The comparison is
/// the point of the details: speed, quality and cost as meters that fill as
/// you move through the list, with your current model's score marked on
/// each so the difference reads at a glance. Scores are editorial family
/// guidance; provider-supported effort levels still drive the session.
struct AgentModelPicker: View {
    let spec: OctetDropdownSpec
    let maxHeight: CGFloat
    let close: () -> Void
    @State private var query = ""
    @State private var hoveredID: String?
    @State private var activeID: String?
    @State private var showAll = false
    @State private var favoritesOnly = false
    @AppStorage("octet.modelPicker.favorites") private var savedFavorites = "[]"
    @State private var chosenEffort = ""
    @FocusState private var listFocused: Bool
    @ObservedObject private var motion = MotionPreferences.shared

    private let listWidth: CGFloat = 392
    private let detailWidth: CGFloat = 248
    /// One comparison column: five segments and their gaps.
    private let metricWidth: CGFloat = 40
    private let rowHeight: CGFloat = 34

    private var primary: [OctetDropdownOption] {
        var families = Set<String>()
        return spec.options.filter { option in
            let family = ModelPickerProfile.resolve(id: option.id, title: option.title)?.family ?? option.title.lowercased().split(separator: " ").first.map(String.init) ?? option.id
            return families.insert(family).inserted || option.id == spec.selected
        }
    }
    private var favoriteIDs: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(savedFavorites.utf8))) ?? [])
    }
    private func favoriteKey(_ id: String) -> String { "\(spec.modelAgent ?? "model"):\(id)" }
    private func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(favoriteKey(id)) }
    private func toggleFavorite(_ id: String) {
        var ids = favoriteIDs
        let key = favoriteKey(id)
        if !ids.insert(key).inserted { ids.remove(key) }
        if let data = try? JSONEncoder().encode(ids.sorted()), let value = String(data: data, encoding: .utf8) { savedFavorites = value }
    }
    private var legacy: [OctetDropdownOption] {
        let ids = Set(primary.map(\.id))
        return spec.options.filter { !ids.contains($0.id) }
    }
    private var options: [OctetDropdownOption] {
        let source = favoritesOnly || !query.isEmpty ? spec.options : primary + (showAll ? legacy : [])
        return source.filter {
            (!favoritesOnly || isFavorite($0.id)) &&
            (query.isEmpty || "\($0.title) \(providerName) \($0.detail ?? "")".localizedCaseInsensitiveContains(query))
        }
    }
    private var browsing: Bool { query.isEmpty && !favoritesOnly }
    private var brand: AgentBrand? { AgentBrand.forAgent(spec.modelAgent) }
    private var providerName: String { spec.modelAgent == "claude" ? "Claude" : brand?.displayName ?? "Provider" }
    private var highlighted: String? { hoveredID ?? activeID ?? spec.selected }
    private var preview: OctetDropdownOption? { spec.options.first { $0.id == highlighted } }
    private var current: OctetDropdownOption? { spec.options.first { $0.id == spec.selected } }
    private var hasEffort: Bool { spec.modelEffort != nil && spec.modelEffortLevels.count > 1 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            providerRail
            Rectangle().fill(ChatStyle.border).frame(width: 1)
            VStack(spacing: 0) {
                searchField
                Rectangle().fill(ChatStyle.border).frame(height: 1)
                columnHeader
                list
            }
            .frame(width: listWidth)
            Rectangle().fill(ChatStyle.border).frame(width: 1)
            details
                .frame(width: detailWidth)
        }
        .fixedSize(horizontal: true, vertical: true)
        .chatPopover()
        .animation(motion.animation(.palette, .easeOut(duration: 0.16)), value: highlighted)
        .onAppear {
            activeID = options.contains { $0.id == spec.selected } ? spec.selected : options.first?.id
            chosenEffort = ModelPickerProfile.effectiveEffort(explicit: spec.modelEffort?.wrappedValue,
                fallback: spec.modelDefaultEffort, levels: spec.modelEffortLevels) ?? ""
            listFocused = true
        }
        .onChange(of: favoritesOnly) { _, _ in activeID = options.first?.id; hoveredID = nil }
        .onChange(of: savedFavorites) { _, _ in if !options.contains(where: { $0.id == activeID }) { activeID = options.first?.id } }
        .onChange(of: query) { _, _ in activeID = options.first?.id; hoveredID = nil }
        .onKeyPress(.downArrow) {
            guard !listFocused else { return .ignored }
            listFocused = true; activeID = options.first?.id
            return .handled
        }
        .onExitCommand(perform: close)
    }

    // MARK: Search and list

    private var searchField: some View {
        HStack(spacing: 8) {
            OctetIcon("magnifyingglass", size: 14).foregroundStyle(ChatStyle.mutedText)
            TextField("", text: $query, prompt: Text("Search models").foregroundStyle(ChatStyle.placeholder))
                .textFieldStyle(.plain)
                .font(ChatStyle.meta)
                .foregroundStyle(ChatStyle.text)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    /// The comparison's columns, over every row.
    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(["Speed", "Quality", "Cost"], id: \.self) { Text($0).frame(width: metricWidth) }
            Color.clear.frame(width: 20)
        }
        .font(Theme.interfaceFont(10.5, weight: .medium))
        .foregroundStyle(ChatStyle.mutedText)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var list: some View {
        let extraRow = !legacy.isEmpty && browsing ? 1 : 0
        let wanted = CGFloat(max(1, options.count) + extraRow) * rowHeight + 12
        return ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(browsing ? primary : options) { row($0).id($0.id) }
                    if !legacy.isEmpty && browsing {
                        legacyToggle
                    }
                    if showAll && browsing {
                        ForEach(legacy) { row($0).id($0.id) }
                    }
                    if options.isEmpty {
                        Text(favoritesOnly && query.isEmpty ? "No favorites yet. Star a model to add it here." : "No matching models")
                            .font(ChatStyle.meta)
                            .foregroundStyle(ChatStyle.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(height: min(wanted, max(120, min(320, maxHeight - 60))))
            .focusable().focusEffectDisabled().focused($listFocused)
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.home) { activeID = options.first?.id; hoveredID = nil; return .handled }
            .onKeyPress(.end) { activeID = options.last?.id; hoveredID = nil; return .handled }
            .onKeyPress(.return) { choose(); return .handled }
            .onKeyPress(.space) { choose(); return .handled }
            .onChange(of: activeID) { _, id in if let id { scroll.scrollTo(id) } }
        }
    }

    private var legacyToggle: some View {
        Button {
            showAll.toggle(); hoveredID = nil
            if !options.contains(where: { $0.id == activeID }) { activeID = options.first?.id }
        } label: {
            HStack(spacing: 8) {
                OctetIcon("chevron.right", size: 12)
                    .rotationEffect(.degrees(showAll ? 90 : 0))
                    .frame(width: 16)
                Text("Legacy models").font(ChatStyle.meta)
                Text("\(legacy.count)").font(ChatStyle.meta.monospacedDigit()).foregroundStyle(ChatStyle.faintIcon)
                Spacer()
            }
            .foregroundStyle(ChatStyle.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Legacy models, \(legacy.count) models")
    }

    private func row(_ option: OctetDropdownOption) -> some View {
        let lit = highlighted == option.id
        let selected = option.id == spec.selected
        let favorite = isFavorite(option.id)
        return HStack(spacing: 8) {
            Button { spec.select(option.id); close() } label: {
                HStack(spacing: 8) {
                    if let brand { AgentLogo(brand: brand, size: 16) }
                    Text(modelTitle(option))
                        .font(ChatStyle.metaMedium)
                        .foregroundStyle(lit || selected ? ChatStyle.text : ChatStyle.secondaryText)
                        .lineLimit(1)
                    if selected {
                        OctetIcon("checkmark", size: 11).foregroundStyle(ChatStyle.primary)
                    }
                    Spacer(minLength: 4)
                    if let profile = Self.profile(option) {
                        let baseline = selected ? nil : current.flatMap(Self.profile)
                        bars(profile.speed, baseline: baseline?.speed, lit: lit, label: "Speed")
                        bars(profile.quality, baseline: baseline?.quality, lit: lit, label: "Quality")
                        bars(profile.cost, baseline: baseline?.cost, lit: lit, label: "Cost")
                    } else {
                        Text("Varies")
                            .font(Theme.interfaceFont(11))
                            .foregroundStyle(ChatStyle.faintIcon)
                            .frame(width: metricWidth * 3 + 16)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusable(false)
            .accessibilityLabel(option.title)
            .accessibilityValue(selected ? "Selected" : "")
            Button { toggleFavorite(option.id) } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(favorite ? ChatStyle.warning : ChatStyle.mutedText)
                    .opacity(lit || favorite ? 1 : 0)
                    .frame(width: 20, height: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(favorite ? "Unfavorite" : "Favorite") \(option.title)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: rowHeight)
        .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
            .fill(lit ? ChatStyle.hover : .clear))
        .onHover { inside in if inside { hoveredID = option.id } else if hoveredID == option.id { hoveredID = nil } }
        .help(option.detail ?? option.title)
    }

    // MARK: Details

    private var details: some View {
        let profile = preview.flatMap(Self.profile)
        let baseline = current.flatMap(Self.profile)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let brand { AgentLogo(brand: brand, size: 16) }
                    Text(preview.map(modelTitle) ?? "Model")
                        .font(Theme.interfaceFont(14, weight: .semibold))
                        .foregroundStyle(ChatStyle.text)
                        .lineLimit(1)
                }
                Text(preview?.detail.map(Self.firstSentence) ?? profile?.subtitle ?? providerName)
                    .font(ChatStyle.meta)
                    .foregroundStyle(ChatStyle.secondaryText)
                    // Two lines held whatever the model, so the popover
                    // doesn't change size as you move through the list.
                    .lineLimit(2, reservesSpace: true)
            }
            .id(highlighted)
            .transition(.opacity)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            if let current {
                // How it stacks up against the model in use, in words.
                Text(comparison(profile, against: baseline, current: current))
                    .font(Theme.interfaceFont(11))
                    .foregroundStyle(ChatStyle.mutedText)
                    .lineLimit(2, reservesSpace: true)
                    .id(highlighted)
                    .transition(.opacity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }

            if hasEffort {
                Rectangle().fill(ChatStyle.border).frame(height: 1)
                ModelEffortPicker(levels: spec.modelEffortLevels, selected: chosenEffort) { applyEffort($0) }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }

            Spacer(minLength: 0)
            Rectangle().fill(ChatStyle.border).frame(height: 1)
            HStack(spacing: 6) {
                Text(ModelPickerProfile.billing(in: preview?.detail) ?? "Provider billing")
                    .id(highlighted).transition(.opacity).lineLimit(1)
                Spacer(minLength: 0)
                KeyHint("↑↓")
                KeyHint("↵")
            }
            .font(Theme.interfaceFont(11))
            .foregroundStyle(ChatStyle.mutedText)
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
    }

    /// A row's comparison column: five segments, always shown. They lift
    /// to the text colour on the highlighted row, one after another, and
    /// the model in use is outlined where it sits on the same scale.
    private func bars(_ score: Int, baseline: Int?, lit: Bool, label: String) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                ZStack {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(index < score ? (lit ? ChatStyle.primary : ChatStyle.secondaryText.opacity(0.75))
                                            : ChatStyle.text.opacity(0.09))
                    if let baseline, index == baseline - 1 {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .strokeBorder(ChatStyle.text.opacity(lit ? 0.9 : 0.45), lineWidth: 1)
                    }
                }
                .frame(width: 6.4, height: 5)
                .animation(motion.animation(.palette, .easeOut(duration: 0.22).delay(Double(index) * 0.035)), value: lit)
            }
        }
        .frame(width: metricWidth)
        .help("\(label): \(score)/5" + (baseline.map { ", the model in use \($0)/5" } ?? "")
              + ". Editorial family guidance, not a benchmark; higher cost means more expensive.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(score) of 5" + (baseline.map { ", current model \($0)" } ?? ""))
    }

    /// "Faster and cheaper than Opus 5.5, a step down in quality."
    private func comparison(_ profile: ModelPickerProfile?, against baseline: ModelPickerProfile?,
                            current: OctetDropdownOption) -> String {
        let name = modelTitle(current)
        guard preview?.id != spec.selected else { return "The model in use." }
        guard let profile, let baseline else { return "Outlined in each row: where \(name) sits." }
        var parts: [String] = []
        if profile.speed != baseline.speed { parts.append(profile.speed > baseline.speed ? "faster" : "slower") }
        if profile.cost != baseline.cost { parts.append(profile.cost < baseline.cost ? "cheaper" : "pricier") }
        let quality = profile.quality == baseline.quality ? "" :
            (profile.quality > baseline.quality ? ", higher quality" : ", a step down in quality")
        if parts.isEmpty && quality.isEmpty { return "Scores the same as \(name)." }
        if parts.isEmpty {
            return profile.quality > baseline.quality ? "Higher quality than \(name)." : "A step down in quality from \(name)."
        }
        return parts.joined(separator: " and ").capitalizedFirst + " than \(name)" + quality + "."
    }

    // MARK: Rail

    private var providerRail: some View {
        VStack(spacing: 4) {
            railButton(active: favoritesOnly, help: "Favorite models") {
                Image(systemName: "star.fill").font(.system(size: 15))
                    .foregroundStyle(favoritesOnly ? ChatStyle.warning : ChatStyle.mutedText)
            } action: { favoritesOnly = true; query = "" }
            Rectangle().fill(ChatStyle.border).frame(width: 20, height: 1).padding(.vertical, 4)
            ForEach(["codex", "claude"], id: \.self) { agent in
                let current = spec.modelAgent == agent
                railButton(active: current && !favoritesOnly,
                           help: current ? "\(providerName) models" : "Start a new \(agent == "codex" ? "Codex" : "Claude") conversation to use these models.") {
                    AgentLogo(brand: AgentBrand.forAgent(agent)!, size: 18)
                        .opacity(current ? 1 : 0.3)
                } action: { favoritesOnly = false; query = "" }
                .disabled(!current)
                .accessibilityLabel(agent == "codex" ? "Codex models" : "Claude models")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(width: 48)
    }

    private func railButton<Label: View>(active: Bool, help: String, @ViewBuilder label: () -> Label,
                                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                    .fill(active ? ChatStyle.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Helpers

    private func modelTitle(_ option: OctetDropdownOption) -> String {
        guard spec.modelAgent == "claude", !option.title.lowercased().hasPrefix("claude"),
              !option.title.lowercased().contains("default") else { return option.title }
        return "Claude \(option.title)"
    }

    /// A model's scores. Default names the model it routes to in its
    /// detail ("Opus 5.5"), so it borrows that one's, which gives the
    /// comparison a baseline while Default is in use.
    private static func profile(_ option: OctetDropdownOption) -> ModelPickerProfile? {
        if let own = ModelPickerProfile.resolve(id: option.id, title: option.title) { return own }
        guard option.title.lowercased().contains("default"), let detail = option.detail else { return nil }
        return ModelPickerProfile.resolve(id: detail, title: detail)
    }

    private static func firstSentence(_ text: String) -> String {
        String(text.split(separator: "·").first ?? Substring(text)).trimmingCharacters(in: .whitespaces)
    }

    private func move(_ delta: Int) {
        guard !options.isEmpty else { return }
        let index = options.firstIndex { $0.id == activeID } ?? 0
        activeID = options[(index + delta + options.count) % options.count].id
        hoveredID = nil
    }
    private func choose() { if let activeID { spec.select(activeID); close() } }
    private func applyEffort(_ level: String) { chosenEffort = level; spec.modelEffort?.wrappedValue = level }
}

/// A key in a hint line, on a faint chip.
private struct KeyHint: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(Theme.interfaceFont(10.5, weight: .medium))
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ChatStyle.bubble))
            .accessibilityHidden(true)
    }
}

/// How hard the model thinks, inside the model picker: the levels as one
/// track, each in its own colour, with the chosen one on a pill that slides
/// along it; its one-line description, and the warning the top levels carry.
/// The lowest level is thinking off.
struct ModelEffortPicker: View {
    let levels: [String]
    let selected: String
    let choose: (String) -> Void
    @ObservedObject private var motion = MotionPreferences.shared
    @Namespace private var pill

    var body: some View {
        let tint = EffortStyle.color(selected)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Effort").font(ChatStyle.meta).foregroundStyle(ChatStyle.secondaryText)
                Spacer(minLength: 4)
                if !selected.isEmpty {
                    EffortName(level: selected, size: 12, color: tint)
                        .id(selected)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                }
            }
            HStack(spacing: 0) {
                ForEach(levels, id: \.self) { level in
                    let on = level == selected
                    Button { choose(level) } label: {
                        Text(Self.short(level))
                            .font(Theme.interfaceFont(11, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? (EffortStyle.isTop(level) ? Color.white : Color.black.opacity(0.85))
                                             : ChatStyle.secondaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background {
                                if on {
                                    // Ultracode keeps its moving purple.
                                    ZStack {
                                        if EffortStyle.isTop(level) {
                                            UltracodeBackground(cell: CGSize(width: 5, height: 6))
                                        } else {
                                            EffortStyle.color(level)
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                                    .shadow(color: EffortStyle.color(level).opacity(0.4), radius: 4)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(level.capitalized) effort")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChatStyle.page.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ChatStyle.border, lineWidth: 1))
            // The description and the top levels' warning share one slot
            // sized for the warning, so moving along the track never
            // resizes the popover; the words cross-fade in place.
            ZStack(alignment: .topLeading) {
                Text(EffortStyle.detail[selected] ?? (selected == levels.first ? "Thinking off" : ""))
                    .font(Theme.interfaceFont(11))
                    .foregroundStyle(ChatStyle.mutedText)
                    .opacity(warned ? 0 : 1)
                HStack(alignment: .top, spacing: 6) {
                    OctetIcon("exclamationmark.triangle.fill", size: 12)
                    Text(EffortStyle.warning)
                        .font(Theme.interfaceFont(11))
                        .lineLimit(3, reservesSpace: true)
                }
                .foregroundStyle(ChatStyle.warning)
                .opacity(warned ? 1 : 0)
                .accessibilityHidden(!warned)
            }
            .contentTransition(.opacity)
            .animation(motion.animation(.palette, .easeInOut(duration: 0.24)), value: selected)
        }
        // A soft, well-damped spring: the pill glides rather than snaps.
        .animation(motion.animation(.palette, .spring(response: 0.42, dampingFraction: 0.88)), value: selected)
    }

    private var warned: Bool { EffortStyle.warned.contains(selected) }

    /// Short enough for five or six across.
    static func short(_ level: String) -> String {
        switch level {
        case "xhigh": "XHigh"
        case "minimal": "Min"
        case "medium": "Med"
        case "ultracode": "Ultra"
        default: level.capitalized
        }
    }
}
