# ``MatrixKit``

A pure-Swift Matrix client SDK: authentication, sync, rooms, messaging,
media, profiles, and push — with SwiftUI-ready observable view models.

## Overview

MatrixKit is a from-scratch Swift 6 implementation of the [Matrix
Client-Server API](https://spec.matrix.org/latest/client-server-api/). It has
no dependency on the Matrix Rust SDK; the SDK itself depends only on
`async-http-client`, `swift-crypto`, and `swift-log` (the `mx` CLI
additionally uses `swift-argument-parser`).

Start with ``MatrixClient``. Log in, start sync, and read rooms through
`@Observable` view models:

```swift
let client = try await MatrixClient.login(
    homeserver: URL(string: "https://matrix.org")!,
    user: "@alice:matrix.org",
    password: "secret"
)
try await client.startSync()
let rooms = client.roomList.joined
```

The package ships three library products:

- **MatrixKit** — the SDK itself (transport, models, sync engine, store,
  observable layer).
- **MatrixKitSQLite** — a `SnapshotCache` backend over raw SQLite,
  portable to Linux.
- **MatrixKitSwiftData** — a `SnapshotCache` backend over SwiftData,
  for Apple-only apps that already use SwiftData.

Both cache backends persist `StoreSnapshot`s so the client can show rooms
instantly on launch while background sync converges to live state. Select
one with `mx --cache sqlite|swiftdata|auto` in the CLI, or instantiate
`SQLiteCache` / `SwiftDataCache` directly.

> Note: End-to-end encryption covers Olm to-device messaging —
> device keys plus a 50-key one-time-key pool (`OlmConnector`),
> claim-on-first-send sessions, encrypted secret sharing and SAS
> verification (requester + responder) — plus Megolm room encryption
> (`RoomCrypto`): encrypted room messaging with automatic room-key
> sharing, session rotation, and server-side key backup. See
> <doc:Encryption> for the full crypto surface.

## Topics

### Getting started

- <doc:GettingStarted>
- <doc:Architecture>
- <doc:Encryption>

### Essentials

- ``MatrixClient``
- ``MatrixError``
- ``SnapshotCache``

### API namespaces

- ``AuthClient``
- ``SyncClient``
- ``SlidingSyncClient``
- ``RoomClient``
- ``RoomStateClient``
- ``MessageClient``
- ``MediaClient``
- ``ProfileClient``
- ``PushClient``
- ``ToDeviceClient``
- ``AccountDataClient``
- ``SpacesClient``
- ``SearchClient``
- ``KeyClient``

### Sync and sliding sync

- ``SyncFilter``
- ``SlidingSyncList``
- ``SlidingSyncRoomSubscription``
- ``SlidingSyncExtensions``

### State and observation

- ``StateStore``
- ``RoomActor``
- ``ObservableRoom``
- ``ObservableRoomList``
- ``ObservableTimeline``

### Foundation types

- ``UserId``
- ``RoomId``
- ``EventId``
- ``MXCURI``
- ``MatrixTransport``
- ``MatrixVersion``
- ``Session``
