import Foundation

/// Images for Qwen Code, which takes them as `@path` mentions of files it
/// may read (its stream-json input turns image blocks into text): written
/// to Qwen's own temp folder, one of the two places `@` may reach, so
/// nothing lands in the project.
enum QwenImages {
    /// `<runtime>/tmp/octet`: Qwen's runtime folder is QWEN_RUNTIME_DIR, else
    /// QWEN_HOME, else ~/.qwen.
    static func directory(environment: [String: String], home: String = NSHomeDirectory()) -> String {
        let runtime = [environment["QWEN_RUNTIME_DIR"], environment["QWEN_HOME"]]
            .compactMap { $0 }.first { !$0.isEmpty }
            .map { ($0 as NSString).expandingTildeInPath } ?? home + "/.qwen"
        return runtime + "/tmp/octet"
    }

    /// `@path`, with spaces escaped as Qwen's `@` reading expects.
    static func mention(_ path: String) -> String {
        "@" + path.replacingOccurrences(of: " ", with: "\\ ")
    }

    /// The message Qwen gets: a mention of each image, then the text.
    static func message(_ text: String, images paths: [String]) -> String {
        let mentions = paths.map(mention).joined(separator: " ")
        return text.isEmpty ? mentions : mentions + "\n" + text
    }

    /// Writes `images` (data and file extension) into `directory`, clearing
    /// ones older than a day; the paths, or nil if any couldn't be written.
    static func save(_ images: [(data: Data, fileExtension: String)], in directory: String,
                     now: Date = Date()) -> [String]? {
        let files = FileManager.default
        guard (try? files.createDirectory(atPath: directory, withIntermediateDirectories: true)) != nil else { return nil }
        for name in (try? files.contentsOfDirectory(atPath: directory)) ?? [] {
            let path = directory + "/" + name
            if let modified = (try? files.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               now.timeIntervalSince(modified) > 86_400 {
                try? files.removeItem(atPath: path)
            }
        }
        var paths: [String] = []
        for image in images {
            let path = directory + "/" + UUID().uuidString.lowercased() + "." + image.fileExtension
            guard (try? image.data.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
            paths.append(path)
        }
        return paths
    }
}
