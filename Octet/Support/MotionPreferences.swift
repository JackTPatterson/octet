import AppKit
import SwiftUI

/// User motion settings. Every animation in Octet asks here first, so turning
/// a switch off (or enabling the system Reduce Motion setting) makes the UI
/// change instantly instead.
@MainActor
final class MotionPreferences: ObservableObject {
    static let shared = MotionPreferences()

    enum Area: String, CaseIterable, Identifiable {
        case sidebar, tabs, palette, toasts, approvals, agentStatus

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sidebar: return "Sidebar"
            case .tabs: return "Tab bar"
            case .palette: return "Command palette"
            case .toasts: return "Toasts"
            case .approvals: return "Approval prompts"
            case .agentStatus: return "Agent status spinner"
            }
        }

        var detail: String {
            switch self {
            case .sidebar: return "Workspaces moving to and from Idle, groups collapsing, sidebar show/hide"
            case .tabs: return "Tabs opening and closing, the active tab indicator sliding"
            case .palette: return "Palette opening and closing, the selection highlight"
            case .toasts: return "Toasts sliding in and out"
            case .approvals: return "An agent's permission request fading up above the composer"
            case .agentStatus: return "The spinning indicator for working agents"
            }
        }
    }

    @Published var enabled: Bool { didSet { save("enabled", enabled) } }
    @Published var followSystemReduceMotion: Bool { didSet { save("followSystem", followSystemReduceMotion) } }
    @Published private var areas: [String: Bool] { didSet { UserDefaults.standard.set(areas, forKey: Self.key("areas")) } }
    @Published private(set) var systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var observer: NSObjectProtocol?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Self.key("enabled")) as? Bool ?? true
        followSystemReduceMotion = defaults.object(forKey: Self.key("followSystem")) as? Bool ?? true
        areas = defaults.dictionary(forKey: Self.key("areas")) as? [String: Bool] ?? [:]
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    func isOn(_ area: Area) -> Bool {
        areas[area.rawValue] ?? true
    }

    func set(_ area: Area, _ on: Bool) {
        areas[area.rawValue] = on
    }

    func binding(_ area: Area) -> Binding<Bool> {
        Binding(get: { self.isOn(area) }, set: { self.set(area, $0) })
    }

    /// Whether `area` animates right now.
    func animates(_ area: Area) -> Bool {
        enabled && isOn(area) && !(followSystemReduceMotion && systemReduceMotion)
    }

    /// The animation for `area`, or nil when motion is off.
    func animation(_ area: Area, _ animation: Animation = .smooth(duration: 0.22)) -> Animation? {
        animates(area) ? animation : nil
    }

    /// Runs `changes` with the area's animation (or without one).
    func perform(_ area: Area, _ animation: Animation = .smooth(duration: 0.22), _ changes: () -> Void) {
        if let chosen = self.animation(area, animation) {
            withAnimation(chosen, changes)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, changes)
        }
    }

    private static func key(_ name: String) -> String { "octet.motion.\(name)" }

    private func save(_ name: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.key(name))
    }
}
