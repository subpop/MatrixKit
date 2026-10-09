# Architecture

How MatrixKit's layers fit together, and where to look when adding a feature.

## Overview

MatrixKit is organized in strict layers. Each layer only depends on the
ones below it:

```
┌─────────────────────────────────────────────┐
│ Observable   MatrixClient + view models      │  SwiftUI state
├─────────────────────────────────────────────┤
│ Namespaces   Auth/Sync/Room/Message/Media…  │  One actor per API area
├─────────────────────────────────────────────┤
│ Store        MatrixStoreWriter/Reader        │  Normalized SwiftData rows
├─────────────────────────────────────────────┤
│ Models       Sync, Room, Message, Auth…      │  Codable DTOs
├─────────────────────────────────────────────┤
│ Types        UserId, RoomId, MatrixError…    │  Strong IDs + errors
├─────────────────────────────────────────────┤
│ Transport    MatrixTransport, SyncConnection │  HTTP + long-poll loop
└─────────────────────────────────────────────┘
```

## Transport

``MatrixTransport`` wraps `AsyncHTTPClient`: JSON encode/decode, Bearer
auth, Matrix error-body mapping (`M_UNKNOWN_TOKEN` → `unknownToken`
with the response's `soft_logout` hint, OIDC `invalid_grant` on refresh
→ `unknownToken` with no hint, 429 → `rateLimited`), and redacted debug
logging. `SyncConnection` owns the
long-poll loop with backoff and yields raw `SyncResponse`s as an
`AsyncStream`.

Encoding rule: path segments are percent-encoded **exactly once** by
`pathSegmentEncoded` at the call site; `buildURL` concatenates verbatim
and never re-encodes.

## Store and sync

`SyncClient` parses each response into a `SyncDelta` (`SyncResponseParser`)
and fans it out to its sinks (`SyncDeltaSink`) — typically the
`MatrixStoreWriter`, which folds every delta into normalized `@Model`
rows (one per room, event, member, and space edge, keeping full event
history). `MatrixStoreReader` (or `@Query` in SwiftUI) reads them back;
`FocusedTimeline` / `ThreadTimeline` page explicit windows (permalinks,
threads) through any `TimelinePaging` backend. Schema changes wipe and
rebuild the store; live sync restores it.

## Observable layer

`@Observable @MainActor` view models (`ObservableTimelineEvent`,
`ObservableUserProfile`, `ObservablePushRules`, …) resolve display-ready
state from stored rows for SwiftUI. `MatrixClient` is the facade: it owns
every namespace actor plus the session, and wires stores in
(`addDeltaSink`, `setMarkerHealer`, `setCiphertextStore`,
`setRoomStateProvider`).

## Concurrency model

Strict Swift 6: actors own all mutable state, value types cross isolation
boundaries, everything is `Sendable`. The CLI REPL stays off `@MainActor`
so blocking `readLine` never starves the sync loop.
