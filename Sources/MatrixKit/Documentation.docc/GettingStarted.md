# Getting Started

Log in, sync, list rooms, and send a message — the five calls that cover
most of MatrixKit.

## Overview

All high-level usage flows through ``MatrixClient``, a `@MainActor`
`@Observable` facade. The actor layer underneath (`AuthClient`,
`SyncClient`, `RoomClient`, …) is available for advanced use.

## Log in

```swift
import MatrixKit

let client = try await MatrixClient.login(
    homeserver: URL(string: "https://matrix.org")!,
    user: "@alice:matrix.org",
    password: "secret",
    deviceDisplayName: "MyApp"
)
```

`login` performs password authentication, then reconciles the session with
`whoAmI` so `client.userId` holds the fully-qualified MXID. To resume a
stored session instead, use ``MatrixClient``'s `restore(homeserver:userId:deviceId:accessToken:refreshToken:oidcClientId:oidcTokenEndpoint:keystore:)`.

All SDK traffic logs to unified logging (subsystem `app.subpop.MatrixKit`):
watch it live with `log stream --predicate 'subsystem == "app.subpop.MatrixKit"' --level debug`
in a second terminal, or browse it after the fact in Console.app.

## Sync

Run an initial sync, then start the background loop. Deltas stream to
subscribers (`deltas()`) and attached stores on every round:

```swift
try await client.syncOnce(filter: .leanInitial)
try await client.startSync(filter: .leanInitial)
```

``SyncFilter/leanInitial`` caps timelines at 50 events and lazy-loads
membership — required on large homeservers, where an unfiltered initial
sync can exceed tens of megabytes.

Stop with `await client.stopSync()`, log out with `try await client.logout()`.

## Rooms and timelines

Read rooms from the normalized store (`@Query`, or
`MatrixStoreReader` outside SwiftUI), and act through the namespace
clients:

```swift
let roomId = RoomId(unchecked: "!abc:matrix.org")
let (joined, _) = try reader.roomEntries()
let window = try reader.timeline(roomId, limit: 50)

try await client.messages.sendText(roomId, "Hello, Matrix!")
try await client.messages.react(roomId, to: eventId, key: "👍")
```

Join and create through the facade:

```swift
try await client.joinRoom(RoomId(unchecked: "!abc:matrix.org"))
let created = try await client.createRoom(CreateRoomRequest(name: "New room"))
```

## Instant launch with the normalized store

Persist sync output incrementally so the next launch renders rooms
before sync completes, with the stored cursor turning the first sync
incremental:

```swift
import MatrixKitSwiftData

let container = try MatrixStore.makeContainer(
    at: MatrixStore.databaseURL(for: userId, in: directory))
let writer = MatrixStoreWriter(modelContainer: container)
try await writer.setLocalUser(userId) // receipts + own-message detection
await client.addDeltaSink(writer)      // every sync delta persists
client.setMarkerHealer(writer)         // read-marker healing covers it too
client.setCiphertextStore(writer)       // late-key decryption refresh
await client.setRoomStateProvider(      // space/search enrichment
    NormalizedRoomStateProvider(modelContainer: container, writer: writer))
// … sync …
let reader = MatrixStoreReader(modelContainer: container)
let (joined, _) = try reader.roomEntries()
```

SwiftUI views can `@Query` the `@Model` schema directly instead of
going through the reader (see `SDRoom.joinedDescriptor()`). Schema
changes wipe and rebuild: the store is a cache, live sync restores it.
