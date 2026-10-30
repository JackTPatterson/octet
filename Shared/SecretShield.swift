import Foundation

/// Keeps secrets someone pastes into a prompt out of the model's context.
/// A pasted key is swapped for `$NAME` before the message goes anywhere,
/// the value is written to a private env file the person can copy from, and
/// anything the agent prints that contains it is masked on the way back.
///
/// This stops accidental leaks into context, logs and the transcript. It
/// isn't a sandbox: an agent that can run commands with the variable set can
/// still send it somewhere, and masking only knows the exact value and its
/// base64 and URL-encoded forms.
enum SecretShield {
    struct Match: Equatable {
        var name: String
        var value: String
    }

    /// Recognisable token shapes, with the variable name each is usually
    /// kept under. Order matters: the more specific prefix comes first.
    private static let tokenShapes: [(name: String, pattern: String)] = [
        ("PRIVATE_KEY", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----"#),
        ("ANTHROPIC_API_KEY", #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#),
        ("OPENAI_API_KEY", #"\bsk-(?:proj-)?[A-Za-z0-9_\-]{32,}"#),
        ("STRIPE_SECRET_KEY", #"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"#),
        ("STRIPE_WEBHOOK_SECRET", #"\bwhsec_[A-Za-z0-9]{24,}"#),
        ("GITHUB_TOKEN", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}|\bgithub_pat_[A-Za-z0-9_]{40,}"#),
        ("AWS_ACCESS_KEY_ID", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("GOOGLE_API_KEY", #"\bAIza[0-9A-Za-z_\-]{35}"#),
        ("SLACK_TOKEN", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
        ("NPM_TOKEN", #"\bnpm_[A-Za-z0-9]{36}\b"#),
        ("JWT", #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#),
    ]

    /// `NAME=value` where the name says it holds a secret, as in a pasted
    /// `.env`. Placeholders (`$FOO`, `${FOO}`) and short values are left.
    private static let assignment = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:export[ \t]+)?([A-Za-z][A-Za-z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL)[A-Za-z0-9_]*)[ \t]*=[ \t]*(?:"([^"\n]{8,})"|'([^'\n]{8,})'|([^\s"'#$][^\s"'#]{7,}))"#,
        options: [.caseInsensitive])

    private static let shapes: [(name: String, regex: NSRegularExpression)] = tokenShapes.map {
        ($0.name, try! NSRegularExpression(pattern: $0.pattern))
    }

    /// Every secret in `text`, longest first so one that contains another
    /// is replaced whole.
    static func find(in text: String) -> [Match] {
        var found: [Match] = []
        let whole = NSRange(text.startIndex..., in: text)
        for (name, regex) in shapes {
            for match in regex.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                found.append(Match(name: name, value: String(text[range])))
            }
        }
        for match in assignment.matches(in: text, range: whole) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let valueRange = (2...4).lazy.compactMap { Range(match.range(at: $0), in: text) }.first
            guard let valueRange else { continue }
            found.append(Match(name: String(text[nameRange]).uppercased(), value: String(text[valueRange])))
        }
        var seen = Set<String>()
        return found
            .filter { seen.insert($0.value).inserted }
            .sorted { $0.value.count > $1.value.count }
    }

    /// The forms a value can turn up in once something has handled it.
    static func variants(of value: String) -> [String] {
        var forms = [value]
        let data = Data(value.utf8)
        forms.append(data.base64EncodedString())
        if let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != value {
            forms.append(encoded)
        }
        // Inside a JSON string a newline or quote is escaped.
        if let json = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: json, encoding: .utf8) {
            let inner = String(text.dropFirst(2).dropLast(2))
            if inner != value { forms.append(inner) }
        }
        return forms
    }

    /// A shell-safe single-quoted literal.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The secrets one conversation has taken in, and the env file that holds
/// them for the person and the agent's shell.
@MainActor
final class SecretVault {
    private(set) var secrets: [SecretShield.Match] = []
    private let conversationID: String
    private var maskForms: [(form: String, name: String)] = []

    init(conversationID: String) {
        self.conversationID = conversationID
        Self.purgeStaleOnce()
    }

    var isEmpty: Bool { secrets.isEmpty }

    /// Where the values are written: owner-only, in a folder only this
    /// user can enter, removed when the conversation closes.
    var fileURL: URL { Self.directory.appendingPathComponent("\(conversationID).env") }

    /// Variables for a process started after secrets were taken in.
    var environment: [String: String] {
        Dictionary(secrets.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
    }

    struct Result {
        var text: String
        /// What this message added, for the note and the transcript.
        var added: [SecretShield.Match]
    }

    /// `text` with every secret in it replaced by `$NAME`.
    func shield(_ text: String) -> Result {
        var shielded = text
        var added: [SecretShield.Match] = []
        for var match in SecretShield.find(in: text) {
            if let known = secrets.first(where: { $0.value == match.value }) {
                shielded = shielded.replacingOccurrences(of: match.value, with: "$\(known.name)")
                continue
            }
            match.name = unique(match.name)
            secrets.append(match)
            added.append(match)
            shielded = shielded.replacingOccurrences(of: match.value, with: "$\(match.name)")
        }
        if !added.isEmpty {
            rebuildMask()
            writeFile()
        }
        return Result(text: shielded, added: added)
    }

    /// The note the agent gets with a message that carried secrets.
    func note(for added: [SecretShield.Match]) -> String {
        let names = added.map { "$\($0.name)" }.joined(separator: ", ")
        let path = SecretShield.quote(fileURL.path)
        return """


        [Octet: the message held \(added.count == 1 ? "a secret" : "\(added.count) secrets"), kept out of this conversation and saved as \(names) in a private temporary environment file, \(fileURL.path), so the person can copy them where they're needed. \
        You can't see the value\(added.count == 1 ? "" : "s"); refer to \(added.count == 1 ? "it" : "them") by name. To use \(added.count == 1 ? "it" : "them") in a command, load the file first: `set -a; . \(path); set +a`. \
        Never print, cat, echo or log the file or the values.]
        """
    }

    /// `text` with any known secret masked as `$NAME`.
    func mask(_ text: String) -> String {
        guard !maskForms.isEmpty else { return text }
        var result = text
        for (form, name) in maskForms where result.contains(form) {
            result = result.replacingOccurrences(of: form, with: "$\(name)")
        }
        return result
    }

    func mask(_ data: Data) -> Data {
        guard !maskForms.isEmpty, let text = String(data: data, encoding: .utf8) else { return data }
        let masked = mask(text)
        return masked == text ? data : Data(masked.utf8)
    }

    func removeFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Internals

    private func unique(_ name: String) -> String {
        let taken = Set(secrets.map(\.name))
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name)_\(n)") { n += 1 }
        return "\(name)_\(n)"
    }

    private func rebuildMask() {
        // Longest first, so a value containing another is masked whole.
        maskForms = secrets
            .flatMap { secret in SecretShield.variants(of: secret.value).map { ($0, secret.name) } }
            .sorted { $0.0.count > $1.0.count }
    }

    private func writeFile() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        let body = "# Secrets Octet kept out of the conversation. Removed when it closes.\n"
            + secrets.map { "export \($0.name)=\(SecretShield.quote($0.value))" }.joined(separator: "\n") + "\n"
        manager.createFile(atPath: fileURL.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o600])
    }

    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("octet-secrets-\(getuid())", isDirectory: true)
    }

    private static var purged = false

    /// Files from a run that didn't get to clean up. Runs before this
    /// run writes its first, so no live conversation's is touched.
    private static func purgeStaleOnce() {
        guard !purged else { return }
        purged = true
        try? FileManager.default.removeItem(at: directory)
    }
}
