import Foundation

/// Which icon a file gets in the Files tab when it has no language logo:
/// by what kind of thing it is, from its name.
enum FileIcons {
    /// An SF Symbol name for a file, or "doc" when it's nothing in particular.
    static func symbol(forName name: String) -> String {
        let lower = name.lowercased()
        if let special = named[lower] { return special }
        if lower.hasPrefix(".env") { return "key" }
        let ext = (lower as NSString).pathExtension
        for (symbol, extensions) in groups where extensions.contains(ext) { return symbol }
        if lower.hasSuffix(".lock") || lower.hasSuffix("-lock.json") { return "lock" }
        return "doc"
    }

    private static let named: [String: String] = [
        ".gitignore": "gearshape", ".gitattributes": "gearshape", ".editorconfig": "gearshape",
        ".prettierrc": "gearshape", ".eslintrc": "gearshape", ".npmrc": "gearshape", ".nvmrc": "gearshape",
        "license": "doc.text", "licence": "doc.text", "readme": "doc.text", "changelog": "doc.text",
        "makefile": "terminal", "package.lock": "lock", "yarn.lock": "lock", "cargo.lock": "lock",
        "gemfile.lock": "lock", "podfile.lock": "lock", "pnpm-lock.yaml": "lock",
    ]

    private static let groups: [(String, Set<String>)] = [
        ("photo", ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "ico", "icns", "svg", "avif"]),
        ("film", ["mp4", "mov", "m4v", "webm", "mkv", "avi"]),
        ("waveform", ["mp3", "wav", "aac", "m4a", "flac", "ogg", "aiff"]),
        ("doc.richtext", ["pdf", "rtf", "pages", "key", "numbers", "doc", "docx", "ppt", "pptx"]),
        ("tablecells", ["csv", "tsv", "xls", "xlsx"]),
        ("doc.zipper", ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg"]),
        ("doc.text", ["txt", "log", "text", "rtfd"]),
        ("lock", ["lock"]),
        ("key", ["pem", "key", "crt", "cer", "p12", "pub"]),
        ("gearshape", ["ini", "conf", "cfg", "plist", "entitlements", "xcconfig", "env", "toml"]),
        ("terminal", ["sh", "zsh", "bash", "fish", "command"]),
        ("shippingbox", ["xcodeproj", "xcworkspace", "framework", "app", "xcframework", "bundle"]),
    ]
}
