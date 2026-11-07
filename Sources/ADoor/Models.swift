import Foundation

public struct Column: Codable, Equatable, Sendable {
    public let name: String
    public let type: String?
}

/// The result of one statement.
public struct QueryResult: Codable, Equatable, Sendable {
    public let rows: [Row]
    public let columns: [Column]
    public let rowCount: Int
    public let command: String
    public let schemaVersion: Int
    public let eventId: String?
    /// True when the server replayed a retained result for an idempotency key instead of running the write again.
    public let replayed: Bool?
}

public struct StatementError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let status: Int
    public let details: JSONValue?
}

/// One statement of a script. Statements commit independently; a failed one stops the script and later ones are skipped.
public enum BatchStatement: Equatable, Sendable {
    case success(index: Int, sql: String, result: QueryResult)
    case error(index: Int, sql: String, error: StatementError, executed: Bool, committed: Bool, rowCount: Int?, eventId: String?)
    case skipped(index: Int, sql: String)

    public var index: Int {
        switch self {
        case .success(let index, _, _), .error(let index, _, _, _, _, _, _), .skipped(let index, _): return index
        }
    }
}

public struct BatchResult: Equatable, Sendable {
    public let results: [BatchStatement]
    public let completed: Int
    public let failedAt: Int?
}

/// `query` and `execute` return one result for a single statement and a batch for a script.
public enum SqlResult: Equatable, Sendable {
    case single(QueryResult)
    case batch(BatchResult)

    public var single: QueryResult? { if case .single(let result) = self { return result }; return nil }
    public var batch: BatchResult? { if case .batch(let result) = self { return result }; return nil }

    init(json: JSONValue, data: Data) throws {
        if json["batch"]?.boolValue == true {
            self = .batch(try BatchResult(json: json))
        } else {
            self = .single(try JSON.decode(QueryResult.self, from: data))
        }
    }
}

extension BatchResult {
    init(json: JSONValue) throws {
        let statements = json["results"]?.arrayValue ?? []
        var results: [BatchStatement] = []
        for statement in statements {
            let index = statement["index"]?.intValue ?? results.count
            let sql = statement["sql"]?.stringValue ?? ""
            switch statement["status"]?.stringValue {
            case "success":
                var object = statement.objectValue ?? [:]
                for key in ["index", "sql", "kind", "status"] { object.removeValue(forKey: key) }
                let result = try JSON.decode(QueryResult.self, from: try JSON.encode(JSONValue.object(object)))
                results.append(.success(index: index, sql: sql, result: result))
            case "error":
                let error = try JSON.decode(StatementError.self, from: try JSON.encode(statement["error"] ?? .object([:])))
                results.append(.error(index: index, sql: sql, error: error, executed: statement["executed"]?.boolValue ?? false, committed: statement["committed"]?.boolValue ?? false, rowCount: statement["rowCount"]?.intValue, eventId: statement["eventId"]?.stringValue))
            default:
                results.append(.skipped(index: index, sql: sql))
            }
        }
        self.init(results: results, completed: json["completed"]?.intValue ?? 0, failedAt: json["failedAt"]?.intValue)
    }
}

public struct TableColumn: Codable, Equatable, Sendable {
    public let name: String
    public let type: String
    public let nullable: Bool
    public let primaryKey: Bool
}

public struct TableDescription: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let spaceId: String
    public let spaceName: String
    public let spaceSlug: String
    public let system: Bool?
    public let systemKind: String?
    public let displayName: String?
    public let columns: [TableColumn]
    public let permissions: [String]
}

public struct Workspace: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
}

/// What `describe()` returns: the connection, the visible tables and the read-only catalog views.
public struct Description: Codable, Sendable {
    public let backend: String
    public let label: String
    public let workspace: Workspace
    public let schemaVersion: Int
    public let connection: JSONValue
    public let tables: [TableDescription]
    public let catalogs: JSONValue
}

/// An authorized invalidation: which table changed, never the row values. A scoped
/// connection sees `table_changed` for data it may read; a workspace owner sees the mutation kind.
public struct ChangeEvent: Codable, Equatable, Sendable {
    public let cursor: String
    public let eventId: String
    public let type: String
    public let table: String?
    public let spaceId: String?
    public let at: String
}

public struct ChangePage: Codable, Sendable {
    public let changes: [ChangeEvent]
    public let nextCursor: String
    public let hasMore: Bool
}

/// Frames of a change subscription. A checkpoint confirms everything up to its cursor; persist it to resume later.
public enum ChangeFrame: Equatable, Sendable {
    case change(ChangeEvent)
    case checkpoint(cursor: String)
}
