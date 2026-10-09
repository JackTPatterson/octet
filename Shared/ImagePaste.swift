import Foundation

/// Pasting a screenshot into an agent is the one thing every terminal UI gets
/// wrong: the image either arrives as binary noise or not at all. Octet sees
/// ⌘V before the terminal does, writes the image somewhere real, and pastes
/// the path — which is what every agent actually accepts.
enum ImagePaste {
    /// Where pasted images live, kept out of the user's folders.
    static func directory(home: String = NSHomeDirectory()) -> String {
        "\(home)/Library/Application Support/Octet/pasted"
    }

    /// A name that sorts by time and says where it came from.
    static func filename(at date: Date = Date(), extension ext: String = "png") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "pasted-\(formatter.string(from: date)).\(ext)"
    }

    /// What gets typed into the pane. Paths with spaces are quoted, since
    /// this lands on a command line.
    static func insertion(for path: String) -> String {
        path.rangeOfCharacter(from: CharacterSet(charactersIn: " '\"\\")) == nil
            ? path
            : "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Whether a clipboard holding an image is really a copied link. Browsers
    /// and Messages put a preview picture (a favicon, a page thumbnail) next
    /// to a copied link, and that picture isn't what was meant: the link is.
    /// "Copy Image" also carries a web address, the image's own, so a link
    /// to an image file, or one copied with an `<img>` in its HTML, still
    /// pastes as the image.
    static func isCopiedLink(text: String?, html: String? = nil) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return false }
        if let html, html.range(of: "<img", options: .caseInsensitive) != nil { return false }
        let imageExtensions: Set = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff", "svg", "avif"]
        return !imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Writes image data and returns the path to paste.
    static func save(_ data: Data, extension ext: String = "png", home: String = NSHomeDirectory(), at date: Date = Date()) throws -> String {
        let folder = directory(home: home)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + filename(at: date, extension: ext)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    /// Pasted images pile up; keep the recent ones and drop the rest.
    static func prune(keeping limit: Int = 50, home: String = NSHomeDirectory()) {
        let folder = directory(home: home)
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder), names.count > limit else { return }
        let sorted = names.map { name -> (String, Date) in
            let attributes = try? manager.attributesOfItem(atPath: folder + "/" + name)
            return (name, (attributes?[.creationDate] as? Date) ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        for (name, _) in sorted.dropFirst(limit) {
            try? manager.removeItem(atPath: folder + "/" + name)
        }
    }
}
