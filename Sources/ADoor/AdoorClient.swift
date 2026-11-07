import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stable, non-secret identity from the app's authenticated session, independent of token rotation.
public struct LocalIdentity: Equatable, Sendable {
    public let accountId: String
    public let workspaceId: String
    public let spaceId: String
    public init(accountId: String, workspaceId: String, spaceId: String) {
        self.accountId = accountId; self.workspaceId = workspaceId; self.spaceId = spaceId
    }
}

/// Where the bearer token comes from: a fixed access key, or a provider such as `TokenProvider` that refreshes.
public enum TokenSource: Sendable {
    case fixed(String)
    case provider(@Sendable () async throws -> String)

    func value() async throws -> String {
        switch self {
        case .fixed(let token): return token
        case .provider(let provider): return try await provider()
        }
    }
}

/// Credentialed requests never follow a redirect to another origin.
final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Everything the server exposes is a named operation on one endpoint; these are the typed conveniences over it.
public final class AdoorClient: @unchecked Sendable {
    /// The ADoor origin, or your own backend that forwards to it. Browser-style cross-origin access is not
    /// available; native apps call ADoor directly.
    public let url: URL
    private let identitySource: (@Sendable () -> LocalIdentity?)?
    let boundIdentity: LocalIdentity?
    let token: TokenSource
    let session: URLSession
    let headers: [String: String]
    let redirects = RedirectBlocker()

    public init(url: URL, token: TokenSource, session: URLSession = .shared, headers: [String: String] = [:], identity: (@Sendable () -> LocalIdentity?)? = nil) {
        self.identitySource = identity
        self.boundIdentity = identity?()
        self.url = url
        self.token = token
        self.session = session
        self.headers = headers
    }

    public convenience init(url: URL, accessKey: String, session: URLSession = .shared, identity: (@Sendable () -> LocalIdentity?)? = nil) {
        self.init(url: url, token: .fixed(accessKey), session: session, identity: identity)
    }

    /// No network request: the app must update this provider before changing credentials or selected context.
    public func localIdentity() throws -> LocalIdentity? {
        guard let boundIdentity else { return nil }
        guard let current = identitySource?(), current == boundIdentity,
              ![current.accountId, current.workspaceId, current.spaceId].contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AdoorError(code: "IDENTITY_CHANGED", message: "The app session changed. Use a new client and local store for this identity.", status: 401)
        }
        return boundIdentity
    }

    func makeRequest(path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil, accept: String = "application/json", extra: [String: String] = [:]) async throws -> URLRequest {
        _ = try localIdentity()
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(try await token.value())", forHTTPHeaderField: "Authorization")
        _ = try localIdentity()
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in extra { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        _ = try localIdentity()
        let received: (Data, URLResponse)
        do { received = try await session.data(for: request, delegate: redirects) }
        catch { throw AdoorError.network(error) }
        _ = try localIdentity()
        let (data, response) = received
        guard let http = response as? HTTPURLResponse else { throw AdoorError(code: "HTTP_INVALID", message: "The server returned no HTTP response.", status: 0) }
        guard (200..<300).contains(http.statusCode) else { throw AdoorError.from(response: http, data: data) }
        return (data, http)
    }

    /// Call any operation by name with a JSON input; the result is the operation's JSON output.
    public func call(_ operation: String, input: JSONValue = .object([:])) async throws -> (JSONValue, Data) {
        guard operation.range(of: #"^[a-z]+\.[a-z_]+$"#, options: .regularExpression) != nil else {
            throw AdoorError(code: "INVALID_OPERATION", message: "Operation names look like data.query.", status: 400)
        }
        let request = try await makeRequest(path: "api/operations/\(operation)", method: "POST", body: try JSON.encode(input), contentType: "application/json")
        let (data, _) = try await send(request)
        return (try JSON.decode(JSONValue.self, from: data), data)
    }

    public func call<T: Decodable>(_ operation: String, input: JSONValue = .object([:]), as type: T.Type) async throws -> T {
        let (_, data) = try await call(operation, input: input)
        return try JSON.decode(type, from: data)
    }

    func sql(_ operation: String, _ text: String, params: [JSONValue], spaceId: String?, idempotencyKey: String?, expectRowCount: Int?) async throws -> SqlResult {
        var input: [String: JSONValue] = ["sql": .string(text)]
        if !params.isEmpty { input["params"] = .array(params) }
        if let spaceId { input["spaceId"] = .string(spaceId) }
        if let idempotencyKey { input["idempotencyKey"] = .string(idempotencyKey) }
        if let expectRowCount { input["expectRowCount"] = .number(Double(expectRowCount)) }
        let (json, data) = try await call(operation, input: .object(input))
        return try SqlResult(json: json, data: data)
    }

    /// One or more SELECT statements with parameters.
    public func query(_ text: String, params: [JSONValue] = [], spaceId: String? = nil) async throws -> SqlResult {
        try await sql("data.query", text, params: params, spaceId: spaceId, idempotencyKey: nil, expectRowCount: nil)
    }

    /// INSERT, UPDATE, DELETE or the managed CREATE TABLE. An idempotency key makes any retry safe: the server
    /// replays the committed result. `expectRowCount` makes a single mutation conditional: a different count is
    /// rolled back inside its transaction and answered with CONFLICT.
    public func execute(_ text: String, params: [JSONValue] = [], spaceId: String? = nil, idempotencyKey: String? = nil, expectRowCount: Int? = nil) async throws -> SqlResult {
        try await sql("data.execute", text, params: params, spaceId: spaceId, idempotencyKey: idempotencyKey, expectRowCount: expectRowCount)
    }

    public func describe() async throws -> Description {
        try await call("store.describe", as: Description.self)
    }

    /// The current committed cursor. Capture it before loading a snapshot, then subscribe from it.
    public func changesHead() async throws -> String {
        struct Head: Decodable { let cursor: String }
        return try await call("changes.head", as: Head.self).cursor
    }

    public func changes(after: String? = nil, limit: Int? = nil) async throws -> ChangePage {
        var input: [String: JSONValue] = [:]
        if let after { input["after"] = .string(after) }
        if let limit { input["limit"] = .number(Double(limit)) }
        return try await call("changes.list", input: .object(input), as: ChangePage.self)
    }
}
