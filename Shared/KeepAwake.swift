import Foundation

/// Whether Octet should keep the Mac from idle-sleeping. An agent can run
/// for an hour without a keystroke, and a Mac that sleeps under it stops the
/// work; agents' own `caffeinate` helpers get killed or outlive the task.
/// Octet already knows which agents are working, so it holds the assertion
/// for exactly that long and no longer.
enum KeepAwake {
    enum Mode: String, Codable, CaseIterable {
        case off
        /// Only on mains power, so a laptop on battery still sleeps.
        case pluggedIn = "plugged_in"
        case always

        var title: String {
            switch self {
            case .off: return "Never"
            case .pluggedIn: return "When plugged in"
            case .always: return "Always"
            }
        }
    }

    /// Why the Mac is being kept awake, or nil when it isn't: the number of
    /// agents working, for the assertion's name in `pmset -g assertions`.
    static func reason(mode: Mode, statuses: [EngineAgentStatus], onBattery: Bool) -> String? {
        guard mode == .always || (mode == .pluggedIn && !onBattery) else { return nil }
        let working = statuses.filter { $0 == .working }.count
        guard working > 0 else { return nil }
        return working == 1 ? "An agent is working in Octet" : "\(working) agents are working in Octet"
    }
}
