# ADoor for Swift

Issues are welcome on [Halmoslabs/adoor-swift](https://github.com/Halmoslabs/adoor-swift/issues). The code is developed in a private repository and mirrored here on each release. It is [MIT licensed](LICENSE). Copyright Halmos Labs.

The package a native app uses for optional shared storage. It speaks the same protocol as the TypeScript client ([Halmoslabs/adoor-js](https://github.com/Halmoslabs/adoor-js)), with the same names: `query`, `execute`, `expectRowCount`, `exchangeCode`, `refreshTokens`, `TokenProvider`, `LocalStore`, `mutate`, and `start`. `createPKCE` and `authorizationURL` are the Swift spellings of `createPkce` and `authorizationUrl`. Token JSON stays snake_case on the wire; Swift properties are camelCase (`selectedSpaceId`).

```swift
.package(url: "https://github.com/Halmoslabs/adoor-swift.git", from: "0.1.1")
```

The first tag is `0.1.1`. Swift Package Manager uses that bare version, without a `v` prefix. Until the tag exists, a checkout of the private monorepo can still build these sources from `swift/` or from the repository-root package.

## Quickstart

Sign in, let the person pick or create a space, then read, write, and follow changes.

`authorizationURL` requires an HTTP or HTTPS service endpoint with a host. Its `url` is already a Foundation `URL`: reject raw whitespace/control characters before constructing it from untrusted text, since Foundation may already have percent-encoded them. Encoded path/query data remains allowed. `redirectUri` stays exact and can contain a registered private-use app scheme; the server still enforces its callback registration policy.

```swift
import ADoor

let pkce = OAuth.createPKCE()
let redirect = "http://127.0.0.1:49101/callback"
let signIn = try OAuth.authorizationURL(
    url: adoorURL, clientId: clientId, redirectUri: redirect, pkce: pkce,
    authorizationDetails: SpaceAuthorizationDetails(
        suggestedName: "My app",
        permissions: [["table": "*", "actions": ["select", "insert", "update", "delete"]]]))
// The app opens `signIn`, owns the loopback callback, and checks `state` once.
let tokens = try await OAuth.exchangeCode(
    url: adoorURL, clientId: clientId, code: code, redirectUri: redirect, codeVerifier: pkce.codeVerifier)
let spaceId = tokens.selectedSpaceId! // the space they picked or created

let provider = TokenProvider(url: adoorURL, clientId: clientId, tokens: tokens) { try await keychain.save($0) }
// currentSessionIdentity() reads the app's current authenticated session,
// saved with these credentials: LocalIdentity(accountId: ..., workspaceId: ..., spaceId: spaceId).
let adoor = AdoorClient(url: adoorURL, token: provider.source,
    identity: { currentSessionIdentity() })
let store = LocalStore(client: adoor, options: LocalStoreOptions(
    collections: ["snippets": CollectionSpec(
        sql: "SELECT id, shortcut, body FROM snippets ORDER BY shortcut", spaceId: spaceId)],
    storage: try FileStorage(directory: appSupport)))
Task { try await store.start() }
for await rows in await store.observe("snippets") { render(rows) }

try await store.mutate(Mutation(
    sql: "UPDATE snippets SET body=$2 WHERE id=$1 AND body=$3",
    params: [id, next, current], spaceId: spaceId, expectRowCount: 1))
```

`SpaceAuthorizationDetails` defaults to letting the person create a space or use an existing one. Omit it to ask only for read access to an existing space. Persist `selectedSpaceId` with the workspace, and pass `spaceId` on later reads and writes. Refresh can return several spaces and does not repeat the selection.

`TokenProvider` rotates the refresh token and waits until `onTokens` has saved the new pair. Put that save in the Keychain. One process owns the token.

`expectRowCount` is one INSERT, UPDATE, or DELETE. Put the values you read in the WHERE clause. A different count rolls the statement back inside its transaction and returns `CONFLICT` (409); nothing is kept, so the same idempotency key can carry the corrected statement. `mutate` shows an optimistic edit, queues it, and refetches when the server rejects it. `start` loads the collections, then follows table changes. `clear()` signs this store out.

Supplying any `storage` requires the client's `identity` provider with nonempty account, workspace and explicitly selected space IDs. The app obtains these IDs from authenticated session/context data at connection time and persists them alongside credentials for offline restarts. For a connection without an account, use its stable connection ID as `accountId` so separate connections stay isolated. The SDK adds the configured server URL and identity to storage keys, even when `namespace` is reused. Collection caches also include explicit space overrides. Omitted spaces use the bound selected space, and queued writes retain that exact target. Custom storage adapters must preserve the supplied keys. Omit `storage` for a fresh memory-only store without an identity requirement.

The identity provider must read the same current app session as the credentials; update it before returning a different account/workspace/space's token, including after an asynchronous refresh. This is an app-supplied identity boundary, not a token parser or cached server authorization. The client checks it around credential resolution and responses; the store checks before hydration, row publication and replay. No identity network requests are added. Return `nil` on sign-out. Token rotation under the same IDs preserves continuity; never use the token itself as an ID. On server/account/workspace/space changes, detach the old UI, cancel its start task, update the app session and create a new client/store. Use `clear()` only for deliberate sign-out/discard after preserving drafts; identity scopes keep retained requests separate. An old store returns no rows and refuses work after its identity changes. `clear()` remains terminal and prevents late responses from restoring data; a write already committed on the server cannot be recalled. Preserve drafts separately before offering discard.

Identity-bound storage uses new keys. Legacy `<namespace>:rows:*` caches remain untouched and are never loaded. A nonempty legacy `<namespace>:outbox` stops hydration/replay with `LEGACY_LOCAL_STATE`, including before accepting a new mutation. Export it through the adapter and verify its original server/account/workspace/space before offering recovery or explicit discard and removing the old key. Neither automatic migration nor `clear()` assigns or discards this ambiguously owned queue. An empty legacy `[]` outbox does not block a new store. Corrupt bound outboxes still stop replay and remain available for recovery.

Rows are `[String: JSONValue]`. Errors are `AdoorError` with `code`, `status`, `retryable`, and `authority`.

## Tests

`swift test` runs in the public repository's CI. The private repository does not spend macOS runner minutes on it. From a checkout of this package:

```sh
swift test
```

Unit tests run on Linux and on Apple platforms. The HTTP tests skip unless `ADOOR_TEST_URL` and `ADOOR_TEST_TOKEN` name an isolated local server with a `notes` table. They do not provision a database. Keychain, the browser callback, and builds for iOS, tvOS, watchOS, and visionOS are the app's to run; this package does not cover them.
