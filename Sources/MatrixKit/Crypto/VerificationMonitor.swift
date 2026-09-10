/// Incoming verification request surfaced to UI.
public struct IncomingVerificationRequest: Hashable, Sendable, Identifiable {
    /// The flow ID (the request's transaction ID).
    public var id: String { transactionId }
    /// The flow ID shared by all messages in the flow.
    public var transactionId: String
    /// Who sent the request.
    public var sender: UserId
    /// The requesting device ID.
    public var deviceId: String

    public init(transactionId: String, sender: UserId, deviceId: String) {
        self.transactionId = transactionId
        self.sender = sender
        self.deviceId = deviceId
    }
}

/// Verification lifecycle events for UI observers.
public enum VerificationMonitorEvent: Hashable, Sendable {
    /// An incoming `m.key.verification.request` arrived.
    case requestReceived(IncomingVerificationRequest)
    /// Both ephemeral keys exchanged; the user can compare SAS now.
    case sasReady(transactionId: String, emoji: [SASEmoji], decimals: [Int])
    /// A flow failed (after a best-effort cancel). Always paired with a
    /// following `sessionFinished` for the same transaction.
    case failed(transactionId: String, message: String)
    /// A flow reached `done` or `cancelled`.
    case sessionFinished(transactionId: String)
}

/// Watches decrypted to-device traffic for verification flows.
///
/// Surfaces incoming requests, routes ready/start/key/accept/mac/done/
/// cancel messages into their sessions, and vends outgoing sessions.
/// MAC peer keys resolve through `macKeysProvider`, which defaults to
/// the peer's device plus master keys (what Element MACs). Our own MAC
/// keys resolve through `ownKeysProvider`, which defaults to this
/// device's ed25519 keys.
///
/// The monitor drives each flow's outbound side automatically: after any
/// state change it sends whatever the state and role make sendable
/// (start/accept/key/done). The only explicit client actions are
/// starting/accepting, `confirm(session:)` after the user approves the
/// SAS match, and cancel/decline.
import Foundation

public actor VerificationMonitor {
    /// Requests older than this are ignored as stale.
    nonisolated static let requestFreshnessMs = 10 * 60 * 1000

    private let toDevice: ToDeviceClient
    private let olm: OlmConnector
    private let session: Session
    private let keys: KeyClient
    private var sessions: [String: VerificationSession] = [:]
    /// Unresolved incoming requests (removed on accept, decline, or finish).
    public private(set) var pendingRequests: [IncomingVerificationRequest] = []
    private var continuations: [AsyncStream<VerificationMonitorEvent>.Continuation] = []

    /// Keys to verify against an incoming MAC, by peer. Defaults to the
    /// peer's device keys plus master key.
    public var macKeysProvider:
        ((UserId) async throws(MatrixError) -> [VerificationSession.KeyToMAC])?

    /// Our keys to MAC when the user approves a match, by user. Defaults
    /// to this device's ed25519 keys; apps add the cross-signing master.
    public var ownKeysProvider:
        ((UserId) async throws(MatrixError) -> [VerificationSession.KeyToMAC])?

    /// Set the override for our MAC keys (see `ownKeysProvider`).
    public func setOwnKeysProvider(
        _ provider: @escaping @Sendable (UserId) async throws(MatrixError)
            -> [VerificationSession.KeyToMAC]
    ) {
        ownKeysProvider = provider
    }

    /// Set the override for peer MAC keys (see `macKeysProvider`).
    public func setMacKeysProvider(
        _ provider: @escaping @Sendable (UserId) async throws(MatrixError)
            -> [VerificationSession.KeyToMAC]
    ) {
        macKeysProvider = provider
    }

    /// Test seam: when set, `sender()` returns this instead of the
    /// Olm/plaintext transport. Lets driver tests run without a server.
    var senderOverride: (any ToDeviceSender)?

    /// Set the test transport override (see `senderOverride`).
    func setSenderOverrideForTesting(_ sender: any ToDeviceSender) {
        senderOverride = sender
    }

    /// Test hook: live `events()` subscriptions. Broadcast events only
    /// reach registered continuations, so tests spin on this before
    /// producing traffic — otherwise a slow subscriber task misses them.
    var subscriberCount: Int { continuations.count }

    /// Flows already surfaced via `sasReady` (notified once per flow).
    private var sasNotified: Set<String> = []

    public init(
        toDevice: ToDeviceClient, olm: OlmConnector, session: Session, keys: KeyClient
    ) {
        self.toDevice = toDevice
        self.olm = olm
        self.session = session
        self.keys = keys
    }

    /// Subscribe to request/finish events. Ends on cancellation.
    public func events() -> AsyncStream<VerificationMonitorEvent> {
        let (stream, continuation) = AsyncStream<VerificationMonitorEvent>.makeStream()
        continuations.append(continuation)
        return stream
    }

    private func notify(_ event: VerificationMonitorEvent) {
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    /// Route decrypted to-device events into verification flows.
    /// Unknown types, unknown flows, stale requests, and our own
    /// device's echoes are ignored.
    public func receive(_ events: [BasicEvent]) async {
        for event in events {
            await receiveOne(event)
        }
    }

    /// The live session for a flow, if tracked.
    public func session(for transactionId: String) -> VerificationSession? {
        sessions[transactionId]
    }

    /// Drop a finished session. Sessions persist until removed so the UI
    /// can read terminal state after `.sessionFinished`.
    public func removeSession(transactionId: String) {
        sessions.removeValue(forKey: transactionId)
    }

    private func dropRequest(transactionId: String) {
        pendingRequests.removeAll { $0.transactionId == transactionId }
    }

    /// Start verifying a peer device (requester role).
    @discardableResult
    public func requestVerification(
        userId: UserId, deviceId: String?
    ) async throws(MatrixError) -> VerificationSession {
        let (ourUser, ourDevice) = try await identity()
        let recipients: [String]
        if let deviceId {
            recipients = [deviceId]
        } else if userId == ourUser {
            recipients = await broadcastRecipients(
                user: userId, excluding: ourDevice)
        } else {
            recipients = ["*"]
        }
        let session = VerificationSession(
            toDevice: await sender(),
            role: .requester,
            ourUserId: ourUser,
            ourDeviceId: ourDevice,
            peerUserId: userId,
            peerDeviceId: deviceId,
            peerDevices: recipients)
        try await session.sendRequest()
        sessions[session.transactionId] = session
        return session
    }

    /// Recipients for a self-verify broadcast: every device but ours, so
    /// the server never echoes our own request back at us. Falls back to
    /// `"*"` when the device list can't be resolved or names only us —
    /// any echo that comes back is dropped by the ingress self-check in
    /// `receiveRequest`.
    private func broadcastRecipients(user: UserId, excluding device: String) async -> [String] {
        guard let ids = try? await olm.deviceIds(for: user) else { return ["*"] }
        let others = ids.filter { $0 != device }
        return others.isEmpty ? ["*"] : others
    }

    /// Accept an incoming request (responder role).
    @discardableResult
    public func acceptRequest(
        _ request: IncomingVerificationRequest
    ) async throws(MatrixError) -> VerificationSession {
        let (ourUser, ourDevice) = try await identity()
        let session = VerificationSession(
            toDevice: await sender(),
            role: .responder,
            ourUserId: ourUser,
            ourDeviceId: ourDevice,
            peerUserId: request.sender,
            peerDeviceId: request.deviceId,
            peerDevices: [request.deviceId],
            transactionId: request.transactionId)
        try await session.sendReady()
        sessions[request.transactionId] = session
        dropRequest(transactionId: request.transactionId)
        return session
    }

    /// Decline an incoming request.
    public func declineRequest(_ request: IncomingVerificationRequest) async throws(MatrixError) {
        sessions.removeValue(forKey: request.transactionId)
        dropRequest(transactionId: request.transactionId)
        try await sender().send(
            eventType: "m.key.verification.cancel",
            content: VerificationCancel(
                code: "m.user", reason: "", transactionId: request.transactionId),
            to: request.sender,
            devices: [request.deviceId])
    }

    /// MAC our keys after the user approves the SAS match, then advance
    /// the flow (sends `done` when the peer's MAC is already in).
    public func confirm(
        _ session: VerificationSession
    ) async throws(MatrixError) {
        try await session.confirm(keysToMac: ownKeys(for: session))
        await drive(session)
    }

    // MARK: - Private

    /// Advance our side of a flow after any state change: send whatever
    /// the current state and role make sendable, surface SAS when ready,
    /// and finish on terminal states. User approval (`confirm`) and
    /// cancellation stay explicit; everything else is automatic.
    ///
    /// Only `confirm`/`sendDone` retry transient failures internally —
    /// resending start/accept/key after a lost response could confuse the
    /// peer, so those surface as `.failed` immediately.
    private func drive(_ session: VerificationSession) async {
        do {
            switch await session.state {
            case .requested:
                break
            case .ready:
                // Requester starts after ready; the responder waits for
                // the peer's start (adopted via the session tie-break).
                if session.role == .requester {
                    try await session.sendStart()
                }
            case .started:
                // The peer started (we didn't): accept and send our key.
                // When we started, wait for the peer's accept instead.
                if await !session.weSentStart {
                    try await session.sendAccept()
                    try await session.sendKey()
                }
            case .accepted:
                // The peer accepted our start: send our key (once).
                if await !session.ourKeySent {
                    try await session.sendKey()
                }
            case .keysExchanged:
                if sasNotified.insert(session.transactionId).inserted {
                    notify(.sasReady(
                        transactionId: session.transactionId,
                        emoji: await session.sasEmoji(),
                        decimals: await session.sasDecimals()))
                }
            case .macSent:
                break
            case .macReceived:
                // Only close the flow once WE have approved too (our MAC
                // sent). A peer that approves first must neither complete
                // our side for us nor block our later approval.
                if await session.ourMacSent {
                    try await session.sendDone()
                }
            case .done, .cancelled:
                break
            }
            let state = await session.state
            if state == .done || state == .cancelled {
                dropRequest(transactionId: session.transactionId)
                notify(.sessionFinished(transactionId: session.transactionId))
            }
        } catch {
            await fail(session, with: error)
        }
    }

    /// Cancel a broken flow best-effort and surface why. Always paired
    /// with a following `sessionFinished` for the same transaction.
    private func fail(_ session: VerificationSession, with error: Error) async {
        try? await session.cancel()
        dropRequest(transactionId: session.transactionId)
        notify(.failed(
            transactionId: session.transactionId,
            message: (error as? MatrixError)?.description
                ?? error.localizedDescription))
        notify(.sessionFinished(transactionId: session.transactionId))
    }

    /// Encrypted transport when Olm is up, plaintext otherwise.
    private func sender() async -> any ToDeviceSender {
        if let override = senderOverride { return override }
        if await olm.isConfigured {
            return EncryptedToDeviceSender(olm: olm)
        }
        return toDevice
    }

    private func identity() async throws(MatrixError) -> (UserId, String) {
        let deviceId = await session.deviceId.value
        guard !deviceId.isEmpty else {
            throw .notAuthenticated
        }
        return (await session.userId, deviceId)
    }

    private func decode<T: Decodable>(_ type: T.Type, from event: BasicEvent) -> T? {
        guard
            let data = try? JSONEncoder().encode(event.content),
            let value = try? JSONDecoder().decode(T.self, from: data)
        else { return nil }
        return value
    }

    private func receiveOne(_ event: BasicEvent) async {
        switch event.type {
        case "m.key.verification.request":
            await receiveRequest(event)
        case "m.key.verification.ready":
            guard
                let sender = event.sender,
                let ready: VerificationReady = decode(VerificationReady.self, from: event)
            else { return }
            var match: VerificationSession?
            for session in sessions.values {
                if session.role == .requester, session.peerUserId == sender,
                    await session.state == .requested
                {
                    match = session
                    break
                }
            }
            guard let match else { return }
            if await apply(to: match, { try await $0.receiveReady(ready) }) {
                await drive(match)
            }
        case "m.key.verification.start":
            guard
                let start: VerificationStart = decode(VerificationStart.self, from: event),
                let session = sessions[start.transactionId]
            else { return }
            if await apply(to: session, { try await $0.receiveStart(start) }) {
                await drive(session)
            }
        case "m.key.verification.accept":
            // Accept carries no flow ID: match the session awaiting it.
            // Either role may await one — the requester when it started, or
            // the responder when the peer started (the canonical flow).
            guard
                let sender = event.sender,
                let accept: VerificationAccept = decode(VerificationAccept.self, from: event)
            else { return }
            var match: VerificationSession?
            for session in sessions.values {
                if session.peerUserId == sender,
                    await session.state == .started
                {
                    match = session
                    break
                }
            }
            guard let match else { return }
            if await apply(to: match, { try await $0.receiveAccept(accept) }) {
                await drive(match)
            }
        case "m.key.verification.key":
            guard
                let key: VerificationKey = decode(VerificationKey.self, from: event),
                let session = sessions[key.transactionId]
            else { return }
            if await apply(to: session, { _ = try await $0.receiveKey(key) }) {
                await drive(session)
            }
        case "m.key.verification.mac":
            guard
                let mac: VerificationMac = decode(VerificationMac.self, from: event),
                let session = sessions[mac.transactionId]
            else { return }
            if await apply(to: session, {
                _ = try await $0.receiveMac(mac, peerKeys: try await macKeys(for: $0))
            }) {
                await drive(session)
            }
        case "m.key.verification.done":
            guard
                let done: VerificationDone = decode(VerificationDone.self, from: event),
                sessions[done.transactionId] != nil
            else { return }
            dropRequest(transactionId: done.transactionId)
            notify(.sessionFinished(transactionId: done.transactionId))
        case "m.key.verification.cancel":
            guard
                let cancel: VerificationCancel = decode(VerificationCancel.self, from: event),
                let session = sessions[cancel.transactionId]
            else { return }
            await session.receiveCancel(cancel)
            dropRequest(transactionId: cancel.transactionId)
            notify(.sessionFinished(transactionId: cancel.transactionId))
        default:
            break
        }
    }

    /// Run a session mutation; on failure cancel the flow best-effort,
    /// surface `.failed`, and finish it so broken handshakes never stall.
    /// Mutations on terminal sessions are ignored (e.g. duplicate
    /// deliveries when v3 and sliding sync run side by side). Returns
    /// whether the mutation applied (the caller then drives the flow).
    private func apply(
        to session: VerificationSession,
        _ mutation: (VerificationSession) async throws -> Void
    ) async -> Bool {
        let state = await session.state
        guard state != .done && state != .cancelled else { return false }
        do {
            try await mutation(session)
            return true
        } catch {
            await fail(session, with: error)
            return false
        }
    }

    private func receiveRequest(_ event: BasicEvent) async {
        guard
            let sender = event.sender,
            let request: VerificationRequest = decode(VerificationRequest.self, from: event),
            request.methods.contains("m.sas.v1"),
            sessions[request.transactionId] == nil,
            !pendingRequests.contains(where: { $0.transactionId == request.transactionId })
        else { return }
        if await isOwnEcho(sender: sender, fromDevice: request.fromDevice) { return }
        let nowMs = Int(Date.now.timeIntervalSince1970 * 1000)
        guard request.timestamp > nowMs - Self.requestFreshnessMs else { return }
        let incoming = IncomingVerificationRequest(
            transactionId: request.transactionId,
            sender: sender,
            deviceId: request.fromDevice)
        pendingRequests.append(incoming)
        notify(.requestReceived(incoming))
    }

    /// Whether a request is our own device's echo (self-verify
    /// broadcasts fan out to every device including ours when the
    /// recipient list falls back to `"*"`): never surface it as an
    /// incoming request. Unknown identity (logged out) skips the check.
    private func isOwnEcho(sender: UserId, fromDevice: String) async -> Bool {
        guard let (ourUser, ourDevice) = try? await identity() else { return false }
        return sender == ourUser && fromDevice == ourDevice
    }

    /// Our keys to MAC when approving a match: the app override, or this
    /// device's ed25519 keys plus our cross-signing master key.
    private func ownKeys(
        for session: VerificationSession
    ) async throws(MatrixError) -> [VerificationSession.KeyToMAC] {
        let (ourUser, ourDevice) = try await identity()
        if let provider = ownKeysProvider {
            let keys = try await provider(ourUser)
            guard !keys.isEmpty else {
                throw .verificationFailed("Nothing to MAC")
            }
            return keys
        }
        guard let response = try? await keys.queryKeys(users: [ourUser]) else {
            throw .verificationFailed("No device keys to MAC")
        }
        var out: [VerificationSession.KeyToMAC] = []
        if let master = response.masterKeys?[ourUser.value],
            let (id, key) = master.keys.first
        {
            out.append(VerificationSession.KeyToMAC(id: id, key: key))
        }
        if let device = response.deviceKeys[ourUser.value]?[ourDevice] {
            out += device.keys
                .filter { $0.key.hasPrefix("ed25519:") }
                .map { VerificationSession.KeyToMAC(id: $0.key, key: $0.value) }
        }
        guard !out.isEmpty else {
            throw .verificationFailed("No device keys to MAC")
        }
        return out
    }

    /// Peer keys to verify against an incoming MAC: the peer's device
    /// keys plus master key (what Element MACs), or the app override.
    private func macKeys(
        for session: VerificationSession
    ) async throws(MatrixError) -> [VerificationSession.KeyToMAC] {
        if let provider = macKeysProvider {
            return try await provider(session.peerUserId)
        }
        let peer = session.peerUserId
        let queried = try await keys.queryKeys(users: [peer])
        var out: [VerificationSession.KeyToMAC] = []
        if let master = queried.masterKeys?[peer.value],
            let (id, key) = master.keys.first
        {
            out.append(VerificationSession.KeyToMAC(id: id, key: key))
        }
        if let devices = queried.deviceKeys[peer.value] {
            for device in devices.values {
                out += device.keys.map {
                    VerificationSession.KeyToMAC(id: $0.key, key: $0.value)
                }
            }
        }
        guard !out.isEmpty else {
            throw .verificationFailed("No peer keys to verify")
        }
        return out
    }
}
