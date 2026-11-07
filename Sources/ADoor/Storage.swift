import Foundation

/// Durable key/value storage for cached rows and the outbox. Values are strings so any store fits.
public protocol Storage: Sendable {
    func get(_ key: String) async throws -> String?
    func set(_ key: String, _ value: String) async throws
    func delete(_ key: String) async throws
}

/// Nothing survives the process; the default when no storage is given.
public actor MemoryStorage: Storage {
    private var values: [String: String] = [:]
    public init() {}
    public func get(_ key: String) -> String? { values[key] }
    public func set(_ key: String, _ value: String) { values[key] = value }
    public func delete(_ key: String) { values.removeValue(forKey: key) }
}

/// One file per key in a directory, for example Application Support. Writes are atomic.
public actor FileStorage: Storage {
    private let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func file(_ key: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        return directory.appendingPathComponent((key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key) + ".json")
    }
    public func get(_ key: String) throws -> String? {
        let url = file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return String(data: try Data(contentsOf: url), encoding: .utf8)
    }
    public func set(_ key: String, _ value: String) throws { try Data(value.utf8).write(to: file(key), options: .atomic) }
    public func delete(_ key: String) throws {
        let url = file(key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
