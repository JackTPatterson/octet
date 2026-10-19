import AppKit
import SwiftUI

/// One entry in an Octet context menu: an action, a submenu, a row of
/// colour swatches, a section heading or a divider.
struct OctetMenuItem: Identifiable {
    enum Kind {
        case action(() -> Void)
        case submenu([OctetMenuItem])
        case swatches(OctetMenuSwatches)
        case header
        case divider
    }

    let id = UUID()
    var title = ""
    var icon: String?
    var agent: String?
    /// A system menu item's own image, drawn where an icon goes.
    var image: NSImage?
    var shortcut: String?
    var destructive = false
    var enabled = true
    var help: String?
    var kind: Kind

    static func action(_ title: String, icon: String? = nil, shortcut: String? = nil, destructive: Bool = false,
                       enabled: Bool = true, help: String? = nil, _ perform: @escaping () -> Void) -> OctetMenuItem {
        OctetMenuItem(title: title, icon: icon, shortcut: shortcut, destructive: destructive, enabled: enabled,
                      help: help, kind: .action(perform))
    }

    static func submenu(_ title: String, icon: String? = nil, enabled: Bool = true,
                        _ items: [OctetMenuItem]) -> OctetMenuItem {
        OctetMenuItem(title: title, icon: icon, enabled: enabled && !items.isEmpty, kind: .submenu(items))
    }

    static func header(_ title: String) -> OctetMenuItem { OctetMenuItem(title: title, kind: .header) }
    static var divider: OctetMenuItem { OctetMenuItem(kind: .divider) }

    static func swatches(_ title: String, _ swatches: OctetMenuSwatches) -> OctetMenuItem {
        OctetMenuItem(title: title, kind: .swatches(swatches))
    }

    /// Rows the keyboard can land on.
    var selectable: Bool {
        guard enabled else { return false }
        switch kind {
        case .action, .submenu: return true
        case .swatches, .header, .divider: return false
        }
    }

    /// Drops dividers at the ends and doubled ones, so items can be built
    /// with dividers around optional groups.
    static func tidy(_ items: [OctetMenuItem]) -> [OctetMenuItem] {
        var result: [OctetMenuItem] = []
        for item in items {
            if case .divider = item.kind {
                guard let last = result.last else { continue }
                if case .divider = last.kind { continue }
            }
            result.append(item)
        }
        while let last = result.last, case .divider = last.kind { result.removeLast() }
        return result
    }
}

/// A row of colour choices, the first "none".
struct OctetMenuSwatches {
    struct Option: Identifiable {
        let id: String
        let name: String
        var color: Color = .clear
        /// Drawn instead of the colour: a system palette item's image.
        var image: NSImage? = nil
    }
    /// Draws the "none" swatch first.
    var offersNone = true
    let options: [Option]
    let selected: String?
    let select: (String?) -> Void
}

extension View {
    /// Right-click (or Control-click) opens an Octet menu at the pointer in
    /// place of the system's. `items` is read at the click, so it reflects
    /// the state then.
    func octetContextMenu(_ items: @escaping () -> [OctetMenuItem]) -> some View {
        overlay(RightClickCatcher { OctetContextMenu.present(items()) })
    }
}

/// Takes only right clicks and Control-clicks; everything else falls
/// through to the view under it.
private struct RightClickCatcher: NSViewRepresentable {
    let open: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(open: open) }
    func updateNSView(_ view: CatcherView, context: Context) { view.open = open }

    final class CatcherView: NSView {
        var open: () -> Void
        init(open: @escaping () -> Void) {
            self.open = open
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown || event.type == .rightMouseUp
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { open() }
        override func mouseDown(with event: NSEvent) { open() }
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }
}

/// Shows Octet menus: one transparent panel over the screen under the
/// pointer, so submenus can sit beside their rows and a click anywhere
/// else closes it, as a system menu's does.
@MainActor
enum OctetContextMenu {
    private static var panel: MenuPanel?
    private static var monitors: [Any] = []
    private static var observers: [NSObjectProtocol] = []

    static var isOpen: Bool { panel != nil }
    #if DEBUG
    /// The open menu, for verification hooks.
    static var debugModel: OctetMenuModel?
    #endif

    static func present(_ items: [OctetMenuItem], at location: NSPoint = NSEvent.mouseLocation) {
        close()
        let items = OctetMenuItem.tidy(items)
        guard !items.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? NSScreen.main else { return }
        let frame = screen.frame
        let origin = CGPoint(x: location.x - frame.minX, y: frame.maxY - location.y)
        let model = OctetMenuModel(items: items, origin: origin)
        #if DEBUG
        debugModel = model
        #endif
        let panel = MenuPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.title = "Octet Menu"
        let host = NSHostingView(rootView: OctetMenuOverlay(model: model).preferredColorScheme(Theme.colorScheme))
        host.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = host
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel

        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            model.handle(event) ? nil : event
        }
        if let keys { monitors.append(keys) }
        // A click in another app closes it.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { close() }
        }) { monitors.append(outside) }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { close() } })
        DebugSnapshot.overlay("context-menu", true)
    }

    private static var installed = false

    /// Every right-click and Control-click in the app opens an Octet menu:
    /// whatever menu the clicked view would have shown (SwiftUI's
    /// contextMenu, a text field's, the terminal's) is drawn as Octet's
    /// instead, its items running the same actions.
    static func installAppWide() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            guard event.type == .rightMouseDown
                    || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return event }
            return MainActor.assumeIsolated { openSystemMenu(for: event) } ? nil : event
        }
    }

    /// Finds the menu the view under the click would show and shows it as
    /// Octet's. False when there's none, so the click carries on as usual.
    @discardableResult
    static func openSystemMenu(for event: NSEvent, at location: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard let window = event.window, !(window is MenuPanel), let content = window.contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = content.hitTest(point)
        // Views with an Octet menu of their own handle the click themselves.
        if view is RightClickCatcher.CatcherView { return false }
        while let current = view {
            if let menu = current.menu(for: event), !menu.items.isEmpty {
                let items = OctetMenuItem.converting(menu)
                guard !items.isEmpty else { return false }
                present(items, at: location)
                retained = menu
                return true
            }
            view = current.superview
        }
        return false
    }

    /// The system menu being shown, kept alive while its items may run.
    private static var retained: NSMenu?

    static func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel?.orderOut(nil)
        panel = nil
        let menu = retained
        retained = nil
        // Released after any action it's running has been sent.
        DispatchQueue.main.async { _ = menu }
        DebugSnapshot.overlay("context-menu", false)
    }

    /// Closes the menu, then runs the action, so whatever it opens (a
    /// rename field, a dialog) gets the keys rather than the menu.
    static func perform(_ action: @escaping () -> Void) {
        close()
        DispatchQueue.main.async(execute: action)
    }
}

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What's open and highlighted at each level.
@MainActor
final class OctetMenuModel: ObservableObject {
    let items: [OctetMenuItem]
    let origin: CGPoint
    /// The submenu open at each level below the root.
    @Published var path: [UUID] = []
    /// The row under the pointer or the keyboard, per level.
    @Published var highlighted: [Int: UUID] = [:]
    /// Where each submenu row sits on the overlay, for placing its submenu.
    @Published var rowFrames: [UUID: CGRect] = [:]

    static let space = "octetMenu"

    init(items: [OctetMenuItem], origin: CGPoint) {
        self.items = items
        self.origin = origin
    }

    func items(atLevel level: Int) -> [OctetMenuItem] {
        var list = items
        for index in 0..<level {
            guard index < path.count, let item = list.first(where: { $0.id == path[index] }),
                  case .submenu(let children) = item.kind else { return [] }
            list = OctetMenuItem.tidy(children)
        }
        return list
    }

    func hover(_ item: OctetMenuItem, level: Int) {
        highlighted[level] = item.selectable ? item.id : nil
        // Hovering a row closes deeper submenus, and opens its own.
        var next = Array(path.prefix(level))
        if item.selectable, case .submenu = item.kind { next.append(item.id) }
        if next != path { path = next }
        for deeper in highlighted.keys where deeper > level { highlighted[deeper] = nil }
    }

    func activate(_ item: OctetMenuItem, level: Int) {
        guard item.enabled else { return }
        switch item.kind {
        case .action(let perform): OctetContextMenu.perform(perform)
        case .submenu(let children):
            path = Array(path.prefix(level)) + [item.id]
            highlighted[level + 1] = OctetMenuItem.tidy(children).first(where: \.selectable)?.id
        default: break
        }
    }

    /// Arrow keys, Return and Esc, for the deepest open level.
    func handle(_ event: NSEvent) -> Bool {
        let level = deepestHighlightedLevel
        let list = items(atLevel: level)
        switch event.keyCode {
        case 53: // Esc
            if path.isEmpty { OctetContextMenu.close() } else { closeLevel() }
        case 125, 126: // Down, Up
            let selectable = list.filter(\.selectable)
            guard !selectable.isEmpty else { return true }
            let current = selectable.firstIndex { $0.id == highlighted[level] }
            let step = event.keyCode == 125 ? 1 : -1
            let index = current.map { ($0 + step + selectable.count) % selectable.count } ?? (step > 0 ? 0 : selectable.count - 1)
            highlighted[level] = selectable[index].id
            path = Array(path.prefix(level))
        case 124: // Right
            if let id = highlighted[level], let item = list.first(where: { $0.id == id }), case .submenu = item.kind {
                activate(item, level: level)
            }
        case 123: // Left
            if !path.isEmpty { closeLevel() }
        case 36, 76: // Return, Enter
            if let id = highlighted[level], let item = list.first(where: { $0.id == id }) { activate(item, level: level) }
        default:
            // Other keys don't reach the terminal while a menu is up.
            return true
        }
        return true
    }

    private var deepestHighlightedLevel: Int {
        // The open submenu's level once something in it is highlighted.
        let open = path.count
        return highlighted[open] != nil ? open : max(0, min(open, (highlighted.keys.max() ?? 0)))
    }

    private func closeLevel() {
        let level = path.count
        highlighted[level] = nil
        path.removeLast()
    }
}


/// The whole screen: a click-away layer, the menu at the pointer and each
/// open submenu beside its row.
private struct OctetMenuOverlay: View {
    @ObservedObject var model: OctetMenuModel
    @State private var shown = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { OctetContextMenu.close() }
                    .simultaneousGesture(TapGesture().modifiers(.control).onEnded { OctetContextMenu.close() })
                OctetMenuList(model: model, level: 0)
                    .fixedSize()
                    .alignmentGuide(.leading) { menu in
                        let x = model.origin.x + 2
                        return x + menu.width <= proxy.size.width - 6 ? -x : -max(6, model.origin.x - menu.width - 2)
                    }
                    .alignmentGuide(.top) { menu in
                        let y = model.origin.y + 2
                        return y + menu.height <= proxy.size.height - 6 ? -y : -max(6, model.origin.y - menu.height - 2)
                    }
                    .scaleEffect(shown ? 1 : 0.97, anchor: .topLeading)
                    .opacity(shown ? 1 : 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            SubmenuLayer(model: model, size: proxy.size)
        }
        .coordinateSpace(name: OctetMenuModel.space)
        .ignoresSafeArea()
        .onAppear {
            withAnimation(MotionPreferences.shared.animation(.palette, .easeOut(duration: 0.12))) { shown = true }
        }
    }
}

/// Each open submenu, beside the row that opened it.
private struct SubmenuLayer: View {
    @ObservedObject var model: OctetMenuModel
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ForEach(Array(model.path.enumerated()), id: \.element) { index, id in
                if let row = model.rowFrames[id] {
                    OctetMenuList(model: model, level: index + 1)
                        .fixedSize()
                        .alignmentGuide(.leading) { menu in
                            let right = row.maxX + 4
                            return right + menu.width <= size.width - 6 ? -right : -max(6, row.minX - menu.width - 4)
                        }
                        .alignmentGuide(.top) { menu in
                            -min(max(6, row.minY - 5), size.height - menu.height - 6)
                        }
                        .transition(.opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// One level of the menu: a glass card of rows.
private struct OctetMenuList: View {
    @ObservedObject var model: OctetMenuModel
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.items(atLevel: level)) { item in
                row(item)
            }
        }
        .padding(4)
        .frame(minWidth: 200, alignment: .leading)
        .octetGlass(cornerRadius: Theme.popoverRadius)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func row(_ item: OctetMenuItem) -> some View {
        switch item.kind {
        case .divider:
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
        case .header:
            Text(item.title)
                .font(Theme.interfaceFont(11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)
        case .swatches(let swatches):
            SwatchRow(title: item.title, swatches: swatches)
        case .action, .submenu:
            OctetMenuRow(item: item, highlighted: model.highlighted[level] == item.id,
                    open: model.path.count > level && model.path[level] == item.id,
                    hover: { model.hover(item, level: level) },
                    activate: { model.activate(item, level: level) })
                .background {
                    if case .submenu = item.kind {
                        GeometryReader { geometry in
                            let frame = geometry.frame(in: .named(OctetMenuModel.space))
                            Color.clear
                                .onAppear { model.rowFrames[item.id] = frame }
                                .onChange(of: frame) { _, new in model.rowFrames[item.id] = new }
                        }
                    }
                }
        }
    }
}

struct OctetMenuRow: View {
    let item: OctetMenuItem
    let highlighted: Bool
    let open: Bool
    let hover: () -> Void
    let activate: () -> Void

    var body: some View {
        let lit = (highlighted || open) && item.enabled
        let tint: Color = !item.enabled ? Theme.textTertiary.opacity(0.7)
            : item.destructive ? Theme.danger : Theme.textPrimary
        HStack(spacing: 8) {
            Group {
                if let agent = item.agent, let brand = AgentBrand.forAgent(agent) {
                    AgentLogo(brand: brand, size: 14)
                } else if let image = item.image {
                    Image(nsImage: image)
                        .renderingMode(image.isTemplate ? .template : .original)
                        .resizable().scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(lit ? Theme.textPrimary : Theme.textSecondary)
                } else if let icon = item.icon {
                    OctetIcon(icon, size: 13).foregroundStyle(item.destructive && item.enabled ? Theme.danger
                                                              : lit ? Theme.textPrimary : Theme.textSecondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 16)
            Text(item.title)
                .font(Theme.uiFont)
                .foregroundStyle(tint)
                .lineLimit(1)
            Spacer(minLength: 16)
            if let shortcut = item.shortcut {
                Text(shortcut).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            if case .submenu = item.kind {
                OctetIcon("chevron.right", size: 11).foregroundStyle(lit ? Theme.textPrimary : Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius - 2)
            .fill(lit ? (item.destructive ? Theme.danger.opacity(0.16) : Theme.hover) : .clear))
        .contentShape(Rectangle())
        .onHover { if $0 { hover() } }
        .onTapGesture(perform: activate)
        .help(item.help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityRemoveTraits(item.enabled ? [] : .isButton)
        .accessibilityAction { activate() }
    }
}

private struct SwatchRow: View {
    let title: String
    let swatches: OctetMenuSwatches
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title).font(Theme.interfaceFont(11, weight: .medium)).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 6) {
                if swatches.offersNone {
                    swatch(id: nil, name: "None") {
                        Circle().strokeBorder(Theme.textTertiary, lineWidth: 1)
                            .overlay(Rectangle().fill(Theme.textTertiary).frame(width: 1.2).rotationEffect(.degrees(45)))
                    }
                }
                ForEach(swatches.options) { option in
                    swatch(id: option.id, name: option.name) {
                        if let image = option.image {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            Circle().fill(option.color)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func swatch<Fill: View>(id: String?, name: String, @ViewBuilder fill: () -> Fill) -> some View {
        let chosen = swatches.selected == id
        let key = id ?? "none"
        return fill()
            .frame(width: 16, height: 16)
            .padding(2)
            .overlay(Circle().strokeBorder(chosen ? Theme.textPrimary : hovered == key ? Theme.textSecondary : .clear,
                                           lineWidth: 1.5))
            .contentShape(Circle())
            .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
            .onTapGesture { OctetContextMenu.perform { swatches.select(id) } }
            .help(name)
            .accessibilityLabel(name)
            .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

extension OctetMenuItem {
    /// A system menu's items as Octet's, each running the original item.
    @MainActor
    static func converting(_ menu: NSMenu) -> [OctetMenuItem] {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        var result: [OctetMenuItem] = []
        for (index, item) in menu.items.enumerated() where !item.isHidden && !item.isAlternate {
            if item.isSeparatorItem {
                result.append(.divider)
                continue
            }
            if item.isSectionHeader {
                result.append(.header(item.title))
                continue
            }
            if let submenu = item.submenu {
                // A palette (SwiftUI's palette picker) is a row of swatches.
                if submenu.presentationStyle == .palette {
                    submenu.update()
                    let entries = submenu.items.enumerated().filter { !$0.element.isHidden }
                    let options = entries.map { offset, entry in
                        OctetMenuSwatches.Option(id: String(offset), name: entry.title.isEmpty ? (entry.toolTip ?? "") : entry.title,
                                                 image: entry.image)
                    }
                    let selected = entries.first { $0.element.state == .on }.map { String($0.offset) }
                    if !item.title.isEmpty { result.append(.header(item.title)) }
                    result.append(.swatches("", OctetMenuSwatches(offersNone: false, options: options, selected: selected, select: { id in
                        guard let id, let offset = Int(id) else { return }
                        submenu.performActionForItem(at: offset)
                    })))
                    continue
                }
                var entry = OctetMenuItem.submenu(item.title, enabled: item.isEnabled, converting(submenu))
                entry.image = item.image
                result.append(entry)
                continue
            }
            var entry = OctetMenuItem.action(item.title, shortcut: shortcut(of: item), enabled: item.isEnabled,
                                             help: item.toolTip) {
                menu.performActionForItem(at: index)
            }
            if item.state == .on { entry.icon = "checkmark" } else { entry.image = item.image }
            result.append(entry)
        }
        return tidy(result)
    }

    /// "⇧⌘N" for a key equivalent.
    static func shortcut(of item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) || (key.uppercased() == key && key.lowercased() != key) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let named: [String: String] = ["\r": "↩", "\u{8}": "⌫", "\u{7f}": "⌫", "\u{1b}": "⎋", "\t": "⇥", " ": "Space",
                                       String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
                                       String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
                                       String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
                                       String(UnicodeScalar(NSRightArrowFunctionKey)!): "→"]
        return text + (named[key] ?? key.uppercased())
    }
}
