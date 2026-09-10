# Architecture

How MatrixKit's layers fit together, and where to look when adding a feature.

## Overview

MatrixKit is organized in strict layers. Each layer only depends on the
ones below it:

```
┌─────────────────────────────────────────────┐
│ Observable   MatrixClient, ObservableRoom…  │  SwiftUI view models
├─────────────────────────────────────────────┤
│ Namespaces   Auth/Sync/Room/Message/Media…  │  One actor per API area
├─────────────────────────────────────────────┤
│ Store        StateStore, RoomActor           │  Client-side state machine
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
auth, Matrix error-body mapping (`M_UNKNOWN_TOKEN` → `unknownToken`,
429 → `rateLimited`), and redacted debug logging. `SyncConnection` owns the
long-poll loop with backoff and yields raw `SyncResponse`s as an
`AsyncStream`.

Encoding rule: path segments are percent-encoded **exactly once** by
`pathSegmentEncoded` at the call site; `buildURL` concatenates verbatim
and never re-encodes.

## Store and sync

`SyncClient` parses each response into a `SyncDelta` (`SyncResponseParser`)
and applies it to the `StateStore`, which routes per-room changes to
`RoomActor` instances. `RoomActor` owns the timeline window (capped at 500
events), member list, and metadata, and notifies observers via
`AsyncStream<RoomUpdate>`.

`StateStore.snapshot()` / `restore(_:)` convert the whole store to and
from a `StoreSnapshot` — the interchange format for ``SnapshotCache``
backends (`MatrixKitSQLite`, `MatrixKitSwiftData`).

## Observable layer

`@Observable @MainActor` classes (`ObservableRoom`, `ObservableTimeline`,
`ObservableRoomList`, …) subscribe to the actor layer and expose bindable
state for SwiftUI. `MatrixClient` is the facade: it owns every namespace
actor plus the store and session, and caches `ObservableRoom` instances
per room ID.

## Concurrency model

Strict Swift 6: actors own all mutable state, value types cross isolation
boundaries, everything is `Sendable`. The CLI REPL stays off `@MainActor`
so blocking `readLine` never starves the sync loop.
