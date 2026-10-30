import XCTest

final class PhoneHostTests: XCTestCase {
    private func request(_ method: String, _ path: String, headers: [String: String] = [:], body: String = "") -> PhoneHTTPRequest {
        PhoneHTTPRequest(method: method, path: path, query: [:], headers: headers, body: Data(body.utf8))
    }

    private func router(auth: PhoneAuthStore = PhoneAuthStore()) -> PhoneHostRouter {
        PhoneHostRouter(config: PhoneHostConfig(environmentID: "env-1", label: "Test Mac", serverVersion: "1", machine: "laptop"), auth: auth)
    }

    private func form(_ code: String, scope: String? = nil) -> String {
        var fields = [
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token": code,
            "subject_token_type": "urn:t3:params:oauth:token-type:environment-bootstrap",
            "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        ]
        if let scope { fields["scope"] = scope }
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)" }.joined(separator: "&")
    }

    private func object(_ response: PhoneHTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    private func failure(of result: Result<(token: String, session: PhoneAuthStore.Session), PhoneAuthStore.ExchangeError>) -> PhoneAuthStore.ExchangeError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    // MARK: - Parser

    func testParsesARequestWithABody() {
        let raw = "POST /oauth/token?a=1&b=x%20y HTTP/1.1\r\nHost: mac\r\nContent-Length: 5\r\nAuthorization: Bearer abc\r\n\r\nhello"
        guard case .request(let request, let consumed) = PhoneHTTPParser.parse(Data(raw.utf8)) else { return XCTFail("did not parse") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/oauth/token")
        XCTAssertEqual(request.query, ["a": "1", "b": "x y"])
        XCTAssertEqual(request.bearerToken, "abc")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hello")
        XCTAssertEqual(consumed, raw.utf8.count)
    }

    func testWaitsForTheRestOfTheBody() {
        let raw = "POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nhello"
        guard case .needMore = PhoneHTTPParser.parse(Data(raw.utf8)) else { return XCTFail("should wait") }
    }

    func testRejectsChunkedAndOversizedBodies() {
        guard case .invalid(let chunked) = PhoneHTTPParser.parse(Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(chunked, 501)
        guard case .invalid(let large) = PhoneHTTPParser.parse(Data("POST /x HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(large, 413)
    }

    func testFormDecodingHandlesPlusAndPercent() {
        XCTAssertEqual(PhoneHTTPForm.decode("a=b+c&d=%2Fe&f"), ["a": "b c", "d": "/e", "f": ""])
    }

    // MARK: - Auth

    func testAPairingCodeWorksOnce() {
        let auth = PhoneAuthStore()
        let pairing = auth.createPairing()
        guard case .success(let first) = auth.exchange(credential: pairing.credential, requestedScopes: nil, label: nil, deviceType: nil, os: nil) else { return XCTFail("first exchange") }
        XCTAssertNotNil(auth.session(bearer: first.token))
        XCTAssertEqual(failure(of: auth.exchange(credential: pairing.credential, requestedScopes: nil, label: nil, deviceType: nil, os: nil)), .invalidCredential)
    }

    func testAnExpiredPairingCodeIsRefused() {
        let auth = PhoneAuthStore()
        let now = Date()
        let pairing = auth.createPairing(now: now)
        let late = now.addingTimeInterval(PhoneAuthStore.pairingLifetime + 1)
        XCTAssertEqual(failure(of: auth.exchange(credential: pairing.credential, requestedScopes: nil, label: nil, deviceType: nil, os: nil, now: late)), .invalidCredential)
    }

    func testTooManyWrongCodesPauseExchanges() {
        let auth = PhoneAuthStore()
        let pairing = auth.createPairing()
        for _ in 0..<PhoneAuthStore.failureLimit {
            _ = auth.exchange(credential: "NOPE", requestedScopes: nil, label: nil, deviceType: nil, os: nil)
        }
        XCTAssertEqual(failure(of: auth.exchange(credential: pairing.credential, requestedScopes: nil, label: nil, deviceType: nil, os: nil)), .locked)
        let later = Date().addingTimeInterval(PhoneAuthStore.lockout + 1)
        guard case .success = auth.exchange(credential: pairing.credential, requestedScopes: nil, label: nil, deviceType: nil, os: nil, now: later) else { return XCTFail("should work after the pause") }
    }

    func testScopesAreNarrowedToWhatTheHostHonors() {
        let auth = PhoneAuthStore()
        let pairing = auth.createPairing()
        guard case .success(let result) = auth.exchange(credential: pairing.credential, requestedScopes: ["orchestration:read", "filesystem:write"], label: nil, deviceType: nil, os: nil) else { return XCTFail() }
        XCTAssertEqual(result.session.scopes, ["orchestration:read"])
    }

    func testATicketIsSingleUseAndBoundToItsPurpose() {
        let auth = PhoneAuthStore()
        guard case .success(let result) = auth.exchange(credential: auth.createPairing().credential, requestedScopes: nil, label: nil, deviceType: nil, os: nil) else { return XCTFail() }
        let rpc = auth.issueTicket(for: result.session, use: "rpc")
        XCTAssertNil(auth.consumeTicket(rpc.ticket, use: "media"), "an rpc ticket must not open media")
        let again = auth.issueTicket(for: result.session, use: "rpc")
        XCTAssertNotNil(auth.consumeTicket(again.ticket, use: "rpc"))
        XCTAssertNil(auth.consumeTicket(again.ticket, use: "rpc"), "tickets are spent on first use")
    }

    func testRevokingASessionStopsItsToken() {
        let auth = PhoneAuthStore()
        guard case .success(let result) = auth.exchange(credential: auth.createPairing().credential, requestedScopes: nil, label: nil, deviceType: nil, os: nil) else { return XCTFail() }
        XCTAssertTrue(auth.revoke(sessionID: result.session.id))
        XCTAssertNil(auth.session(bearer: result.token))
    }

    func testPairedPhonesSurviveARestartAsHashes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-host-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let auth = PhoneAuthStore(url: url)
        guard case .success(let result) = auth.exchange(credential: auth.createPairing().credential, requestedScopes: nil, label: nil, deviceType: nil, os: nil) else { return XCTFail() }
        XCTAssertNotNil(PhoneAuthStore(url: url).session(bearer: result.token))
        let stored = try String(contentsOf: url)
        XCTAssertFalse(stored.contains(result.token), "the token itself must not be on disk")
    }

    // MARK: - Router

    func testTheFullPairingFlow() {
        let auth = PhoneAuthStore()
        let router = router(auth: auth)
        let code = auth.createPairing().credential

        let descriptor = object(router.handle(request("GET", "/.well-known/t3/environment")))
        XCTAssertEqual(descriptor["environmentId"] as? String, "env-1")
        XCTAssertEqual(descriptor["orchestrationProtocolVersion"] as? Int, 2)

        let token = router.handle(request("POST", "/oauth/token", body: form(code)))
        XCTAssertEqual(token.status, 200)
        let bearer = object(token)["access_token"] as? String ?? ""
        XCTAssertEqual(object(token)["token_type"] as? String, "Bearer")

        let session = object(router.handle(request("GET", "/api/auth/session", headers: ["authorization": "Bearer \(bearer)"])))
        XCTAssertEqual(session["authenticated"] as? Bool, true)

        let ticket = router.handle(request("POST", "/api/auth/websocket-ticket/rpc", headers: ["authorization": "Bearer \(bearer)"]))
        XCTAssertEqual(ticket.status, 200)
        XCTAssertNotNil(object(ticket)["ticket"] as? String)
    }

    func testBadCredentialsAreRefused() {
        let router = router()
        XCTAssertEqual(router.handle(request("POST", "/oauth/token", body: form("WRONG"))).status, 401)
        XCTAssertEqual(router.handle(request("POST", "/api/auth/websocket-ticket")).status, 401)
        XCTAssertEqual(router.handle(request("POST", "/oauth/token", body: "grant_type=password")).status, 400)
        XCTAssertEqual(router.handle(request("GET", "/nope")).status, 404)
    }

    // MARK: - Over the wire

    func testServerAnswersOverLoopback() throws {
        let auth = PhoneAuthStore()
        let server = PhoneHostServer(router: router(auth: auth), backend: PhoneHostRPCTests.Backend())
        try server.start(port: nil, loopbackOnly: true)
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)

        let done = expectation(description: "response")
        var received: (Int, [String: Any])?
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/.well-known/t3/environment")!) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse {
                received = (http.statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(received?.0, 200)
        XCTAssertEqual(received?.1["label"] as? String, "Test Mac")
    }
}
