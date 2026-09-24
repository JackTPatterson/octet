import Foundation

/// The machine a pane is logged into over SSH, read from the `ssh`, `mosh`
/// or `et` command its shell is running.
struct SSHTarget: Equatable {
    let host: String
    let user: String?

    var display: String { user.map { "\($0)@\(host)" } ?? host }

    /// Options that take a value, as `ssh(1)` lists them.
    private static let optionsWithValue = Set("BbcDEeFIiJLlmOoPpQRSWw")

    /// The target of an interactive `ssh` from its arguments. nil for anything
    /// else, and for `ssh host command`: that runs one command and leaves,
    /// which is what git, rsync and scp start behind the scenes.
    static func parse(_ arguments: [String]) -> SSHTarget? {
        guard let executable = arguments.first,
              ["ssh", "mosh", "et"].contains((executable as NSString).lastPathComponent) else { return nil }
        var user: String?
        var destination: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if destination != nil { return nil }
            if argument == "--" { continue }
            // mosh's and et's long options carry their values with `=`.
            if argument.hasPrefix("--") { continue }
            if argument.hasPrefix("-"), argument.count > 1 {
                // Flags can be bundled (`-tt`, `-4v`); a value-taking one ends
                // the bundle, with its value attached or as the next argument.
                for (offset, flag) in argument.dropFirst().enumerated() where optionsWithValue.contains(flag) {
                    let attached = String(argument.dropFirst(offset + 2))
                    let value = attached.isEmpty ? (index < arguments.count ? arguments[index] : nil) : attached
                    if attached.isEmpty { index += 1 }
                    if flag == "l" { user = value }
                    break
                }
                continue
            }
            destination = argument
        }
        guard var target = destination, !target.isEmpty else { return nil }
        if target.hasPrefix("ssh://") {
            target = String(target.dropFirst("ssh://".count))
            if let colon = target.lastIndex(of: ":"), !target[colon...].contains("]") {
                target = String(target[..<colon])
            }
        }
        // et takes `host:port`; an IPv6 address has more than one colon.
        if (executable as NSString).lastPathComponent == "et", target.filter({ $0 == ":" }).count == 1,
           let colon = target.firstIndex(of: ":") {
            target = String(target[..<colon])
        }
        if let at = target.lastIndex(of: "@") {
            user = String(target[..<at])
            target = String(target[target.index(after: at)...])
        }
        guard !target.isEmpty else { return nil }
        return SSHTarget(host: target, user: user)
    }

    /// The arguments of a command line from `ps -o args=`, split on spaces.
    static func parse(commandLine: String) -> SSHTarget? {
        parse(commandLine.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}
