import Foundation

/// The TCP ports dev servers in a workspace are listening on, found by
/// following each listening process up its parents to a pane's shell.
enum ListeningPorts {
    struct Listener: Equatable {
        let pid: Int
        let command: String
        let port: Int
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` output: `p` starts a process, `c`
    /// names it, `n` is an address like `*:3000` or `[::1]:5173`.
    static func parseLsof(_ text: String) -> [Listener] {
        var result: [Listener] = []
        var pid = 0, command = ""
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int(value) ?? 0; command = ""
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let listener = Listener(pid: pid, command: command, port: port)
                // IPv4 and IPv6 sockets for one port are one server.
                if !result.contains(listener) { result.append(listener) }
            default: break
            }
        }
        return result
    }

    /// `ps -axo pid=,ppid=` output as child → parent.
    static func parseParents(_ text: String) -> [Int: Int] {
        var parents: [Int: Int] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int(fields[0]), let parent = Int(fields[1]) else { continue }
            parents[pid] = parent
        }
        return parents
    }

    /// Ports by pane: a listener belongs to the pane whose shell it descends
    /// from. Sorted, without repeats.
    static func byPane(_ listeners: [Listener], parents: [Int: Int], shells: [String: Int]) -> [String: [Int]] {
        let paneOfShell = Dictionary(shells.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var result: [String: Set<Int>] = [:]
        for listener in listeners {
            var pid = listener.pid
            var steps = 0
            while pid > 1, steps < 64 {
                if let pane = paneOfShell[pid] {
                    result[pane, default: []].insert(listener.port)
                    break
                }
                guard let parent = parents[pid], parent != pid else { break }
                pid = parent
                steps += 1
            }
        }
        return result.mapValues { $0.sorted() }
    }
}
