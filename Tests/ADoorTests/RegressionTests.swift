import XCTest
import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ADoor

private actor Gate {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; for waiter in waiters { waiter.resume() }; waiters = [] }
}
private actor Recorder {
    var requests: [URLRequest] = []
    var saves = 0
    var returned = 0
    func record(_ request: URLRequest) { requests.append(request) }
    func saved() -> Int { saves += 1; return saves }
    func didReturn() { returned += 1 }
}
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    private var transportTask: Task<Void, Never>?
    static func register(_ host: String, _ handler: @escaping Handler) { lock.lock(); defer { lock.unlock() }; handlers[host] = handler }
    static func handler(_ host: String) -> Handler? { lock.lock(); defer { lock.unlock() }; return handlers[host] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.handler(request.url!.host!)!
        transportTask = Task {
            do {
                let (status, data) = try await handler(request)
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) } }
        }
    }
    override func stopLoading() { transportTask?.cancel() }
}
private actor TestStorage: Storage {
    var values: [String: String] = [:]
    let gate: Gate?
    var failReceiptOnce = false
    let receiptGate: Gate?
    var savingReceipt = false
    init(gate: Gate? = nil, failReceiptOnce: Bool = false, receiptGate: Gate? = nil) { self.gate = gate; self.failReceiptOnce = failReceiptOnce; self.receiptGate = receiptGate }
    func get(_ key: String) -> String? { values[key] }
    func set(_ key: String, _ value: String) async throws {
        if key.hasSuffix(":outbox") { await gate?.wait() }
        if key.hasSuffix(":outbox"), value == "[]", let receiptGate { savingReceipt = true; await receiptGate.wait() }
        if failReceiptOnce, key.hasSuffix(":outbox"), !value.contains("first-key"), value.contains("second-key") {
            failReceiptOnce = false; throw URLError(.cannotWriteToFile)
        }
        values[key] = value
    }
    func delete(_ key: String) { values.removeValue(forKey: key) }
}

private final class AppSession: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: LocalIdentity? = LocalIdentity(accountId: "A", workspaceId: "workspace", spaceId: "chosen")
    func current() -> LocalIdentity? { lock.lock(); defer { lock.unlock() }; return identity }
    func signOut() { lock.lock(); defer { lock.unlock() }; identity = nil }
    func switchAccount() { lock.lock(); defer { lock.unlock() }; identity = LocalIdentity(accountId: "B", workspaceId: "workspace", spaceId: "chosen") }
}

final class RegressionTests: XCTestCase {
    private func savedKey(_ url: URL, _ part: String) throws -> String {
        let data = try JSON.encode(["adoor", url.absoluteString, "account", "workspace", "chosen"])
        let scope = "adoor:v2:" + CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return scope + (part.hasPrefix("rows:") ? ":chosen:" : ":") + part
    }
    private let result = Data(#"{"rows":[],"columns":[],"rowCount":1,"command":"UPDATE","schemaVersion":1}"#.utf8)
    private func fixture(_ handler: @escaping StubProtocol.Handler) -> (URL, URLSession) {
        let host = UUID().uuidString.lowercased() + ".example"
        StubProtocol.register(host, handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return (URL(string: "https://\(host)")!, URLSession(configuration: configuration))
    }
    private func tokens() throws -> Tokens {
        try JSON.decode(Tokens.self, from: Data(#"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600,"installation_id":"installation","connection_id":"connection","workspace_id":"workspace","space_ids":["other","chosen"],"selected_space_id":"chosen"}"#.utf8))
    }
    private func eventually(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 { if await condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    func testChooserAndSelectedSpaceAreCarriedAcrossOAuth() throws {
        let details = SpaceAuthorizationDetails(suggestedName: "My app", permissions: [["table": "*", "actions": ["select", "insert", "update", "create"]]])
        let url = try OAuth.authorizationURL(url: URL(string: "https://adoor.example")!, clientId: "client", redirectUri: "http://127.0.0.1:49101/callback", pkce: OAuth.createPKCE(), authorizationDetails: details)
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "authorization_details" }!.value!
        let value = try JSON.decode(JSONValue.self, from: Data(raw.utf8))
        XCTAssertEqual(value.arrayValue?.first?["space_selection"]?["allow"], ["create", "existing"])
        XCTAssertEqual(try tokens().selectedSpaceId, "chosen")
    }

    func testConcurrentTokenCallersWaitForPersistence() async throws {
        let recorder = Recorder(), gate = Gate(), data = try JSON.encode(tokens())
        let (url, session) = fixture { request in await recorder.record(request); return (200, data) }
        defer { session.invalidateAndCancel() }
        let provider = TokenProvider(url: url, clientId: "client", tokens: try tokens(), session: session, onTokens: { _ in _ = await recorder.saved(); await gate.wait() })
        let first = Task { let token = try await provider.token(); await recorder.didReturn(); return token }
        try await eventually { await recorder.saves == 1 }
        let second = Task { let token = try await provider.token(); await recorder.didReturn(); return token }
        try await Task.sleep(nanoseconds: 30_000_000)
        let returned = await recorder.returned
        XCTAssertEqual(returned, 0, "No caller may use rotated credentials before persistence.")
        await gate.open()
        let a = try await first.value, b = try await second.value, calls = await recorder.requests.count
        XCTAssertEqual(a, "new-access"); XCTAssertEqual(b, a); XCTAssertEqual(calls, 1)
    }

    func testLostRefreshResponseIsNeverRetried() async throws {
        let recorder = Recorder()
        let (url, session) = fixture { request in await recorder.record(request); throw URLError(.networkConnectionLost) }
        defer { session.invalidateAndCancel() }
        let provider = TokenProvider(url: url, clientId: "client", tokens: try tokens(), session: session)
        for _ in 0..<2 { do { _ = try await provider.token(); XCTFail("Expected reconnect") } catch let error as AdoorError { XCTAssertEqual(error.code, "REFRESH_UNCERTAIN") } }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 1)
    }

    func testFailedPersistenceRetriesSamePairWithoutAnotherRotation() async throws {
        let recorder = Recorder(), data = try JSON.encode(tokens())
        let (url, session) = fixture { request in await recorder.record(request); return (200, data) }
        defer { session.invalidateAndCancel() }
        let provider = TokenProvider(url: url, clientId: "client", tokens: try tokens(), session: session, onTokens: { _ in if await recorder.saved() == 1 { throw URLError(.cannotWriteToFile) } })
        do { _ = try await provider.token(); XCTFail("Expected save failure") } catch {}
        let token = try await provider.token(), calls = await recorder.requests.count, saves = await recorder.saves
        XCTAssertEqual(token, "new-access"); XCTAssertEqual(calls, 1); XCTAssertEqual(saves, 2)
    }

    func testWriteWaitsForDurableOutbox() async throws {
        let gate = Gate(), recorder = Recorder(), data = result
        let storage = TestStorage(gate: gate)
        let (url, session) = fixture { request in await recorder.record(request); return (200, data) }
        defer { session.invalidateAndCancel() }
        let store = LocalStore(client: AdoorClient(url: url, accessKey: "fixture", session: session, identity: { LocalIdentity(accountId: "account", workspaceId: "workspace", spaceId: "chosen") }), options: LocalStoreOptions(collections: [:], storage: storage))
        let mutation = Task { try await store.mutate(Mutation(sql: "UPDATE notes SET title=$1", params: ["original"], idempotencyKey: "stable-key", expectRowCount: 1)) }
        try await eventually { await store.pendingCount == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        let before = await recorder.requests.count; XCTAssertEqual(before, 0)
        await gate.open(); _ = try await mutation.value
        let after = await recorder.requests.count; XCTAssertEqual(after, 1)
        try await store.clear()
    }

    func testClearDuringRefetchCannotResurrectRows() async throws {
        let gate = Gate(), recorder = Recorder(), storage = MemoryStorage()
        let data = Data(#"{"rows":[{"id":"private"}],"columns":[],"rowCount":1,"command":"SELECT","schemaVersion":1}"#.utf8)
        let (url, session) = fixture { request in await recorder.record(request); await gate.wait(); return (200, data) }
        defer { session.invalidateAndCancel() }
        let store = LocalStore(client: AdoorClient(url: url, accessKey: "fixture", session: session, identity: { LocalIdentity(accountId: "account", workspaceId: "workspace", spaceId: "chosen") }), options: LocalStoreOptions(collections: ["notes": CollectionSpec(sql: "SELECT id FROM notes")], storage: storage))
        let refetch = Task { try await store.refresh("notes") }
        try await eventually { await recorder.requests.count == 1 }
        try await store.clear(); await gate.open(); try await refetch.value
        let rows = await store.rows(of: "notes"), cache = await storage.get(try savedKey(url, "rows:notes"))
        XCTAssertTrue(rows.isEmpty); XCTAssertNil(cache)
        do { _ = try await store.mutate(Mutation(sql: "UPDATE notes SET title=1")); XCTFail("Cleared store must be closed") } catch let error as AdoorError { XCTAssertEqual(error.code, "STORE_CLOSED") }
    }

    func testClearDuringWriteDoesNotCrashOrResumeTwice() async throws {
        let gate = Gate(), recorder = Recorder(), data = result
        let (url, session) = fixture { request in await recorder.record(request); await gate.wait(); return (200, data) }
        defer { session.invalidateAndCancel() }
        let store = LocalStore(client: AdoorClient(url: url, accessKey: "fixture", session: session, identity: { LocalIdentity(accountId: "account", workspaceId: "workspace", spaceId: "chosen") }), options: LocalStoreOptions(collections: [:]))
        let mutation = Task { try await store.mutate(Mutation(sql: "UPDATE notes SET title=1")) }
        try await eventually { await recorder.requests.count == 1 }
        try await store.clear(); await gate.open()
        do { _ = try await mutation.value; XCTFail("Expected closed store") } catch let error as AdoorError { XCTAssertEqual(error.code, "STORE_CLOSED") }
        let pending = await store.pendingCount; XCTAssertEqual(pending, 0)
    }

    func testRestartLoadsOutboxBeforeAcceptingNewWritesAndKeepsGuard() async throws {
        let recorder = Recorder(), data = result, storage = MemoryStorage()
        let queued = PersistedMutation(id: "old", sql: "UPDATE notes SET title='old'", params: [], spaceId: nil, idempotencyKey: "old-key", expectRowCount: 1)
        let (url, session) = fixture { request in await recorder.record(request); return (200, data) }
        defer { session.invalidateAndCancel() }
        await storage.set(try savedKey(url, "outbox"), String(decoding: try JSON.encode([queued]), as: UTF8.self))
        let store = LocalStore(client: AdoorClient(url: url, accessKey: "fixture", session: session, identity: { LocalIdentity(accountId: "account", workspaceId: "workspace", spaceId: "chosen") }), options: LocalStoreOptions(collections: [:], storage: storage))
        _ = try await store.mutate(Mutation(sql: "UPDATE notes SET title='new'", idempotencyKey: "new-key"))
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        let first = try JSON.decode(JSONValue.self, from: requestBody(requests[0]))
        XCTAssertEqual(first["idempotencyKey"], "old-key"); XCTAssertEqual(first["expectRowCount"], 1)
        try await store.clear()
    }

    func testCorruptOutboxIsPreservedWithoutSending() async throws {
        let recorder = Recorder(), storage = MemoryStorage(), data = result
        let (url, session) = fixture { request in await recorder.record(request); return (200, data) }
        defer { session.invalidateAndCancel() }
        await storage.set(try savedKey(url, "outbox"), "{invalid")
        let store = LocalStore(client: AdoorClient(url: url, accessKey: "fixture", session: session, identity: { LocalIdentity(accountId: "account", workspaceId: "workspace", spaceId: "chosen") }), options: LocalStoreOptions(collections: [:], storage: storage))
        do { _ = try await store.mutate(Mutation(sql: "UPDATE notes SET title=1")); XCTFail("Expected corrupt outbox") } catch let error as AdoorError { XCTAssertEqual(error.code, "OUTBOX_CORRUPT") }
        let count = await recorder.requests.count, outbox = await storage.get(try savedKey(url, "outbox"))
        XCTAssertEqual(count, 0); XCTAssertEqual(outbox, "{invalid")
    }

    func testInitialRevocationBlocksReplayAndClearsCachedRows() async throws {
        let recorder = Recorder(), storage = MemoryStorage()
        let queued = PersistedMutation(id: "old", sql: "UPDATE notes SET title='old'", params: [], spaceId: nil, idempotencyKey: "old-key", expectRowCount: 1)
        let outbox = String(decoding: try JSON.encode([queued]), as: UTF8.self)
        let (url, session) = fixture { request in
            await recorder.record(request)
            if request.url!.path.hasSuffix("changes.head") { return (200, Data(#"{"cursor":"0"}"#.utf8)) }
            return (403, Data(#"{"error":{"code":"FORBIDDEN","message":"Access removed"}}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        await storage.set(try savedKey(url, "outbox"), outbox); await storage.set(try savedKey(url, "rows:notes"), #"[{"id":"private"}]"#)
        let store = LocalStore(client: AdoorClient(url: url, accessKey: "fixture", session: session, identity: { LocalIdentity(accountId: "account", workspaceId: "workspace", spaceId: "chosen") }), options: LocalStoreOptions(collections: ["notes": CollectionSpec(sql: "SELECT id FROM notes")], storage: storage))
        do { try await store.start(); XCTFail("Expected authority failure") } catch let error as AdoorError { XCTAssertEqual(error.code, "FORBIDDEN") }
        let status = await store.status, rows = await store.rows(of: "notes"), requests = await recorder.requests, cache = await storage.get(try savedKey(url, "rows:notes")), retained = await storage.get(try savedKey(url, "outbox"))
        XCTAssertEqual(status, .blocked); XCTAssertTrue(rows.isEmpty); XCTAssertNil(cache); XCTAssertEqual(retained, outbox)
        XCTAssertFalse(requests.contains { $0.url!.path.hasSuffix("data.execute") })
    }

    func testSuppliedStorageRequiresIdentityAndPreservesLegacyDrafts() async throws {
        let recorder = Recorder(), storage = MemoryStorage(), data = result
        let (url, session) = fixture { request in await recorder.record(request); return (200, data) }
        defer { session.invalidateAndCancel() }
        let unbound = LocalStore(client: AdoorClient(url: url, accessKey: "B", session: session), options: LocalStoreOptions(collections: [:], storage: storage))
        do { _ = try await unbound.mutate(Mutation(sql: "UPDATE notes SET title=1")); XCTFail("Expected identity requirement") }
        catch let error as AdoorError { XCTAssertEqual(error.code, "IDENTITY_REQUIRED") }
        let legacy = #"[{"id":"A-draft","sql":"UPDATE notes SET title=1","idempotencyKey":"A-key"}]"#
        await storage.set("adoor:outbox", legacy)
        await storage.set("adoor:rows:notes", #"[{"id":"A-private"}]"#)
        let bound = LocalStore(client: AdoorClient(url: url, accessKey: "B", session: session, identity: { LocalIdentity(accountId: "B", workspaceId: "workspace", spaceId: "chosen") }), options: LocalStoreOptions(collections: ["notes": CollectionSpec(sql: "SELECT id FROM notes")], storage: storage))
        do { try await bound.start(); XCTFail("Expected explicit legacy recovery") }
        catch let error as AdoorError { XCTAssertEqual(error.code, "LEGACY_LOCAL_STATE") }
        try await bound.clear()
        let requests = await recorder.requests, outbox = await storage.get("adoor:outbox"), rows = await bound.rows(of: "notes"), cache = await storage.get("adoor:rows:notes")
        XCTAssertTrue(requests.isEmpty); XCTAssertEqual(outbox, legacy); XCTAssertTrue(rows.isEmpty); XCTAssertNotNil(cache)
    }

    func testStorageIsolatesAccountWorkspaceServerAndSpaceAndResumesSameIdentity() async throws {
        let recorder = Recorder(), firstStorage = TestStorage(), data = result
        let snapshot = Data(#"{"rows":[{"id":"A-private"}],"columns":[],"rowCount":1,"command":"SELECT","schemaVersion":1}"#.utf8)
        let (url, session) = fixture { request in
            await recorder.record(request)
            if request.url!.path.hasSuffix("data.execute") { throw URLError(.notConnectedToInternet) }
            return (200, snapshot)
        }
        defer { session.invalidateAndCancel() }
        let scope = LocalIdentity(accountId: "A", workspaceId: "workspace", spaceId: "chosen")
        let collections = ["notes": CollectionSpec(sql: "SELECT id FROM notes")]
        let first = LocalStore(client: AdoorClient(url: url, accessKey: "A-old", session: session, identity: { scope }), options: LocalStoreOptions(collections: collections, storage: firstStorage))
        try await first.refresh("notes")
        let queued = Task { try? await first.mutate(Mutation(sql: "UPDATE notes SET title=$1", params: ["A-draft"], idempotencyKey: "A-key", expectRowCount: 1)) }
        try await eventually { await recorder.requests.contains { $0.url!.path.hasSuffix("data.execute") } }
        // Simulate a process restart using only state written by the SDK.
        let storage = MemoryStorage()
        for (key, value) in await firstStorage.values { await storage.set(key, value) }
        try await first.clear(); _ = await queued.value
        StubProtocol.register(url.host!) { _ in throw URLError(.notConnectedToInternet) }

        let targets = [
            (url, LocalIdentity(accountId: "B", workspaceId: "workspace", spaceId: "chosen")),
            (url, LocalIdentity(accountId: "A", workspaceId: "other-workspace", spaceId: "chosen")),
            (url, LocalIdentity(accountId: "A", workspaceId: "workspace", spaceId: "other-space")),
            (url.appendingPathComponent("other-server"), scope)
        ]
        for (endpoint, identity) in targets {
            let store = LocalStore(client: AdoorClient(url: endpoint, accessKey: "other", session: session, identity: { identity }), options: LocalStoreOptions(collections: collections, storage: storage))
            let running = Task { try await store.start() }
            try await eventually { await store.status == .offline }
            let rows = await store.rows(of: "notes"), pending = await store.pendingCount
            XCTAssertTrue(rows.isEmpty); XCTAssertEqual(pending, 0)
            running.cancel(); _ = try? await running.value
            try await store.clear()
        }
        let offline = LocalStore(client: AdoorClient(url: url, accessKey: "A-refreshed", session: session, identity: { scope }), options: LocalStoreOptions(collections: collections, storage: storage))
        let running = Task { try await offline.start() }
        try await eventually { await offline.status == .offline }
        let restoredRows = await offline.rows(of: "notes"), restoredPending = await offline.pendingCount
        XCTAssertEqual(restoredRows, [["id": "A-private"]]); XCTAssertEqual(restoredPending, 1)
        running.cancel(); _ = try? await running.value

        let replayRecorder = Recorder()
        StubProtocol.register(url.host!) { request in await replayRecorder.record(request); return (200, data) }
        let reload = LocalStore(client: AdoorClient(url: url, accessKey: "A-refreshed", session: session, identity: { scope }), options: LocalStoreOptions(collections: [:], storage: storage))
        _ = try await reload.mutate(Mutation(sql: "UPDATE notes SET title='next'", idempotencyKey: "next-key"))
        let requests = await replayRecorder.requests
        XCTAssertEqual(requests.count, 2)
        let replay = try JSON.decode(JSONValue.self, from: requestBody(requests[0]))
        XCTAssertEqual(replay["idempotencyKey"], "A-key"); XCTAssertEqual(replay["spaceId"], "chosen"); XCTAssertEqual(replay["expectRowCount"], 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer A-refreshed")
        try await reload.clear()
    }

    func testChangingIdentityWhileResolvingTokenNeverSendsWithNewCredential() async throws {
        let state = AppSession(), gate = Gate(), entered = Gate(), recorder = Recorder(), data = result
        let (url, session) = fixture { request in await recorder.record(request); return (200, data) }
        defer { session.invalidateAndCancel() }
        let client = AdoorClient(url: url, token: .provider { await entered.open(); await gate.wait(); return "B" }, session: session, identity: { state.current() })
        let request = Task { try await client.execute("UPDATE notes SET title=1") }
        await entered.wait(); state.switchAccount(); await gate.open()
        do { _ = try await request.value; XCTFail("Expected changed identity") }
        catch let error as AdoorError { XCTAssertEqual(error.code, "IDENTITY_CHANGED") }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSignOutPreventsLateRowsAndNewWritesFromOldStore() async throws {
        let state = AppSession(), gate = Gate(), entered = Gate(), storage = MemoryStorage()
        let snapshot = Data(#"{"rows":[{"id":"A-private"}],"columns":[],"rowCount":1,"command":"SELECT","schemaVersion":1}"#.utf8)
        let (url, session) = fixture { _ in await entered.open(); await gate.wait(); return (200, snapshot) }
        defer { session.invalidateAndCancel() }
        let client = AdoorClient(url: url, accessKey: "A", session: session, identity: { state.current() })
        let store = LocalStore(client: client, options: LocalStoreOptions(collections: ["notes": CollectionSpec(sql: "SELECT id FROM notes")], storage: storage))
        let read = Task { try await store.refresh("notes") }
        await entered.wait(); state.signOut(); await gate.open()
        do { try await read.value; XCTFail("Expected changed identity") }
        catch let error as AdoorError { XCTAssertEqual(error.code, "IDENTITY_CHANGED") }
        let rows = await store.rows(of: "notes"), status = await store.status
        XCTAssertTrue(rows.isEmpty); XCTAssertEqual(status, .blocked)
        do { _ = try await store.mutate(Mutation(sql: "UPDATE notes SET title=1")); XCTFail("Expected closed store") }
        catch let error as AdoorError { XCTAssertEqual(error.code, "STORE_CLOSED") }
        try await store.clear()
    }

    func testIdentitySwitchWhileSavingReceiptRejectsOldResponse() async throws {
        let state = AppSession(), gate = Gate(), recorder = Recorder(), data = result
        let storage = TestStorage(receiptGate: gate)
        let (url, session) = fixture { request in await recorder.record(request); return (200, data) }
        defer { session.invalidateAndCancel() }
        let store = LocalStore(client: AdoorClient(url: url, accessKey: "A", session: session, identity: { state.current() }), options: LocalStoreOptions(collections: [:], storage: storage))
        let write = Task { try await store.mutate(Mutation(sql: "UPDATE notes SET title=1")) }
        try await eventually { await storage.savingReceipt }
        state.switchAccount(); await gate.open()
        do { _ = try await write.value; XCTFail("Expected changed identity") }
        catch let error as AdoorError { XCTAssertEqual(error.code, "IDENTITY_CHANGED") }
        let requests = await recorder.requests, status = await store.status
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(status, .blocked)
        try await store.clear()
    }

    func testErrorFlagsAndLargeNumberDoNotTrap() {
        XCTAssertTrue(AdoorError(code: "RATE_LIMITED", message: "", status: 429).retryable)
        XCTAssertTrue(AdoorError(code: "HTTP_403", message: "", status: 403).authority)
        XCTAssertNil(JSONValue.number(1e30).intValue)
        XCTAssertNil(JSONValue.number(.infinity).intValue)
    }

    private func requestBody(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }
        return data
    }
}
