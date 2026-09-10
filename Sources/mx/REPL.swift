/// mx: interactive REPL over the MatrixKit actor layer.
///
/// In-memory only. Sync runs in a background task; new messages in the
/// open room print live. Input runs off the MainActor (global queue)
/// so the sync loop never starves while waiting for input.
import ArgumentParser
import Foundation
import Logging
import MatrixKit
import MatrixKitCrypto
import MatrixKitSQLite

#if canImport(SwiftData)
    import MatrixKitSwiftData
#endif

/// Snapshot cache backend preference (`--cache`).
enum CachePreference: String, Sendable, ExpressibleByArgument {
    case auto
    case sqlite
    case swiftdata
}

/// Launch configuration, parsed from flags and handed to the REPL.
struct REPLConfig: Sendable {
    var cache: CachePreference = .auto
    var logLevel: Logger.Level?
}

@main
struct Mx: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mx",
        abstract: "Interactive REPL over the MatrixKit SDK."
    )

    @Option(name: .long, help: "Write log output to a file instead of the console.")
    var logFile: String?

    @Option(
        name: .long,
        help:
            "Log level for protocol traffic: trace, debug, info, notice, warning, error, critical."
    )
    var logLevel: String?

    @Option(name: .long, help: "Snapshot cache backend: sqlite, swiftdata, or auto.")
    var cache: CachePreference = .auto

    mutating func run() async throws {
        if let path = logFile {
            do {
                try FileLogging.enable(path: path)
                emit("Logging debug output to \(path)")
            } catch {
                emit("Error: could not open log file at \(path): \(error)")
            }
        }
        await REPL(config: REPLConfig(cache: cache, logLevel: Self.parseLogLevel(logLevel))).run()
    }

    private static func parseLogLevel(_ raw: String?) -> Logger.Level? {
        switch raw?.lowercased() {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "notice": return .notice
        case "warning": return .warning
        case "error": return .error
        case "critical": return .critical
        default: return nil
        }
    }
}

/// Number of timeline events shown when opening a room.
private let openLimit = 20

@MainActor
final class REPL {
    private var client: MatrixClient?
    private var roomOrder: [RoomId] = []
    private var currentRoom: RoomId?
    private var seenEventIds = Set<EventId>()
    private var visibleEvents: [MessageEvent] = []
    private var syncTask: Task<Void, Never>?
    private var running = true
    /// Unlocked 4S storage key from `recover`, kept for `show-secret`.
    private var unlockedStorageKey: (key: Data, keyId: String)?
    /// Backup private key from `recover`, kept for `backup-restore`.
    private var recoveredBackupKey: Data?
    /// Snapshot cache backend, from `--cache`.
    private let cachePreference: CachePreference
    /// Protocol log level for new transports, from `--log-level`
    /// (toggled at runtime by `debug on/off`).
    private var logLevel: Logger.Level?

    init(config: REPLConfig = REPLConfig()) {
        self.cachePreference = config.cache
        self.logLevel = config.logLevel
    }
    /// Incoming `m.key.verification.request` events by sender user ID.
    /// `verify <user>` with no device arg answers a pending request.
    private var pendingVerificationRequests: [String: BasicEvent] = [:]

    /// A verification handshake is running. Second invocations are
    /// refused: two poll loops race `syncOnce` token advancement and
    /// each drops the other's events.
    private var verifyInFlight = false

    /// On-disk state cache (per user, backend-selectable). Loaded after
    /// login for an instant room list; saved debounced on deltas and on quit.
    /// Backend: `--cache sqlite|swiftdata|auto` (default auto: swiftdata
    /// where available, else sqlite).
    private var cache: (any SnapshotCache)?
    private var lastCacheSave = Date.distantPast

    /// Minimum seconds between cache writes during live sync.
    private let cacheSaveInterval: TimeInterval = 30

    // MARK: - Main loop

    func run() async {
        emit("mx — a simple Matrix client. Type 'help' for commands.")
        defer { LineEditor.shared.disableRawMode() }
        while running {
            let prompt = await currentPrompt()
            guard let line = await readEditedLine(prompt: prompt) else { break }
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            guard let command = parseCommand(line) else { continue }
            await execute(command)
        }
        await stopSyncLoop()
        await saveCache(force: true)
        if let client {
            try? await client.transport.shutdown()
        }
        emit("Bye!")
    }

    /// Read a line with history + editing, off the MainActor so the
    /// sync loop never starves while waiting for input.
    private func readEditedLine(prompt: String, recordHistory: Bool = true) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                continuation.resume(
                    returning: LineEditor.shared.readLine(
                        prompt: prompt, recordHistory: recordHistory,
                        leadingNewline: recordHistory))
            }
        }
    }

    /// Timestamped prompt: `[1:58 PM] mx [room] > `.
    private func currentPrompt() async -> String {
        let label: String
        if let client, let roomId = currentRoom {
            let room = await client.store.room(roomId)
            label = "mx [\(await room.displayName())]"
        } else {
            label = "mx"
        }
        return "\(styled(timestamp(), ANSI.dim)) \(styled(label, ANSI.bold + ANSI.cyan))> "
    }

    // MARK: - Commands

    private func execute(_ command: Command) async {
        switch command {
        case .login(let homeserver, let user, let password):
            await doLogin(homeserver: homeserver, user: user, password: password)
        case .loginOAuth(let homeserver):
            await doLoginOAuth(homeserver: homeserver)
        case .restore:
            await doRestore()
        case .logout:
            await doLogout()
        case .rooms:
            await listRooms()
        case .join(let target):
            await doJoin(target: target)
        case .open(let target):
            await doOpen(target: target)
        case .back:
            currentRoom = nil
            seenEventIds = []
            visibleEvents = []
        case .send(let text):
            await requireRoom { client, roomId in
                try await client.messages.sendText(roomId, text)
            }
        case .esend(let text):
            await requireRoom { client, roomId in
                try await client.sendEncryptedText(roomId, text)
            }
        case .sharekey:
            await requireRoom { client, roomId in
                try await client.shareRoomKey(roomId)
            }
        case .reply(let ref, let text):
            guard let eventId = resolveEventRef(ref) else { return }
            await requireRoom { client, roomId in
                try await client.messages.reply(roomId, to: eventId, body: text)
            }
        case .react(let ref, let key):
            guard let eventId = resolveEventRef(ref) else { return }
            await requireRoom { client, roomId in
                try await client.messages.react(roomId, to: eventId, key: key)
            }
        case .members:
            await showMembers()
        case .topic(let newTopic):
            await doTopic(newTopic: newTopic)
        case .leave:
            await doLeave()
        case .verify(let user, let device):
            await doVerify(user: user, device: device)
        case .crosssign:
            await doCrosssign()
        case .crosssignImport(let path):
            await doCrosssignImport(path: path)
        case .exportCrosssign(let path):
            await doExportCrosssign(path: path)
        case .fetchSecrets(let device):
            await doFetchSecrets(device: device)
        case .recover(let secret):
            await doRecover(secret: secret)
        case .showSecret(let name):
            await doShowSecret(name: name)
        case .backupRestore:
            await doBackupRestore()
        case .identity:
            await doIdentity()
        case .pushrules(let room):
            await doPushRules(room: room)
        case .debug(let enabled):
            await doDebug(enabled: enabled)
        case .help:
            printHelp()
        case .quit:
            running = false
        }
    }

    private func doDebug(enabled: Bool?) async {
        if let enabled {
            logLevel = enabled ? .debug : nil
        }
        let level: Logger.Level = logLevel ?? .info
        if let client {
            await client.transport.setLogLevel(level)
        }
        printInfo("Debug logging \(logLevel != nil ? "on" : "off") (level: \(level)).")
    }

    // MARK: - Auth

    private func doLogin(homeserver: String, user: String, password: String) async {
        guard client == nil else {
            printError("Already logged in — logout first.")
            return
        }
        guard let url = URL(string: homeserver), url.scheme != nil else {
            printError("Invalid homeserver URL: \(homeserver)")
            return
        }
        do {
            printInfo("Logging in as \(user)…")
            let client = try await MatrixClient.login(
                homeserver: url, user: user, password: password,
                deviceDisplayName: "mx",
                logLevel: logLevel,
                keystore: olmKeystore())
            await completeLogin(client, label: user)
        } catch {
            printError("Login failed: \(error)")
        }
    }

    private func doLoginOAuth(homeserver: String) async {
        guard client == nil else {
            printError("Already logged in — logout first.")
            return
        }
        guard let url = URL(string: homeserver), url.scheme != nil else {
            printError("Invalid homeserver URL: \(homeserver)")
            return
        }
        do {
            printInfo("Starting OIDC device login…")
            let client = try await MatrixClient.loginViaOIDC(
                homeserver: url,
                clientName: "mx",
                // MAS requires a client_uri and ≥1 redirect_uri even for
                // device-flow clients (the loopback URI is never used).
                clientURI: "https://matrix.org",
                onUserCode: { code, uri, expires in
                    emit(
                        "Open \(uri) and enter code: \(code) "
                            + "(expires in \(expires / 60) min)")
                },
                logLevel: logLevel,
                keystore: olmKeystore())
            // Persist for zero-interaction `restore`.
            if let dir = OIDCAccountStore.defaultDirectory(),
                let userId = client.userId,
                let deviceId = client.deviceId
            {
                let session = client.session
                let account = OIDCAccount(
                    homeserver: url, userId: userId, deviceId: deviceId,
                    clientId: await session.oidcClientId ?? "",
                    tokenEndpoint: await session.oidcTokenEndpoint ?? "",
                    accessToken: await session.accessToken,
                    refreshToken: await session.refreshToken,
                    expiresInSeconds: (await session.expiresInMs).map { $0 / 1000 })
                do {
                    try OIDCAccountStore(directory: dir).save(account)
                } catch {
                    printError("Could not save session: \(error)")
                }
            }
            await completeLogin(client, label: client.userId?.value ?? "OIDC user")
        } catch {
            printError("OIDC login failed: \(error)")
        }
    }

    private func doRestore() async {
        guard client == nil else {
            printError("Already logged in — logout first.")
            return
        }
        guard let dir = OIDCAccountStore.defaultDirectory(),
            let account = OIDCAccountStore(directory: dir).load()
        else {
            printError("No saved OIDC session. Use login-oauth first.")
            return
        }
        do {
            printInfo("Restoring session for \(account.userId.value)…")
            let client = await MatrixClient.restore(
                homeserver: account.homeserver, userId: account.userId,
                deviceId: account.deviceId,
                accessToken: account.accessToken,
                refreshToken: account.refreshToken,
                logLevel: logLevel,
                keystore: olmKeystore())
            await client.session.updateOIDC(
                clientId: account.clientId,
                tokenEndpoint: account.tokenEndpoint)
            // Tokens may have expired on disk: probe, then refresh once.
            do {
                _ = try await client.auth.whoAmI()
            } catch {
                printInfo("Saved token expired, refreshing…")
                try await client.auth.refresh()
            }
            await completeLogin(client, label: account.userId.value)
        } catch {
            printError("Restore failed: \(error)")
        }
    }

    /// Shared post-login path: hydrate cache, incremental sync, live loop.
    private func completeLogin(_ client: MatrixClient, label: String) async {
        self.client = client
        // Hydrate from disk first: instant room list, and the cached
        // sync token turns the sync below into a small incremental one.
        if let userId = client.userId,
            let cache = await makeCache(for: userId)
        {
            self.cache = cache
            do {
                if let snapshot = try await cache.load() {
                    await client.store.restore(snapshot)
                    printInfo(
                        "Loaded cached state (\(snapshot.rooms.count) rooms). Syncing…"
                    )
                    await listRooms()
                }
            } catch {
                printError("Cache unavailable: \(error)")
            }
        }
        do {
            // Lean initial sync: matrix.org ships tens of MiB of full
            // room state unfiltered.
            try await client.sync.syncOnce(filter: .leanInitial)
        } catch {
            try? await client.transport.shutdown()
            self.client = nil
            printError("Login succeeded but initial sync failed: \(error)")
            return
        }
        await listRooms()
        do {
            try await startSyncLoop()
        } catch {
            try? await client.transport.shutdown()
            self.client = nil
            printError("Could not start live sync: \(error)")
            return
        }
        await saveCache(force: true)
        if await ensureDeviceIdentity(client: client) {
            printInfo("Device keys published for \(label).")
        }
        if await client.secrets.autoload() {
            printInfo("Loaded persisted cross-signing keys.")
        }
        printInfo("Logged in as \(label). Live sync running.")
    }

    private func doLogout() async {
        guard let client else {
            printError("Not logged in.")
            return
        }
        await stopSyncLoop()
        await saveCache(force: true)
        do {
            try await client.logout()
        } catch {
            printError("Logout failed: \(error)")
        }
        self.client = nil
        self.cache = nil
        currentRoom = nil
        roomOrder = []
        seenEventIds = []
        visibleEvents = []
        printInfo("Logged out.")
    }

    // MARK: - Rooms

    private func listRooms() async {
        guard let client else {
            printError("Not logged in. Use: login <homeserver> <user> <password>")
            return
        }
        let infos = await client.store.roomInfos()
        let joined = infos.filter { $0.membership == .join }
            .sorted { ($0.name ?? $0.roomId.value) < ($1.name ?? $1.roomId.value) }
        let invited = infos.filter { $0.membership == .invite }
            .sorted { ($0.name ?? $0.roomId.value) < ($1.name ?? $1.roomId.value) }
        roomOrder = joined.map(\.roomId)
        if joined.isEmpty && invited.isEmpty {
            printInfo("No rooms yet. Join one with: join <room-id-or-alias>")
            return
        }
        for (index, info) in joined.enumerated() {
            let room = await client.store.room(info.roomId)
            let unread = await room.unreadCount
            let badge = unread > 0 ? styled(" [\(unread) unread]", ANSI.bold + ANSI.red) : ""
            let name = styled(info.name ?? info.roomId.value, ANSI.bold + ANSI.cyan)
            emit("[\(index)] \(name)\(badge)")
            emit("    \(ANSI.dim)\(info.roomId.value)\(ANSI.reset)")
        }
        for info in invited {
            let name = styled(info.name ?? info.roomId.value, ANSI.bold + ANSI.yellow)
            emit("📩 Invite: \(name)  \(ANSI.dim)\(info.roomId.value)\(ANSI.reset)")
        }
    }

    private func doJoin(target: String) async {
        guard let client else {
            printError("Not logged in.")
            return
        }
        do {
            if target.hasPrefix("#") {
                let alias = try RoomAlias(target)
                try await client.rooms.join(alias)
            } else {
                let roomId = try RoomId(target)
                try await client.rooms.join(roomId)
            }
            try await client.sync.syncOnce()
            await listRooms()
        } catch {
            printError("Join failed: \(error)")
        }
    }

    private func doOpen(target: String) async {
        guard let client else {
            printError("Not logged in.")
            return
        }
        let roomId: RoomId?
        if let index = Int(target), roomOrder.indices.contains(index) {
            roomId = roomOrder[index]
        } else if let id = try? RoomId(target) {
            roomId = id
        } else {
            roomId = nil
        }
        guard let roomId else {
            printError("Unknown room. Use 'rooms' to list, then 'open <number>'.")
            return
        }
        currentRoom = roomId
        seenEventIds = []
        visibleEvents = []
        let room = await client.store.room(roomId)
        let name = await room.displayName()
        let topic = await room.topic
        emit(styled("── \(name) ──", ANSI.bold + ANSI.cyan))
        if let topic, !topic.isEmpty { printInfo("Topic: \(topic)") }
        let localUser = client.userId
        for event in await room.timeline.suffix(openLimit) {
            printTimelineEvent(event, localUser: localUser)
        }
    }

    private func showMembers() async {
        guard let client, let roomId = currentRoom else {
            printError("No room open. Use 'open <number>' first.")
            return
        }
        let room = await client.store.room(roomId)
        let members = await room.members
        for userId in members.keys.sorted(by: { $0.value < $1.value }) {
            let content = members[userId]
            let display = content?.displayname ?? userId.localpart ?? userId.value
            let membership = content?.membership.rawValue ?? "?"
            emit("\(display)  \(styled(userId.value, ANSI.dim))  (\(membership))")
        }
    }

    private func doTopic(newTopic: String?) async {
        guard let client, let roomId = currentRoom else {
            printError("No room open. Use 'open <number>' first.")
            return
        }
        if let newTopic {
            do {
                try await client.roomState.setTopic(roomId, topic: newTopic)
                printInfo("Topic updated.")
            } catch {
                printError("Failed to set topic: \(error)")
            }
        } else {
            let room = await client.store.room(roomId)
            printInfo("Topic: \(await room.topic ?? "(none)")")
        }
    }

    private func doLeave() async {
        guard let client, let roomId = currentRoom else {
            printError("No room open. Use 'open <number>' first.")
            return
        }
        do {
            try await client.rooms.leave(roomId)
            try await client.sync.syncOnce()
            currentRoom = nil
            seenEventIds = []
            visibleEvents = []
            await listRooms()
        } catch {
            printError("Leave failed: \(error)")
        }
    }

    // MARK: - Verification

    private func doCrosssign() async {
        guard let client else {
            printError("Not logged in.")
            return
        }
        do {
            if await !client.crossSigning.hasKeys {
                let keys = await client.crossSigning.generate()
                printInfo("Generated cross-signing keys.")
                emit("  master:       \(keys.master)")
                emit("  self-signing: \(keys.selfSigning)")
                emit("  user-signing: \(keys.userSigning)")
            }
            try await client.crossSigning.upload()
            printInfo("Cross-signing keys uploaded. Back up the private halves!")
        } catch .uiaa(let challenge) {
            await handleCrosssignUIAA(challenge)
        } catch {
            printError("Cross-sign failed: \(error)")
        }
    }

    /// Complete the UIAA challenge from a cross-signing upload. Every path
    /// that uploads REPLACES the server identity — approval only blesses
    /// the replacement. Keeping the identity means aborting and verifying
    /// this device from an existing one (`verify`) instead.
    private func handleCrosssignUIAA(_ challenge: UIAAChallenge) async {
        guard let client else { return }
        let canReset = challenge.offersStage(UIAAChallenge.resetStage)
        let canOAuth = challenge.offersStage(UIAAChallenge.oauthStage)
        guard canReset || canOAuth else {
            printError("No completable UIAA stage: \(MatrixError.uiaa(challenge))")
            return
        }
        emit(styled("Server already holds a cross-signing identity.", ANSI.bold + ANSI.yellow))
        emit("Uploading REPLACES it and unverifies all your devices.")
        emit("To keep it: abort here, then `verify` this device from an existing one.")
        var oauthKey = ""
        var resetKey = ""
        var n = 0
        if canOAuth {
            n += 1
            oauthKey = "\(n)"
            if let url = challenge.approvalURL(for: UIAAChallenge.oauthStage) {
                emit("[\(oauthKey)] Approve in a browser, then retry the upload: \(url)")
            } else {
                emit("[\(oauthKey)] Approve on your account, then retry the upload")
            }
        }
        if canReset {
            n += 1
            resetKey = "\(n)"
            emit("[\(resetKey)] RESET now (replaces the identity immediately)")
        }
        emit("Anything else aborts — existing identity untouched.")
        let choice = await readEditedLine(prompt: "Choice: ", recordHistory: false) ?? ""
        if !oauthKey.isEmpty, choice == oauthKey {
            _ = await readEditedLine(
                prompt: "Press enter after approving: ", recordHistory: false)
            do {
                try await client.crossSigning.upload(
                    auth: UIAAuth(
                        type: UIAAChallenge.oauthStage,
                        session: challenge.session))
                printInfo(
                    "Cross-signing keys uploaded — old identity replaced. Back up the private halves!"
                )
            } catch {
                printError("Cross-sign failed: \(error)")
            }
            return
        }
        if !resetKey.isEmpty, choice == resetKey {
            emit("Resetting WIPES the server identity and unverifies all your devices.")
            guard
                await readEditedLine(
                    prompt: "Type RESET to replace the identity, anything else to abort: ",
                    recordHistory: false) == "RESET"
            else {
                printInfo("Aborted — existing identity untouched.")
                return
            }
            do {
                try await client.crossSigning.uploadWithReset()
                printInfo("Identity reset and keys uploaded. Back up the private halves!")
            } catch {
                printError("Cross-sign reset failed: \(error)")
            }
            return
        }
        printInfo(
            "Aborted — existing identity untouched. `identity` inspects it; `verify` trusts this device instead."
        )
    }

    /// Show the server-side cross-signing identity and compare it with the
    /// keys held locally. Read-only — safe to run any time.
    private func doIdentity() async {
        guard let client else {
            printError("Not logged in.")
            return
        }
        guard let userId = client.userId else {
            printError("No user ID in session.")
            return
        }
        emit("This device:")
        emit("  user ID: \(userId.value)")
        if let deviceId = client.deviceId {
            emit("  device ID: \(deviceId.value)")
            if let backup = await DeviceIdentityStore(keystore: olmKeystore())
                .load(userId: userId, deviceId: deviceId),
                let material = try? DeviceIdentityKeys.restore(backup),
                let curvePublic = try? material.curve25519Public()
            {
                emit("  ed25519: \(material.signing.publicKeyBase64)")
                emit("  curve25519: \(Primitives.base64UnpaddedEncode(curvePublic))")
            } else {
                emit("  (no local device identity stored)")
            }
        } else {
            emit("  device ID: (none in session)")
        }
        emit("  Olm configured: \(await client.olm.isConfigured ? "yes" : "no")")
        emit("  pending secret requests: \(await client.secrets.pendingCount)")
        do {
            let response = try await client.crossSigning.fetchKeys(users: [userId])
            guard let master = response.masterKeys?[userId.value] else {
                printInfo(
                    "Server holds no cross-signing identity for \(userId.value). `crosssign` will create one."
                )
                return
            }
            emit("Server identity for \(userId.value):")
            for keyId in master.keys.keys.sorted() {
                emit("  master \(keyId): \(master.keys[keyId] ?? "")")
            }
            if let local = await client.crossSigning.publicKeys {
                emit("Local public keys: master \(local.master)")
                if master.keys.values.contains(local.master) {
                    printInfo("Local keys match the server identity.")
                } else {
                    emit(
                        styled(
                            "Local keys do NOT match the server identity.", ANSI.bold + ANSI.yellow)
                    )
                }
            } else {
                printInfo(
                    "This device holds no cross-signing private keys (normal unless you ran `crosssign` here)."
                )
            }
        } catch {
            printError("Identity check failed: \(error)")
        }
    }

    /// Show per-room notification modes from the server push rules.
    /// Read-only — safe to run any time. Without an argument, lists
    /// every room with custom rules; with a room ID, shows that room.
    private func doPushRules(room filter: String?) async {
        guard let client else {
            printError("Not logged in.")
            return
        }
        do {
            if let filter {
                // Accept bare room IDs some servers emit (no `:server` part).
                let roomId = (try? RoomId(filter)) ?? RoomId(unchecked: filter)
                if let mode = try await client.notifications
                    .getRoomNotificationMode(roomId: roomId)
                {
                    emit("\(roomId.value): \(mode)")
                } else {
                    emit("\(roomId.value): (default applies)")
                }
                let ruleset = try await client.notifications.pushRulesSnapshot()
                let matched: [(kind: String, rule: PushRule)] = [
                    "override", "room",
                ].flatMap { kind in
                    (ruleset.global[kind] ?? []).filter {
                        $0.ruleId == roomId.value
                            || json($0.conditions ?? []).contains(roomId.value)
                    }.map { (kind, $0) }
                }
                if matched.isEmpty {
                    printInfo("No override/room rules reference this room.")
                }
                for (kind, rule) in matched {
                    emit(
                        "  [\(kind)] \(rule.ruleId) enabled=\(rule.enabled) default=\(rule.isDefault)"
                    )
                    emit("    conditions: \(json(rule.conditions ?? []))")
                    emit("    actions: \(json(rule.actions))")
                }
                return
            }
            let customs = try await client.notifications
                .roomsWithCustomNotificationSettings()
            if customs.isEmpty {
                printInfo("No rooms with custom notification rules.")
                return
            }
            for roomId in customs.sorted(by: { $0.value < $1.value }) {
                let mode = try await client.notifications
                    .getRoomNotificationMode(roomId: roomId)
                emit("\(roomId.value): \(mode.map { "\($0)" } ?? "(default applies)")")
            }
        } catch {
            printError("Push-rules fetch failed: \(error)")
        }
    }

    /// Ask our own (or a peer's) devices to share cross-signing private
    /// halves via `m.secret.request`. Answers arrive as `m.secret.send`
    /// and auto-import when all three halves are banked.
    private func doFetchSecrets(device: String?) async {
        guard let client, let userId = client.userId else {
            printError("Not logged in.")
            return
        }
        do {
            let ids = try await client.secrets.requestSecrets(
                from: userId, deviceId: device)
            printInfo(
                "Requested cross-signing secrets (\(ids.count) requests). Approve the share on another device."
            )
        } catch {
            printError("Secret request failed: \(error)")
        }
    }

    /// Unlock 4S secret storage and import the cross-signing keys.
    /// `Es…` input is treated as a recovery key, anything else as a
    /// passphrase. Retains the storage key (for `show-secret`) and the
    /// backup private key (for `backup-restore`).
    private func doRecover(secret: String) async {
        guard let client else {
            printError("Not logged in.")
            return
        }
        let stripped = secret.filter { !$0.isWhitespace }
        do {
            printInfo("Unlocking secret storage…")
            let unlocked: (key: Data, keyId: String)
            if stripped.hasPrefix("Es") {
                unlocked = try await client.secretStorage.unlock(
                    recoveryKey: secret)
            } else {
                printInfo("Deriving key from passphrase (this takes a moment)…")
                unlocked = try await client.secretStorage.unlock(
                    passphrase: secret)
            }
            unlockedStorageKey = unlocked
            let outcome = try await client.recover(
                storageKey: unlocked.key, keyId: unlocked.keyId)
            recoveredBackupKey = outcome.backupPrivateKey
            if outcome.crossSigningImported {
                printInfo("Recovery complete: cross-signing keys imported.")
            } else {
                printInfo(
                    "Recovery complete, but no cross-signing secrets are stored.")
            }
            if outcome.backupPrivateKey != nil {
                printInfo(
                    "A megolm backup key was recovered; run `backup-restore` to import sessions.")
            }
        } catch {
            printError("Recovery failed: \(error)")
        }
    }

    /// Decrypt one stored secret with the key `recover` unlocked,
    /// printing only a prefix (secrets never hit the terminal whole).
    private func doShowSecret(name: String) async {
        guard let client else {
            printError("Not logged in.")
            return
        }
        guard let unlocked = unlockedStorageKey else {
            printError("No unlocked storage key — run `recover` first.")
            return
        }
        do {
            guard
                let value = try await client.secretStorage.secret(
                    name, keyId: unlocked.keyId, storageKey: unlocked.key)
            else {
                printInfo("No secret named \(name) is stored.")
                return
            }
            printInfo("\(name): \(value.prefix(12))… (\(value.count) chars)")
        } catch {
            printError("Could not decrypt \(name): \(error)")
        }
    }

    /// Download and import backed-up megolm sessions with the backup
    /// private key `recover` retained. A separate step from recovery:
    /// restores are large and deserve their own progress line.
    private func doBackupRestore() async {
        guard let client else {
            printError("Not logged in.")
            return
        }
        guard let privateKey = recoveredBackupKey else {
            printError("No backup key — run `recover` first.")
            return
        }
        do {
            printInfo("Downloading backed-up sessions…")
            let count = try await client.restoreKeyBackup(privateKey: privateKey)
            printInfo("Restored \(count) megolm sessions.")
        } catch {
            printError("Backup restore failed: \(error)")
        }
    }

    /// Import cross-signing private halves from a JSON backup file
    /// (the `CrossSigningBackup` shape `export-crosssign` writes), then
    /// persist them to the local 0600 store.
    private func doCrosssignImport(path: String) async {
        guard let client else {
            printError("Not logged in.")
            return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let backup = try JSONDecoder().decode(CrossSigningBackup.self, from: data)
            try await client.crossSigning.importPrivateKeys(
                master: backup.masterPrivateKey,
                selfSigning: backup.selfSigningPrivateKey,
                userSigning: backup.userSigningPrivateKey)
            guard await client.secrets.persist() else {
                printError("Keys imported for this session, but persisting them failed.")
                return
            }
            printInfo("Cross-signing keys imported and persisted.")
        } catch {
            printError("Import failed: \(error)")
        }
    }

    /// Export cross-signing private halves to a JSON backup file (0600).
    /// Handle the file as a secret — it grants signing power.
    private func doExportCrosssign(path: String) async {
        guard let client else {
            printError("Not logged in.")
            return
        }
        guard
            let keys = await client.crossSigning.exportPrivateKeys()
        else {
            printError("No local cross-signing keys to export.")
            return
        }
        do {
            let backup = CrossSigningBackup(
                masterPrivateKey: keys.master,
                selfSigningPrivateKey: keys.selfSigning,
                userSigningPrivateKey: keys.userSigning)
            let data = try JSONEncoder().encode(backup)
            let url = URL(fileURLWithPath: path)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            printInfo("Cross-signing keys exported to \(path) (mode 0600).")
        } catch {
            printError("Export failed: \(error)")
        }
    }

    /// Interactive SAS verification, driven by the verification monitor:
    /// request (or accept a pending request) → the monitor sends
    /// start/accept/keys itself → compare emoji → the monitor MACs and
    /// finishes. Live sync stays up so the monitor sees peer traffic.
    private func doVerify(user: String, device: String?) async {
        guard !verifyInFlight else {
            printError(
                "A verification is already running; wait for it to finish.")
            return
        }
        verifyInFlight = true
        defer { verifyInFlight = false }
        guard let client else {
            printError("Not logged in.")
            return
        }
        guard let peer = try? UserId(user) else {
            printError("Invalid user ID: \(user)")
            return
        }
        // Our device must have published keys or peers won't surface the
        // request (covers logins from before key upload existed).
        guard await ensureDeviceIdentity(client: client) else {
            printError("Verify aborted: no device identity.")
            return
        }
        do {
            let monitor = client.verifications
            // Subscribe before starting: our flow's events can't predate
            // the subscription, so nothing is missed.
            let stream = await monitor.events()
            let session: VerificationSession
            if device == nil,
                let request = pendingVerificationRequests.removeValue(
                    forKey: peer.value),
                let body: VerificationRequest = decodeToDevice(request)
            {
                // Answer their request (responder role).
                session = try await monitor.acceptRequest(
                    IncomingVerificationRequest(
                        transactionId: body.transactionId, sender: peer,
                        deviceId: body.fromDevice))
                printInfo(
                    "Request accepted. Waiting for \(peer.value) to start…")
            } else {
                session = try await monitor.requestVerification(
                    userId: peer, deviceId: device)
                printInfo(
                    "Verification requested. Ask \(peer.value) to accept on their device…")
            }
            let txn = await session.transactionId
            let (emoji, decimals) = try await waitForSAS(
                stream: stream, transactionId: txn, session: session,
                timeout: 300)
            emit("Compare these emoji with \(peer.value)'s device:")
            emit("  " + emoji.map(\.emoji).joined(separator: "  "))
            emit("  (" + emoji.map(\.description).joined(separator: ", ") + ")")
            emit("  decimals: " + decimals.map(String.init).joined(separator: "-"))
            let answer = await readEditedLine(prompt: "Do they match? (yes/no) ", recordHistory: false)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard answer == "yes" || answer == "y" else {
                try? await session.cancel(
                    code: "m.mismatched_sas", reason: "User rejected SAS")
                await monitor.removeSession(transactionId: txn)
                printInfo("Verification cancelled.")
                return
            }
            // MAC our keys, verify theirs, done (monitor-driven).
            try await monitor.confirm(session)
            try await waitForFinished(
                monitor: monitor, session: session, transactionId: txn,
                timeout: 120)
            await monitor.removeSession(transactionId: txn)
            await postVerify(client: client, session: session, peer: peer)
        } catch {
            printError("Verify failed: \(error)")
        }
    }

    /// Wait for the monitor's SAS event for a flow (or its failure).
    private func waitForSAS(
        stream: AsyncStream<VerificationMonitorEvent>,
        transactionId: String,
        session: VerificationSession,
        timeout: TimeInterval
    ) async throws -> ([SASEmoji], [Int]) {
        try await withThrowingTaskGroup(of: ([SASEmoji], [Int]).self) { group in
            group.addTask {
                for await event in stream {
                    switch event {
                    case .sasReady(let txn, let emoji, let decimals)
                        where txn == transactionId:
                        return (emoji, decimals)
                    case .failed(let txn, let message)
                        where txn == transactionId:
                        throw MatrixError.verificationFailed(message)
                    case .sessionFinished(let txn)
                        where txn == transactionId:
                        throw MatrixError.verificationFailed(
                            "Verification finished before SAS was shown")
                    default:
                        break
                    }
                }
                throw MatrixError.verificationFailed("Verification stream ended")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Int(timeout)))
                try? await session.cancel(code: "m.timeout", reason: "Timed out")
                throw MatrixError.verificationFailed("Timed out waiting for peer")
            }
            guard let result = try await group.next() else {
                throw MatrixError.verificationFailed("Timed out waiting for peer")
            }
            group.cancelAll()
            return result
        }
    }

    /// Wait for a flow to finish after approval (or its failure). Checks
    /// terminal state first: the peer may have settled the flow while the
    /// user was comparing emoji, before this subscription existed.
    private func waitForFinished(
        monitor: VerificationMonitor,
        session: VerificationSession,
        transactionId: String,
        timeout: TimeInterval
    ) async throws {
        // Subscribe first, then check state: a flow that settled before
        // the subscription shows terminal state; one that settles after
        // arrives on the stream. Nothing in between is missed.
        let stream = await monitor.events()
        if await session.state == .done { return }
        if await session.state == .cancelled {
            throw MatrixError.verificationFailed("Peer cancelled the verification")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream {
                    switch event {
                    case .sessionFinished(let txn) where txn == transactionId:
                        return
                    case .failed(let txn, let message)
                        where txn == transactionId:
                        throw MatrixError.verificationFailed(message)
                    default:
                        break
                    }
                }
                throw MatrixError.verificationFailed("Verification stream ended")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Int(timeout)))
                try? await session.cancel(code: "m.timeout", reason: "Timed out")
                throw MatrixError.verificationFailed("Timed out waiting for peer MACs")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Drive the responder side: ready → wait for start → accept → keys,
    /// then the shared SAS comparison + MAC exchange. The requester sends
    /// `start`; we answer with `accept`.
    /// Post-verify key handling: sign the peer device when we hold
    /// cross-signing keys, else request our secrets from the peer.
    private func postVerify(
        client: MatrixClient, session: VerificationSession, peer: UserId
    ) async {
        // Mark the device verified with our self-signing key when available.
        if let deviceId = await session.peerDeviceId,
            await client.crossSigning.hasKeys
        {
            do {
                try await client.crossSigning.signDevice(
                    userId: peer, deviceId: DeviceId(deviceId))
                printInfo("Verified and signed \(peer.value):\(deviceId).")
            } catch {
                printError("Verified, but signing failed: \(error)")
            }
        } else {
            printInfo(
                "Verified \(peer.value). (No local cross-signing keys — requesting them from the peer…)"
            )
            if let deviceId = await session.peerDeviceId {
                do {
                    _ = try await client.secrets.requestSecrets(
                        from: peer, deviceId: deviceId)
                    printInfo(
                        "Secret request sent. Ask the peer to approve sharing on their device.")
                } catch {
                    printError("Secret request failed: \(error)")
                }
            }
        }
    }

    /// Decode a to-device event's content into a message struct.
    private func decodeToDevice<T: Decodable>(_ event: BasicEvent) -> T? {
        guard
            let data = try? JSONEncoder().encode(AnyCodableDictionary(event.content)),
            let value = try? JSONDecoder().decode(T.self, from: data)
        else { return nil }
        return value
    }

    // MARK: - Sync

    private func startSyncLoop() async throws {
        guard let client else { return }
        let stream = try await client.sync.start(filter: .leanInitial)
        syncTask = Task {
            for await delta in stream {
                await self.handleDelta(delta)
            }
        }
    }

    private func stopSyncLoop() async {
        syncTask?.cancel()
        syncTask = nil
        if let client {
            await client.sync.stop()
        }
    }

    private func handleDelta(_ delta: SyncDelta) async {
        guard let client else { return }
        // Decrypt Olm to-device first: encrypted answers (m.secret.send,
        // verification events) arrive as m.room.encrypted.
        var toDevice = delta.toDevice
        if await client.olm.isConfigured {
            let decrypted = await client.olm.decrypt(delta.toDevice)
            if logLevel != nil {
                for event in decrypted {
                    emit("🔍 Decrypted \(event.type) from \(event.sender?.value ?? "?")")
                }
            }
            toDevice += decrypted
        }
        for event in toDevice where event.type == "m.secret.send" {
            switch await client.secrets.receive(event) {
            case .ignored:
                break
            case .unknownRequest:
                if logLevel != nil {
                    let requestId: String
                    if let data = try? JSONEncoder().encode(
                        AnyCodableDictionary(event.content)),
                        let send = try? JSONDecoder().decode(
                            SecretSend.self, from: data)
                    {
                        requestId = send.requestId
                    } else {
                        requestId = "(undecodable)"
                    }
                    let pending = await client.secrets.pendingCount
                    emit(
                        "🔍 Ignoring m.secret.send from \(event.sender?.value ?? "?") (request_id \(requestId), \(pending) pending)"
                    )
                }
            case .stored(let name):
                emit("\n🔑 Received secret \(name)…")
            case .completed:
                emit("\n🔑 Cross-signing keys received, imported, and persisted.")
            }
        }
        for event in toDevice
        where event.type == "m.key.verification.request" {
            guard let sender = event.sender else { continue }
            pendingVerificationRequests[sender.value] = event
            let from = event.content["from_device"]?.stringValue ?? "?"
            emit(
                "\n🔐 \(styled(sender.value, ANSI.bold)) (\(from)) "
                    + "wants to verify. Run "
                    + styled("verify \(sender.value)", ANSI.bold)
                    + " to answer.")
        }
        for (roomId, invite) in delta.invited {
            let name =
                invite.events.first(where: {
                    $0.type == EventType.roomName.rawValue
                })?.content["name"]?.stringValue ?? roomId.value
            let from = invite.inviter.map(\.value) ?? "?"
            emit("\n📩 Invite to \(styled(name, ANSI.bold + ANSI.yellow)) from \(from)")
        }
        if let roomId = currentRoom {
            if delta.left[roomId] != nil {
                emit(
                    "\n\(styled("You left or were removed from this room.", ANSI.bold + ANSI.red))")
                currentRoom = nil
                seenEventIds = []
                visibleEvents = []
                return
            }
            if let joined = delta.joined[roomId] {
                for event in joined.timeline where !seenEventIds.contains(event.eventId) {
                    printTimelineEvent(event, localUser: client.userId, prefix: "\n")
                }
            }
        }
        await saveCache()
    }

    /// File-backed key store for Olm session persistence, or nil when no
    /// cache directory is available (Olm state then stays in-memory only).
    private func olmKeystore() -> (any KeyStore)? {
        OIDCAccountStore.defaultDirectory().map {
            FileKeyStore(directory: $0)
        }
    }

    /// Load-or-generate our device identity and publish its keys.
    ///
    /// Without uploaded device keys the server knows nothing about this
    /// device: `/keys/query` omits it and other clients won't surface our
    /// verification requests. Best-effort: warns and continues on failure.
    /// Returns false only when no identity could be established.
    @discardableResult
    private func ensureDeviceIdentity(client: MatrixClient) async -> Bool {
        guard
            let userId = client.userId, let deviceId = client.deviceId
        else { return false }
        let store = DeviceIdentityStore(keystore: olmKeystore())
        let identity = DeviceIdentity(
            transport: client.transport, session: client.session)
        do {
            if let backup = await store.load(userId: userId, deviceId: deviceId) {
                try await identity.restore(backup)
            } else {
                await identity.generate()
                if let backup = await identity.backup() {
                    try await store.save(backup, userId: userId, deviceId: deviceId)
                }
            }
            try await identity.upload()
            // Bring up Olm key exchange on the same identity: configure
            // the connector, then publish a signed one-time-key pool.
            // Best-effort like the upload above.
            do {
                guard let backup = await identity.backup() else { return true }
                let material = try DeviceIdentityKeys.restore(backup)
                try await client.olm.configure(
                    identity: material, userId: userId, deviceId: deviceId)
                try await client.olm.ensureKeys()
            } catch {
                printError(
                    "Could not publish one-time keys (\(error)). Encrypted "
                        + "secret exchange and verification will be unavailable.")
            }
            return true
        } catch {
            printError(
                "Could not publish device keys (\(error)). Other devices "
                    + "may not show verification requests from this session.")
            return false
        }
    }

    /// Build the snapshot cache for a user. Backend from `--cache`
    /// (`sqlite`, `swiftdata`, or `auto`); auto picks SwiftData where
    /// available, else SQLite. Nil when no directory is available or
    /// the store won't open.
    private func makeCache(for userId: UserId) async -> (any SnapshotCache)? {
        let preference = cachePreference
        #if canImport(SwiftData)
            if preference != .sqlite,
                let file = SwiftDataCache.databaseURL(for: userId),
                let cache = try? SwiftDataCache(database: file)
            {
                printInfo("Cache backend: SwiftData.")
                return cache
            }
        #endif
        if preference != .swiftdata,
            let file = SQLiteCache.databaseURL(for: userId),
            let cache = try? SQLiteCache(database: file)
        {
            printInfo("Cache backend: SQLite.")
            return cache
        }
        return nil
    }

    /// Persist the store snapshot, debounced during live sync so a large
    /// cache (matrix.org: hundreds of rooms) isn't rewritten per delta.
    private func saveCache(force: Bool = false) async {
        guard let cache, let client else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastCacheSave) >= cacheSaveInterval else {
            return
        }
        lastCacheSave = now
        do {
            try await cache.save(await client.store.snapshot())
        } catch {
            printError("Cache save failed: \(error)")
        }
    }

    // MARK: - Helpers

    /// Run a closure against the open room, reporting errors.
    private func requireRoom(
        _ action: (MatrixClient, RoomId) async throws -> Void
    ) async {
        guard let client, let roomId = currentRoom else {
            printError("No room open. Use 'open <number>' first.")
            return
        }
        do {
            try await action(client, roomId)
        } catch {
            printError("\(error)")
        }
    }

    /// Resolve `$event-id` or a 1-based list number to an event ID.
    private func resolveEventRef(_ ref: String) -> EventId? {
        if ref.hasPrefix("$") {
            return EventId(unchecked: ref)
        }
        guard let number = Int(ref),
            visibleEvents.indices.contains(number - 1)
        else {
            printError("Unknown message reference: \(ref). Use a list number or $event-id.")
            return nil
        }
        return visibleEvents[number - 1].eventId
    }

    /// Print an event with its 1-based list number, tracking it for reply/react.
    private func printTimelineEvent(
        _ event: MessageEvent, localUser: UserId?, prefix: String = ""
    ) {
        guard let line = formatEvent(event, localUser: localUser) else { return }
        if !seenEventIds.contains(event.eventId) {
            seenEventIds.insert(event.eventId)
            visibleEvents.append(event)
        }
        let number = (visibleEvents.firstIndex(of: event) ?? 0) + 1
        emit("\(prefix)[\(number)] \(line)")
    }
}
