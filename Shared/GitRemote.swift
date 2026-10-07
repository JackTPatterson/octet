import Foundation

/// A checkout's remote as a web page, and the git commands the Git panel
/// runs itself: commit, push, pull, fetch.
enum GitRemote {
    /// `https://github.com/owner/repo` for any of the ways a remote is
    /// spelled: `git@github.com:owner/repo.git`, `ssh://git@host/owner/repo`,
    /// `https://user@host/owner/repo.git`. Nil for a local path.
    static func webURL(_ remote: String) -> URL? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        if text.hasSuffix("/") { text = String(text.dropLast()) }
        var host: String
        var path: String
        if let scheme = text.range(of: "://") {
            let rest = text[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash])
            path = String(rest[rest.index(after: slash)...])
        } else if let colon = text.firstIndex(of: ":"), !text.hasPrefix("/"), !text.hasPrefix(".") {
            // scp-like: user@host:owner/repo
            host = String(text[..<colon])
            path = String(text[text.index(after: colon)...])
        } else {
            return nil
        }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        // An ssh port isn't the web one.
        if let port = host.firstIndex(of: ":") { host = String(host[..<port]) }
        // GitHub's ssh-over-https host.
        if host == "ssh.github.com" { host = "github.com" }
        guard !host.isEmpty, host.contains("."), !path.isEmpty else { return nil }
        return URL(string: "https://\(host)/\(path)")
    }

    /// Where a branch's pull request starts: GitHub's compare page, GitLab's
    /// new merge request, Bitbucket's new pull request; the repository's page
    /// elsewhere.
    static func pullRequestURL(remote: String, branch: String, base: String?) -> URL? {
        guard let web = webURL(remote), let host = web.host else { return nil }
        let encode = { (name: String) in name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? name }
        let target = base.map(shortBase)
        if host.contains("github") {
            let range = target.map { "\(encode($0))...\(encode(branch))" } ?? encode(branch)
            return URL(string: web.absoluteString + "/compare/" + range + "?expand=1")
        }
        if host.contains("gitlab") {
            var components = URLComponents(string: web.absoluteString + "/-/merge_requests/new")
            components?.queryItems = [URLQueryItem(name: "merge_request[source_branch]", value: branch)]
                + (target.map { [URLQueryItem(name: "merge_request[target_branch]", value: $0)] } ?? [])
            return components?.url
        }
        if host.contains("bitbucket") {
            var components = URLComponents(string: web.absoluteString + "/pull-requests/new")
            components?.queryItems = [URLQueryItem(name: "source", value: branch)]
                + (target.map { [URLQueryItem(name: "dest", value: $0)] } ?? [])
            return components?.url
        }
        return web
    }

    /// `origin/main` is `main` on the remote's site.
    static func shortBase(_ base: String) -> String {
        guard let slash = base.firstIndex(of: "/") else { return base }
        return String(base[base.index(after: slash)...])
    }

    // MARK: - Commands

    /// Push: the branch to its upstream, or published to `origin` (the
    /// first remote when there's no origin) with its upstream set.
    static func pushArguments(branch: String?, upstream: String?, remotes: [String]) -> [String]? {
        if upstream != nil { return ["push"] }
        guard let branch, let remote = remotes.contains("origin") ? "origin" : remotes.first else { return nil }
        return ["push", "-u", remote, branch]
    }

    /// Pull without a merge commit or a rebase: only when it fast-forwards,
    /// so an agent's work is never rewritten from the panel.
    static let pullArguments = ["pull", "--ff-only"]
    static let fetchArguments = ["fetch", "--all", "--prune"]

    /// Commit: what's staged, or everything when nothing is.
    static func commitPlan(files: [AgentGit.FileChange]) -> (stageAll: Bool, count: Int) {
        let staged = files.filter(\.staged).count
        return staged > 0 ? (false, staged) : (true, files.count)
    }

    /// The first line of a git error that says what went wrong, in plainer
    /// words for the usual ones.
    static func explain(_ error: String) -> String {
        let lowered = error.lowercased()
        if lowered.contains("not possible to fast-forward") || lowered.contains("diverging branches") {
            return "The branch and its upstream have both moved on. Ask the agent to update from upstream, or merge in a terminal."
        }
        if lowered.contains("rejected") && (lowered.contains("fetch first") || lowered.contains("non-fast-forward")) {
            return "The remote has commits this branch doesn't. Pull first, then push."
        }
        if lowered.contains("could not read username") || lowered.contains("authentication failed")
            || lowered.contains("permission denied (publickey)") || lowered.contains("terminal prompts disabled") {
            return "Git couldn't sign in to the remote. Push once from a terminal so your credentials are saved, then try again."
        }
        if lowered.contains("nothing to commit") { return "Nothing to commit." }
        if lowered.contains("please tell me who you are") {
            return "Git doesn't know who you are yet. Set user.name and user.email (git config --global), then commit again."
        }
        let lines = error.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first { $0.lowercased().hasPrefix("error:") || $0.lowercased().hasPrefix("fatal:") }
            .map { String($0.drop(while: { $0 != ":" }).dropFirst()).trimmingCharacters(in: .whitespaces) }
            ?? lines.first ?? error
    }
}
