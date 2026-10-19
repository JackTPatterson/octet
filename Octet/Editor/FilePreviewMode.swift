import Foundation

/// How a file opens, chosen from its name alone so it's cheap and testable.
/// Text kinds open in the editor (some with a rendered view beside the
/// source); media kinds open in a viewer and never read as text.
enum FilePreviewMode: Equatable {
    case text, markdown, svg, table, image, audio, video, pdf, binary

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "ico", "icns"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "caf", "ogg", "opus"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "avi", "mkv"]
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]
    /// Formats that are never text, so they skip the read that would fail.
    static let binaryExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "dmg", "pkg", "iso",
        "exe", "dll", "dylib", "so", "a", "o", "class", "jar", "wasm", "bin", "dat",
        "ttf", "otf", "woff", "woff2", "eot", "sqlite", "sqlite3", "db",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "psd", "ai", "sketch", "fig", "car", "nib", "pyc", "DS_Store",
    ]

    static func mode(forPath path: String) -> FilePreviewMode {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "svg" { return .svg }
        if ext == "csv" || ext == "tsv" { return .table }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if ext == "pdf" { return .pdf }
        if markdownExtensions.contains(ext) { return .markdown }
        if binaryExtensions.contains(ext) || (path as NSString).lastPathComponent == ".DS_Store" { return .binary }
        return .text
    }

    /// Whether the file's bytes become the editor's text.
    var readsText: Bool {
        switch self {
        case .text, .markdown, .svg, .table: true
        case .image, .audio, .video, .pdf, .binary: false
        }
    }

    /// Whether a Preview / Source switch makes sense (Markdown has its own).
    var hasSourceToggle: Bool { self == .svg || self == .table }

    /// The delimiter a table file uses.
    static func delimiter(forPath path: String) -> Character {
        (path as NSString).pathExtension.lowercased() == "tsv" ? "\t" : ","
    }
}

/// Delimited text as rows of cells.
enum DelimitedTable {
    /// Rows the table shows before it says it stopped.
    static let maximumRows = 5_000

    struct Parsed: Equatable {
        var rows: [[String]]
        /// Whether more rows followed the cap.
        var truncated: Bool
    }

    /// RFC 4180 style: quoted cells may hold the delimiter, newlines and
    /// doubled quotes. Blank lines are skipped; a final newline adds no row.
    static func parse(_ text: String, delimiter: Character = ",", maximumRows: Int = maximumRows) -> Parsed {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var atCellStart = true
        var cellQuoted = false
        var truncated = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endCell() {
            row.append(cell)
            cell = ""
            atCellStart = true
            cellQuoted = false
        }
        func endRow() {
            let wasQuoted = cellQuoted
            endCell()
            if row.count == 1, row[0].isEmpty, !wasQuoted { row = []; return }
            rows.append(row)
            row = []
        }

        while true {
            guard let c = pending ?? iterator.next() else { break }
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { cell.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    cell.append(c)
                }
                continue
            }
            if c == "\"", atCellStart {
                quoted = true
                cellQuoted = true
                atCellStart = false
            } else if c == delimiter {
                endCell()
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                endRow()
                if rows.count >= maximumRows + 1 {
                    // Header plus the cap; anything more is left unread.
                    truncated = iterator.next() != nil
                    return Parsed(rows: rows, truncated: truncated)
                }
            } else {
                cell.append(c)
                atCellStart = false
            }
        }
        if cellQuoted || !cell.isEmpty || !row.isEmpty { endRow() }
        if rows.count > maximumRows + 1 { rows.removeLast(rows.count - maximumRows - 1); truncated = true }
        return Parsed(rows: rows, truncated: truncated)
    }

    /// Orders cell values: numbers by value, anything else as Finder would.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        if let x = Double(a.trimmingCharacters(in: .whitespaces)), let y = Double(b.trimmingCharacters(in: .whitespaces)) {
            return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        }
        return a.localizedStandardCompare(b)
    }

    /// Row indices ordered by a column; `nil` keeps file order.
    static func order(_ rows: [[String]], column: Int?, ascending: Bool) -> [Int] {
        let indices = Array(rows.indices)
        guard let column else { return indices }
        func cell(_ i: Int) -> String { rows[i].indices.contains(column) ? rows[i][column] : "" }
        return indices.sorted { i, j in
            let result = compare(cell(i), cell(j))
            if result == .orderedSame { return i < j }
            return (result == .orderedAscending) == ascending
        }
    }
}
