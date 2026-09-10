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
| SQLite cache | system `sqlite3` (`brew install sqlite` / `libsqlite3-dev`) |

## Installation

Add the package and depend on the products you need:

```swift
.package(url: "<repo-url>", from: "0.1.0"),
```

| Product | Contents | When to use it |
|---|---|---|
| `MatrixKit` | Core SDK: transport, auth, sync engine, rooms, messages, media, profile, push, store, `@Observable` layer | Always |
| `MatrixKitSQLite` | `SQLiteCache`: Linux-portable snapshot cache over the system `sqlite3` | Caching on any platform, including Linux |
| `MatrixKitSwiftData` | `SwiftDataCache`: snapshot cache backed by SwiftData | Apple-only apps that already use SwiftData |

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

// 2. Initial sync, then live sync (room list refreshes per delta).
try await client.syncOnce()
try await client.startSync()

// 3. Rooms.
for room in client.roomList.joined {
    print(room.name, room.unreadCount)
}

// 4. Open a room and send.
let room = await client.room(RoomId(unchecked: "!abc:matrix.org"))
try await room.send(text: "Hello, Matrix!")
try await room.react(to: eventId, key: "👍")
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
`store` with v3 sync but keeps its own `pos` cursor, so the two loops can
run side by side without thrashing the v2 sync token:

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

`@Observable`, MainActor-bound view models backed by the actor store:

- `MatrixClient.roomList` (`ObservableRoomList`) — `joined` / `invited`,
  `totalUnread`, `totalHighlights`, `refresh()`
- `client.room(_:)` → `ObservableRoom` — metadata, `members`, `timeline`,
  typing, and actions (`send(text:)`, `reply(to:text:)`, `edit`,
  `redact`, `react`, `invite`, `leave`, `loadMembers`, `markRead`,
  `setTyping`, `setName`, `setTopic`)
- `ObservableTimeline` / `ObservableTimelineEvent` — rendered timeline
  with `loadMore()` pagination
- `ObservableUserProfile`, `ObservablePushRules` — profiles and push rules

Rooms subscribe to `RoomActor.updates()` (`AsyncStream<RoomUpdate>`) so
views converge as sync deltas land.

## Snapshot caching

`SnapshotCache` (`Store/SnapshotCache.swift`) is the persistence boundary:
`save(_ snapshot:)`, `load() -> StoreSnapshot?`, `clear()`. The store
serializes to `StoreSnapshot` and restores from it, so any backend plugs
in — including your own.

- `SQLiteCache` (`MatrixKitSQLite`) — raw `sqlite3`, WAL mode, atomic
  whole-snapshot replace. More portable.
- `SwiftDataCache` (`MatrixKitSwiftData`) — `@Model` rows, same replace
  semantics. Apple platforms only.

Cache files live per user under the caches directory:

```
~/Library/Caches/MatrixKit/<sanitized-user-id>/{store.sqlite,store.swiftdata}
```

Migrations are clean-reset, not incremental: `SnapshotVersion.current`
is checked on load and a mismatch wipes the file. That's safe because the
snapshot is a transient cache — live sync rebuilds it.

## Debugging

Redacted request/response logging (secrets are masked as `<redacted>`):

```swift
// Per client:
try await MatrixClient.login(..., logLevel: .debug)

// Or for everything, via environment:
MATRIXKIT_DEBUG=1        // → .debug
MATRIXKIT_LOG_LEVEL=trace
```

The `mx` CLI takes flags instead (`--log-level trace|debug|…`);
`debug on` toggles it at runtime.

Decode failures include the JSON path and a body snippet
(`missing key 'device_id' at $.device_id | body: …`), so most wire-shape
issues are self-diagnosing.

## CLI playground

`mx` is an interactive REPL over the SDK — useful for manual
testing against a real server:

```
swift run mx --cache sqlite --log-level debug
login https://matrix.org @alex:matrix.org secret
rooms → open 0 → send hello → back → quit
```

Flags: `--cache sqlite|swiftdata|auto` selects the snapshot backend
(auto prefers SwiftData where available); `--log-file <path>` captures
logs to a file; `debug on` toggles HTTP logging at runtime. The prompt
shows a timestamp, and ↑/↓ recalls command history.

## Architecture

```text
Transport (MatrixTransport, SyncConnection — SwiftNIO via AsyncHTTPClient)
Models    (Codable DTOs: Auth, Sync, Room, Message, Common)
Types     (UserId/RoomId/…, enums, MatrixError)
Clients   (Auth, Sync, Room, RoomState, Message, Media, Profile, Push actors)
Store     (StateStore + per-room RoomActor state machines, SnapshotCache)
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
