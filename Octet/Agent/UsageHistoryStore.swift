import Foundation

/// Usage across every Claude Code, Codex and OpenCode session on this Mac
/// for the last 90 days, read from the agents' own logs for the usage page.
///
/// The logs run to gigabytes, so each file's records are cached by its size
/// and modification time and only changed files are read again. The scan
/// runs off the main thread and starts when the page opens, not at launch:
/// nothing else needs it.
@MainActor
final class UsageHistoryStore: ObservableObject {
    static let shared = UsageHistoryStore()

    @Published private(set) var records: [UsageRecord] = []
    @Published private(set) var scanning = false
    @Published private(set) var updatedAt: Date?

    private init() {}

    /// Reads the logs again unless a read finished in the last minute.
    /// `profiles` are the extra accounts whose config folders hold logs too.
    func refresh(force: Bool = false, profiles: [AccountProfile] = []) {
        guard !scanning else { return }
        if !force, let updatedAt, Date().timeIntervalSince(updatedAt) < 60 { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let records = UsageLogScanner(cacheURL: Self.cacheURL, profiles: profiles).scan(now: Date())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = UsageHistoryStore.shared
                    store.records = records
                    store.updatedAt = Date()
                    store.scanning = false
                }
            }
        }
    }

    nonisolated private static var cacheURL: URL {
        EngineSession.supportDirectory.appendingPathComponent("usage-history-cache.plist")
    }
}

/// Finds the agents' logs, reads the ones that changed, and keeps what each
/// file held for next time.
struct UsageLogScanner {
    let cacheURL: URL
    var profiles: [AccountProfile] = []
    var home = FileManager.default.homeDirectoryForCurrentUser
    var environment = ProcessInfo.processInfo.environment

    /// Bumped when parsing or pricing changes, so cached records are read again.
    static let cacheVersion = 2
    /// A little past the longest period, so a file touched 90 days ago still counts.
    static let keepDays = 91

    private struct Cache: Codable {
        var version = UsageLogScanner.cacheVersion
        var files: [String: CachedFile] = [:]
    }

    private struct CachedFile: Codable {
        var size: Int
        var modified: Date
        var records: [UsageRecord]
    }

    private enum Kind { case claude, codex }

    func scan(now: Date) -> [UsageRecord] {
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        var cache = loadCache()
        let files = logFiles(modifiedAfter: cutoff)

        // Unchanged files come from the cache; changed ones are read in parallel.
        var stale: [LogFile] = []
        var fresh: [String: CachedFile] = [:]
        for file in files {
            if let cached = cache.files[file.path], cached.size == file.size, cached.modified == file.modified {
                fresh[file.path] = cached
            } else {
                stale.append(file)
            }
        }
        let parsed = UnsafeMutableBufferPointer<CachedFile?>.allocate(capacity: stale.count)
        parsed.initialize(repeating: nil)
        defer { parsed.deallocate() }
        DispatchQueue.concurrentPerform(iterations: stale.count) { index in
            let file = stale[index]
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .mappedIfSafe) else { return }
            var records: [UsageRecord]
            switch file.kind {
            case .claude:
                records = UsageRecords.dedupe(UsageLogParsers.claude(data))
            case .codex:
                let name = (file.path as NSString).lastPathComponent
                records = UsageRecords.compact(UsageLogParsers.codex(data, fallbackSession: name))
            }
            if let account = file.account { for i in records.indices { records[i].account = account } }
            parsed[index] = CachedFile(size: file.size, modified: file.modified, records: records)
        }
        for (index, file) in stale.enumerated() {
            if let result = parsed[index] { fresh[file.path] = result }
        }
        cache.files = fresh
        saveCache(cache)

        var all = fresh.values.flatMap(\.records)
        all = UsageRecords.dedupe(all)
        all += UsageLogParsers.openCode(database: openCodeDatabase, since: cutoff)
        return UsageRecords.compact(all.filter { $0.date >= cutoff && $0.date <= now })
    }

    // MARK: Files

    private struct LogFile {
        let path: String
        let kind: Kind
        /// The profile whose folder it's in; nil for the default folder.
        let account: String?
        let size: Int
        let modified: Date
    }

    /// The default folders, then each account profile's. Octet itself
    /// runs agents with the profile's folder in their environment, never
    /// its own, so its CLAUDE_CONFIG_DIR and CODEX_HOME are the defaults.
    private var roots: [(url: URL, kind: Kind, account: String?)] {
        let claude = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        var roots: [(url: URL, kind: Kind, account: String?)] = [
            (claude.appendingPathComponent("projects"), .claude, nil),
            (codex.appendingPathComponent("sessions"), .codex, nil),
        ]
        var seen = Set(roots.map { $0.url.standardizedFileURL.path })
        for profile in profiles {
            let base = URL(fileURLWithPath: profile.expandedHome(userHome: home.path))
            let root = profile.agent == "codex" ? (base.appendingPathComponent("sessions"), Kind.codex)
                : (base.appendingPathComponent("projects"), Kind.claude)
            guard seen.insert(root.0.standardizedFileURL.path).inserted else { continue }
            roots.append((root.0, root.1, profile.id))
        }
        return roots
    }

    private var openCodeDatabase: String {
        let data = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".local/share")
        return data.appendingPathComponent("opencode/opencode.db").path
    }

    private func logFiles(modifiedAfter cutoff: Date) -> [LogFile] {
        var files: [LogFile] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for (root, kind, account) in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= cutoff else { continue }
                files.append(LogFile(path: url.path, kind: kind, account: account, size: values.fileSize ?? 0, modified: modified))
            }
        }
        return files
    }

    // MARK: Cache

    private func loadCache() -> Cache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? PropertyListDecoder().decode(Cache.self, from: data),
              cache.version == Self.cacheVersion else { return Cache() }
        return cache
    }

    private func saveCache(_ cache: Cache) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
