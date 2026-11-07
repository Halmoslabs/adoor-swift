# Changelog

## 0.1.2

Fixes the release script so the first public release actually publishes. The package is unchanged from the unpublished 0.1.1.

## 0.1.1

First published release. The package is unchanged from the unpublished 0.1.0.

## 0.1.0

First release of the ADoor Swift package.

- The same operation names as the TypeScript client: `query`, `execute`, `expectRowCount`, `exchangeCode`, `refreshTokens`, `LocalStore`, `mutate`, and `start`.
- PKCE (`createPKCE`, `authorizationURL`) and a token provider that waits for the new refresh token to be saved.
- Swift Package Manager builds for the platforms declared in `Package.swift`. Unit tests run with `swift test`.

- Supplied local storage requires an explicit client account/workspace/selected-space identity; caches and outboxes are scoped to it and the server. Legacy unbound writes require explicit recovery.
