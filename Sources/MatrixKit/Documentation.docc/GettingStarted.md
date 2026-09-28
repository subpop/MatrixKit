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

Run an initial sync, then start the background loop. Room lists refresh on
every delta automatically:

```swift
try await client.syncOnce(filter: .leanInitial)
try await client.startSync(filter: .leanInitial)
```

``SyncFilter/leanInitial`` caps timelines at 50 events and lazy-loads
membership — required on large homeservers, where an unfiltered initial
sync can exceed tens of megabytes.

Stop with `await client.stopSync()`, log out with `try await client.logout()`.

## Rooms and timelines

```swift
// Cached per ID — same instance on repeat calls.
let room = await client.room(RoomId(unchecked: "!abc:matrix.org"))

room.name          // Observable metadata
room.timeline      // ObservableTimeline of ObservableTimelineEvent

try await room.send(text: "Hello, Matrix!")
try await room.reply(to: eventId, text: "…")
try await room.react(to: eventId, key: "👍")
```

Join and create through the facade:

```swift
try await client.joinRoom(RoomId(unchecked: "!abc:matrix.org"))
let created = try await client.createRoom(CreateRoomRequest(name: "New room"))
```

## Instant launch with a snapshot cache

Persist the store so the next launch renders rooms before sync completes:

```swift
import MatrixKitSQLite

let cache = try SQLiteCache(database: url)
await client.store.restore(await cache.load() ?? StoreSnapshot())
// … sync …
try await cache.save(await client.store.snapshot())
```

`SQLiteCache` (portable) and `SwiftDataCache` (Apple-only) both implement
``SnapshotCache`` and are interchangeable.
