import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
/// The token endpoint's response, plus when it was issued so refresh can run ahead of expiry.
public struct Tokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var tokenType: String
    public var expiresIn: Int
    public var refreshToken: String
    public var installationId: String
    public var connectionId: String
    public var workspaceId: String
    public var spaceIds: [String]
    /// Present on code exchange; refresh may omit it. Persist the selected library separately.
    public var selectedSpaceId: String?
    public var issuedAt: Date?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", tokenType = "token_type", expiresIn = "expires_in", refreshToken = "refresh_token"
        case installationId = "installation_id", connectionId = "connection_id", workspaceId = "workspace_id", spaceIds = "space_ids", selectedSpaceId = "selected_space_id", issuedAt = "issued_at"
    }

    public var expiresAt: Date? { issuedAt.map { $0.addingTimeInterval(TimeInterval(expiresIn)) } }
}

/// Explicit space chooser and least-privilege grants. OAuth scope labels do not grant data access.
public struct SpaceAuthorizationDetails: Encodable, Sendable {
    public let type = "adoor_space_access"
    public let spaceSelection: Selection
    public let permissions: [JSONValue]
    public let capabilities: [String]
    public struct Selection: Encodable, Sendable {
        public let allow: [String]
        public let suggestedName: String?
        enum CodingKeys: String, CodingKey { case allow, suggestedName = "suggested_name" }
    }
    enum CodingKeys: String, CodingKey { case type, spaceSelection = "space_selection", permissions, capabilities }
    public init(allow: [String] = ["create", "existing"], suggestedName: String? = nil, permissions: [JSONValue], capabilities: [String] = []) {
        spaceSelection = Selection(allow: allow, suggestedName: suggestedName)
        self.permissions = permissions
        self.capabilities = capabilities
    }
}

public struct PKCE: Sendable {
    public let codeVerifier: String
    public let codeChallenge: String
    public let state: String
}

enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
    private static func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 { (value >> bits) | (value << (32 - bits)) }
    static func hash(_ data: Data) -> Data {
        var message = [UInt8](data)
        let bits = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bits >> shift) & 0xff)) }
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        for offset in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                w[index] = (UInt32(message[start]) << 24) | (UInt32(message[start + 1]) << 16) | (UInt32(message[start + 2]) << 8) | UInt32(message[start + 3])
            }
            for index in 16..<64 {
                let s0 = rotate(w[index - 15], 7) ^ rotate(w[index - 15], 18) ^ (w[index - 15] >> 3)
                let s1 = rotate(w[index - 2], 17) ^ rotate(w[index - 2], 19) ^ (w[index - 2] >> 10)
                w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[index] &+ w[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return Data(h.flatMap { [UInt8(($0 >> 24) & 0xff), UInt8(($0 >> 16) & 0xff), UInt8(($0 >> 8) & 0xff), UInt8($0 & 0xff)] })
    }
}

public enum OAuth {
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes)
    }

    /// A fresh S256 verifier and challenge, plus a state value, for one authorization attempt.
    public static func createPKCE() -> PKCE {
        let verifier = base64url(random(32))
        return PKCE(codeVerifier: verifier, codeChallenge: base64url(SHA256.hash(Data(verifier.utf8))), state: base64url(random(32)))
    }

    /// The browser navigation that starts consent. The person approves exact spaces and permissions there.
    /// Use a registered redirect and validate state, callback origin/path and single consumption in the app.
    /// Omission of authorizationDetails requests read-only access to an existing space.
    /// url is the HTTP(S) service endpoint; redirectUri can be a registered app deep link.
    public static func authorizationURL(url: URL, clientId: String, redirectUri: String, pkce: PKCE, scope: String? = nil, resource: String? = nil, authorizationDetails: SpaceAuthorizationDetails? = nil) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
            throw AdoorError(code: "INVALID_URL", message: "The ADoor service endpoint must use HTTP or HTTPS with a host.", status: 400)
        }
        var components = URLComponents(url: url.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state)
        ]
        if let authorizationDetails { items.append(URLQueryItem(name: "authorization_details", value: String(decoding: try JSON.encode([authorizationDetails]), as: UTF8.self))) }
        if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        if let resource { items.append(URLQueryItem(name: "resource", value: resource)) }
        components.queryItems = items
        return components.url!
    }

    static func tokenRequest(url: URL, fields: [(String, String)], session: URLSession) async throws -> Tokens {
        var request = URLRequest(url: url.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        let received: (Data, URLResponse)
        do { received = try await session.data(for: request, delegate: RedirectBlocker()) }
        catch { throw AdoorError.network(error) }
        let (data, response) = received
        guard let http = response as? HTTPURLResponse else { throw AdoorError(code: "HTTP_INVALID", message: "The server returned no HTTP response.", status: 0) }
        guard (200..<300).contains(http.statusCode) else { throw AdoorError.from(response: http, data: data) }
        var tokens = try JSON.decode(Tokens.self, from: data)
        tokens.issuedAt = Date()
        return tokens
    }

    public static func exchangeCode(url: URL, clientId: String, code: String, redirectUri: String, codeVerifier: String, resource: String? = nil, session: URLSession = .shared) async throws -> Tokens {
        var fields = [("grant_type", "authorization_code"), ("client_id", clientId), ("code", code), ("redirect_uri", redirectUri), ("code_verifier", codeVerifier)]
        if let resource { fields.append(("resource", resource)) }
        return try await tokenRequest(url: url, fields: fields, session: session)
    }

    public static func refreshTokens(url: URL, clientId: String, refreshToken: String, resource: String? = nil, session: URLSession = .shared) async throws -> Tokens {
        var fields = [("grant_type", "refresh_token"), ("client_id", clientId), ("refresh_token", refreshToken)]
        if let resource { fields.append(("resource", resource)) }
        return try await tokenRequest(url: url, fields: fields, session: session)
    }
}

/// A token source that refreshes ahead of expiry with one in-flight refresh shared by concurrent callers.
/// Refresh tokens rotate on every use; persist each rotation from `onTokens` (the Keychain is the right place).
public actor TokenProvider {
    public private(set) var tokens: Tokens
    private let url: URL
    private let clientId: String
    private let resource: String?
    private let session: URLSession
    private let leeway: TimeInterval
    private let onTokens: (@Sendable (Tokens) async throws -> Void)?
    private var refreshing: Task<String, Error>?
    private var refreshFailure: AdoorError?
    private var needsPersistence = false

    public init(url: URL, clientId: String, tokens: Tokens, resource: String? = nil, session: URLSession = .shared, leeway: TimeInterval = 60, onTokens: (@Sendable (Tokens) async throws -> Void)? = nil) {
        self.url = url
        self.clientId = clientId
        self.tokens = tokens
        self.resource = resource
        self.session = session
        self.leeway = leeway
        self.onTokens = onTokens
    }

    public func token() async throws -> String {
        if let refreshFailure { throw refreshFailure }
        // The shared task includes persistence, not only the HTTP rotation.
        if let refreshing { return try await refreshing.value }
        if !needsPersistence, let expiresAt = tokens.expiresAt, Date() < expiresAt.addingTimeInterval(-leeway) { return tokens.accessToken }
        let task = Task { try await self.rotateAndPersist() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func rotateAndPersist() async throws -> String {
        if !needsPersistence {
            do {
                tokens = try await OAuth.refreshTokens(url: url, clientId: clientId, refreshToken: tokens.refreshToken, resource: resource, session: session)
                needsPersistence = true
            } catch {
                // The response may have been lost after rotation committed.
                // Reusing the consumed token revokes the entire family.
                let failure = AdoorError(code: "REFRESH_UNCERTAIN", message: "Refresh did not complete safely. Reconnect before requesting another token.", status: 401)
                refreshFailure = failure
                throw failure
            }
        }
        try await onTokens?(tokens)
        needsPersistence = false
        return tokens.accessToken
    }

    /// Use as `AdoorClient(url:token:)`'s source.
    public nonisolated var source: TokenSource { .provider { [self] in try await self.token() } }
}
