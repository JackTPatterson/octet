import Foundation

/// Machines the engine already knows how to reach. Herd lists them and opens
/// a session on one, so working on another box doesn't mean dropping into a
/// bare ssh and losing everything Herd shows.
struct RemoteMachine: Identifiable, Equatable {
    let id: String
    let label: String
    /// The ssh target the engine connects with.
    let target: String
    var enabled = true
    var lastResult: String = ""

    /// What opens a session on it, run inside a pane.
    func command(herdrPath: String, session: String) -> [String] {
        [herdrPath, "--remote", target, "--session", session]
    }
}

enum RemoteMachines {
    /// Parses `herdr machine list --json`, tolerating either an array or an
    /// object with a machines key.
    static func parse(_ data: Data) -> [RemoteMachine] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [[String: Any]]
        if let list = object as? [[String: Any]] {
            rows = list
        } else if let wrapper = object as? [String: Any] {
            rows = wrapper["machines"] as? [[String: Any]] ?? []
        } else {
            return []
        }
        return rows.compactMap { row in
            let target = (row["target"] ?? row["ssh_target"] ?? row["host"]) as? String
            guard let target, !target.isEmpty else { return nil }
            let label = (row["label"] ?? row["name"]) as? String ?? target
            return RemoteMachine(
                id: (row["id"] as? String) ?? label,
                label: label,
                target: target,
                enabled: (row["enabled"] as? Bool) ?? true,
                lastResult: (row["last_result"] as? String) ?? ""
            )
        }
    }

    /// A session name that says which machine it belongs to.
    static func sessionName(for machine: RemoteMachine) -> String {
        let cleaned = machine.label.lowercased()
            .replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "herd-" + (cleaned.isEmpty ? "remote" : cleaned)
    }
}
