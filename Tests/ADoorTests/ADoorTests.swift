import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ADoor

/// Unit tests run anywhere. Integration tests run against a local ADoor fixture when ADOOR_TEST_URL and
/// ADOOR_TEST_TOKEN name a server and a connection access key with select/insert/update/delete on a `notes`
/// table (title text, done boolean). They do not provision a database.
final class ADoorTests: XCTestCase {
    func testPKCEChallengeIsSHA256OfVerifier() throws {
        let empty = SHA256.hash(Data())
        XCTAssertEqual(empty.map { String(format: "%02x", $0) }.joined(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let abc = SHA256.hash(Data("abc".utf8))
        XCTAssertEqual(abc.map { String(format: "%02x", $0) }.joined(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let pkce = OAuth.createPKCE()
        XCTAssertEqual(pkce.codeChallenge, OAuth.base64url(SHA256.hash(Data(pkce.codeVerifier.utf8))))
        XCTAssertFalse(pkce.codeChallenge.contains("="))
        let url = try OAuth.authorizationURL(url: URL(string: "https://adoor.example")!, clientId: "client", redirectUri: "myapp://callback", pkce: pkce)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(components.queryItems?.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(components.queryItems?.first { $0.name == "state" }?.value, pkce.state)
    }

    func testAuthorizationRejectsNonNetworkEndpoints() throws {
        for endpoint in ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "JAVASCRIPT:alert(1)", "data:text/html,script", "file:///tmp/page.html", "com.example.app:/oauth", "my-app+oauth://authorize", "http:/missing-host"] {
            let url = try XCTUnwrap(URL(string: endpoint))
            XCTAssertThrowsError(try OAuth.authorizationURL(url: url, clientId: "client", redirectUri: "com.example.app:/callback", pkce: OAuth.createPKCE())) { error in
                XCTAssertEqual((error as? AdoorError)?.code, "INVALID_URL")
            }
        }
        // Foundation may reject these inputs itself; any parsed URL must still be rejected here.
        for endpoint in ["java\nscript:alert(1)", "java\tscript:alert(1)", "java\rscript:alert(1)", "\u{0000}javascript:alert(1)", " javascript:alert(1)"] {
            if let url = URL(string: endpoint) {
                XCTAssertThrowsError(try OAuth.authorizationURL(url: url, clientId: "client", redirectUri: "com.example.app:/callback", pkce: OAuth.createPKCE()))
            }
        }
    }

    func testAuthorizationPreservesPrivateUseCallbacksAndEncodedData() throws {
        let pkce = OAuth.createPKCE()
        for endpoint in ["https://adoor.example", "http://remote.example:8080", "http://127.0.0.1:4345", "HTTPS://adoor.example"] {
            for redirect in ["http://127.0.0.1:49101/callback", "cursor://anysphere.cursor-mcp/oauth/callback", "com.example.app:/oauth2redirect/provider", "com.example.app+oauth:/callback?data=%09%0A%20", "com.example.app-oauth:/callback", "MyApp://callback"] {
                let url = try OAuth.authorizationURL(url: XCTUnwrap(URL(string: endpoint + "/base%20path")), clientId: "client", redirectUri: redirect, pkce: pkce, scope: "mcp offline_access", resource: "https://adoor.example/mcp?label=hello%20world")
                let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(components.percentEncodedPath, "/base%20path/oauth/authorize")
                XCTAssertEqual(items["redirect_uri"], redirect)
                XCTAssertEqual(items["client_id"], "client")
                XCTAssertEqual(items["response_type"], "code")
                XCTAssertEqual(items["state"], pkce.state)
                XCTAssertEqual(items["code_challenge"], pkce.codeChallenge)
                XCTAssertEqual(items["code_challenge_method"], "S256")
                XCTAssertEqual(items["scope"], "mcp offline_access")
                XCTAssertEqual(items["resource"], "https://adoor.example/mcp?label=hello%20world")
            }
        }
    }

    func testSSEFramesParseAcrossFieldsAndBlankLines() {
        var parser = SSEFrameParser()
        XCTAssertNil(parser.feed(line: ": heartbeat"))
        XCTAssertNil(parser.feed(line: "id: 17"))
        XCTAssertNil(parser.feed(line: "event: change"))
        XCTAssertNil(parser.feed(line: "data: {\"cursor\":\"17\","))
        XCTAssertNil(parser.feed(line: "data: \"type\":\"table_changed\"}\r"))
        let frame = parser.feed(line: "")
        XCTAssertEqual(frame, SSEFrameParser.Frame(id: "17", event: "change", data: "{\"cursor\":\"17\",\n\"type\":\"table_changed\"}"))
        XCTAssertNil(parser.feed(line: ""), "Consecutive blank lines emit nothing.")
    }

    func testJSONValueRoundTripsRowsAndLiterals() throws {
        let row: Row = ["id": "a", "qty": 2, "done": false, "note": nil, "tags": ["x", "y"], "meta": ["k": 1.5]]
        let data = try JSON.encode(row)
        let decoded = try JSON.decode(Row.self, from: data)
        XCTAssertEqual(decoded, row)
        XCTAssertEqual(decoded["qty"]?.intValue, 2)
        XCTAssertEqual(decoded["meta"]?["k"]?.doubleValue, 1.5)
        XCTAssertTrue(decoded["note"]?.isNull ?? false)
    }

    func testSqlResultDistinguishesSingleAndBatch() throws {
        let single = Data(#"{"rows":[{"n":1}],"columns":[{"name":"n","type":"23"}],"rowCount":1,"command":"SELECT","schemaVersion":3}"#.utf8)
        let result = try SqlResult(json: try JSON.decode(JSONValue.self, from: single), data: single)
        XCTAssertEqual(result.single?.rows.first?["n"]?.intValue, 1)
        let batch = Data(#"{"batch":true,"atomic":false,"completed":1,"failedAt":1,"results":[{"index":0,"sql":"INSERT 1","kind":"insert","status":"success","rows":[],"columns":[],"rowCount":1,"command":"INSERT","schemaVersion":3,"eventId":"9"},{"index":1,"sql":"INSERT 2","kind":"insert","status":"error","error":{"code":"TABLE_NOT_FOUND","message":"missing","status":404}},{"index":2,"sql":"SELECT","kind":"select","status":"skipped"}]}"#.utf8)
        let parsed = try SqlResult(json: try JSON.decode(JSONValue.self, from: batch), data: batch)
        guard let batchResult = parsed.batch else { return XCTFail("expected a batch") }
        XCTAssertEqual(batchResult.completed, 1)
        XCTAssertEqual(batchResult.failedAt, 1)
        XCTAssertEqual(batchResult.results.count, 3)
        if case .error(_, _, let error, _, _, _, _) = batchResult.results[1] { XCTAssertEqual(error.code, "TABLE_NOT_FOUND") } else { XCTFail("expected an error statement") }
        if case .skipped = batchResult.results[2] {} else { XCTFail("expected a skipped statement") }
    }

    func testErrorEnvelopeAndFlags() {
        let response = HTTPURLResponse(url: URL(string: "https://adoor.example/api/operations/data.execute")!, statusCode: 409, httpVersion: nil, headerFields: nil)!
        let error = AdoorError.from(response: response, data: Data(#"{"error":{"code":"CONFLICT","message":"changed"}}"#.utf8))
        XCTAssertEqual(error.code, "CONFLICT")
        XCTAssertEqual(error.status, 409)
        XCTAssertFalse(error.retryable)
        XCTAssertFalse(error.authority)
        XCTAssertTrue(AdoorError(code: "WORKSPACE_BUSY", message: "", status: 429).retryable)
        XCTAssertTrue(AdoorError(code: "FORBIDDEN", message: "", status: 403).authority)
    }

    func testTablesAreInferredFromSQL() {
        XCTAssertEqual(LocalStore.tables(in: "SELECT p.name FROM people p JOIN companies c ON c.id=p.company_id WHERE p.archived=false"), ["people", "companies"])
        XCTAssertEqual(LocalStore.tables(in: "SELECT 1"), [])
    }

    // MARK: Integration

    private func fixture() throws -> AdoorClient {
        guard let url = ProcessInfo.processInfo.environment["ADOOR_TEST_URL"].flatMap(URL.init(string:)), let token = ProcessInfo.processInfo.environment["ADOOR_TEST_TOKEN"] else {
            throw XCTSkip("Set ADOOR_TEST_URL and ADOOR_TEST_TOKEN to run against a local ADoor fixture.")
        }
        return AdoorClient(url: url, accessKey: token)
    }

    func testIntegrationQueryExecuteAndIdempotentReplay() async throws {
        let client = try fixture()
        let description = try await client.describe()
        XCTAssertTrue(description.tables.contains { $0.name == "notes" })
        let key = UUID().uuidString
        let title = "swift-\(key.prefix(8))"
        let first = try await client.execute("INSERT INTO notes(title,done) VALUES ($1,false) RETURNING id", params: [.string(title)], idempotencyKey: key)
        let again = try await client.execute("INSERT INTO notes(title,done) VALUES ($1,false) RETURNING id", params: [.string(title)], idempotencyKey: key)
        XCTAssertEqual(again.single?.replayed, true)
        XCTAssertEqual(first.single?.rows, again.single?.rows)
        let read = try await client.query("SELECT count(*)::int AS n FROM notes WHERE title=$1", params: [.string(title)])
        XCTAssertEqual(read.single?.rows.first?["n"]?.intValue, 1)
    }

    func testIntegrationConflictIsEnforcedByTheServer() async throws {
        let client = try fixture()
        let title = "swift-conflict-\(UUID().uuidString.prefix(8))"
        _ = try await client.execute("INSERT INTO notes(title,done) VALUES ($1,false)", params: [.string(title)])
        _ = try await client.execute("UPDATE notes SET done=true WHERE title=$1", params: [.string(title)], expectRowCount: 1)
        do {
            _ = try await client.execute("UPDATE notes SET title=$2 WHERE title=$1 AND done=false", params: [.string(title), .string(title + "-stale")], expectRowCount: 1)
            XCTFail("A stale compare-and-set must not commit")
        } catch let error as AdoorError {
            XCTAssertEqual(error.code, "CONFLICT")
            XCTAssertEqual(error.status, 409)
        }
        let read = try await client.query("SELECT done FROM notes WHERE title=$1", params: [.string(title)])
        XCTAssertEqual(read.single?.rows.first?["done"]?.boolValue, true)
    }

    func testIntegrationLocalStoreSnapshotsAppliesOptimisticallyAndFollowsChanges() async throws {
        let client = try fixture()
        let store = LocalStore(client: client, options: LocalStoreOptions(collections: ["notes": CollectionSpec(sql: "SELECT id,title,done FROM notes ORDER BY title")]))
        let running = Task { try await store.start() }
        defer { running.cancel() }
        try await waitUntil("store reaches live") { await store.status == .live }
        let title = "swift-local-\(UUID().uuidString.prefix(8))"
        let result = try await store.mutate(Mutation(sql: "INSERT INTO notes(title,done) VALUES ($1,false) RETURNING id", params: [.string(title)], apply: ["notes": { rows in rows + [["id": "pending", "title": .string(title), "done": false]] }]))
        XCTAssertEqual(result.single?.rowCount, 1)
        try await waitUntil("server row replaces the optimistic one") {
            let rows = await store.rows(of: "notes")
            return rows.contains { $0["title"]?.stringValue == title && $0["id"]?.stringValue != "pending" } && !rows.contains { $0["id"]?.stringValue == "pending" }
        }
        _ = try await client.execute("UPDATE notes SET done=true WHERE title=$1", params: [.string(title)])
        try await waitUntil("external commit is followed") {
            await store.rows(of: "notes").contains { $0["title"]?.stringValue == title && $0["done"]?.boolValue == true }
        }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ check: @escaping @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await check()) {
            if Date() > deadline { XCTFail("Timed out waiting until \(what)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
