import CryptoKit
import XCTest

final class PeerCryptoTests: XCTestCase {
    private func pair(clientIdentity: PeerCrypto.Identity = .init(), serverIdentity: PeerCrypto.Identity = .init())
        throws -> (PeerCrypto.Session, PeerCrypto.Session) {
        let client = try PeerCrypto.Handshake(role: .client, identity: clientIdentity, device: "A", name: "Laptop")
        let server = try PeerCrypto.Handshake(role: .server, identity: serverIdentity, device: "B", name: "Studio")
        return (try client.finish(peerHelloData: server.helloData), try server.finish(peerHelloData: client.helloData))
    }

    func testBothSidesAgreeOnTheCodeAndTheChannel() throws {
        let (client, server) = try pair()
        XCTAssertEqual(client.pairingCode, server.pairingCode)
        XCTAssertTrue(client.pairingCode.range(of: #"^\d{3} \d{3}$"#, options: .regularExpression) != nil)
        XCTAssertEqual(client.peer.name, "Studio")
        XCTAssertEqual(server.peer.device, "A")

        let sealed = try client.seal(Data("hello".utf8))
        XCTAssertEqual(String(decoding: try server.open(sealed), as: UTF8.self), "hello")
        let back = try server.seal(Data("hi".utf8))
        XCTAssertEqual(String(decoding: try client.open(back), as: UTF8.self), "hi")
    }

    func testEachSideProvesItsIdentity() throws {
        let (client, server) = try pair()
        XCTAssertNoThrow(try server.verify(proof: client.proof()))
        XCTAssertNoThrow(try client.verify(proof: server.proof()))
        // A proof sent straight back doesn't pass as the other side's.
        XCTAssertThrowsError(try client.verify(proof: client.proof()))
    }

    /// Someone in the middle runs a separate exchange with each Mac: the
    /// codes differ, and neither Mac's proof checks out on the other side.
    func testSomeoneInTheMiddleShowsDifferentCodes() throws {
        let laptop = PeerCrypto.Identity(), studio = PeerCrypto.Identity(), attacker = PeerCrypto.Identity()
        let client = try PeerCrypto.Handshake(role: .client, identity: laptop, device: "A", name: "Laptop")
        let server = try PeerCrypto.Handshake(role: .server, identity: studio, device: "B", name: "Studio")
        // The attacker answers each side with its own hello, using the other
        // Mac's name and device id.
        let fakeServer = try PeerCrypto.Handshake(role: .server, identity: attacker, device: "B", name: "Studio")
        let fakeClient = try PeerCrypto.Handshake(role: .client, identity: attacker, device: "A", name: "Laptop")
        let laptopSide = try client.finish(peerHelloData: fakeServer.helloData)
        let studioSide = try server.finish(peerHelloData: fakeClient.helloData)
        XCTAssertNotEqual(laptopSide.pairingCode, studioSide.pairingCode)
        // A Mac that knows the other's real identity isn't fooled either.
        XCTAssertNotEqual(laptopSide.peer.identity, studio.publicKey)
    }

    func testTamperedReplayedOrReorderedFramesAreRefused() throws {
        let (client, server) = try pair()
        let first = try client.seal(Data("one".utf8))
        let second = try client.seal(Data("two".utf8))
        var tampered = first
        tampered[tampered.count - 20] ^= 0x01
        XCTAssertThrowsError(try server.open(tampered))
        XCTAssertThrowsError(try server.open(second)) { XCTAssertEqual($0 as? PeerCrypto.Failure, .outOfOrder) }
        XCTAssertNoThrow(try server.open(first))
        XCTAssertThrowsError(try server.open(first)) { XCTAssertEqual($0 as? PeerCrypto.Failure, .outOfOrder) }
        XCTAssertNoThrow(try server.open(second))
        // A frame sealed for the other direction doesn't open here.
        XCTAssertThrowsError(try client.open(try client.seal(Data("mine".utf8))))
    }

    func testRefusesGarbageAndOtherVersions() throws {
        let client = try PeerCrypto.Handshake(role: .client, identity: .init(), device: "A", name: "Laptop")
        XCTAssertThrowsError(try client.finish(peerHelloData: Data("not json".utf8))) {
            XCTAssertEqual($0 as? PeerCrypto.Failure, .badHello)
        }
        var hello = PeerCrypto.Hello(device: "B", name: "Old", identity: PeerCrypto.Identity().publicKey,
                                     ephemeral: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        hello.version = 99
        XCTAssertThrowsError(try client.finish(peerHelloData: try JSONEncoder().encode(hello))) {
            XCTAssertEqual($0 as? PeerCrypto.Failure, .versionMismatch(99))
        }
    }

    func testIdentitiesSurviveBeingSavedAndHaveAFingerprint() throws {
        let identity = PeerCrypto.Identity()
        XCTAssertEqual(try PeerCrypto.Identity(raw: identity.raw).publicKey, identity.publicKey)
        XCTAssertTrue(PeerCrypto.fingerprint(identity.publicKey).range(of: #"^[0-9A-F]{4}-[0-9A-F]{4}$"#, options: .regularExpression) != nil)
    }
}
