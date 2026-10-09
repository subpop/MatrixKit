# MatrixKit

A pure-Swift Matrix client SDK. Strict Swift 6 concurrency throughout (actors +
`async`/`await` + `AsyncStream`), with an `@Observable` layer for SwiftUI on
top.

Targets [spec.matrix.org](https://spec.matrix.org/latest/) Client-Server API (v3
sync, sliding sync, rooms, messaging, media, profile, pushers). End-to-end
encryption covers to-device Olm messaging, verification, cross-signing, and
Megolm room encryption (see [Scope](#scope)).

## Requirements

| | |
|---|---|
| Swift | 6.3+ (language mode `.v6`) |
| Platforms | macOS 26+, iOS 26+ |

## Installation

Add the package and depend on the products you need:

```swift
.package(url: "<repo-url>", from: "0.1.0"),
```

| Product | Contents | When to use it |
|---|---|---|
| `MatrixKit` | Core SDK: transport, auth, sync engine, rooms, messages, media, profile, push, `@Observable` layer | Always |
| `MatrixKitSwiftData` | Normalized persistent store: `SDRoom`/`SDRoomEvent`/`SDRoomMember` `@Model` schema, `MatrixStoreWriter` (sync fold), `MatrixStoreReader` (fetch reads) | Persisting rooms and timelines on Apple platforms |

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "MatrixKit", package: "MatrixKit"),
    .product(name: "MatrixKitSwiftData", package: "MatrixKit"),
]),
```

## Quick start

`MatrixClient` is `@MainActor` — call it from UI code or `MainActor` tasks.

```swift
import MatrixKit

// 1. Log in (password or SSO-token login; session reconciled via whoami).
// The homeserver URL is resolved through `.well-known/matrix/client`
// discovery first (silent fallback to the declared URL), so delegating
// server names just work.
let client = try await MatrixClient.login(
    homeserver: URL(string: "https://matrix.org")!,
    user: "@alex:matrix.org",
    password: storedPassword,
    deviceDisplayName: "MyApp"
)

// 2. Attach the normalized store, then initial sync + live sync
// (deltas stream to subscribers/sinks).
import MatrixKitSwiftData
guard let userId = client.userId else {
    fatalError("Login must set userId")
}
let container = try MatrixStore.makeContainer(
    at: MatrixStore.databaseURL(for: userId, in: directory))
let writer = MatrixStoreWriter(modelContainer: container)
try await writer.setLocalUser(userId) // receipts + own-message detection
await client.addDeltaSink(writer)      // every sync delta persists
client.setMarkerHealer(writer)         // read-marker healing covers it too
client.setCiphertextStore(writer)       // late-key decryption refresh
await client.setRoomStateProvider(      // space/search enrichment
    NormalizedRoomStateProvider(modelContainer: container, writer: writer))
try await client.syncOnce()
try await client.startSync()

// 3. Rooms (see below for the reader).
let reader = MatrixStoreReader(modelContainer: container)
let (joined, _) = try reader.roomEntries()
for room in joined {
    print(room.displayName, room.unread)
}

// 4. Open a room and send.
let roomId = RoomId(unchecked: "!abc:matrix.org")
let window = try reader.timeline(roomId, limit: 50)
try await client.messages.sendText(roomId, "Hello, Matrix!")
try await client.messages.react(roomId, to: eventId, key: "👍")
```

Restore a session from stored tokens (e.g. Keychain) instead of logging in:

```swift
let client = await MatrixClient.restore(
    homeserver: homeserver,
    userId: userId,
    deviceId: deviceId,
    accessToken: accessToken,
    refreshToken: refreshToken
)
```

### OIDC login (MSC3861)

MAS-based servers (including matrix.org) authenticate via OIDC. Two flows:

```swift
// Headless / CLI: prints a code + URL, polls until authorized.
let client = try await MatrixClient.loginViaOIDC(
    homeserver: URL(string: "https://matrix.org")!,
    onUserCode: { code, url, expiresInSeconds in
        print("Open \(url), enter \(code)")
    }
)

// Native apps: open the URL in a browser, complete with the redirect.
let pending = try await MatrixClient.prepareOIDCBrowserLogin(
    homeserver: homeserver, redirectURI: "myapp://oidc-callback")
openInBrowser(pending.authorizationURL)
let client = try await MatrixClient.completeOIDCBrowserLogin(
    pending, code: callbackCode, state: callbackState)
```

OIDC sessions refresh via their token endpoint (`client.auth.refresh()`
routes automatically) and revoke on `logout()`. `OIDCAccountStore`
persists one CLI session to disk for zero-interaction restore; apps
should use the Keychain + `restore()` + `session.updateOIDC(...)`.

### Going lower level

The facade delegates to per-domain actors you can use directly
(`client.auth`, `client.sync`, `client.rooms`, `client.roomState`,
`client.messages`, `client.media`, `client.profile`, `client.push`).
IDs are strong types (`UserId`, `RoomId`, `EventId`, …) and every failure
surfaces as a `MatrixError` (retryable errors expose `isRetryable` /
`retryAfter`).

### Large homeservers

Unfiltered initial sync on matrix.org-scale servers ships tens of MiB of
room state. Use the lean preset:

```swift
try await client.syncOnce(filter: .leanInitial)  // timeline:50, lazy members
try await client.startSync(filter: .leanInitial)
```

### Sliding sync

For large accounts, the opt-in sliding sync engine (MSC4186 simplified
sliding sync) fetches a window of rooms instead of full state. It shares
the delta sinks with v3 sync but keeps its own `pos` cursor, so the two
loops can run side by side without thrashing the v2 sync token:

```swift
try await client.slidingSyncOnce()  // one round-trip, default 20-room window
try await client.startSlidingSync() // ... or the long-poll loop
await client.stopSlidingSync()
```

Customize the window via `lists`/`room_subscriptions`, or drive
`client.slidingSync` directly (`subscribe`/`unsubscribe` take effect on
the next request). E2EE extensions (to-device, device lists) ride along
whenever crypto hooks are installed, so the sliding path decrypts
timelines and processes device updates the same way the v3 loop does
(`SlidingSyncClient` + shared `SyncCryptoHooks`).

## SwiftUI layer

`@Observable`, MainActor-bound view models resolved from stored rows:

- `ObservableTimelineEvent` — rendered timeline event (classification,
  reactions, edits, replies, mentions); build lists with
  `ObservableTimelineEvent.render(_:members:localUser:highlightKeywords:sendStates:)`
  over `@Query` rows
- `ObservableUserProfile`, `ObservablePushRules` — profiles and push rules
- `FocusedTimeline` / `ThreadTimeline` — explicit event windows
  (permalinks, threads) with bidirectional pagination

Live sync deltas stream through `client.deltas()`; views converge as
sinks persist them and `@Query` refreshes.

## Normalized persistence

Sync deltas persist incrementally into a normalized SwiftData store
(`MatrixKitSwiftData`) — one row per room, event, member, and space
edge — so the next launch renders rooms from disk before sync
completes, with the stored cursor turning the first sync incremental:

```swift
import MatrixKitSwiftData

// Per-user file (or pass your own directory for app-group isolation).
let container = try MatrixStore.makeContainer(
    at: MatrixStore.databaseURL(for: userId, in: directory))
let writer = MatrixStoreWriter(modelContainer: container)
try await writer.setLocalUser(userId)
await client.addDeltaSink(writer)   // every sync delta persists
client.setMarkerHealer(writer)      // read-marker healing covers it too
client.setCiphertextStore(writer)    // late-key decryption refresh
await client.setRoomStateProvider(   // space/search enrichment
    NormalizedRoomStateProvider(modelContainer: container, writer: writer))

let reader = MatrixStoreReader(modelContainer: container)
let (joined, invited) = try reader.roomEntries()
let window = try reader.timeline(roomId, limit: 50)
```

The writer precomputes badge-driving state onto each room row
(effective unread, first-unread event, read-marker timestamp), folds
redactions into their targets, and tracks staged local echoes until
sync confirms them — so reads stay simple fetches. Full event history
is kept; no window trimming.

SwiftUI views can also `@Query` the `@Model` types directly
(`SDRoom.joinedDescriptor()`, `SDRoomEvent.timelineDescriptor(roomId:)`)
and render with `ObservableTimelineEvent.render(...)`.

The store file lives per user, per instance, under the caches directory:

```
~/Library/Caches/MatrixKit/[Debug/]<instance>/<sanitized-user-id>/matrix-store.swiftdata
```

`Debug/` appears in debug builds so dev runs never touch release data;
non-alphanumerics in instance names and user IDs become `_`
(`@alice:matrix.org` → `_alice_matrix_org`). Schema changes are
clean-reset, never migrated: a version mismatch wipes the file, and
live sync rebuilds it.

## Debugging

Redacted request/response logging (secrets are masked as `<redacted>`):

```swift
// Per client:
try await MatrixClient.login(..., logLevel: .debug)

// Or for everything, via environment:
MATRIXKIT_DEBUG=1        // → .debug
MATRIXKIT_LOG_LEVEL=trace
```

Decode failures include the JSON path and a body snippet
(`missing key 'device_id' at $.device_id | body: …`), so most wire-shape
issues are self-diagnosing.

## CLI playground

`mx` is an interactive REPL over the SDK — useful for manual
testing against a real server:

```
swift run mx --instance demo
login https://matrix.org @alex:matrix.org secret
rooms → open 0 → send hello → back → quit
```

`--instance <name>` persists the session (account, device identity,
Olm sessions, and the normalized room store) under one directory so
relaunches resume where you left off; without it, each run uses a
fresh ephemeral instance that is deleted on exit. Relaunching with the
same instance renders the room list instantly from
`matrix-store.swiftdata` and prints `Resumed from stored sync cursor.`
Room persistence needs SwiftData (Apple platforms); elsewhere `mx`
syncs memory-only. The prompt shows a timestamp, and ↑/↓ recalls
command history.

## Architecture

```text
Transport (MatrixTransport, SyncConnection — SwiftNIO via AsyncHTTPClient)
Models    (Codable DTOs: Auth, Sync, Room, Message, Common)
Types     (UserId/RoomId/…, enums, MatrixError)
Clients   (Auth, Sync, Room, RoomState, Message, Media, Profile, Push actors)
Store     (MatrixKitSwiftData: normalized @Model rows, writer fold, reader/@Query reads)
Observable(MatrixClient facade + @Observable view models)
```

Full API docs: DocC catalog in
`Sources/MatrixKit/Documentation.docc/` (Getting Started, Architecture),
published via Swift Package Index (`.spi.yml`).

## Development

```bash
swift build          # zero-warning build
swift test           # full suite across MatrixKitTests + MatrixKitCryptoTests
make -C Tools/OlmInteropHarness  # live vodozemac interop (else loud-skipped)
```

Contributions welcome. Please follow the existing code patterns such as strict
concurrency (`Sendable`, actors). Match the existing `///` doc coverage on new
public API.
