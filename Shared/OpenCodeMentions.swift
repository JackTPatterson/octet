import Foundation

/// `@path` mentions in a message to OpenCode, as the file parts its own
/// interface sends: the server reads each file into the prompt, where a
/// plain `@path` would leave the model with only a name.
enum OpenCodeMentions {
    private static let pattern = try! NSRegularExpression(pattern: #"(?<![\w@])@([^\s@]+)"#)

    static func fileParts(in text: String, cwd: String,
                          isFile: (String) -> Bool = OpenCodeMentions.isFile) -> [[String: Any]] {
        var seen = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match -> [String: Any]? in
            guard let tokenRange = Range(match.range(at: 1), in: text) else { return nil }
            // Sentence punctuation after a path isn't part of it.
            let token = String(text[tokenRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}\"'"))
            guard !token.isEmpty else { return nil }
            let absolute = token.hasPrefix("/") ? token
                : token.hasPrefix("~/") ? NSHomeDirectory() + token.dropFirst(1)
                : (cwd as NSString).appendingPathComponent(token)
            let path = (absolute as NSString).standardizingPath
            guard isFile(path), seen.insert(path).inserted else { return nil }
            // Where the mention sits, in the UTF-16 offsets the server counts in.
            let start = match.range.location
            let end = start + 1 + (token as NSString).length
            return [
                "type": "file", "mime": "text/plain",
                "url": URL(fileURLWithPath: path).absoluteString,
                "filename": (path as NSString).lastPathComponent,
                "source": ["type": "file", "path": token,
                           "text": ["value": "@" + token, "start": start, "end": end]] as [String: Any],
            ]
        }
    }

    static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }
}
