import Network
import XCTest

/// Two nodes in one process, over real TCP on the loopback interface.
final class PeerLinkTests: XCTestCase {
    final class Host: PeerHost {
        var accept = true
        var codes: [String] = []
        var requests: [(PeerProtocol.Method, [String: Any], String)] = []
        var events: [(String, [String: Any])] = []
        let lock = NSLock()

        func handle(method: PeerProtocol.Method, params: [String: Any], from peer: PairedPeer,
                    reply: @escaping (Result<[String: Any], PeerProtocol.RemoteError>) -> Void) {
            lock.withLock { requests.append((method, params, peer.name)) }
            switch method {
            case .agents: reply(.success(["agents": [["id": "w1:p1", "agent": "claude", "status": "idle"]]]))
            case .send: reply(.failure(.init(code: "declined", message: "Declined here.")))
            default: reply(.success(["echo": params]))
            }
        }

        func handle(event: String, data: [String: Any], from peer: PairedPeer) {
            lock.withLock { events.append((event, data)) }
        }

        func approvePairing(name: String, code: String, fingerprint: String, incoming: Bool, answer: @escaping (Bool) -> Void) {
            lock.withLock { codes.append(code) }
            answer(accept)
        }

        func peersChanged() {}
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("octet-peers-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func node(_ name: String, host: Host) throws -> PeerNode {
        let node = PeerNode(store: PeerStore(url: folder.appendingPathComponent("\(name).json")), machineName: { name })
        node.host = host
        try node.start(advertise: false, loopbackOnly: true)
        XCTAssertNotNil(node.port)
        return node
    }

    private func endpoint(_ node: PeerNode) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: node.port!)!)
    }

    private func pair(_ a: PeerNode, _ b: PeerNode) throws -> Result<PairedPeer, Error> {
        let done = expectation(description: "paired")
        var outcome: Result<PairedPeer, Error>!
        a.connect(to: endpoint(b), pairing: true) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return outcome
    }

    private func call(_ node: PeerNode, _ device: String, _ method: PeerProtocol.Method,
                      _ params: [String: Any] = [:]) -> Result<[String: Any], PeerProtocol.RemoteError> {
        let done = expectation(description: "answered")
        var outcome: Result<[String: Any], PeerProtocol.RemoteError>!
        node.call(device: device, method: method, params: params, timeout: 5) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return outcome
    }

    func testPairsWithMatchingCodesThenCarriesRequestsBothWays() throws {
        let laptopHost = Host(), studioHost = Host()
        let laptop = try node("Laptop", host: laptopHost), studio = try node("Studio", host: studioHost)
        defer { laptop.stop(); studio.stop() }

        let paired = try pair(laptop, studio).get()
        XCTAssertEqual(paired.name, "Studio")
        XCTAssertEqual(paired.trust, .ask)
        XCTAssertEqual(laptopHost.codes.count, 1)
        XCTAssertEqual(laptopHost.codes, studioHost.codes, "both screens show the same code")
        // Give the studio a moment to store the laptop too.
        let deadline = Date().addingTimeInterval(3)
        while studio.store.peers.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(studio.store.peers.map(\.name), ["Laptop"])

        let agents = try call(laptop, studio.store.device, .agents).get()
        XCTAssertEqual((agents["agents"] as? [[String: Any]])?.first?["id"] as? String, "w1:p1")
        XCTAssertEqual(studioHost.requests.first?.2, "Laptop", "the studio knows who asked")
        // Errors come back as errors.
        if case .failure(let error) = call(laptop, studio.store.device, .send, ["text": "hi"]) {
            XCTAssertEqual(error.code, "declined")
        } else { XCTFail("expected a refusal") }
        // And the other way, over the same connection.
        let echo = try call(studio, laptop.store.device, .read, ["agent": "x"]).get()
        XCTAssertEqual((echo["echo"] as? [String: Any])?["agent"] as? String, "x")

        let done = expectation(description: "event")
        studio.send(event: .taskFinished, data: ["task": "t1"], to: laptop.store.device)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(laptopHost.events.first?.0, "task.finished")
    }

    func testPairedMacsReconnectWithoutAskingAndOthersAreRefused() throws {
        let laptopHost = Host(), studioHost = Host()
        var laptop = try node("Laptop", host: laptopHost)
        var studio = try node("Studio", host: studioHost)
        _ = try pair(laptop, studio).get()
        Thread.sleep(forTimeInterval: 0.5)
        let studioDevice = studio.store.device
        laptop.stop(); studio.stop()

        // Both restart with what they stored: no code this time.
        laptop = try node("Laptop", host: laptopHost)
        studio = try node("Studio", host: studioHost)
        defer { laptop.stop(); studio.stop() }
        laptop.store.update(device: studioDevice) { $0.lastHost = "127.0.0.1"; $0.lastPort = studio.port }
        XCTAssertNoThrow(try call(laptop, studioDevice, .agents).get())
        XCTAssertEqual(laptopHost.codes.count, 1, "no second pairing")

        // A stranger that doesn't ask to pair gets nothing.
        let stranger = try node("Stranger", host: Host())
        defer { stranger.stop() }
        let refused = expectation(description: "refused")
        stranger.connect(to: endpoint(studio), pairing: false) { result in
            if case .failure = result { refused.fulfill() }
        }
        wait(for: [refused], timeout: 10)
    }

    func testADeclinedPairingStoresNothing() throws {
        let laptopHost = Host(), studioHost = Host()
        studioHost.accept = false
        let laptop = try node("Laptop", host: laptopHost), studio = try node("Studio", host: studioHost)
        defer { laptop.stop(); studio.stop() }
        XCTAssertThrowsError(try pair(laptop, studio).get())
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(laptop.store.peers.isEmpty)
        XCTAssertTrue(studio.store.peers.isEmpty)
    }

    func testAMacClaimingAPairedDevicesIdWithAnotherKeyIsRefused() throws {
        let laptopHost = Host(), studioHost = Host()
        let laptop = try node("Laptop", host: laptopHost), studio = try node("Studio", host: studioHost)
        defer { laptop.stop(); studio.stop() }
        _ = try pair(laptop, studio).get()
        Thread.sleep(forTimeInterval: 0.3)
        // An impostor copies the laptop's device id but has its own key.
        var contents = laptop.store.contents
        contents.identity = PeerCrypto.Identity().raw
        contents.peers = []
        let url = folder.appendingPathComponent("impostor.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(contents).write(to: url)
        let impostor = PeerNode(store: PeerStore(url: url), machineName: { "Laptop" })
        impostor.host = Host()
        try impostor.start(advertise: false, loopbackOnly: true)
        defer { impostor.stop() }
        let refused = expectation(description: "refused")
        impostor.connect(to: endpoint(studio), pairing: true) { result in
            if case .failure = result { refused.fulfill() }
        }
        wait(for: [refused], timeout: 10)
    }
}
