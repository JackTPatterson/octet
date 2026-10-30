import Foundation

/// This Mac as T3 clients see an environment: what it is called, which
/// protocol it speaks, and how its auth is described.
struct PhoneHostConfig {
    var environmentID: String
    var label: String
    var serverVersion: String
    /// One of T3's machine kinds ("laptop", "desktop", "mac-mini", "mac-studio"), when known.
    var machine: String?
}

/// The HTTP half of the host: no sockets, so it can be tested by handing it requests.
final class PhoneHostRouter {
    static let protocolVersion = 2
    static let sessionCookieName = "octet_session"

    let config: PhoneHostConfig
    let auth: PhoneAuthStore

    init(config: PhoneHostConfig, auth: PhoneAuthStore) {
        self.config = config
        self.auth = auth
    }

    func handle(_ request: PhoneHTTPRequest, now: Date = Date()) -> PhoneHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/.well-known/t3/environment"):
            return .json(descriptor())
        case ("GET", "/api/auth/session"):
            return session(request, now: now)
        case ("POST", "/oauth/token"):
            return exchange(request, now: now)
        case ("POST", "/api/auth/websocket-ticket"):
            return ticket(request, use: nil, now: now)
        case ("POST", "/api/auth/websocket-ticket/rpc"):
            return ticket(request, use: "rpc", now: now)
        case ("POST", "/api/auth/websocket-ticket/media"):
            return ticket(request, use: "media", now: now)
        default:
            return .json(["error": "not_found"], status: 404)
        }
    }

    // MARK: - Metadata

    func descriptor() -> [String: Any] {
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x64"
        #else
        let arch = "other"
        #endif
        var platform: [String: Any] = ["os": "darwin", "arch": arch]
        if let machine = config.machine { platform["machine"] = machine }
        return [
            "environmentId": config.environmentID,
            "label": config.label,
            "platform": platform,
            "serverVersion": config.serverVersion,
            "orchestrationProtocolVersion": Self.protocolVersion,
            // Every capability this host does not serve stays unset, which hides it in the app.
            "capabilities": ["repositoryIdentity": false],
        ]
    }

    var authDescriptor: [String: Any] {
        [
            "policy": "remote-reachable",
            "bootstrapMethods": ["one-time-token"],
            "sessionMethods": ["bearer-access-token"],
            "sessionCookieName": Self.sessionCookieName,
        ]
    }

    // MARK: - Auth

    private func session(_ request: PhoneHTTPRequest, now: Date) -> PhoneHTTPResponse {
        guard let token = request.bearerToken, let session = auth.session(bearer: token, now: now) else {
            return .json(["authenticated": false, "auth": authDescriptor])
        }
        var body: [String: Any] = [
            "authenticated": true,
            "auth": authDescriptor,
            "sessionMethod": "bearer-access-token",
            "expiresAt": Self.date(session.expiresAt),
        ]
        body.merge(Self.scopeFields(session.scopes)) { $1 }
        return .json(body)
    }

    private func exchange(_ request: PhoneHTTPRequest, now: Date) -> PhoneHTTPResponse {
        let form = PhoneHTTPForm.decode(String(decoding: request.body, as: UTF8.self))
        guard form["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange",
              form["subject_token_type"] == "urn:t3:params:oauth:token-type:environment-bootstrap",
              form["requested_token_type"] == "urn:ietf:params:oauth:token-type:access_token" else {
            return Self.invalid(400, code: "invalid_request", reason: "invalid_command")
        }
        guard let credential = form["subject_token"]?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty else {
            return Self.invalid(401, code: "auth_invalid", reason: "missing_credential")
        }
        var scopes: [String]?
        if let scope = form["scope"] {
            let parts = scope.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard !parts.contains(where: \.isEmpty) else { return Self.invalid(400, code: "invalid_request", reason: "invalid_scope") }
            scopes = parts
        }
        switch auth.exchange(credential: credential, requestedScopes: scopes, label: form["client_label"],
                             deviceType: form["client_device_type"], os: form["client_os"], now: now) {
        case .success(let result):
            return .json([
                "access_token": result.token,
                "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
                "token_type": "Bearer",
                "expires_in": Int(result.session.expiresAt.timeIntervalSince(now)),
                "scope": result.session.scopes.joined(separator: " "),
            ])
        case .failure(.invalidScope):
            return Self.invalid(400, code: "invalid_request", reason: "scope_not_granted")
        case .failure(.locked):
            return PhoneHTTPResponse.json(Self.errorBody("auth_invalid", "invalid_credential"), status: 429)
        case .failure(.invalidCredential):
            return Self.invalid(401, code: "auth_invalid", reason: "invalid_credential")
        }
    }

    private func ticket(_ request: PhoneHTTPRequest, use: String?, now: Date) -> PhoneHTTPResponse {
        guard let token = request.bearerToken else { return Self.invalid(401, code: "auth_invalid", reason: "missing_credential") }
        guard let session = auth.session(bearer: token, now: now) else { return Self.invalid(401, code: "auth_invalid", reason: "invalid_credential") }
        let issued = auth.issueTicket(for: session, use: use, now: now)
        return .json(["ticket": issued.ticket, "expiresAt": Self.date(issued.expiresAt)])
    }

    // MARK: - Encoding

    /// T3's `authScopeResponse`: `scopes` is the part older clients know, `permissions` is everything granted.
    static func scopeFields(_ granted: [String]) -> [String: Any] {
        let legacy: Set<String> = ["orchestration:read", "orchestration:operate", "terminal:operate",
                                   "review:write", "access:read", "access:write", "relay:read", "relay:write"]
        return ["scopes": granted.filter(legacy.contains), "permissions": granted]
    }

    static func errorBody(_ code: String, _ reason: String) -> [String: Any] {
        let tag: String
        switch code {
        case "auth_invalid": tag = "EnvironmentAuthInvalidError"
        case "invalid_request": tag = "EnvironmentRequestInvalidError"
        default: tag = "EnvironmentInternalError"
        }
        return ["_tag": tag, "code": code, "reason": reason, "traceId": UUID().uuidString.lowercased()]
    }

    private static func invalid(_ status: Int, code: String, reason: String) -> PhoneHTTPResponse {
        .json(errorBody(code, reason), status: status)
    }

    static func date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
