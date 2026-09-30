import CryptoKit
import Foundation

/// Downloads a registry plugin's files into the plugin folder. Every file is
/// checked against the checksum the registry lists before anything moves
/// into place, and the plugin's own manifest must carry the id it was
/// listed under; a failure leaves what was installed before untouched.
enum PluginInstaller {
    enum Failure: LocalizedError {
        case invalid(String)
        case download(String, Error?)
        case checksum(String)
        case manifest(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let why): "The registry lists it with \(why)"
            case .download(let file, let error): "Couldn't download \(file)" + (error.map { ": \($0.localizedDescription)" } ?? "")
            case .checksum(let file): "\(file) doesn't match the registry's checksum"
            case .manifest(let why): why
            }
        }
    }

    static func install(_ entry: PluginRegistry.Entry, into root: String, registry: URL,
                        session: URLSession = .shared) async throws {
        if let problem = entry.problem { throw Failure.invalid(problem) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
        // Staged beside the destination, so the final move is a rename.
        let staging = root + "/.staging-\(entry.id)-\(UUID().uuidString)"
        try fileManager.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(atPath: staging) }

        for file in entry.files {
            guard let url = entry.url(of: file) else { throw Failure.download(file.path, nil) }
            let data: Data
            do {
                let (body, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download(file.path, nil) }
                data = body
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.download(file.path, error)
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == file.sha256 else { throw Failure.checksum(file.path) }
            let destination = staging + "/" + file.path
            try fileManager.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: destination))
            // Scripts run through `sh`, but keep them executable for people
            // who run them by hand.
            if file.path.hasSuffix(".sh") {
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)
            }
        }

        switch OctetPlugins.load(staging + "/" + OctetPluginManifest.fileName) {
        case .success(let manifest):
            guard manifest.id == entry.id else {
                throw Failure.manifest("Its manifest says it is \(manifest.id), not \(entry.id)")
            }
            if let problem = OctetPlugins.validate(manifest) { throw Failure.manifest(problem) }
        case .failure(let error):
            throw Failure.manifest("Its manifest couldn't be read: \(error.localizedDescription)")
        }

        let receipt = PluginInstallReceipt(id: entry.id, version: entry.version, repo: entry.repo, ref: entry.ref,
                                           registry: registry.absoluteString, installedAt: Date())
        try PluginInstallReceipt.encoder.encode(receipt)
            .write(to: URL(fileURLWithPath: staging + "/" + PluginInstallReceipt.fileName))

        let destination = root + "/" + entry.id
        if fileManager.fileExists(atPath: destination) {
            _ = try fileManager.replaceItemAt(URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: staging))
        } else {
            try fileManager.moveItem(atPath: staging, toPath: destination)
        }
    }
}
