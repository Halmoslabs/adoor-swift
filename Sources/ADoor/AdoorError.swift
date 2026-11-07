import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The server's error envelope as a typed error, plus transport failures with status 0.
public struct AdoorError: Error, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String
    /// HTTP status, or 0 when the request never reached the server.
    public let status: Int
    public let details: JSONValue?

    public init(code: String, message: String, status: Int, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.details = details
    }

    /// A retry with the same idempotency key is safe and may succeed later.
    public var retryable: Bool { status == 0 || status >= 500 || status == 429 }

    /// The caller's authority ended or changed; a retry needs a new credential or a fresh read.
    public var authority: Bool {
        status == 401 || status == 403 || ["UNAUTHORIZED", "FORBIDDEN", "PERMISSIONS_CHANGED", "CONNECTION_CHANGED", "WORKSPACE_CHANGED", "FIELD_ACCESS_DENIED"].contains(code)
    }

    public var description: String { "\(code) (\(status)): \(message)" }

    static func network(_ error: Error) -> AdoorError {
        AdoorError(code: "NETWORK", message: error.localizedDescription, status: 0)
    }

    /// Build the typed error from a failed response; non-JSON bodies become a transport error with the HTTP status.
    static func from(response: HTTPURLResponse, data: Data) -> AdoorError {
        if let body = try? JSON.decode(JSONValue.self, from: data), let error = body["error"], let code = error["code"]?.stringValue {
            return AdoorError(code: code, message: error["message"]?.stringValue ?? code, status: response.statusCode, details: error["details"])
        }
        return AdoorError(code: "HTTP_\(response.statusCode)", message: "The request failed with HTTP \(response.statusCode).", status: response.statusCode)
    }
}
