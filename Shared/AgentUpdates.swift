import Foundation

struct AgentUpdate: Equatable {
    let id: String
    let displayName: String
    let current: String
    let latest: String
    let command: String
}

/// Reads public release metadata for agent tools Octet can launch. The check
/// is read-only; installing a release remains an explicit user action.
enum AgentUpdateChecker {
    private struct Package {
        let name: String
        let command: String
    }

    private static let packages: [String: Package] = [
        "claude": Package(name: "@anthropic-ai/claude-code", command: "claude update"),
        "codex": Package(name: "@openai/codex", command: "codex update"),
        "pi": Package(name: "@earendil-works/pi-coding-agent", command: "pi update --self"),
        "opencode": Package(name: "opencode-ai", command: "opencode upgrade"),
        "qwen": Package(name: "@qwen-code/qwen-code", command: "qwen update"),
    ]

    static func check(_ agents: [DiscoveredAgent], completion: @escaping ([AgentUpdate]) -> Void) {
        let candidates = agents.compactMap { agent -> (DiscoveredAgent, Package, String)? in
            guard agent.executablePath != nil, let package = packages[agent.id],
                  let version = version(in: agent.version) else { return nil }
            return (agent, package, version)
        }
        check(candidates, index: 0, updates: [], completion: completion)
    }

    private static func check(_ candidates: [(DiscoveredAgent, Package, String)], index: Int,
                              updates: [AgentUpdate], completion: @escaping ([AgentUpdate]) -> Void) {
        guard index < candidates.count else {
            completion(updates.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            })
            return
        }
        let (agent, package, current) = candidates[index]
        let escaped = package.name.replacingOccurrences(of: "/", with: "%2F")
        guard let url = URL(string: "https://registry.npmjs.org/\(escaped)/latest") else {
            return check(candidates, index: index + 1, updates: updates, completion: completion)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { data, _, _ in
            var next = updates
            if let data,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let latest = json["version"] as? String,
               isNewer(latest, than: current) {
                next.append(AgentUpdate(id: agent.id, displayName: agent.displayName,
                                        current: current, latest: latest, command: package.command))
            }
            check(candidates, index: index + 1, updates: next, completion: completion)
        }.resume()
    }

    static func version(in text: String?) -> String? {
        guard let text,
              let match = text.range(of: #"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?"#,
                                     options: .regularExpression) else { return nil }
        return String(text[match])
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func parts(_ version: String) -> ([Int], String?) {
            let halves = version.split(separator: "-", maxSplits: 1).map(String.init)
            return (halves[0].split(separator: ".").map { Int($0) ?? 0 },
                    halves.count > 1 ? halves[1] : nil)
        }
        let lhs = parts(candidate), rhs = parts(installed)
        let count = max(lhs.0.count, rhs.0.count)
        for index in 0..<count {
            let a = index < lhs.0.count ? lhs.0[index] : 0
            let b = index < rhs.0.count ? rhs.0[index] : 0
            if a != b { return a > b }
        }
        if lhs.1 == nil, rhs.1 != nil { return true }
        if lhs.1 != nil, rhs.1 == nil { return false }
        return (lhs.1 ?? "").localizedStandardCompare(rhs.1 ?? "") == .orderedDescending
    }
}
