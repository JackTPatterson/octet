import CryptoKit
import Foundation

/// The secure channel between two Octets on a network. Each Mac has a
/// long-term signing identity; every connection runs a fresh X25519 key
/// exchange over the two hellos, and each side signs the exchange with its
/// identity so the other knows who it's talking to. Everything after the
/// hellos is sealed with ChaChaPoly, a key per direction and a counter per
/// message, so a frame can't be read, changed, replayed or reordered.
///
/// Two Macs that haven't met compare a 6-digit code drawn from the same
/// exchange: someone in the middle would have run two exchanges, and the
/// codes on the two screens wouldn't match.
enum PeerCrypto {
    static let protocolVersion = 1

    /// A Mac's long-term identity.
    struct Identity {
        let signingKey: Curve25519.Signing.PrivateKey
        var publicKey: Data { signingKey.publicKey.rawRepresentation }

        init(signingKey: Curve25519.Signing.PrivateKey = .init()) {
            self.signingKey = signingKey
        }

        init(raw: Data) throws {
            signingKey = try .init(rawRepresentation: raw)
        }

        var raw: Data { signingKey.rawRepresentation }
    }

    /// What each side sends first, in the clear.
    struct Hello: Codable, Equatable {
        var version = PeerCrypto.protocolVersion
        let device: String
        let name: String
        /// The Mac's signing key.
        let identity: Data
        /// This connection's key-exchange key.
        let ephemeral: Data
    }

    enum Role: String { case client, server }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case badHello
        case versionMismatch(Int)
        case badSignature
        case sealed
        case outOfOrder

        var description: String {
            switch self {
            case .badHello: "The other Mac sent something that isn't an Octet hello."
            case .versionMismatch(let version): "The other Mac speaks version \(version) of Octet's protocol; this one speaks \(PeerCrypto.protocolVersion). Update both."
            case .badSignature: "The other Mac couldn't prove who it is."
            case .sealed: "A message didn't decrypt: it was changed on the way, or isn't from this connection."
            case .outOfOrder: "A message arrived out of order or twice."
            }
        }
    }

    /// One side of a connection, from its hello to the sealed channel.
    final class Handshake {
        let role: Role
        let identity: Identity
        let hello: Hello
        let helloData: Data
        private let ephemeral = Curve25519.KeyAgreement.PrivateKey()

        init(role: Role, identity: Identity, device: String, name: String) throws {
            self.role = role
            self.identity = identity
            hello = Hello(device: device, name: name, identity: identity.publicKey,
                          ephemeral: ephemeral.publicKey.rawRepresentation)
            helloData = try JSONEncoder().encode(hello)
        }

        /// The other side's hello: the channel, and what's needed to prove
        /// who each side is.
        func finish(peerHelloData: Data) throws -> Session {
            guard let peer = try? JSONDecoder().decode(Hello.self, from: peerHelloData),
                  let peerEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.ephemeral),
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: peer.identity)) != nil else {
                throw Failure.badHello
            }
            guard peer.version == PeerCrypto.protocolVersion else { throw Failure.versionMismatch(peer.version) }
            let clientHello = role == .client ? helloData : peerHelloData
            let serverHello = role == .client ? peerHelloData : helloData
            var transcript = SHA256()
            transcript.update(data: Data("octet-peer-v1".utf8))
            transcript.update(data: withLength(clientHello))
            transcript.update(data: withLength(serverHello))
            let digest = Data(transcript.finalize())
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peerEphemeral)
            func key(_ label: String) -> SymmetricKey {
                shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: digest, sharedInfo: Data(label.utf8), outputByteCount: 32)
            }
            let toServer = key("client-to-server"), toClient = key("server-to-client")
            return Session(role: role, identity: identity, peer: peer, transcript: digest,
                           sendKey: role == .client ? toServer : toClient,
                           receiveKey: role == .client ? toClient : toServer,
                           sasKey: key("pairing-code"))
        }
    }

    /// The sealed channel, once both hellos are in.
    final class Session {
        let role: Role
        let peer: Hello
        let transcript: Data
        private let identity: Identity
        private let sendKey: SymmetricKey
        private let receiveKey: SymmetricKey
        private let sasKey: SymmetricKey
        private var sent: UInt64 = 0
        private var received: UInt64 = 0

        fileprivate init(role: Role, identity: Identity, peer: Hello, transcript: Data,
                         sendKey: SymmetricKey, receiveKey: SymmetricKey, sasKey: SymmetricKey) {
            self.role = role
            self.identity = identity
            self.peer = peer
            self.transcript = transcript
            self.sendKey = sendKey
            self.receiveKey = receiveKey
            self.sasKey = sasKey
        }

        /// The 6 digits both screens show while pairing, as "123 456".
        var pairingCode: String {
            let bytes = sasKey.withUnsafeBytes { Array($0.prefix(4)) }
            let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
            let digits = String(format: "%06u", value)
            return digits.prefix(3) + " " + digits.suffix(3)
        }

        /// This side's proof of identity: its signature over the exchange
        /// and its role, so a proof can't be sent back as the other side's.
        func proof() throws -> Data {
            try identity.signingKey.signature(for: transcript + Data(role.rawValue.utf8))
        }

        /// Checks the other side's proof against the key in its hello.
        func verify(proof: Data) throws {
            let peerRole: Role = role == .client ? .server : .client
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: peer.identity),
                  key.isValidSignature(proof, for: transcript + Data(peerRole.rawValue.utf8)) else {
                throw Failure.badSignature
            }
        }

        func seal(_ plaintext: Data) throws -> Data {
            let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sent))
            sent += 1
            return box.combined
        }

        /// Opens the next frame; frames must arrive in the order they were
        /// sealed, each once.
        func open(_ frame: Data) throws -> Data {
            guard let box = try? ChaChaPoly.SealedBox(combined: frame) else { throw Failure.sealed }
            guard Data(box.nonce) == Data(Self.nonce(received)) else { throw Failure.outOfOrder }
            guard let plaintext = try? ChaChaPoly.open(box, using: receiveKey) else { throw Failure.sealed }
            received += 1
            return plaintext
        }

        private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
            var bytes = [UInt8](repeating: 0, count: 12)
            for index in 0..<8 { bytes[11 - index] = UInt8(truncatingIfNeeded: counter >> (8 * UInt64(index))) }
            return try! ChaChaPoly.Nonce(data: bytes)
        }
    }

    private static func withLength(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        return Data(bytes: &length, count: 4) + data
    }

    /// A short, stable fingerprint of a Mac's identity, for showing in
    /// Settings: "3F2A-9C1E".
    static func fingerprint(_ identity: Data) -> String {
        let hex = SHA256.hash(data: identity).prefix(4).map { String(format: "%02X", $0) }.joined()
        return hex.prefix(4) + "-" + hex.suffix(4)
    }
}
