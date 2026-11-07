import Foundation
import CryptoKit

/// A SELECT the store keeps current. Tables default to those named after FROM and JOIN.
public struct CollectionSpec: Sendable {
    public var sql: String
    public var params: [JSONValue]
    public var spaceId: String?
    public var tables: [String]?
    public init(sql: String, params: [JSONValue] = [], spaceId: String? = nil, tables: [String]? = nil) {
        self.sql = sql
        self.params = params
        self.spaceId = spaceId
        self.tables = tables
    }
}

/// A write applied locally at once and sent with an idempotency key, so a retry never duplicates it.
public struct Mutation: Sendable {
    public var sql: String
    public var params: [JSONValue]
    public var spaceId: String?
    /// Defaults to a fresh UUID. Reuse one to make an application-level retry idempotent too.
    public var idempotencyKey: String?
    /// Optimistic projections per collection, replaced by server rows once the change is confirmed.
    public var apply: [String: @Sendable ([Row]) -> [Row]]
    /// Compare-and-set guard: put the values you read into the WHERE clause; the server rolls back a write that
    /// would change a different number of rows and answers CONFLICT.
    public var expectRowCount: Int?
    public init(sql: String, params: [JSONValue] = [], spaceId: String? = nil, idempotencyKey: String? = nil, apply: [String: @Sendable ([Row]) -> [Row]] = [:], expectRowCount: Int? = nil) {
        self.sql = sql
        self.params = params
        self.spaceId = spaceId
        self.idempotencyKey = idempotencyKey
        self.apply = apply
        self.expectRowCount = expectRowCount
    }
}

/// What the outbox persists about a queued write.
public struct PersistedMutation: Codable, Equatable, Sendable {
    public let id: String
    public let sql: String
    public let params: [JSONValue]
    public let spaceId: String?
    public let idempotencyKey: String
    public let expectRowCount: Int?
}

public enum Status: String, Sendable { case idle, syncing, live, offline, blocked }

public struct LocalStoreOptions: Sendable {
    public var collections: [String: CollectionSpec]
    public var storage: Storage?
    /// App key prefix; identity isolation is added automatically. Legacy keys are left untouched.
    public var namespace: String
    /// The server rejected a queued write for good: permissions, validation, a conflict, a changed retry.
    public var onRejected: (@Sendable (PersistedMutation, AdoorError) -> Void)?
    /// Transient failures and refetch errors; the store keeps retrying.
    public var onError: (@Sendable (AdoorError) -> Void)?
    public var initialRetry: TimeInterval = 0.5
    public var maxRetry: TimeInterval = 10
    public init(collections: [String: CollectionSpec], storage: Storage? = nil, namespace: String = "adoor", onRejected: (@Sendable (PersistedMutation, AdoorError) -> Void)? = nil, onError: (@Sendable (AdoorError) -> Void)? = nil) {
        self.collections = collections
        self.storage = storage
        self.namespace = namespace
        self.onRejected = onRejected
        self.onError = onError
    }
}

/// A local-first view over ADoor: collections are SELECTs kept current from the durable change feed, writes
/// apply locally first and reach the server through an idempotent outbox that survives restarts. Authority
/// stays with the server: a rejected write is rolled back and reported, never retried.
public actor LocalStore {
    private struct Pending {
        let persisted: PersistedMutation
        let apply: [String: @Sendable ([Row]) -> [Row]]
        let continuation: CheckedContinuation<SqlResult, Error>?
    }
    private struct CollectionState {
        var spec: CollectionSpec
        var tables: [String]
        var base: [Row] = []
        var synced = false
        var listeners: [UUID: @Sendable ([Row]) -> Void] = [:]
    }

    private let client: AdoorClient
    private let options: LocalStoreOptions
    private let storage: Storage
    private let identity: LocalIdentity?
    private let scope: String
    private var collections: [String: CollectionState] = [:]
    private var pending: [Pending] = []
    private var flushTask: Task<Void, Never>?
    private var syncTask: Task<Void, Error>?
    private var loading: Task<Void, Error>?
    private var storageTail: Task<Void, Never>?
    private var closed = false
    private var started = false
    private var refreshScheduled: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var statusListeners: [UUID: @Sendable (Status) -> Void] = [:]
    public private(set) var status: Status = .idle
    public var pendingCount: Int { pending.count }

    public init(client: AdoorClient, options: LocalStoreOptions) {
        self.client = client
        self.options = options
        self.storage = options.storage ?? MemoryStorage()
        // Validation is performed by load/refresh before any storage or network use.
        let identity = client.boundIdentity
        self.identity = identity
        if let identity {
            let server = client.url.absoluteURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = [options.namespace, server, identity.accountId, identity.workspaceId, identity.spaceId]
            let data = try! JSON.encode(parts)
            self.scope = "adoor:v2:" + CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else { self.scope = options.namespace }
        for (name, spec) in options.collections {
            var selected = spec
            if selected.spaceId == nil { selected.spaceId = identity?.spaceId }
            collections[name] = CollectionState(spec: selected, tables: spec.tables ?? LocalStore.tables(in: spec.sql))
        }
    }

    static func tables(in sql: String) -> [String] {
        var names: [String] = []
        let pattern = try! NSRegularExpression(pattern: #"\b(?:from|join)\s+"?([a-z_][a-z0-9_]*)"?"#, options: [.caseInsensitive])
        for match in pattern.matches(in: sql, range: NSRange(sql.startIndex..., in: sql)) {
            if let range = Range(match.range(at: 1), in: sql) {
                let name = sql[range].lowercased()
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    private func key(_ part: String) -> String {
        if identity != nil, part.hasPrefix("rows:"), let spaceId = collections[String(part.dropFirst(5))]?.spec.spaceId {
            return "\(scope):\(spaceId):\(part)"
        }
        return "\(scope):\(part)"
    }
    private func report(_ error: Error) {
        options.onError?(error as? AdoorError ?? AdoorError(code: "CLIENT", message: error.localizedDescription, status: 0))
    }
    private func setStatus(_ next: Status) {
        guard status != next else { return }
        status = next
        for listener in statusListeners.values { listener(next) }
    }

    // MARK: Reading

    /// Server rows with pending optimistic projections applied, or the cached rows before the first sync.
    public func rows(of name: String) -> [Row] {
        guard (try? checkIdentity()) != nil, let state = collections[name] else { return [] }
        return pending.reduce(state.base) { rows, mutation in mutation.apply[name].map { $0(rows) } ?? rows }
    }

    public func isSynced(_ name: String) -> Bool { (try? checkIdentity()) != nil && (collections[name]?.synced ?? false) }

    /// The listener receives the current rows at once and after every change. Keep the token to unsubscribe.
    @discardableResult
    public func subscribe(_ name: String, _ listener: @escaping @Sendable ([Row]) -> Void) -> UUID {
        let token = UUID()
        collections[name]?.listeners[token] = listener
        listener(rows(of: name))
        return token
    }
    public func unsubscribe(_ name: String, _ token: UUID) { collections[name]?.listeners.removeValue(forKey: token) }

    /// Rows as an async sequence, for `for await rows in store.observe("notes")`.
    public func observe(_ name: String) -> AsyncStream<[Row]> {
        AsyncStream { continuation in
            let token = subscribe(name) { rows in continuation.yield(rows) }
            continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(name, token) } }
        }
    }

    @discardableResult
    public func onStatus(_ listener: @escaping @Sendable (Status) -> Void) -> UUID {
        let token = UUID()
        statusListeners[token] = listener
        listener(status)
        return token
    }
    public func removeStatusListener(_ token: UUID) { statusListeners.removeValue(forKey: token) }

    private func notify(_ name: String) {
        guard let state = collections[name] else { return }
        let current = rows(of: name)
        for listener in state.listeners.values { listener((try? checkIdentity()) != nil ? current : []) }
    }

    // MARK: Storage and lifecycle

    // Actors are reentrant across await. Serialize storage explicitly so an old
    // write cannot complete after a newer outbox or after sign-out cleanup.
    private func storageWork<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = storageTail
        let task = Task { _ = await previous?.value; return try await operation() }
        storageTail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func persistOutbox() async throws {
        guard !closed else { return }
        let storage = self.storage, outboxKey = key("outbox")
        let encoded = String(decoding: try JSON.encode(pending.map(\.persisted)), as: UTF8.self)
        try await storageWork { try await storage.set(outboxKey, encoded) }
    }

    private func load() async throws {
        if let loading { try await loading.value; return }
        let task = Task { try await self.hydrate() }
        loading = task
        try await task.value
    }

    private func checkIdentity() throws {
        let current = try client.localIdentity()
        if options.storage != nil && identity == nil {
            throw AdoorError(code: "IDENTITY_REQUIRED", message: "Storage requires a client identity with accountId, workspaceId and spaceId.", status: 400)
        }
        guard current == identity else { throw AdoorError(code: "IDENTITY_CHANGED", message: "The app session changed. Use a new client and local store for this identity.", status: 401) }
    }

    private func hydrate() async throws {
        try checkIdentity()
        if identity != nil, let legacy = try await storage.get("\(options.namespace):outbox"), legacy != "[]" {
            throw AdoorError(code: "LEGACY_LOCAL_STATE", message: "An unbound legacy outbox exists. Export it and verify its owner before removing its old key; it will not be replayed or cleared automatically.", status: 409)
        }
        for name in collections.keys {
            let cached = try await storage.get(key("rows:\(name)"))
            guard !closed else { return }
            try checkIdentity()
            if let cached, let rows = try? JSON.decode([Row].self, from: Data(cached.utf8)) { collections[name]?.base = rows }
        }
        let outbox = try await storage.get(key("outbox"))
        guard !closed else { return }
        try checkIdentity()
        if let outbox {
            guard let entries = try? JSON.decode([PersistedMutation].self, from: Data(outbox.utf8)), Set(entries.map(\.id)).count == entries.count else {
                throw AdoorError(code: "OUTBOX_CORRUPT", message: "The saved outbox is unreadable. Preserve it for recovery before reconnecting.", status: 409)
            }
            pending = entries.map { Pending(persisted: $0, apply: [:], continuation: nil) }
        }
        for name in collections.keys { notify(name) }
    }

    private func ensureOpen() throws {
        if closed { throw AdoorError(code: "STORE_CLOSED", message: "This store is closed. Reconnect with a new instance.", status: 409) }
    }

    private func halt(_ error: AdoorError, status next: Status, rejected: PersistedMutation? = nil) async throws {
        guard !closed else { return }
        closed = true
        syncTask?.cancel(); flushTask?.cancel(); refreshTask?.cancel()
        refreshScheduled.removeAll()
        let retained = pending.map(\.persisted)
        for mutation in pending { mutation.continuation?.resume(throwing: error) }
        pending.removeAll()
        for name in collections.keys { collections[name]?.base = []; collections[name]?.synced = false; notify(name) }
        setStatus(next)
        if let rejected { options.onRejected?(rejected, error) }
        let storage = self.storage, outboxKey = key("outbox"), cacheKeys = collections.keys.map { key("rows:\($0)") }
        let encoded = String(decoding: try JSON.encode(retained), as: UTF8.self)
        try await storageWork {
            // Never overwrite a corrupt or as-yet-unread outbox with an empty list.
            if !retained.isEmpty { try await storage.set(outboxKey, encoded) }
            for key in cacheKeys { try await storage.delete(key) }
        }
    }

    // MARK: Syncing

    public func refresh(_ name: String) async throws {
        try ensureOpen()
        guard let state = collections[name] else { throw AdoorError(code: "UNKNOWN_COLLECTION", message: "No collection is named \(name).", status: 400) }
        do {
            try checkIdentity()
            let result = try await client.query(state.spec.sql, params: state.spec.params, spaceId: state.spec.spaceId)
            guard !closed else { return }
            try checkIdentity()
            guard case .single(let single) = result else { throw AdoorError(code: "SINGLE_STATEMENT", message: "A collection is one SELECT statement.", status: 400) }
            let storage = self.storage, cacheKey = key("rows:\(name)")
            let encoded = String(decoding: try JSON.encode(single.rows), as: UTF8.self)
            try await storageWork { try await storage.set(cacheKey, encoded) }
            guard !closed else { return }
            try checkIdentity()
            collections[name]?.base = single.rows
            collections[name]?.synced = true
            notify(name)
        } catch {
            if let typed = error as? AdoorError, typed.authority { try await halt(typed, status: .blocked) }
            throw error
        }
    }

    private func schedule(_ names: [String]) {
        guard !closed else { return }
        refreshScheduled.formUnion(names)
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await Task.yield()
            await self?.runScheduledRefresh()
        }
    }
    private func runScheduledRefresh() async {
        refreshTask = nil
        guard !closed else { return }
        let names = refreshScheduled
        refreshScheduled = []
        await withTaskGroup(of: Void.self) { group in
            for name in names { group.addTask { [self] in do { try await self.refresh(name) } catch { await self.report(error) } } }
        }
    }
    private func affected(by change: ChangeEvent) -> [String] {
        collections.compactMap { (name, state) -> String? in
            guard let table = change.table?.lowercased() else { return name }
            return state.tables.isEmpty || state.tables.contains(table) ? name : nil
        }
    }

    /// Start once. Cancellation stops this instance and retains requests for a new instance to recover.
    public func start() async throws {
        try ensureOpen()
        guard !started else { throw AdoorError(code: "STORE_LIFECYCLE", message: "Start a fresh store instance once per connection.", status: 409) }
        started = true
        let task = Task { try await self.runSync() }
        syncTask = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if !closed, task.isCancelled {
                try await halt(AdoorError(code: "STORE_STOPPED", message: "Sync stopped. Pending requests were retained.", status: 409), status: .idle)
                return
            }
            throw error
        }
    }

    private func runSync() async throws {
        setStatus(.syncing)
        try await load()
        while !closed {
            try Task.checkCancellation()
            do {
                let head = try await client.changesHead()
                for name in collections.keys { try await refresh(name) }
                guard !closed else { return }
                setStatus(.live)
                if !pending.isEmpty { flush() }
                for try await frame in client.subscribeChanges(SubscribeOptions(after: head)) {
                    try Task.checkCancellation()
                    guard !closed else { return }
                    if case .change(let change) = frame { setStatus(.live); schedule(affected(by: change)) }
                }
                try Task.checkCancellation()
            } catch {
                if let typed = error as? AdoorError, typed.authority { try await halt(typed, status: .blocked); throw typed }
                if closed { return }
                try Task.checkCancellation()
                report(error); setStatus(.offline)
                try await Task.sleep(nanoseconds: retryNanoseconds(options.initialRetry))
            }
        }
    }

    private func retryNanoseconds(_ interval: TimeInterval) -> UInt64 {
        // Public retry options must not trap on negative, infinite or huge values.
        UInt64(min(3600, max(0.001, interval.isFinite ? interval : 10)) * 1_000_000_000)
    }

    // MARK: Writing

    public func mutate(_ input: Mutation) async throws -> SqlResult {
        try ensureOpen()
        try await load()
        try ensureOpen()
        try checkIdentity()
        let persisted = PersistedMutation(id: UUID().uuidString, sql: input.sql, params: input.params, spaceId: input.spaceId ?? identity?.spaceId, idempotencyKey: input.idempotencyKey ?? "\(options.namespace):\(UUID().uuidString)", expectRowCount: input.expectRowCount)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(persisted: persisted, apply: input.apply, continuation: continuation))
            for name in input.apply.keys { notify(name) }
            // This also saves later queued edits while the head waits for retry.
            Task {
                do { try await persistOutbox(); flush() }
                catch { report(error); flush() } // drain retries storage before any HTTP request
            }
        }
    }

    private func flush() {
        guard !closed, flushTask == nil else { return }
        flushTask = Task { [weak self] in await self?.drain() }
    }

    private func settle(_ mutation: Pending, _ outcome: Result<SqlResult, AdoorError>) async throws {
        guard !closed, pending.first?.persisted.id == mutation.persisted.id else { return }
        let storage = self.storage, outboxKey = key("outbox")
        let encoded = String(decoding: try JSON.encode(pending.dropFirst().map(\.persisted)), as: UTF8.self)
        try await storageWork { try await storage.set(outboxKey, encoded) }
        guard !closed, pending.first?.persisted.id == mutation.persisted.id else { return }
        try checkIdentity()
        pending.removeFirst()
        switch outcome {
        case .success(let result): mutation.continuation?.resume(returning: result)
        case .failure(let error):
            mutation.continuation?.resume(throwing: error)
            options.onRejected?(mutation.persisted, error)
        }
        schedule(mutation.apply.isEmpty ? Array(collections.keys) : Array(mutation.apply.keys))
    }

    private func drain() async {
        defer { flushTask = nil }
        var delay = options.initialRetry
        while let mutation = pending.first, !Task.isCancelled, !closed {
            do {
                try await persistOutbox()
                guard !closed, !Task.isCancelled else { return }
                try checkIdentity()
                let result = try await client.execute(mutation.persisted.sql, params: mutation.persisted.params, spaceId: mutation.persisted.spaceId, idempotencyKey: mutation.persisted.idempotencyKey, expectRowCount: mutation.persisted.expectRowCount)
                guard !closed, !Task.isCancelled else { return }
                try checkIdentity()
                if case .batch(let batch) = result, let failedAt = batch.failedAt {
                    guard batch.results.indices.contains(failedAt) else { throw AdoorError(code: "INVALID_RESPONSE", message: "The batch failure index is invalid.", status: 502) }
                    var cause = AdoorError(code: "BATCH_FAILED", message: "A statement did not run.", status: 500)
                    if case .error(_, _, let error, _, _, _, _) = batch.results[failedAt] { cause = AdoorError(code: error.code, message: error.message, status: error.status, details: error.details) }
                    if cause.authority { throw cause }
                    if cause.retryable { throw cause }
                    try await settle(mutation, .failure(AdoorError(code: "BATCH_FAILED", message: "Statement \(failedAt + 1) failed with \(cause.code); \(batch.completed) earlier statements committed and later ones were skipped. Send a corrected script under a new idempotency key.", status: cause.status)))
                    continue
                }
                delay = options.initialRetry
                if status == .offline { setStatus(.live) }
                try await settle(mutation, .success(result))
            } catch {
                guard !closed, !Task.isCancelled else { return }
                let typed = error as? AdoorError ?? AdoorError.network(error)
                if typed.authority {
                    do { try await halt(typed, status: .blocked, rejected: mutation.persisted) } catch { report(error) }
                    report(typed); return
                }
                if typed.retryable {
                    setStatus(.offline); report(typed)
                    try? await Task.sleep(nanoseconds: retryNanoseconds(delay))
                    delay = min(options.maxRetry, delay * 2)
                } else {
                    do { try await settle(mutation, .failure(typed)) }
                    catch { report(error); try? await Task.sleep(nanoseconds: retryNanoseconds(delay)) }
                }
            }
        }
    }

    /// Terminal sign-out/discard. An already committed server write cannot be recalled.
    public func clear() async throws {
        if options.storage != nil && identity == nil { try checkIdentity() }
        closed = true
        syncTask?.cancel(); flushTask?.cancel(); refreshTask?.cancel()
        refreshScheduled.removeAll()
        for mutation in pending { mutation.continuation?.resume(throwing: AdoorError(code: "STORE_CLOSED", message: "The local store was cleared.", status: 409)) }
        pending.removeAll()
        for name in collections.keys { collections[name]?.base = []; collections[name]?.synced = false; notify(name) }
        setStatus(.idle)
        let storage = self.storage, keys = [key("outbox")] + collections.keys.map { key("rows:\($0)") }
        try await storageWork { for key in keys { try await storage.delete(key) } }
    }
}
