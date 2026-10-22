import AppKit
import SwiftUI

// MARK: - Tiles

/// One tile: a file with its type's icon, or pasted text with its first
/// line; a remove button in the composer, a preview on click.
struct ChatAttachmentTile: View {
    enum Content { case file(path: String, cwd: String?), pasted(String) }
    let content: Content
    var remove: (() -> Void)?
    @State private var hovered = false
    @State private var previewing = false

    var body: some View {
        HStack(spacing: 10) {
            ChatFileBadge(style: style)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ChatStyle.metaMedium)
                    .foregroundStyle(ChatStyle.text)
                    .lineLimit(1)
                    // A file keeps its extension in view; pasted text its start.
                    .truncationMode(isPasted ? .tail : .middle)
                Text(subtitle)
                    .font(Theme.interfaceFont(11))
                    .foregroundStyle(ChatStyle.mutedText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 7)
        .padding(.trailing, 10)
        // One width for every tile, as ChatGPT's are.
        .frame(width: 176, height: 46)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovered ? ChatStyle.hover : ChatStyle.bubble))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ChatStyle.border, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if let remove, hovered {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ChatStyle.onPrimary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(ChatStyle.primary))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .accessibilityLabel("Remove \(title)")
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { open() }
        .popover(isPresented: $previewing, arrowEdge: .top) { preview }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(subtitle): \(title)")
        .accessibilityAddTraits(.isButton)
    }


    private var isPasted: Bool { if case .pasted = content { true } else { false } }

    private var style: ChatFileStyle {
        switch content {
        case .file(let path, _): isFolder(path) ? .folder : ChatFileStyle(path: path)
        case .pasted: .pasted
        }
    }

    private var title: String {
        switch content {
        case .file(let path, _): (path as NSString).lastPathComponent
        case .pasted(let text):
            text.split(separator: "\n", omittingEmptySubsequences: true).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? "Pasted text"
        }
    }

    private var subtitle: String {
        switch content {
        case .file(let path, _):
            if isFolder(path) { return "Folder" }
            let ext = (path as NSString).pathExtension
            return ext.isEmpty ? "File" : Self.kind(ext)
        case .pasted(let text):
            let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            return "Pasted text · \(lines) \(lines == 1 ? "line" : "lines")"
        }
    }

    private var help: String {
        switch content {
        case .file(let path, _): path + (remove == nil ? "\nClick to open" : "")
        case .pasted: "Click to see the pasted text"
        }
    }

    private func resolved(_ path: String, cwd: String?) -> String {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return (path as NSString).expandingTildeInPath }
        return ((cwd ?? NSHomeDirectory()) as NSString).appendingPathComponent(path)
    }

    private func isFolder(_ path: String) -> Bool {
        guard case .file(_, let cwd) = content else { return false }
        var directory: ObjCBool = false
        return path.hasSuffix("/") || (FileManager.default.fileExists(atPath: resolved(path, cwd: cwd), isDirectory: &directory) && directory.boolValue)
    }

    private func open() {
        switch content {
        case .file(let path, let cwd):
            NSWorkspace.shared.open(URL(fileURLWithPath: resolved(path, cwd: cwd)))
        case .pasted:
            previewing = true
        }
    }

    @ViewBuilder private var preview: some View {
        if case .pasted(let text) = content {
            ScrollView {
                Text(text)
                    .font(Theme.Text.mono(12))
                    .foregroundStyle(ChatStyle.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(width: 520, height: min(420, CGFloat(text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }) * 17 + 28))
            .background(ChatStyle.card)
        }
    }

    static func kind(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": "PDF"
        case "md", "markdown": "Markdown"
        case "txt": "Text"
        case "json": "JSON"
        case "csv": "Spreadsheet"
        case "xlsx", "xls": "Excel"
        case "doc", "docx": "Document"
        case "zip", "gz", "tar": "Archive"
        case "mov", "mp4", "m4v": "Video"
        case "mp3", "wav", "m4a": "Audio"
        default: ext.uppercased()
        }
    }

}

/// A file type's look on its tile: red for PDF, green for spreadsheets,
/// blue for documents and so on, with the extension spelled out where a
/// word says more than a picture (PDF, CSV), and a symbol where it doesn't
/// (images, folders, code, pasted text).
struct ChatFileStyle {
    let color: Color
    var label: String?
    var symbol: String = "doc.fill"

    static let folder = ChatFileStyle(color: Color(hex: "0EA5E9"), symbol: "folder.fill")
    static let pasted = ChatFileStyle(color: Color(hex: "14B8A6"), symbol: "text.alignleft")

    init(color: Color, label: String? = nil, symbol: String = "doc.fill") {
        self.color = color
        self.label = label
        self.symbol = symbol
    }

    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": self.init(color: Color(hex: "E5484D"), label: "PDF")
        case "csv", "tsv": self.init(color: Color(hex: "16A34A"), label: ext.uppercased())
        case "xlsx", "xls", "numbers": self.init(color: Color(hex: "15803D"), label: "XLS")
        case "doc", "docx", "pages", "rtf": self.init(color: Color(hex: "2563EB"), label: "DOC")
        case "ppt", "pptx", "key": self.init(color: Color(hex: "EA580C"), label: "PPT")
        case "md", "markdown": self.init(color: Color(hex: "475569"), label: "MD")
        case "txt", "log": self.init(color: Color(hex: "64748B"), label: ext.uppercased())
        case "json", "yaml", "yml", "toml", "xml", "plist":
            self.init(color: Color(hex: "0891B2"), label: ext == "yml" ? "YAML" : String(ext.uppercased().prefix(4)))
        case "zip", "gz", "tar", "tgz", "7z", "rar", "dmg": self.init(color: Color(hex: "D97706"), label: String(ext.uppercased().prefix(3)))
        case "mov", "mp4", "m4v", "webm": self.init(color: Color(hex: "DB2777"), label: String(ext.uppercased().prefix(4)))
        case "mp3", "wav", "m4a", "aiff", "flac": self.init(color: Color(hex: "F97316"), label: String(ext.uppercased().prefix(4)))
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff":
            self.init(color: Color(hex: "9333EA"), symbol: "photo.fill")
        case "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "cc", "cpp", "h", "m",
             "cs", "php", "sh", "zsh", "sql", "html", "css", "scss", "vue", "svelte":
            self.init(color: Color(hex: "4F46E5"), symbol: "chevron.left.forwardslash.chevron.right")
        default: self.init(color: Color(hex: "6B7280"), label: ext.isEmpty ? nil : String(ext.uppercased().prefix(4)))
        }
    }
}

/// The icon on a tile: a page-like square in the type's colour, its top
/// corner folded, with the type's label or symbol in white.
struct ChatFileBadge: View {
    let style: ChatFileStyle
    var size: CGFloat = 32

    var body: some View {
        let fold = size * 0.28
        ZStack {
            FoldedCorner(fold: fold)
                .fill(LinearGradient(colors: [style.color.opacity(0.92), style.color],
                                     startPoint: .top, endPoint: .bottom))
            // The fold itself, a shade lighter.
            Path { path in
                path.move(to: CGPoint(x: size - fold, y: 0))
                path.addLine(to: CGPoint(x: size - fold, y: fold - 2))
                path.addQuadCurve(to: CGPoint(x: size - fold + 2, y: fold), control: CGPoint(x: size - fold, y: fold))
                path.addLine(to: CGPoint(x: size, y: fold))
                path.closeSubpath()
            }
            .fill(Color.white.opacity(0.35))
            Group {
                if let label = style.label {
                    Text(label)
                        .font(.system(size: label.count > 3 ? size * 0.24 : size * 0.29, weight: .heavy, design: .rounded))
                        .tracking(-0.2)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                } else {
                    Image(systemName: style.symbol).font(.system(size: size * 0.4, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .offset(y: style.label == nil ? 1 : size * 0.08)
        }
        .frame(width: size, height: size)
        .shadow(color: style.color.opacity(0.35), radius: 3, y: 1)
    }
}

/// A rounded square with its top-right corner cut, like a page's fold.
private struct FoldedCorner: Shape {
    let fold: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 7
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// An image tile, for the composer: a square thumbnail with the same remove
/// button as the other tiles.
struct ChatImageTile: View {
    let data: Data
    var remove: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        Group {
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ChatStyle.bubble
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ChatStyle.border, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if let remove, hovered {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ChatStyle.onPrimary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(ChatStyle.primary))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .accessibilityLabel("Remove image")
            }
        }
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityLabel("Attached image")
    }
}

/// The composer's tray: images, files and pasted text waiting to go, in
/// one row above the box.
struct ComposerAttachmentTray: View {
    let images: [AgentSession.Attachment]
    let extras: [ComposerExtra]
    let cwd: String
    let removeImage: (Int) -> Void
    let removeExtra: (ComposerExtra) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    ChatImageTile(data: image.data) { removeImage(index) }
                }
                ForEach(extras) { extra in
                    switch extra.kind {
                    case .file(let path):
                        ChatAttachmentTile(content: .file(path: path, cwd: cwd)) { removeExtra(extra) }
                    case .pasted(let text):
                        ChatAttachmentTile(content: .pasted(text)) { removeExtra(extra) }
                    }
                }
            }
            // Room for the remove buttons that sit over the corners.
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }
}

/// What a sent message carried, above its bubble: images as thumbnails,
/// files and pasted text as tiles, right-aligned like the bubble.
struct SentAttachments: View {
    let images: [Data]
    let parts: ChatAttachmentFormat.Parts
    let cwd: String?
    @Environment(\.openImage) private var openImage

    var body: some View {
        // Wraps onto more rows rather than running off the side.
        FlowRight(spacing: 8) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: images.count == 1 ? min(240, image.size.width) : 96,
                               height: images.count == 1 ? min(180, image.size.height) : 96)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ChatStyle.border, lineWidth: 1))
                        .contentShape(Rectangle())
                        .onTapGesture { openImage(data) }
                        .help("Click to enlarge")
                        .accessibilityLabel("Image")
                        .accessibilityAddTraits(.isButton)
                }
            }
            ForEach(Array(parts.files.enumerated()), id: \.offset) { _, path in
                ChatAttachmentTile(content: .file(path: path, cwd: cwd))
            }
            ForEach(Array(parts.pasted.enumerated()), id: \.offset) { _, text in
                ChatAttachmentTile(content: .pasted(text))
            }
        }
    }
}

/// Lays its children out in rows from the trailing edge, wrapping.
struct FlowRight: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let added = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += added
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
