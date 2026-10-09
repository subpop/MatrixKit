# ``MatrixKit``

A pure-Swift Matrix client SDK: authentication, sync, rooms, messaging,
media, profiles, and push — with SwiftUI-ready observable view models.

## Overview

MatrixKit is a from-scratch Swift 6 implementation of the [Matrix
Client-Server API](https://spec.matrix.org/latest/client-server-api/). It has
no dependency on the Matrix Rust SDK; the SDK itself depends only on
`async-http-client` and `swift-crypto` (the `mx` CLI
additionally uses `swift-argument-parser`). Logging goes to unified
logging (`os.Logger`, subsystem `app.subpop.MatrixKit`).

Start with ``MatrixClient``. Log in, attach the persistent store, start
sync, and read rooms through `@Query` (or the fetch-based reader):

```swift
import MatrixKitSwiftData

let client = try await MatrixClient.login(
    homeserver: URL(string: "https://matrix.org")!,
    user: "@alice:matrix.org",
    password: "secret"
)
guard let userId = client.userId else {
    fatalError("Login must set userId")
}
let container = try MatrixStore.makeContainer(
    at: MatrixStore.databaseURL(for: userId, in: directory))
let writer = MatrixStoreWriter(modelContainer: container)
await client.addDeltaSink(writer)
try await client.startSync()

@Query(SDRoom.joinedDescriptor()) var rooms: [SDRoom]
```

The package ships three library products:

- **MatrixKit** — the SDK itself (transport, models, sync engine,
  namespace clients, observable view models).
- **MatrixKitSwiftData** — the normalized persistent store over
  SwiftData, for Apple-only apps: the `SDRoom`/`SDRoomEvent`/
  `SDRoomMember` schema plus the sync-fold writer and fetch reader.
- **MatrixRTC** — encrypted MatrixRTC voice/video calls.

The persistent store keeps full event history on disk so the client can
show rooms instantly on launch while background sync converges to live
state; the stored cursor makes the first sync incremental.

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

- ``SyncDeltaSink``
- ``RoomStateProvider``
- ``MarkerHealingStore``
- ``CiphertextStore``
- ``ObservableTimelineEvent``
- ``FocusedTimeline``
- ``ThreadTimeline``

### Foundation types

- ``UserId``
- ``RoomId``
- ``EventId``
- ``MXCURI``
- ``MatrixTransport``
- ``MatrixVersion``
- ``Session``
