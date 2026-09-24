import Foundation

struct WorkingTreeChanges: Equatable {
    var added: Int
    var removed: Int
    /// Files changed, untracked ones included.
    var files = 0

    var isEmpty: Bool { added == 0 && removed == 0 && files == 0 }

    static func read(in directory: String) -> WorkingTreeChanges? {
        guard let root = run(["-C", directory, "rev-parse", "--show-toplevel"]), root.status == 0 else { return nil }
        let repo = root.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return nil }

        var result = WorkingTreeChanges(added: 0, removed: 0)
        let againstHead = run(["-C", repo, "diff", "--numstat", "--no-ext-diff", "--no-textconv", "HEAD"])
        let tracked = againstHead?.status == 0
            ? againstHead
            : run(["-C", repo, "diff", "--numstat", "--no-ext-diff", "--no-textconv"])
        if let tracked { result = parseNumstat(tracked.output) }

        if let untracked = run(["-C", repo, "ls-files", "--others", "--exclude-standard", "-z"]),
           untracked.status == 0 {
            let untrackedFiles = untracked.output.split(separator: "\0")
            result.files += untrackedFiles.count
            let files = untrackedFiles.prefix(250)
            var remainingBytes = 10_000_000
            for relative in files where remainingBytes > 0 {
                let url = URL(fileURLWithPath: repo).appendingPathComponent(String(relative)).standardizedFileURL
                guard url.path.hasPrefix(URL(fileURLWithPath: repo).standardizedFileURL.path + "/"),
                      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
                      size.intValue <= min(2_000_000, remainingBytes),
                      let data = try? Data(contentsOf: url), !data.contains(0) else { continue }
                remainingBytes -= data.count
                if !data.isEmpty {
                    result.added += data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                        + (data.last == 0x0A ? 0 : 1)
                }
            }
        }
        return result
    }

    static func parseNumstat(_ text: String) -> WorkingTreeChanges {
        var result = WorkingTreeChanges(added: 0, removed: 0)
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            result.added += Int(fields[0]) ?? 0
            result.removed += Int(fields[1]) ?? 0
            result.files += 1
        }
        return result
    }

    private static func run(_ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
