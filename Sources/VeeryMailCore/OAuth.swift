import CryptoKit
import Foundation

// Fastmail OAuth for a native public client, following Fastmail's developer documentation
// (https://www.fastmail.com/dev/#oauth) and the "OAuth Profile for Open Public Clients" it
// supports: metadata discovery, dynamic registration, Authorization Code + PKCE (S256),
// state and issuer checks, loopback redirect, refresh-token rotation, revocation.

public struct OAuthServerMetadata: Codable, Equatable, Sendable {
    public let issuer: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let registrationEndpoint: URL?
    public let revocationEndpoint: URL?
    public let scopesSupported: [String]
    public let codeChallengeMethodsSupported: [String]?
    public let authorizationResponseIssParameterSupported: Bool?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case scopesSupported = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case authorizationResponseIssParameterSupported = "authorization_response_iss_parameter_supported"
    }
}

public struct OAuthRegistration: Codable, Equatable, Sendable {
    public let issuer: String
    public let clientId: String
    public let redirectURI: String
    public let scope: String
}

public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String
    public let clientId: String
    public let issuer: String

    public func expiresSoon(now: Date, margin: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) < margin
    }
}

public enum OAuthError: LocalizedError, Equatable {
    case canceled
    case stateMismatch
    case issuerMismatch
    case redirectMismatch
    case unsupportedServer(String)
    case registrationFailed(String)
    case missingScope(String)
    case server(code: String, description: String?)
    /// The refresh token was rejected. `temporary` is Fastmail's hint that it may work again later.
    case invalidGrant(temporary: Bool, description: String?)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .canceled: return "Sign-in was canceled."
        case .stateMismatch: return "The sign-in response didn’t match the request, so it was rejected. Please try again."
        case .issuerMismatch: return "The sign-in response came from an unexpected server, so it was rejected."
        case .redirectMismatch: return "The sign-in response arrived at the wrong address, so it was rejected."
        case .unsupportedServer(let why): return "Fastmail’s sign-in service isn’t compatible: \(why)"
        case .registrationFailed(let why): return "Couldn’t register Veery Mail with Fastmail: \(why)"
        case .missingScope(let scope): return "Fastmail didn’t grant the access Veery Mail needs (\(scope))."
        case .server(let code, let description): return "Fastmail sign-in error: \(description ?? code)"
        case .invalidGrant(let temporary, let description):
            return (description ?? "Your Fastmail sign-in has expired.")
                + (temporary ? " This may be temporary." : " Please sign in again.")
        case .badResponse(let what): return "Unexpected response from Fastmail’s sign-in service (\(what))."
        }
    }
}

/// PKCE (RFC 7636) with the S256 method.
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    public static func make() -> PKCE {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var rng = SystemRandomNumberGenerator()
        let verifier = String((0..<64).map { _ in alphabet[Int(rng.next(upperBound: UInt32(alphabet.count)))] })
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One authorization in progress. Never reused.
public struct PendingAuthorization: Equatable, Sendable {
    public let state: String
    public let pkce: PKCE
    public let redirectURI: String
    public let issuer: String
    public let clientId: String
    public let authorizationURL: URL
}

public struct OAuthClientInfo: Sendable {
    public var clientName = "Veery Mail"
    public var softwareId = "0b6d7c2e-5a3f-4e1b-9c8d-2f7a1e4b6c90"
    public var softwareVersion = "0.2.0"
    public var clientURI: String?
    public var policyURI: String?
    public var tosURI: String?
    public init() {}
}

public final class FastmailOAuth: @unchecked Sendable {
    public static let fastmailIssuer = "https://api.fastmail.com"
    /// Registered redirect. The port is added at sign-in time (loopback, RFC 8252 §7.3).
    /// The path names the service, as the profile requires for clients of several servers.
    public static let redirectPath = "/oauth/fastmail"
    public static let jmapResource = "https://api.fastmail.com/jmap/session"

    public let issuer: String
    let transport: HTTPTransport
    let info: OAuthClientInfo

    public init(issuer: String = FastmailOAuth.fastmailIssuer, transport: HTTPTransport = NoRedirectTransport(),
                info: OAuthClientInfo = OAuthClientInfo()) {
        self.issuer = issuer; self.transport = transport; self.info = info
    }

    /// Scopes to request: mail (and contacts if wanted), plus offline_access when advertised.
    public static func scopes(for metadata: OAuthServerMetadata, includeContacts: Bool) -> [String] {
        var scopes = ["urn:ietf:params:oauth:scope:mail"]
        if includeContacts, metadata.scopesSupported.contains("urn:ietf:params:oauth:scope:contacts") {
            scopes.append("urn:ietf:params:oauth:scope:contacts")
        }
        if metadata.scopesSupported.contains("offline_access") { scopes.append("offline_access") }
        return scopes
    }

    // MARK: Discovery

    public func discover() async throws -> OAuthServerMetadata {
        guard let url = URL(string: issuer + "/.well-known/oauth-authorization-server") else {
            throw OAuthError.unsupportedServer("bad issuer")
        }
        let (data, response) = try await transport.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("json") else {
            throw OAuthError.unsupportedServer("metadata unavailable")
        }
        let metadata: OAuthServerMetadata
        do { metadata = try JSONDecoder().decode(OAuthServerMetadata.self, from: data) } catch {
            throw OAuthError.badResponse("metadata")
        }
        guard metadata.issuer == issuer else { throw OAuthError.issuerMismatch }
        guard metadata.registrationEndpoint != nil else { throw OAuthError.unsupportedServer("no registration endpoint") }
        guard metadata.codeChallengeMethodsSupported?.contains("S256") ?? false else {
            throw OAuthError.unsupportedServer("PKCE S256 not supported")
        }
        guard metadata.scopesSupported.contains("urn:ietf:params:oauth:scope:mail") else {
            throw OAuthError.unsupportedServer("mail scope not offered")
        }
        return metadata
    }

    // MARK: Registration (RFC 7591, open registration)

    public func register(_ metadata: OAuthServerMetadata, scopes: [String]) async throws -> OAuthRegistration {
        guard let endpoint = metadata.registrationEndpoint else { throw OAuthError.unsupportedServer("no registration endpoint") }
        let redirect = "http://127.0.0.1" + Self.redirectPath
        var body: [String: Any] = [
            "redirect_uris": [redirect],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "scope": scopes.joined(separator: " "),
            "client_name": info.clientName,
            "software_id": info.softwareId,
            "software_version": info.softwareVersion,
        ]
        if let v = info.clientURI { body["client_uri"] = v }
        if let v = info.policyURI { body["policy_uri"] = v }
        if let v = info.tosURI { body["tos_uri"] = v }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let clientId = json["client_id"] as? String else {
            throw OAuthError.registrationFailed((json["error_description"] as? String) ?? (json["error"] as? String) ?? "no client id")
        }
        // The server's values win (profile §3.3); abort if it dropped something required.
        let redirects = json["redirect_uris"] as? [String] ?? [redirect]
        guard redirects.contains(redirect) else { throw OAuthError.registrationFailed("redirect address not accepted") }
        let grantedScope = json["scope"] as? String ?? scopes.joined(separator: " ")
        let granted = Set(grantedScope.split(separator: " ").map(String.init))
        for needed in scopes where !granted.contains(needed) && needed != "offline_access" {
            throw OAuthError.missingScope(needed)
        }
        return OAuthRegistration(issuer: metadata.issuer, clientId: clientId, redirectURI: redirect, scope: grantedScope)
    }

    // MARK: Authorization

    /// Builds the browser URL. `port` is the loopback listener's port.
    public func beginAuthorization(_ metadata: OAuthServerMetadata, registration: OAuthRegistration,
                                   port: UInt16, scopes: [String]) -> PendingAuthorization {
        let pkce = PKCE.make()
        let state = PKCE.base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let redirect = "http://127.0.0.1:\(port)" + Self.redirectPath
        var c = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var query = c.queryItems ?? []
        query += [
            URLQueryItem(name: "client_id", value: registration.clientId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: Self.jmapResource),
        ]
        if scopes.contains("offline_access") { query.append(URLQueryItem(name: "prompt", value: "consent")) }
        c.queryItems = query
        return PendingAuthorization(state: state, pkce: pkce, redirectURI: redirect, issuer: metadata.issuer,
                                    clientId: registration.clientId, authorizationURL: c.url!)
    }

    /// Validates the redirect and returns the authorization code.
    public func code(from callback: URL, for pending: PendingAuthorization, expectIssuer: Bool) throws -> String {
        guard var expected = URLComponents(string: pending.redirectURI),
              var actual = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw OAuthError.redirectMismatch
        }
        let items = actual.queryItems ?? []
        expected.query = nil; actual.query = nil
        guard expected.scheme == actual.scheme, expected.host == actual.host,
              expected.port == actual.port, expected.path == actual.path else { throw OAuthError.redirectMismatch }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == pending.state else { throw OAuthError.stateMismatch }
        if let iss = value("iss") {
            guard iss == pending.issuer else { throw OAuthError.issuerMismatch }
        } else if expectIssuer {
            throw OAuthError.issuerMismatch
        }
        if let error = value("error") {
            if error == "access_denied" { throw OAuthError.canceled }
            throw OAuthError.server(code: error, description: value("error_description"))
        }
        guard let code = value("code"), !code.isEmpty else { throw OAuthError.badResponse("no code") }
        return code
    }

    // MARK: Tokens

    public func exchange(code: String, pending: PendingAuthorization, metadata: OAuthServerMetadata,
                         now: Date = Date()) async throws -> OAuthTokens {
        try await tokenRequest(metadata, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": pending.redirectURI,
            "client_id": pending.clientId, "code_verifier": pending.pkce.verifier,
            "resource": Self.jmapResource,
        ], clientId: pending.clientId, previousRefresh: nil, now: now)
    }

    /// Exchanges the refresh token. The new refresh token replaces the old one, which must
    /// never be used again (Fastmail revokes access if it is).
    public func refresh(_ tokens: OAuthTokens, metadata: OAuthServerMetadata, now: Date = Date()) async throws -> OAuthTokens {
        try await tokenRequest(metadata, [
            "grant_type": "refresh_token", "refresh_token": tokens.refreshToken,
            "client_id": tokens.clientId, "resource": Self.jmapResource,
        ], clientId: tokens.clientId, previousRefresh: tokens.refreshToken, now: now)
    }

    public func revoke(_ tokens: OAuthTokens, metadata: OAuthServerMetadata) async {
        guard let endpoint = metadata.revocationEndpoint else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(["token": tokens.refreshToken, "token_type_hint": "refresh_token", "client_id": tokens.clientId])
        _ = try? await transport.data(for: req)
    }

    private func tokenRequest(_ metadata: OAuthServerMetadata, _ params: [String: String], clientId: String,
                              previousRefresh: String?, now: Date) async throws -> OAuthTokens {
        var req = URLRequest(url: metadata.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(params)
        let (data, response) = try await transport.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = json["error"] as? String ?? "http_\(status)"
            if code == "invalid_grant" {
                throw OAuthError.invalidGrant(temporary: json["temporary"] as? Bool ?? false,
                                              description: json["error_description"] as? String)
            }
            throw OAuthError.server(code: code, description: json["error_description"] as? String)
        }
        guard let access = json["access_token"] as? String,
              (json["token_type"] as? String)?.lowercased() == "bearer" else {
            throw OAuthError.badResponse("token")
        }
        guard let refreshToken = (json["refresh_token"] as? String) ?? previousRefresh else {
            throw OAuthError.badResponse("no refresh token")
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return OAuthTokens(accessToken: access, refreshToken: refreshToken,
                           expiresAt: now.addingTimeInterval(expiresIn),
                           scope: json["scope"] as? String ?? "", clientId: clientId, issuer: metadata.issuer)
    }

    static func form(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(params.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }
}

/// Where OAuth tokens live (Keychain in the app, memory in tests).
public protocol TokenStore: Sendable {
    func load() -> OAuthTokens?
    func save(_ tokens: OAuthTokens) throws
    func clear()
}

/// Supplies fresh access tokens to the JMAP client and rotates refresh tokens safely.
/// Concurrent requests share one refresh.
public actor OAuthCredentials: CredentialProvider {
    private var tokens: OAuthTokens
    private let metadata: OAuthServerMetadata
    private let oauth: FastmailOAuth
    private let store: TokenStore
    private let now: @Sendable () -> Date
    private var refreshing: Task<OAuthTokens, Error>?
    /// Called once when the refresh token is permanently rejected (the user must sign in again).
    private let onSignedOut: @Sendable (OAuthError) -> Void

    public init(tokens: OAuthTokens, metadata: OAuthServerMetadata, oauth: FastmailOAuth, store: TokenStore,
                now: @escaping @Sendable () -> Date = { Date() },
                onSignedOut: @escaping @Sendable (OAuthError) -> Void) {
        self.tokens = tokens; self.metadata = metadata; self.oauth = oauth; self.store = store
        self.now = now; self.onSignedOut = onSignedOut
    }

    public func accessToken() async throws -> String {
        if tokens.expiresSoon(now: now()) {
            return try await refreshNow().accessToken
        }
        return tokens.accessToken
    }

    public func refreshAfterUnauthorized() async -> Bool {
        (try? await refreshNow()) != nil
    }

    public func current() -> OAuthTokens { tokens }

    private func refreshNow() async throws -> OAuthTokens {
        if let refreshing { return try await refreshing.value }
        let snapshot = tokens
        let task = Task { try await oauth.refresh(snapshot, metadata: metadata, now: now()) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            tokens = fresh
            try? store.save(fresh)   // the old refresh token is now dead; keep only the new one
            return fresh
        } catch let error as OAuthError {
            if case .invalidGrant(let temporary, _) = error, !temporary {
                store.clear()
                onSignedOut(error)
            }
            throw error
        }
    }
}

/// A transport that never follows redirects (required for metadata discovery) and keeps
/// no cookies or cache.
public final class NoRedirectTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    public init(protocolClasses: [AnyClass]? = nil) {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await session.data(for: request) }
    public func upload(for request: URLRequest, from body: Data) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, from: body)
    }
    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await session.bytes(for: request)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? { nil }
}
