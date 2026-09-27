import Foundation

/// A Mac this one has paired with.
struct PairedPeer: Codable, Equatable, Identifiable {
    let device: String
    var name: String
    /// Its signing key, as it proved while pairing.
    let identity: Data
    var trust: PeerTrust
    /// Where it was last reached, to try first next time.
    var lastHost: String?
    var lastPort: UInt16?
    let paired: Date

    var id: String { device }
    var fingerprint: String { PeerCrypto.fingerprint(identity) }
}

/// This Mac's identity and the Macs it has paired with, in one file only
/// this user can read (like ~/.ssh). Octet's support folder, so each
/// session keeps its own.
final class PeerStore {
    struct Contents: Codable {
        var device: String
        var identity: Data
        var peers: [PairedPeer]
    }

    let url: URL
    private(set) var contents: Contents
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Contents.self, from: data),
           (try? PeerCrypto.Identity(raw: saved.identity)) != nil {
            contents = saved
        } else {
            contents = Contents(device: UUID().uuidString, identity: PeerCrypto.Identity().raw, peers: [])
            save()
        }
    }

    var device: String { lock.withLock { contents.device } }
    var identity: PeerCrypto.Identity { lock.withLock { try! PeerCrypto.Identity(raw: contents.identity) } }
    var peers: [PairedPeer] { lock.withLock { contents.peers } }

    func peer(device: String) -> PairedPeer? { peers.first { $0.device == device } }

    /// A machine by the name an agent or script used, or its device id.
    func peer(named name: String) -> PairedPeer? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return peers.first { $0.device.lowercased() == wanted } ?? peers.first { $0.name.lowercased() == wanted }
    }

    func add(_ peer: PairedPeer) {
        lock.withLock {
            contents.peers.removeAll { $0.device == peer.device }
            contents.peers.append(peer)
        }
        save()
    }

    func update(device: String, _ change: (inout PairedPeer) -> Void) {
        lock.withLock {
            guard let index = contents.peers.firstIndex(where: { $0.device == device }) else { return }
            change(&contents.peers[index])
        }
        save()
    }

    func forget(device: String) {
        lock.withLock { contents.peers.removeAll { $0.device == device } }
        save()
    }

    private func save() {
        let data = lock.withLock { try? JSONEncoder().encode(contents) }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
