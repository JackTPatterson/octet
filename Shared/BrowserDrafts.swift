import Foundation
import CryptoKit

struct BrowserDraft: Codable, Equatable {
    let id: UUID
    var context: BrowserElementContext
    var note: String
}

enum BrowserDrafts {
    struct Envelope: Codable { var projectDirectory: String?; var items: [BrowserDraft] }
    static func file(key: String, directory: URL) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    static func load(_ file: URL) throws -> [BrowserDraft] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 400_000 else { throw BrowserElementContext.AnnotationError.invalid }
        return Array(try JSONDecoder().decode(Envelope.self, from: data).items.prefix(8))
    }
    static func save(_ items: [BrowserAnnotation], to file: URL, projectDirectory: String? = nil) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rows = items.prefix(8).map { BrowserDraft(id: $0.id, context: $0.context, note: String($0.note.prefix(2000))) }
        try JSONEncoder().encode(Envelope(projectDirectory: projectDirectory, items: rows)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func retained(in root: String, directory: URL) -> Bool {
        let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.contains { file in
            guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Envelope.self, from: data),
                  !saved.items.isEmpty, let project = saved.projectDirectory else { return false }
            let path = URL(fileURLWithPath: project).resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root + "/")
        }
    }

}

enum BrowserViewport: String, CaseIterable {
    case desktop, phone, tablet, laptop
    var title: String {
        switch self {
        case .desktop: "Fit pane"
        case .phone: "Phone · 390 × 844"
        case .tablet: "Tablet · 768 × 1024"
        case .laptop: "Laptop · 1440 × 900"
        }
    }
    var size: CGSize? {
        switch self {
        case .desktop: nil
        case .phone: CGSize(width: 390, height: 844)
        case .tablet: CGSize(width: 768, height: 1024)
        case .laptop: CGSize(width: 1440, height: 900)
        }
    }
}
