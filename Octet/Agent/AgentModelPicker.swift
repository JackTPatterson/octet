import SwiftUI

/// T3-style provider browsing with affectUI-inspired comparison dots. Scores are editorial
/// family guidance; provider-supported effort levels still drive the session.
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
    private let blue = Color(red: 0.23, green: 0.51, blue: 0.96)
    private let metricWidth: CGFloat = 38
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
            (!favoritesOnly || favoriteIDs.contains(favoriteKey($0.id))) &&
            (query.isEmpty || "\($0.title) \(providerName) \($0.detail ?? "")".localizedCaseInsensitiveContains(query))
        }
    }
    private var brand: AgentBrand? { AgentBrand.forAgent(spec.modelAgent) }
    private var providerName: String { spec.modelAgent == "claude" ? "Claude" : brand?.displayName ?? "Provider" }
    private var highlighted: String? { hoveredID ?? activeID ?? spec.selected }
    private var preview: OctetDropdownOption? { spec.options.first { $0.id == highlighted } }
    private var extended: Bool { !chosenEffort.isEmpty && chosenEffort != spec.modelEffortLevels.first }
    private var rowHeight: CGFloat { 46 }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            providerRail
            Divider()
            VStack(spacing: 0) {
            OctetTextField(placeholder: "Search models…", text: $query)
                .padding(10)
            HStack(spacing: 3) {
                Text("MODEL").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(["SPEED", "QUALITY", "COST"], id: \.self) { Text($0).frame(width: metricWidth) }
            }.font(Theme.interfaceFont(8.5)).foregroundStyle(Theme.textTertiary)
                .padding(.leading, 12).padding(.trailing, 34).padding(.top, 2).padding(.bottom, 5)

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(query.isEmpty && !favoritesOnly ? primary : options) { row($0).id($0.id) }
                        if !legacy.isEmpty && query.isEmpty && !favoritesOnly {
                            Button {
                                showAll.toggle(); hoveredID = nil
                                if !options.contains(where: { $0.id == activeID }) { activeID = options.first?.id }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Legacy models").font(Theme.uiFont)
                                        Text("\(legacy.count) models").font(Theme.interfaceFont(11)).foregroundStyle(Theme.textTertiary)
                                    }
                                    Spacer()
                                    OctetIcon(showAll ? "chevron.down" : "chevron.right", size: 11)
                                }.padding(.horizontal, 10).frame(height: 48).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Legacy models, \(legacy.count) models")
                        }
                        if showAll && query.isEmpty && !favoritesOnly {
                            ForEach(legacy) { row($0).id($0.id) }
                        }
                        if options.isEmpty { Text(favoritesOnly && query.isEmpty ? "No favorites yet. Star a model to add it here." : "No matching models").font(Theme.uiFont).foregroundStyle(Theme.textSecondary).padding(12) }
                    }.padding(.horizontal, 5)
                }
                .frame(height: min(CGFloat(max(1, options.count) + (!legacy.isEmpty && query.isEmpty && !favoritesOnly ? 1 : 0)) * (rowHeight + 2), max(96, min(288, maxHeight - 190))))
                .focusable().focusEffectDisabled().focused($listFocused)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.home) { activeID = options.first?.id; hoveredID = nil; return .handled }
                .onKeyPress(.end) { activeID = options.last?.id; hoveredID = nil; return .handled }
                .onKeyPress(.return) { choose(); return .handled }
                .onKeyPress(.space) { choose(); return .handled }
                .onChange(of: activeID) { _, id in if let id { scroll.scrollTo(id) } }
            }
            if spec.modelEffort != nil && spec.modelEffortLevels.count > 1 {
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        OctetIcon("lightbulb.fill", size: 13).foregroundStyle(Color.white)
                        Text("Extended thinking").font(Theme.uiFont)
                        Spacer()
                        Toggle("Extended thinking", isOn: Binding(get: { extended }, set: { enabled in
                            let levels = spec.modelEffortLevels
                            applyEffort(enabled ? (levels.contains("high") ? "high" : levels[1]) : levels[0])
                        })).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(blue)
                        .help("Off uses the lowest supported effort. On lets you choose a higher effort.")
                    }
                    if extended {
                        HStack(spacing: 8) {
                            Text("Effort").font(Theme.interfaceFont(11)).foregroundStyle(Theme.textSecondary)
                            Spacer(minLength: 2)
                            HStack(spacing: 3) {
                                ForEach(spec.modelEffortLevels, id: \.self) { level in
                                    Button { applyEffort(level) } label: {
                                        Text(level.capitalized).font(Theme.interfaceFont(9))
                                            .padding(.horizontal, 5).frame(height: 20)
                                            .background(chosenEffort == level ? Theme.cardSelected : Theme.hover.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                                    }.buttonStyle(.plain)
                                    .accessibilityLabel("\(level.capitalized) effort")
                                    .accessibilityAddTraits(chosenEffort == level ? .isSelected : [])
                                }
                            }
                        }.padding(.leading, 21)
                            .transition(motion.animates(.palette) ? .opacity.combined(with: .move(edge: .top)) : .identity)
                    }
                }.padding(12)
            }
            Divider()
            HStack(spacing: 4) {
                Text(ModelPickerProfile.billing(in: preview?.detail) ?? "Provider billing")
                    .id(highlighted).transition(.opacity).lineLimit(1)
                Spacer(minLength: 0)
                Text("↑↓  ↵").accessibilityHidden(true)
            }.font(Theme.interfaceFont(9.5)).foregroundStyle(Theme.textTertiary).padding(11)
        }
        }
        .frame(width: 400).fixedSize(horizontal: false, vertical: true).octetGlass(cornerRadius: 11)
        .animation(motion.animation(.palette, .easeInOut(duration: 0.18)), value: extended)
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
    private func modelTitle(_ option: OctetDropdownOption) -> String {
        guard spec.modelAgent == "claude", !option.title.lowercased().hasPrefix("claude"),
              !option.title.lowercased().contains("default") else { return option.title }
        return "Claude \(option.title)"
    }
    private var providerRail: some View {
        VStack(spacing: 5) {
            Button { favoritesOnly = true; query = "" } label: {
                Image(systemName: "star.fill").font(.system(size: 19))
                    .frame(width: 38, height: 38)
                    .background(favoritesOnly ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help("Favorite models").accessibilityLabel("Favorite models")
            Divider().padding(.horizontal, 5).padding(.vertical, 3)
            ForEach(["codex", "claude"], id: \.self) { agent in
                let current = spec.modelAgent == agent
                Button { favoritesOnly = false; query = "" } label: {
                    AgentLogo(brand: AgentBrand.forAgent(agent)!, size: 22)
                        .frame(width: 38, height: 38)
                        .opacity(current ? 1 : 0.35)
                        .overlay(alignment: .trailing) {
                            if current && !favoritesOnly {
                                Capsule().fill(Color.white).frame(width: 2, height: 19).offset(x: 4)
                            }
                        }
                }.buttonStyle(.plain).disabled(!current)
                    .help(current ? "\(providerName) models" : "Start a new \(agent == "codex" ? "Codex" : "Claude") conversation to use these models.")
                    .accessibilityLabel(agent == "codex" ? "Codex models" : "Claude models")
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8).frame(width: 48)
    }
    private func row(_ option: OctetDropdownOption) -> some View {
        let profile = ModelPickerProfile.resolve(id: option.id, title: option.title)
        let lit = highlighted == option.id
        return HStack(spacing: 0) {
        Button { spec.select(option.id); close() } label: {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(modelTitle(option)).font(Theme.interfaceFont(11.5, weight: .medium)).lineLimit(1)
                        if option.id == spec.selected { OctetIcon("checkmark", size: 9).foregroundStyle(blue) }
                    }
                    HStack(spacing: 5) {
                        if let brand { AgentLogo(brand: brand, size: 12) }
                        Text(providerName).font(Theme.interfaceFont(11)).foregroundStyle(Theme.textSecondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    if let profile {
                        bars(profile.speed, lit: lit, label: "Speed")
                        bars(profile.quality, lit: lit, label: "Quality")
                        bars(profile.cost, lit: lit, label: "Cost")
                    } else {
                        Text("Varies").font(Theme.interfaceFont(10)).foregroundStyle(Theme.textTertiary)
                            .frame(width: metricWidth * 3 + 6)
                    }
                }
            }
            .padding(.horizontal, 7).frame(height: rowHeight)
            .background(lit ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))

            .contentShape(Rectangle())
        }.buttonStyle(.plain).focusable(false)
            .accessibilityLabel(option.title)
            .accessibilityValue(option.id == spec.selected ? "Selected" : "")
        Button { toggleFavorite(option.id) } label: {
            Image(systemName: favoriteIDs.contains(favoriteKey(option.id)) ? "star.fill" : "star")
                .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                .opacity(lit || favoriteIDs.contains(favoriteKey(option.id)) ? 1 : 0.3)
                .frame(width: 22, height: rowHeight).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(favoriteIDs.contains(favoriteKey(option.id)) ? "Unfavorite" : "Favorite") \(option.title)")
        }
        .onHover { inside in if inside { hoveredID = option.id } else if hoveredID == option.id { hoveredID = nil } }
        .help(option.detail ?? option.title)
    }
    private func bars(_ score: Int, lit: Bool, label: String) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius: 0.6)
                    .fill(lit && index < score ? Color.white : Theme.textTertiary.opacity(lit ? 0.25 : 0.3))
                    .frame(width: 5, height: 4)
                    .animation(motion.animation(.palette, .easeOut(duration: 0.15).delay(Double(index) * 0.025)), value: lit)
            }
        }.frame(width: metricWidth)
            .help("\(label): \(score)/5. Editorial family guidance, not a benchmark; higher cost means more expensive.")
            .accessibilityLabel("\(label), relative profile \(score) of 5")
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
