import Foundation
import Logging
import MatrixKitCrypto
import Observation

/// Top-level Matrix client: SwiftUI-ready facade over the actor layer.
///
/// Holds every API-namespace client plus the store and session. Long-lived
/// `@Observable` state (`isAuthenticated`, `syncStatus`, rooms) drives views;
/// all network and state mutation happens in the underlying actors.
@Observable @MainActor
public final class MatrixClient {
    /// The homeserver this client talks to (e.g. `https://matrix.org`).
    public let homeserver: URL
    /// True after a successful `login`/`restore`, false after `logout`.
    /// Drives logged-in vs. logged-out UI.
    public private(set) var isAuthenticated: Bool
    /// The logged-in user's fully-qualified MXID (reconciled via `whoAmI`
    /// at login). Nil when logged out.
    public private(set) var userId: UserId?
    /// The session's device ID, if known.
    public private(set) var deviceId: DeviceId?
    /// Long-poll lifecycle state (`.idle`, `.syncing`, `.failed(…)`).
    public private(set) var syncStatus: SyncStatus
    /// Sliding sync lifecycle state. Independent of `syncStatus`.
    public private(set) var slidingSyncStatus: SyncStatus
    /// Versions and unstable flags from `GET /versions`, captured at
    /// login/restore. Nil when the fetch failed — feature checks treat
    /// unknown as supported (optimistic), preserving today's behavior.
    public private(set) var serverVersions: ServerVersions?

    // MARK: - Actor layer (public for advanced use)

    /// Raw HTTP layer. Prefer the namespace clients below; reach for this
    /// only for endpoints MatrixKit doesn't wrap yet.
    public let transport: MatrixTransport
    /// Tokens, device, and user IDs for this session.
    public let session: Session
    /// Client-side room state, sync token, and account data.
    public let store: StateStore
    /// Login, refresh, logout, and server discovery.
    public let auth: AuthClient
    /// Long-poll loop and delta application.
    public let sync: SyncClient
    /// Sliding sync loop (MSC4186) and delta application. Opt-in via
    /// `startSlidingSync`; shares `store` with `sync` but keeps its own
    /// `pos` cursor (see `StateStore.applySliding`).
    public let slidingSync: SlidingSyncClient
    /// Room membership and directory operations.
    public let rooms: RoomClient
    /// Room state, typing, and receipts.
    public let roomState: RoomStateClient
    /// Space hierarchy, children management, and parent lookup.
    public let spaces: SpacesClient
    /// Per-user and per-room account data (read markers, ignore list, …).
    public let accountData: AccountDataClient
    /// Sending, redacting, reacting, and paginating messages.
    public let messages: MessageClient
    /// Full-text message search.
    public let search: SearchClient
    /// MXC upload/download and authenticated `mxc://` URLs.
    public let media: MediaClient
    /// Display names and avatars.
    public let profile: ProfileClient
    /// Pushers and push-rule management.
    public let push: PushClient
    /// High-level notification settings over push rules.
    public let notifications: NotificationSettings
    /// Device/cross-signing key upload, query, and signatures.
    public let keys: KeyClient
    /// Cross-signing identity lifecycle (generate/upload/sign devices).
    public let crossSigning: CrossSigning
    /// Send-to-device messaging (verification flows).
    public let toDevice: ToDeviceClient
    /// Olm end-to-end encryption for to-device messages (unconfigured
    /// until `configure` with the device identity; see `OlmConnector`).
    public let olm: OlmConnector
    /// Cross-signing secret sharing (request/receive/persist private halves).
    public let secrets: SecretShare
    /// 4S secret storage: unlock with a recovery key or passphrase, then
    /// decrypt named secrets (cross-signing keys, backup key).
    public let secretStorage: SecretStorage
    /// Megolm room encryption (outbound sessions, key sharing, inbound
    /// decrypt). Dormant until `configureEncryption()`; see `RoomCrypto`.
    public let roomCrypto: RoomCrypto
    /// Server-side key backup (version management, upload, restore).
    public let backup: KeyBackup
    /// Verification flows (request monitoring, SAS sessions).
    public let verifications: VerificationMonitor
    /// Whether this session is cross-signing verified. See
    /// `refreshVerificationState()`.
    public private(set) var isSessionVerified: Bool
    /// Whether the verification state was checked at least once.
    /// Gates UI that hides on `!isSessionVerified` (which reads false
    /// before the first check).
    public private(set) var hasCheckedVerificationState: Bool

    // MARK: - Observable conveniences

    public private(set) var roomList: ObservableRoomList!

    private var roomCache: [RoomId: ObservableRoom] = [:]
    /// The app-provided secret store (Olm sessions, megolm sessions,
    /// cross-signing backup, device identities). Retained so logout
    /// wipes the same backend login wrote to.
    private let keystore: (any KeyStore)?
    private var syncTask: Task<Void, Never>?
    private var slidingSyncTask: Task<Void, Never>?
    /// Live `deltas()` subscribers. Yielded every sync delta; never
    /// finished (subscribers survive sync restarts) or removed (the client
    /// lives for the session). Mirrors `VerificationMonitor.events()`.
    private var deltaContinuations: [AsyncStream<SyncDelta>.Continuation] = []
    /// Live decrypted to-device subscribers. Yielded every sync batch that
    /// produced Olm-decrypted inner events; never finished (subscribers
    /// survive sync restarts) or removed (the client lives for the
    /// session). Follows the `deltas()` pattern; consumed by MatrixRTC
    /// for `io.element.call.encryption_keys`.
    private var decryptedToDeviceContinuations: [AsyncStream<[BasicEvent]>.Continuation] = []
    /// Decryptor for paginated history, armed by `configureEncryption()`
    /// alongside the sync hooks (`Timeline.setDecryptor` was previously
    /// never called, so back-pagination stayed encrypted).
    private var timelineDecryptor:
        (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?

    init(homeserver: URL, session: Session, transport: MatrixTransport, keystore: (any KeyStore)? = nil, serverVersions: ServerVersions? = nil) async {
        self.homeserver = homeserver
        self.session = session
        self.transport = transport
        self.serverVersions = serverVersions
        self.keystore = keystore
        self.store = StateStore()
        let connection = SyncConnection(transport: transport, session: session)
        self.auth = AuthClient(transport: transport, session: session)
        await transport.setTokenRefresher({ [auth, session] in
            try? await auth.refresh()
            let token = await session.accessToken
            return token.isEmpty ? nil : token
        })
        self.sync = SyncClient(connection: connection, store: store, session: session)
        self.slidingSync = SlidingSyncClient(transport: transport, session: session, store: store)
        self.rooms = RoomClient(transport: transport, session: session)
        self.roomState = RoomStateClient(transport: transport, session: session)
        self.spaces = SpacesClient(transport: transport, session: session, store: store)
        self.accountData = AccountDataClient(transport: transport, session: session)
        self.messages = MessageClient(transport: transport, session: session)
        self.search = SearchClient(transport: transport, session: session, store: store)
        self.media = MediaClient(transport: transport, session: session)
        self.profile = ProfileClient(transport: transport, session: session)
        self.push = PushClient(transport: transport, session: session)
        self.notifications = NotificationSettings(push: push)
        self.keys = KeyClient(transport: transport, session: session)
        self.crossSigning = CrossSigning(transport: transport, session: session)
        self.toDevice = ToDeviceClient(transport: transport, session: session)
        // Olm diagnostics follow the same level knobs as transport
        // (`MATRIXKIT_LOG_LEVEL` / `MATRIXKIT_DEBUG=1`): a default
        // `.info` logger would swallow the `.debug` decrypt-failure
        // lines that diagnose stuck verifications.
        var olmLogger = Logger(label: "MatrixKit.Olm")
        MatrixTransport.applyConfiguredLevel(to: &olmLogger)
        var roomLogger = Logger(label: "MatrixKit.RoomCrypto")
        MatrixTransport.applyConfiguredLevel(to: &roomLogger)
        self.olm = OlmConnector(
            keys: self.keys, sender: self.toDevice,
            logger: olmLogger, keystore: keystore)
        self.secrets = SecretShare(
            sender: self.toDevice, session: session,
            crossSigning: self.crossSigning,
            store: CrossSigningStore(keystore: keystore),
            olm: self.olm)
        self.secretStorage = SecretStorage(accountData: self.accountData)
        self.roomCrypto = RoomCrypto(
            sharer: self.olm, sender: self.messages, keystore: keystore,
            logger: roomLogger)
        self.backup = KeyBackup(transport: transport, session: session)
        self.verifications = VerificationMonitor(
            toDevice: self.toDevice, olm: self.olm, session: session, keys: self.keys)
        self.isSessionVerified = false
        self.hasCheckedVerificationState = false
        self.isAuthenticated = await session.isValid
        self.userId = await session.isValid ? session.userId : nil
        self.deviceId = await session.isValid ? session.deviceId : nil
        self.syncStatus = .idle
        self.slidingSyncStatus = .idle
        if let userId = self.userId {
            await store.setLocalUser(userId)
        }
        self.roomList = ObservableRoomList(client: self)
    }

    // MARK: - Factories

    /// Whether a sliding sync attempt may proceed: true when versions are
    /// unknown (optimistic — preserves behavior on fetch failure) or the
    /// server advertises simplified sliding sync.
    public var canUseSlidingSync: Bool {
        guard let serverVersions else { return true }
        return serverVersions.hasUnstableFeature(UnstableFeature.simplifiedSlidingSync)
    }

    /// Fetch `GET /versions` best-effort (nil on any failure). Callers use
    /// the authenticated session so per-user unstable features are included.
    private static func fetchServerVersions(
        transport: MatrixTransport, session: Session
    ) async -> ServerVersions? {
        try? await AuthClient(transport: transport, session: session).serverVersions()
    }

    /// Wire an authenticated session into a client (whoami reconciliation
    /// + store setup). Shared by all `login*` factories.
    private static func adoptSession(
        homeserver: URL, session: Session, transport: MatrixTransport,
        keystore: (any KeyStore)? = nil
    ) async throws -> MatrixClient {
        let auth = AuthClient(transport: transport, session: session)
        // Re-read the session the server assigned (user ID may be qualified
        // differently, e.g. fully-qualified MXID).
        let whoami = try await auth.whoAmI()
        // The session's login-time IDs may be empty or unqualified;
        // adopt the server-assigned ones so key upload and signing
        // use the authenticated identity.
        await session.updateIDs(userId: whoami.userId, deviceId: whoami.deviceId)
        let client = await MatrixClient(
            homeserver: homeserver, session: session, transport: transport,
            keystore: keystore,
            serverVersions: await fetchServerVersions(
                transport: transport, session: session))
        client.userId = whoami.userId
        if let deviceId = whoami.deviceId {
            client.deviceId = deviceId
        }
        client.isAuthenticated = true
        await client.store.setLocalUser(whoami.userId)
        return client
    }

    /// Log in with a password and return a wired-up client.
    ///
    /// The homeserver URL is resolved through `.well-known/matrix/client`
    /// discovery first (falls back to the declared URL on any failure).
    ///
    /// - Parameter logLevel: transport log level. Defaults to
    ///   `MATRIXKIT_LOG_LEVEL` / `MATRIXKIT_DEBUG=1` env, else `.info`.
    ///   Pass `.debug` to log redacted request/response bodies.
    public static func login(
        homeserver: URL,
        user: String,
        password: String,
        deviceDisplayName: String? = nil,
        logLevel: Logger.Level? = nil,
        keystore: (any KeyStore)? = nil
    ) async throws -> MatrixClient {
        let homeserver = await MatrixTransport.resolveHomeserver(declared: homeserver)
        let transport = MatrixTransport(homeserver: homeserver, logLevel: logLevel)
        do {
            let session = Session(
                homeserver: homeserver,
                userId: UserId(unchecked: ""),
                deviceId: DeviceId(""),
                accessToken: ""
            )
            let auth = AuthClient(transport: transport, session: session)
            try await auth.login(
                user: user, password: password,
                initialDeviceDisplayName: deviceDisplayName
            )
            return try await adoptSession(
                homeserver: homeserver, session: session, transport: transport,
                keystore: keystore)
        } catch {
            // Don't leak the owned HTTP client (its deinit traps if not shut down).
            try? await transport.shutdown()
            throw error
        }
    }

    /// Log in via the OIDC device flow (MSC3861, headless/CLI-friendly).
    /// `onUserCode` receives `(userCode, verificationURL, expiresInSeconds)`
    /// for display; polling starts once it returns. Throws
    /// `M_OIDC_UNSUPPORTED` on servers without OIDC or device flow.
    /// The homeserver URL is resolved through `.well-known/matrix/client`
    /// discovery first (falls back to the declared URL on any failure).
    public static func loginViaOIDC(
        homeserver: URL,
        clientName: String = "MatrixKit",
        clientURI: String? = nil,
        logoURI: String? = nil,
        redirectURIs: [String] = ["http://localhost/"],
        onUserCode: @Sendable @escaping (String, String, Int) async -> Void,
        logLevel: Logger.Level? = nil,
        keystore: (any KeyStore)? = nil
    ) async throws -> MatrixClient {
        let homeserver = await MatrixTransport.resolveHomeserver(declared: homeserver)
        let transport = MatrixTransport(homeserver: homeserver, logLevel: logLevel)
        do {
            let session = Session(
                homeserver: homeserver,
                userId: UserId(unchecked: ""),
                deviceId: DeviceId(""),
                accessToken: ""
            )
            let auth = AuthClient(transport: transport, session: session)
            try await auth.loginViaOIDCDevice(
                clientName: clientName, clientURI: clientURI, logoURI: logoURI,
                redirectURIs: redirectURIs, onUserCode: onUserCode)
            return try await adoptSession(
                homeserver: homeserver, session: session, transport: transport,
                keystore: keystore)
        } catch {
            try? await transport.shutdown()
            throw error
        }
    }

    /// Pending browser-based OIDC login. Open `authorizationURL`, have the
    /// user authenticate, then pass the redirected `code` + `state` to
    /// `completeOIDCBrowserLogin`. Created by `prepareOIDCBrowserLogin`.
    public struct OIDCAuthorization: Sendable {
        /// URL to open in a browser (`ASWebAuthenticationSession`, etc.).
        public let authorizationURL: URL
        /// CSRF token echoed back on the redirect; validated on completion.
        public let state: String
        let codeVerifier: String
        let clientId: String
        let metadata: AuthMetadata
        let redirectURI: String
        let transport: MatrixTransport
        let session: Session
    }

    /// Start a browser-based OIDC login (native apps). Returns the pending
    /// authorization; the caller opens the URL and completes via
    /// `completeOIDCBrowserLogin`. The transport is owned by the pending
    /// authorization (shut down automatically on failure).
    /// The homeserver URL is resolved through `.well-known/matrix/client`
    /// discovery first (falls back to the declared URL on any failure).
    public static func prepareOIDCBrowserLogin(
        homeserver: URL,
        clientName: String = "MatrixKit",
        clientURI: String? = nil,
        logoURI: String? = nil,
        redirectURI: String,
        logLevel: Logger.Level? = nil
    ) async throws -> OIDCAuthorization {
        let homeserver = await MatrixTransport.resolveHomeserver(declared: homeserver)
        let transport = MatrixTransport(homeserver: homeserver, logLevel: logLevel)
        do {
            let oidc = OIDCClient(transport: transport)
            guard let metadata = try await oidc.discover() else {
                throw MatrixError.serverError(
                    code: "M_OIDC_UNSUPPORTED",
                    message: "Homeserver does not advertise OIDC auth metadata",
                    retryAfter: nil
                )
            }
            let clientId = try await oidc.register(
                metadata: metadata, clientName: clientName, clientURI: clientURI,
                logoURI: logoURI, redirectURIs: [redirectURI])
            let deviceId = OIDCClient.makeDeviceID()
            let (url, state, verifier) = try OIDCClient.authorizationURL(
                metadata: metadata, clientId: clientId,
                redirectURI: redirectURI, deviceId: deviceId)
            let session = Session(
                homeserver: homeserver,
                userId: UserId(unchecked: ""),
                deviceId: DeviceId(deviceId),
                accessToken: ""
            )
            return OIDCAuthorization(
                authorizationURL: url, state: state, codeVerifier: verifier,
                clientId: clientId, metadata: metadata,
                redirectURI: redirectURI, transport: transport,
                session: session)
        } catch {
            try? await transport.shutdown()
            throw error
        }
    }

    /// Finish a browser-based OIDC login after the redirect. Validates
    /// `state`, exchanges the code, and returns a wired-up client.
    public static func completeOIDCBrowserLogin(
        _ authorization: OIDCAuthorization,
        code: String,
        state: String,
        keystore: (any KeyStore)? = nil
    ) async throws -> MatrixClient {
        guard state == authorization.state else {
            try? await authorization.transport.shutdown()
            throw MatrixError.serverError(
                code: "M_OIDC_STATE_MISMATCH",
                message: "OIDC redirect state does not match the request",
                retryAfter: nil
            )
        }
        do {
            let oidc = OIDCClient(transport: authorization.transport)
            let tokens = try await oidc.exchangeCode(
                metadata: authorization.metadata,
                clientId: authorization.clientId, code: code,
                verifier: authorization.codeVerifier,
                redirectURI: authorization.redirectURI)
            await authorization.session.update(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                expiresInMs: tokens.expiresIn.map { $0 * 1000 })
            await authorization.session.updateOIDC(
                clientId: authorization.clientId,
                tokenEndpoint: authorization.metadata.tokenEndpoint)
            return try await adoptSession(
                homeserver: authorization.session.homeserver,
                session: authorization.session,
                transport: authorization.transport,
                keystore: keystore)
        } catch {
            try? await authorization.transport.shutdown()
            throw error
        }
    }

    /// Restore a client from existing tokens (e.g. Keychain).
    /// The homeserver URL is resolved through `.well-known/matrix/client`
    /// discovery first (falls back to the declared URL on any failure).
    public static func restore(
        homeserver: URL,
        userId: UserId,
        deviceId: DeviceId,
        accessToken: String,
        refreshToken: String? = nil,
        oidcClientId: String? = nil,
        oidcTokenEndpoint: String? = nil,
        logLevel: Logger.Level? = nil,
        keystore: (any KeyStore)? = nil
    ) async -> MatrixClient {
        let homeserver = await MatrixTransport.resolveHomeserver(declared: homeserver)
        let transport = MatrixTransport(homeserver: homeserver, logLevel: logLevel)
        let session = Session(
            homeserver: homeserver,
            userId: userId,
            deviceId: deviceId,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
        if let oidcClientId, let oidcTokenEndpoint {
            await session.updateOIDC(clientId: oidcClientId, tokenEndpoint: oidcTokenEndpoint)
        }
        let versions = await fetchServerVersions(transport: transport, session: session)
        return await MatrixClient(homeserver: homeserver, session: session, transport: transport, keystore: keystore, serverVersions: versions)
    }

    /// Reconcile the in-memory identity with the server (`GET /account/whoami`),
    /// adopting the server-assigned user/device IDs. Call after `restore(...)`
    /// so a restored session matches login-time identity; without it, a stored
    /// MXID that differs from the server-assigned one breaks own-message
    /// detection (`sender == localUserId`).
    public func reconcileIdentity() async throws(MatrixError) {
        let whoami = try await auth.whoAmI()
        await session.updateIDs(userId: whoami.userId, deviceId: whoami.deviceId)
        userId = whoami.userId
        if let deviceId = whoami.deviceId {
            self.deviceId = deviceId
        }
        isAuthenticated = true
        await store.setLocalUser(whoami.userId)
    }

    // MARK: - Auth

    /// Log out (server-side token invalidation + local reset).
    /// OIDC sessions revoke via their revocation endpoint; legacy sessions
    /// use `POST /logout`.
    public func logout() async throws {
        await stopSync()
        if await session.isOIDC {
            try await auth.logoutOIDC()
        } else {
            try await auth.logout()
        }
        isAuthenticated = false
        userId = nil
        deviceId = nil
        roomCache = [:]
    }

    /// Delete all local crypto material for the current user: persisted
    /// Olm sessions + one-time keys, megolm sessions, the cross-signing
    /// store entry (plus any legacy backup file), and device identity
    /// entries — all in the injected `KeyStore` when one was provided.
    /// Call BEFORE `logout()` (which clears the user ID this
    /// needs). Best-effort — every step ignores errors so one failure
    /// can't trap sign-out.
    public func deleteLocalCryptoMaterial() async {
        await olm.deletePersistedState()
        await roomCrypto.deletePersistedSessions()
        guard let userId else { return }
        try? await CrossSigningStore(keystore: keystore).delete(userId: userId)
        try? await DeviceIdentityStore(keystore: keystore).deleteAll(userId: userId)
    }

    // MARK: - Sync

    /// Start the sync loop. Room list refreshes on every delta.
    public func startSync(filter: SyncFilter? = nil) async throws {
        guard syncTask == nil else { return }
        syncStatus = .syncing
        do {
            let stream = try await sync.start(filter: filter)
            syncTask = Task { [weak self] in
                guard let self else { return }
                for await delta in stream {
                    // New fully-read IDs only arrive via room account data;
                    // resolve their timestamps so badges stop counting from
                    // the stale receipt position.
                    if delta.joined.values.contains(where: { !$0.accountData.isEmpty }) {
                        await self.resolveReadMarkers()
                    }
                    await self.roomList.refresh()
                    self.notifyDelta(delta)
                }
                self.syncStatus = .idle
                self.syncTask = nil
            }
        } catch {
            syncStatus = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Stop the sync loop.
    public func stopSync() async {
        syncTask?.cancel()
        syncTask = nil
        await sync.stop()
        if case .syncing = syncStatus {
            syncStatus = .idle
        }
    }

    /// Subscribe to live sync deltas (e.g. for local message
    /// notifications). The stream stays open across sync restarts and ends
    /// on cancellation. Follows the `VerificationMonitor.events()` pattern.
    public func deltas() -> AsyncStream<SyncDelta> {
        let (stream, continuation) = AsyncStream<SyncDelta>.makeStream()
        deltaContinuations.append(continuation)
        return stream
    }

    private func notifyDelta(_ delta: SyncDelta) {
        for continuation in deltaContinuations {
            continuation.yield(delta)
        }
    }

    /// Subscribe to Olm-decrypted to-device inner events (e.g. for
    /// MatrixRTC call key exchange). Batches arrive per sync round-trip;
    /// the stream stays open across sync restarts and ends on
    /// cancellation. Follows the `deltas()` pattern.
    public func decryptedToDevice() -> AsyncStream<[BasicEvent]> {
        let (stream, continuation) = AsyncStream<[BasicEvent]>.makeStream()
        decryptedToDeviceContinuations.append(continuation)
        return stream
    }

    /// Single sync round-trip (initial sync / catch-up).
    public func syncOnce(filter: SyncFilter? = nil) async throws {
        try await sync.syncOnce(filter: filter)
        await resolveReadMarkers()
        await roomList.refresh()
        await logRoomList()
    }

    /// Resolve fully-read marker timestamps the sync window couldn't:
    /// one `GET /rooms/{id}/event/{fullyRead}` per room that has a marker
    /// ID outside its timeline window, once per marker ID (successes are
    /// cached on the actor; failures retry on the next pass). Without
    /// this, such rooms count unread from the often-stale receipt
    /// timestamp — and history pagination widens the phantom.
    public func resolveReadMarkers() async {
        let rooms = await store.joinedRooms()
        for room in rooms {
            guard !Task.isCancelled else { return }
            guard await room.needsMarkerResolution,
                let marker = await room.fullyReadEventId
            else { continue }
            let roomId = room.roomId
            guard let event = try? await messages.event(roomId, marker) else { continue }
            await room.adoptResolvedMarkerTs(marker, ts: event.originServerTs)
        }
    }

    /// Start the sliding sync loop. Room list refreshes on every delta.
    /// Runs independently of `startSync`; E2EE/to-device extensions ride
    /// along whenever crypto hooks are installed, so the sliding path
    /// delivers keys and decrypts timelines the same way the v3 loop does.
    /// No-ops (with a warning) when the server is known not to advertise
    /// simplified sliding sync; unknown versions proceed optimistically.
    public func startSlidingSync(
        lists: [String: SlidingSyncList] = SlidingSyncClient.defaultLists,
        subscriptions: [RoomId: SlidingSyncRoomSubscription] = [:]
    ) async throws {
        guard slidingSyncTask == nil else { return }
        guard canUseSlidingSync else {
            var syncLogger = Logger(label: "MatrixKit.SlidingSync")
            MatrixTransport.applyConfiguredLevel(to: &syncLogger)
            syncLogger.warning(
                "Sliding sync unsupported: server versions do not advertise \(UnstableFeature.simplifiedSlidingSync)")
            return
        }
        slidingSyncStatus = .syncing
        do {
            let stream = try await slidingSync.start(lists: lists, subscriptions: subscriptions)
            slidingSyncTask = Task { [weak self] in
                guard let self else { return }
                for await delta in stream {
                    if delta.joined.values.contains(where: { !$0.accountData.isEmpty }) {
                        await self.resolveReadMarkers()
                    }
                    await self.roomList.refresh()
                    self.notifyDelta(delta)
                }
                self.slidingSyncStatus = .idle
                self.slidingSyncTask = nil
            }
        } catch {
            slidingSyncStatus = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Stop the sliding sync loop.
    public func stopSlidingSync() async {
        slidingSyncTask?.cancel()
        slidingSyncTask = nil
        await slidingSync.stop()
        if case .syncing = slidingSyncStatus {
            slidingSyncStatus = .idle
        }
    }

    /// Single sliding sync round-trip, applied to the store. Same
    /// support gate as `startSlidingSync` (no-op when known-unsupported).
    public func slidingSyncOnce(
        lists: [String: SlidingSyncList]? = nil,
        subscriptions: [RoomId: SlidingSyncRoomSubscription]? = nil
    ) async throws {
        guard canUseSlidingSync else { return }
        try await slidingSync.syncOnce(lists: lists, subscriptions: subscriptions)
        await resolveReadMarkers()
        await roomList.refresh()
        await logRoomList()
    }

    /// Friendly debug line for a completed initial fetch: Relay shows it
    /// as "Fetched room list (N rooms)" under the room-list category.
    private func logRoomList() async {
        var roomListLogger = Logger(label: "MatrixKit.Client")
        MatrixTransport.applyConfiguredLevel(to: &roomListLogger)
        let count = await store.joinedRooms().count
        roomListLogger.debug("Fetched room list (\(count) rooms)")
    }

    // MARK: - Encryption

    /// Enable Megolm room encryption: restore persisted inbound sessions
    /// and install the sync hooks that route `m.room_key` to-device
    /// events into `roomCrypto`, decrypt timelines, and invalidate stale
    /// device caches. Also arms the `m.room_key_request` cycle (request
    /// unknown sessions, serve peer requests) and OTK pool refills.
    /// Requires `olm.configure(…)` first.
    public func configureEncryption() async {
        await roomCrypto.restore()
        await roomCrypto.setLocalUserId(userId)
        let olm = self.olm
        let roomCrypto = self.roomCrypto
        let deviceId = self.deviceId
        var keyLogger = Logger(label: "MatrixKit.RoomCrypto")
        MatrixTransport.applyConfiguredLevel(to: &keyLogger)
        // Unknown sessions fire once per session (throttled in
        // `RoomCrypto`): ask the sender for the key. The closure only
        // captures actor references and values, so it stays `@Sendable`.
        await roomCrypto.setUnknownSessionHandler({ [olm, deviceId, keyLogger] unknown in
            Task {
                guard let deviceId else { return }
                let content = RoomCrypto.keyRequestContent(
                    requestId: UUID().uuidString, deviceId: deviceId,
                    roomId: unknown.roomId, sessionId: unknown.sessionId)
                do {
                    let ids = try await olm.deviceIds(for: unknown.sender)
                    guard !ids.isEmpty else {
                        keyLogger.warning(
                            "RoomCrypto key request: no devices",
                            metadata: ["user": "\(unknown.sender.value)"])
                        return
                    }
                    try await olm.sendEncrypted(
                        eventType: RoomCrypto.keyRequestType, content: content,
                        to: unknown.sender, devices: ids.map { DeviceId($0) })
                    keyLogger.debug(
                        "RoomCrypto sent key request",
                        metadata: [
                            "user": "\(unknown.sender.value)",
                            "sessionId": "\(unknown.sessionId.prefix(8))…",
                        ])
                } catch {
                    keyLogger.warning(
                        "RoomCrypto key request failed",
                        metadata: ["error": "\(error)"])
                }
            }
        })
        let hooks = SyncCryptoHooks(
            handleToDevice: { events in
                await self.routeToDeviceEvents(events)
            },
            decryptRoomEvent: { event, roomId in
                await roomCrypto.decryptRoomEvent(event, in: roomId)
            },
            handleDeviceLists: { changed, left in
                for user in changed + left {
                    await olm.invalidateDevices(for: user)
                }
            },
            handleKeyCounts: { [olm, keyLogger] count in
                do {
                    try await olm.maintainKeys(serverCount: count)
                } catch {
                    keyLogger.warning(
                        "RoomCrypto OTK refill failed",
                        metadata: ["error": "\(error)"])
                }
            }
        )
        await sync.setCryptoHooks(hooks)
        await slidingSync.setCryptoHooks(hooks)
        timelineDecryptor = hooks.decryptRoomEvent
        for room in roomCache.values {
            await room.setTimelineDecryptor(hooks.decryptRoomEvent)
        }
    }

    /// Route sync to-device traffic into the crypto consumers.
    ///
    /// The verification monitor gets both the raw events and the
    /// Olm-decrypted ones: peers that cannot encrypt to us (unknown or
    /// keyless device) send verification traffic in plaintext, and
    /// `olm.decrypt` only returns `m.room.encrypted` inners. Raw
    /// `m.room.encrypted` envelopes are undecodable as verification
    /// messages, so they are safely ignored downstream.
    func routeToDeviceEvents(_ events: [BasicEvent]) async {
        let decrypted = await olm.decrypt(events)
        if !decrypted.isEmpty {
            for continuation in decryptedToDeviceContinuations {
                continuation.yield(decrypted)
            }
        }
        for event in decrypted
            where event.type == RoomCrypto.roomKeyType
        {
            // A newly-shared session can unlock stored ciphertext in
            // that room — re-decrypt it immediately instead of leaving
            // "Unable to decrypt" placeholders until relaunch.
            if let roomId = await roomCrypto.receiveRoomKey(event) {
                _ = await roomCache[roomId]?.retryDecryption()
            }
        }
        for event in decrypted where event.type == "m.secret.send" {
            if await secrets.receive(event) == .completed {
                await refreshVerificationState()
            }
        }
        for event in decrypted where event.type == RoomCrypto.keyRequestType {
            await self.serveKeyRequest(event)
        }
        await verifications.receive(events + decrypted)
    }

    /// Serve an `m.room_key_request`: share our current outbound session
    /// with the requesting device when the requester is a joined member
    /// of the room. Duplicate `request_id`s share once. Never throws —
    /// failures are logged so sync routing stays total.
    func serveKeyRequest(_ event: BasicEvent) async {
        var keyLogger = Logger(label: "MatrixKit.RoomCrypto")
        MatrixTransport.applyConfiguredLevel(to: &keyLogger)
        guard
            event.content["action"]?.stringValue != "request_cancellation",
            event.content["algorithm"]?.stringValue == RoomCrypto.megolmAlgorithm,
            let requestId = event.content["request_id"]?.stringValue,
            let requestingDevice = event.content["requesting_device_id"]?.stringValue,
            let roomString = event.content["room_id"]?.stringValue,
            let sessionId = event.content["session_id"]?.stringValue,
            let requester = event.sender
        else { return }
        let roomId = RoomId(unchecked: roomString)
        guard await roomCrypto.claimServedRequest(requestId) else { return }
        do {
            let members = try await rooms.joinedMembers(roomId)
            guard members.keys.contains(requester) else {
                keyLogger.debug(
                    "RoomCrypto ignoring key request from non-member",
                    metadata: ["user": "\(requester.value)"])
                return
            }
            try await roomCrypto.shareCurrentSession(
                roomId: roomId, to: requester,
                devices: [DeviceId(requestingDevice)])
            keyLogger.debug(
                "RoomCrypto served key request",
                metadata: [
                    "user": "\(requester.value)",
                    "sessionId": "\(sessionId.prefix(8))…",
                ])
        } catch {
            keyLogger.warning(
                "RoomCrypto key-request serve failed",
                metadata: ["error": "\(error)"])
        }
    }

    /// Recompute cross-signing verification state from our device keys.
    /// Call after login/restore and after verification flows complete.
    /// Self-heals: when keys are held locally but our device lacks a
    /// valid self-signature (e.g. secrets arrived while the sign step
    /// failed), re-signs before re-checking. Failures keep the previous
    /// state but still mark it checked.
    public func refreshVerificationState() async {
        defer { hasCheckedVerificationState = true }
        guard let userId, let deviceId else { return }
        do {
            let queried = try await keys.queryKeys(users: [userId])
            guard let device = queried.deviceKeys[userId.value]?[deviceId.value] else {
                return
            }
            if await crossSigning.isDeviceVerified(device) {
                isSessionVerified = true
                return
            }
            if await crossSigning.hasKeys {
                _ = try? await crossSigning.signDevice(
                    userId: userId, deviceId: deviceId)
                let requeried = try await keys.queryKeys(users: [userId])
                if let fresh = requeried.deviceKeys[userId.value]?[deviceId.value] {
                    isSessionVerified = await crossSigning.isDeviceVerified(fresh)
                    return
                }
            }
            isSessionVerified = false
        } catch {
            return
        }
    }

    /// Backup and recovery state for settings UI. A missing backup reads
    /// as disabled (including when offline).
    public func encryptionStatus() async -> EncryptionStatus {
        let backupEnabled = (try? await backup.backupInfo()) != nil
        var recoveryEnabled = false
        if let userId,
            let fetched = try? await crossSigning.fetchKeys(users: [userId])
        {
            recoveryEnabled = fetched.masterKeys?[userId.value] != nil
                && fetched.selfSigningKeys?[userId.value] != nil
                && fetched.userSigningKeys?[userId.value] != nil
        }
        return EncryptionStatus(
            backupEnabled: backupEnabled, recoveryEnabled: recoveryEnabled)
    }

    /// Whether another device exists to verify against via SAS
    /// (any device other than our own). Offline reads as false.
    public func hasDevicesToVerifyAgainst() async -> Bool {
        guard let devices = try? await auth.devices() else { return false }
        return devices.contains { !$0.isCurrentDevice }
    }

    /// Recover 4S secrets with an `Es...` recovery key: unlock the
    /// default storage key, import the cross-signing private keys, and
    /// return the backup private key for the separate
    /// `restoreKeyBackup` step. Passphrase unlock is CPU-heavy by
    /// design — call `recover(withPassphrase:)` off the main actor.
    public func recover(withRecoveryKey key: String) async throws(MatrixError) -> RecoveryOutcome {
        let (storageKey, keyId) = try await secretStorage.unlock(recoveryKey: key)
        return try await recover(storageKey: storageKey, keyId: keyId)
    }

    /// Recover 4S secrets with the account passphrase. See
    /// `recover(withRecoveryKey:)`; prefer a detached task.
    public func recover(withPassphrase passphrase: String) async throws(MatrixError) -> RecoveryOutcome {
        let (storageKey, keyId) = try await secretStorage.unlock(passphrase: passphrase)
        return try await recover(storageKey: storageKey, keyId: keyId)
    }

    /// Download and import every backed-up megolm session. Separate
    /// from `recover` — restores are large and belong behind their own
    /// progress UI. Returns the number of sessions imported.
    @discardableResult
    public func restoreKeyBackup(privateKey: Data) async throws(MatrixError) -> Int {
        guard let info = try await backup.backupInfo(), let version = info.version else {
            throw MatrixError.recoveryFailed("No key backup on this account")
        }
        let sessions = try await backup.downloadSessions(
            version: version, privateKey: privateKey)
        for session in sessions {
            try await roomCrypto.importSession(
                roomId: session.roomId, sessionId: session.sessionId,
                export: session.export)
        }
        // Imported keys alone change nothing on screen: stored
        // ciphertext must be re-run through the decryptor so the
        // timeline rebuilds with the new sessions.
        _ = await retryTimelineDecryption()
        return sessions.count
    }

    /// Ask a peer device for the `m.megolm_backup.v1` private key
    /// (post-verification restore offer). The answer arrives through
    /// the `secrets` event stream as `SecretShareEvent.backupKeyReceived`.
    /// Only peers holding the key can answer — see
    /// `SecretShare/requestBackupKey`.
    @discardableResult
    public func requestBackupKey(
        from userId: UserId, deviceId: String?
    ) async throws(MatrixError) -> String {
        try await secrets.requestBackupKey(from: userId, deviceId: deviceId)
    }

    /// Recover 4S secrets with an already-unlocked storage key (see
    /// `SecretStorage/unlock(recoveryKey:keyId:)`). Imports the
    /// cross-signing private keys, self-signs this device so the
    /// recovery key verifies the session directly, and returns the
    /// backup private key for the separate `restoreKeyBackup` step.
    public func recover(
        storageKey: Data, keyId: String
    ) async throws(MatrixError) -> RecoveryOutcome {
        // Sequential: `async let` erases typed throws to `any Error`.
        let masterKey = try await secretStorage.secret(
            SecretName.master, keyId: keyId, storageKey: storageKey)
        let selfKey = try await secretStorage.secret(
            SecretName.selfSigning, keyId: keyId, storageKey: storageKey)
        let userKey = try await secretStorage.secret(
            SecretName.userSigning, keyId: keyId, storageKey: storageKey)
        let backupKey = try await secretStorage.secret(
            "m.megolm_backup.v1", keyId: keyId, storageKey: storageKey)
        var outcome = RecoveryOutcome(crossSigningImported: false)
        if let masterKey, let selfKey, let userKey {
            try await crossSigning.importPrivateKeys(
                master: masterKey, selfSigning: selfKey, userSigning: userKey)
            outcome.crossSigningImported = true
            // Persist immediately: without this the keys live only in
            // memory and the session is unverified again after restart
            // (the `m.secret.send` path persists on receipt, but
            // recovery never went through it).
            guard await secrets.persist() else {
                throw MatrixError.recoveryFailed(
                    "Keys recovered but could not be saved on this device")
            }
        }
        if let backupKey, let privateKey = Primitives.base64UnpaddedDecode(backupKey) {
            outcome.backupPrivateKey = privateKey
            // Hold the key in memory so this device can answer peers'
            // `m.megolm_backup.v1` share requests (request-driven only —
            // never persisted).
            await secrets.cacheBackupKey(privateKey)
        }
        if outcome.crossSigningImported, let userId, let deviceId {
            // Unlike the opportunistic heal in
            // `refreshVerificationState` (which swallows upload
            // failures), this propagates: a failed self-signature
            // surfaces as an error, not a silent "still unverified".
            try await crossSigning.signDevice(
                userId: userId, deviceId: deviceId)
        }
        await refreshVerificationState()
        return outcome
    }

    /// Send encrypted content: share the room's Megolm session
    /// with joined members (once per session), then send ciphertext.
    /// Shares include our own other devices (they need the session to
    /// read what we send); only our current device is skipped. Pass the
    /// staged local-echo transaction ID so sync confirms the echo.
    @discardableResult
    public func sendEncryptedContent(
        _ roomId: RoomId, _ content: any Encodable & Sendable,
        transactionId: TransactionId = .random()
    ) async throws -> EventId {
        let members = try await rooms.joinedMembers(roomId)
        let ownDevice = deviceId
        try await roomCrypto.ensureShared(
            roomId: roomId, users: Array(members.keys),
            excludingDevice: ownDevice)
        return try await roomCrypto.sendEncryptedContent(
            roomId, content, transactionId: transactionId)
    }

    /// (Re-)share the room's Megolm session with all joined members,
    /// including our own other devices (e.g. after a membership change).
    /// Call `rotateOutbound` first (via `roomCrypto`) when a member leaves.
    public func shareRoomKey(_ roomId: RoomId) async throws {
        let members = try await rooms.joinedMembers(roomId)
        let ownDevice = deviceId
        try await roomCrypto.shareRoomKey(
            roomId: roomId, users: Array(members.keys),
            excludingDevice: ownDevice)
    }

    // MARK: - Rooms

    /// Re-run Megolm decryption over every cached room's stored
    /// ciphertext (see `RoomActor.retryDecryption`). Late key arrivals
    /// — backup restores, room-key shares — and rooms opened from the
    /// on-disk snapshot land here. Returns the total decrypted.
    @discardableResult
    public func retryTimelineDecryption() async -> Int {
        var total = 0
        for room in roomCache.values {
            total += await room.retryDecryption()
        }
        return total
    }

    /// Observable view model for a room (cached per ID).
    public func room(_ roomId: RoomId) async -> ObservableRoom {
        if let cached = roomCache[roomId] {
            return cached
        }
        let actor = await store.room(roomId)
        let observable = await ObservableRoom(
            room: actor,
            messages: messages,
            rooms: rooms,
            roomState: roomState,
            accountData: accountData,
            media: media,
            localUser: userId
        )
        observable.encryptSender = { [weak self] roomId, content, txn in
            guard let self else { throw MatrixError.notAuthenticated }
            return try await self.sendEncryptedContent(
                roomId, content, transactionId: txn)
        }
        // Heal senders whose `m.room.member` sync omitted under lazy
        // member loading. `GET /profile/{userId}` reports no membership,
        // so healed entries read as joined senders.
        observable.profileFetcher = { [weak self] userId in
            guard let self else { return nil }
            guard
                let profile = try? await self.profile.getProfile(userId),
                profile.displayname != nil || profile.avatarUrl != nil
            else { return nil }
            return MemberContent(
                membership: .join,
                displayname: profile.displayname,
                avatarUrl: profile.avatarUrl)
        }
        await observable.setTimelineDecryptor(timelineDecryptor)
        roomCache[roomId] = observable
        // Snapshot-backed timelines open as ciphertext; decrypt with
        // whatever sessions the store already holds (persisted across
        // relaunch or imported before this room was opened).
        _ = await observable.retryDecryption()
        return observable
    }

    /// Create a room and return its view model.
    @discardableResult
    public func createRoom(_ request: CreateRoomRequest) async throws -> ObservableRoom {
        let roomId = try await rooms.create(request)
        await roomList.refresh()
        return await room(roomId)
    }

    /// Join a room by ID and return its view model.
    @discardableResult
    public func joinRoom(_ roomId: RoomId) async throws -> ObservableRoom {
        try await rooms.join(roomId)
        try await syncOnce()
        return await room(roomId)
    }

    /// Knock on a room by ID. Syncs after knocking so the `.knock`
    /// membership lands in the store, and returns the knocked room's ID.
    @discardableResult
    public func knockRoom(_ roomId: RoomId, reason: String? = nil) async throws -> RoomId {
        let resolved = try await rooms.knock(roomId, reason: reason)
        try await syncOnce()
        return resolved
    }

    /// Knock on a room by alias. Syncs after knocking so the `.knock`
    /// membership lands in the store, and returns the resolved room ID.
    @discardableResult
    public func knockRoom(_ alias: RoomAlias, reason: String? = nil) async throws -> RoomId {
        let resolved = try await rooms.knock(alias, reason: reason)
        try await syncOnce()
        return resolved
    }

    // MARK: - Profiles & push

    /// Observable profile for a user.
    public func profile(for userId: UserId) -> ObservableUserProfile {
        ObservableUserProfile(
            userId: userId, profiles: profile, media: media, localUser: self.userId)
    }

    /// Observable push-rule management.
    public func pushRules() -> ObservablePushRules {
        ObservablePushRules(push: push)
    }
}
