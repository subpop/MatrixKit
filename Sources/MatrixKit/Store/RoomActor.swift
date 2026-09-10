/// Per-room update notifications emitted by `RoomActor`.
import Foundation

public enum RoomUpdate: Hashable, Sendable {
    case timelineAppended(count: Int)
    case timelineReset
    case stateChanged
    case membersChanged
    case unreadChanged(notification: Int, highlight: Int)
    case typingChanged(users: [UserId])
    case membershipChanged(Membership)
}

/// Delivery state of a locally-echoed event.
public enum SendState: Hashable, Sendable {
    /// Staged locally; not yet confirmed by sync.
    case pending
    /// The send failed with a human-readable reason.
    case failed(String)
}

/// Per-room client-side state machine.
///
/// Owns the room's timeline window, member list, and metadata. Sync deltas
/// are applied via `applyJoined` / `applyInvite` / `applyLeft`; observers
/// subscribe through `updates()`.
public actor RoomActor {
    /// Maximum timeline events kept in memory per room.
    public static let maxTimelineEvents = 500

    /// The room's Matrix ID.
    public let roomId: RoomId

    /// Explicit name from `m.room.name` state. Nil until state arrives.
    public private(set) var name: String?
    /// Topic from `m.room.topic` state, if set.
    public private(set) var topic: String?
    /// Avatar from `m.room.avatar` state, if set.
    public private(set) var avatarURL: MXCURI?
    /// The local user's membership (`.join`, `.invite`, `.leave`, …).
    public private(set) var membership: Membership
    /// Membership contents keyed by user ID.
    public private(set) var members: [UserId: MemberContent]
    /// Last-known sync heroes (candidate display-name fallbacks).
    public private(set) var heroes: [UserId] = []
    /// Child rooms listed by `m.space.child` state (spaces only).
    public private(set) var spaceChildren: Set<RoomId> = []
    /// Parent spaces listed by `m.space.parent` state.
    public private(set) var spaceParents: Set<RoomId> = []
    /// Parent spaces flagged canonical (`canonical: true`).
    public private(set) var canonicalParentIds: Set<RoomId> = []
    /// Raw `m.room.power_levels` content, if known (drives child-management
    /// checks without a per-space network fetch). Persisted with the snapshot.
    public private(set) var powerLevelsContent: [String: AnyCodable]?
    /// Last-fetched hierarchy rows for this space (MSC2946), including
    /// server-reported member counts for children the user hasn't joined.
    /// Persisted with the snapshot so a space's detail renders instantly
    /// on relaunch; refreshed from the network on open.
    public private(set) var hierarchyChildren: [SpaceChild] = []
    /// Direct-child edges from the space's own hierarchy entry (ordering).
    /// Persisted alongside the rows.
    public private(set) var hierarchyDirectChildren: [SpaceChildEdge] = []
    /// Cursor for the next hierarchy page, if any.
    public private(set) var hierarchyNextBatch: BatchToken?

    /// The canonical parent to use, when one is declared: the lowest room
    /// ID by Unicode code points (spec tiebreak).
    public var canonicalParentId: RoomId? {
        canonicalParentIds.min { codePointLessThan($0.value, $1.value) }
    }

    /// Newest timeline window, oldest first, capped at `maxTimelineEvents`.
    public private(set) var timeline: [MessageEvent]
    /// Unread notification count from the latest sync.
    public private(set) var unreadCount: Int
    /// Highlighted (mention/keyword) notification count.
    public private(set) var highlightCount: Int
    /// Users currently sending `m.typing` (ephemeral, never persisted).
    public private(set) var typingUsers: [UserId]
    /// Pagination cursor for older history (`GET /messages`).
    public private(set) var prevBatch: BatchToken?
    /// Event up to which the user has sent a read receipt.
    public private(set) var fullyReadEventId: EventId?
    /// Client-side read-marker timestamp (ms since epoch): the max of the
    /// persisted snapshot marker, ingested `m.fully_read` positions, and
    /// own `m.read` receipt timestamps. Nil means unknown — badge counts
    /// fall back to the server value.
    public private(set) var readMarkerTsMs: Int?
    /// Whether the room is encrypted (`m.room.encryption` state).
    public private(set) var isEncrypted: Bool
    /// Delivery states of locally-echoed events, by echo event ID.
    /// Entries clear when sync confirms the send.
    public private(set) var sendStates: [EventId: SendState]
    /// Canonical alias (`m.room.canonical_alias`), if set.
    public private(set) var canonicalAlias: String?
    /// Alternative aliases, if any.
    public private(set) var altAliases: [String]
    /// Pinned event IDs (`m.room.pinned_events`).
    public private(set) var pinnedEventIds: [String]
    /// Successor room after an upgrade (`m.room.tombstone`).
    public private(set) var successorRoomId: String?
    /// Whether the room is a space (`m.room.create` type `m.space`).
    public private(set) var isSpace: Bool
    /// Whether the room is a direct chat (`m.direct` account data).
    public private(set) var isDirect: Bool
    /// Whether the room carries the `m.favourite` tag.
    public private(set) var isFavourite: Bool

    /// Pending sends by transaction ID value.
    private var pendingEchoes: [String: EventId] = [:]
    /// Transaction IDs by echo event ID (for cancel-by-event).
    private var echoTransactions: [EventId: TransactionId] = [:]
    /// Transaction IDs whose server confirmations must be dropped (the
    /// staged echo was cancelled and its send must never surface, e.g. a
    /// reaction toggled off before sync confirmed it). Entries persist:
    /// overlapping sync/pagination windows can redeliver the event.
    private var suppressedTransactions: Set<String> = []

    private var continuations: [AsyncStream<RoomUpdate>.Continuation] = []
    /// Last-emitted badge-driving unread count (dedupes `.unreadChanged`).
    private var lastEmittedUnread = 0
    /// Fully-read marker IDs whose timestamps were resolved via a
    /// single-event fetch (see `adoptResolvedMarkerTs`). Success-only:
    /// failed fetches retry on the next resolution pass.
    private var resolvedMarkerIds: Set<EventId> = []

    public init(roomId: RoomId, membership: Membership = .join) {
        self.roomId = roomId
        self.membership = membership
        self.members = [:]
        self.timeline = []
        self.unreadCount = 0
        self.highlightCount = 0
        self.typingUsers = []
        self.readMarkerTsMs = nil
        self.isEncrypted = false
        self.sendStates = [:]
        self.canonicalAlias = nil
        self.altAliases = []
        self.pinnedEventIds = []
        self.successorRoomId = nil
        self.isSpace = false
        self.isDirect = false
        self.isFavourite = false
    }

    // MARK: - Subscriptions

    /// Subscribe to room updates. The stream ends when the subscriber
    /// cancels or `finishUpdates()` is called.
    public func updates() -> AsyncStream<RoomUpdate> {
        let (stream, continuation) = AsyncStream<RoomUpdate>.makeStream()
        continuations.append(continuation)
        return stream
    }

    private func notify(_ update: RoomUpdate) {
        for continuation in continuations {
            continuation.yield(update)
        }
    }

    // MARK: - Delta application

    /// Apply a joined-room delta: confirm pending echoes whose
    /// transaction IDs the server echoed back, then append (or reset on
    /// `limited`) the remaining timeline.
    public func applyJoined(_ delta: JoinedRoomDelta) {
        if delta.timelineLimited {
            // Gap in history — replace the window to avoid a mixed view.
            // Confirmed echoes resolve against the fresh window below.
            // Dedupe: servers may repeat the anchor across the window.
            timeline = delta.timeline.dedupedByEventId()
            confirmEchoes(in: &timeline)
            foldRedactions()
            notify(.timelineReset)
        } else if !delta.timeline.isEmpty {
            var incoming = delta.timeline
            confirmEchoes(in: &incoming)
            // Sync and pagination windows can overlap; drop repeats so the
            // timeline keeps unique event IDs.
            let known = Set(timeline.map(\.eventId))
            incoming.removeAll { known.contains($0.eventId) }
            incoming = incoming.dedupedByEventId()
            if !incoming.isEmpty {
                timeline.append(contentsOf: incoming)
                if timeline.count > Self.maxTimelineEvents {
                    timeline.removeFirst(timeline.count - Self.maxTimelineEvents)
                }
                foldRedactions()
                notify(.timelineAppended(count: incoming.count))
            }
        }
        if let prevBatch = delta.prevBatch {
            // Sync `prev_batch` describes the live window, not older
            // history `/messages` already fetched. A pagination-advanced
            // cursor must survive ordinary deltas; adopt the sync token
            // only when the window was (re)initialized.
            if delta.timelineLimited || self.prevBatch == nil {
                self.prevBatch = prevBatch
            }
        }
        if !delta.state.isEmpty {
            applyStateEvents(delta.state)
        }
        // State changes inside the timeline window are NOT repeated in
        // `state` by the server, so fold them in too (timeline order is
        // newest-last, giving the freshest event the final say). Without
        // this, sticky state like m.room.avatar can be missed forever
        // once the sync token advances past the event.
        let timelineState = delta.timeline.filter { $0.stateKey != nil }
        if !timelineState.isEmpty {
            applyStateEvents(timelineState)
        }
        if !delta.heroes.isEmpty {
            heroes = delta.heroes
        }
        if !delta.ephemeral.isEmpty {
            applyEphemeral(delta.ephemeral)
        }
        applyRoomAccountData(delta.accountData)
        if unreadCount != delta.unreadCount || highlightCount != delta.highlightCount {
            unreadCount = delta.unreadCount
            highlightCount = delta.highlightCount
        }
        // Marker ingestion (ephemeral/account data above) runs first so
        // the emitted count reflects the freshest read position.
        emitUnreadIfChanged()
        if membership != .join {
            membership = .join
            notify(.membershipChanged(.join))
        }
    }

    /// Apply an invite: set `.invite` membership and record stripped state.
    public func applyInvite(_ delta: InvitedRoomDelta) {
        membership = .invite
        applyStrippedState(delta.events)
        notify(.membershipChanged(.invite))
    }

    /// Apply a leave: append final timeline events and set `.leave`.
    public func applyLeft(_ delta: LeftRoomDelta) {
        if !delta.timeline.isEmpty {
            let known = Set(timeline.map(\.eventId))
            let incoming = delta.timeline.filter { !known.contains($0.eventId) }
                .dedupedByEventId()
            timeline.append(contentsOf: incoming)
            // Same redaction folding as `applyJoined`: the leave timeline
            // can carry redactions whose targets sit in the window.
            foldRedactions()
        }
        if !delta.state.isEmpty {
            applyStateEvents(delta.state)
        }
        // Same timeline-window folding as `applyJoined`: servers omit
        // timeline-covered state updates from the `state` block.
        let timelineState = delta.timeline.filter { $0.stateKey != nil }
        if !timelineState.isEmpty {
            applyStateEvents(timelineState)
        }
        applyRoomAccountData(delta.accountData)
        membership = .leave
        notify(.membershipChanged(.leave))
    }

    /// Apply a knock state change and set `.knock` membership.
    public func applyKnock(_ delta: KnockedRoomDelta) {
        membership = .knock
        applyStrippedState(delta.events)
        notify(.membershipChanged(.knock))
    }

    // MARK: - Local mutations

    /// Set the local user (used for display-name fallback and receipts).
    public func setLocalUser(_ userId: UserId) {
        localUser = userId
    }

    /// Adopt an out-of-band avatar URL (e.g. healed via a direct state
    /// fetch after sync missed the update). Publishes like a state change.
    public func adoptAvatarURL(_ url: MXCURI?) {
        avatarURL = url
        notify(.stateChanged)
    }

    /// Adopt an out-of-band member entry (e.g. a profile healed via
    /// `GET /profile/{userId}` for a sender whose `m.room.member` sync
    /// omitted under lazy member loading). Never overwrites an entry
    /// already known from sync state, which stays authoritative.
    /// Publishes like a member change so views re-resolve display names.
    public func adoptMember(_ userId: UserId, content: MemberContent) {
        guard members[userId] == nil else { return }
        members[userId] = content
        notify(.membersChanged)
        notify(.stateChanged)
    }

    /// Adopt fetched hierarchy rows for this space (overwrites), so the
    /// detail view's next open renders from the snapshot without a network
    /// round trip. Publishes like a state change.
    public func setHierarchy(
        children: [SpaceChild], directChildren: [SpaceChildEdge] = [],
        nextBatch: BatchToken?
    ) {
        hierarchyChildren = children
        hierarchyDirectChildren = directChildren
        hierarchyNextBatch = nextBatch
        notify(.stateChanged)
    }

    /// Optimistically append a locally-echoed event (replaced on confirm).
    public func appendLocalEcho(_ event: MessageEvent) {
        timeline.append(event)
        notify(.timelineAppended(count: 1))
    }

    /// Stage a locally-echoed send, tracked by transaction ID until sync
    /// confirms it (the server echoes `unsigned.transaction_id` back) or
    /// it is failed/cancelled.
    public func stageEcho(_ event: MessageEvent, transactionId: TransactionId) {
        pendingEchoes[transactionId.value] = event.eventId
        echoTransactions[event.eventId] = transactionId
        sendStates[event.eventId] = .pending
        timeline.append(event)
        if timeline.count > Self.maxTimelineEvents {
            timeline.removeFirst(timeline.count - Self.maxTimelineEvents)
        }
        notify(.timelineAppended(count: 1))
    }

    /// Mark a staged send failed, keeping its echo visible with the reason.
    public func failEcho(transactionId: TransactionId, reason: String) {
        guard let echoId = pendingEchoes.removeValue(forKey: transactionId.value) else { return }
        echoTransactions.removeValue(forKey: echoId)
        sendStates[echoId] = .failed(reason)
        notify(.timelineReset)
    }

    /// Drop a staged send. Returns false when no echo holds the transaction.
    /// (The PUT may still land server-side; sync then delivers it normally.)
    @discardableResult
    public func cancelEcho(transactionId: TransactionId) -> Bool {
        guard let echoId = pendingEchoes.removeValue(forKey: transactionId.value) else {
            return false
        }
        echoTransactions.removeValue(forKey: echoId)
        sendStates.removeValue(forKey: echoId)
        timeline.removeAll { $0.eventId == echoId }
        notify(.timelineReset)
        return true
    }

    /// The staged transaction behind an echo event ID, if any.
    public func echoTransactionId(for eventId: EventId) -> TransactionId? {
        echoTransactions[eventId]
    }

    /// Drop future server confirmations for a transaction (after
    /// `cancelEcho`). The in-flight PUT may still land; when sync delivers
    /// it, `confirmEchoes` discards it instead of appending a zombie event.
    public func suppressTransaction(_ transactionId: TransactionId) {
        suppressedTransactions.insert(transactionId.value)
    }

    /// Stamp `redacted_because` onto a window event unless already stamped.
    /// Returns the prior `unsigned` (nil when the event had none) so
    /// optimistic stamps can be rolled back if the server call fails.
    @discardableResult
    public func stampRedaction(
        target: EventId, stamp: AnyCodable
    ) -> [String: AnyCodable]? {
        guard let index = timeline.firstIndex(where: { $0.eventId == target })
        else { return nil }
        let prior = timeline[index].unsigned
        guard prior?["redacted_because"] == nil else { return prior }
        var unsigned = prior ?? [:]
        unsigned["redacted_because"] = stamp
        timeline[index].unsigned = unsigned
        notify(.timelineAppended(count: 1))
        return prior
    }

    /// Restore a window event's `unsigned` (rolls back an optimistic stamp).
    public func restoreUnsigned(
        target: EventId, unsigned: [String: AnyCodable]?
    ) {
        guard let index = timeline.firstIndex(where: { $0.eventId == target })
        else { return }
        timeline[index].unsigned = unsigned
        notify(.timelineAppended(count: 1))
    }

    /// Newest message-like event (message or sticker), for list previews.
    /// State and reaction events never qualify.
    public func latestMessageEvent() -> MessageEvent? {
        timeline.last {
            $0.type == EventType.roomMessage.rawValue
                || $0.type == EventType.sticker.rawValue
        }
    }

    /// Message-like events that drive the unread estimate. Edits
    /// (`m.replace`) reuse the `m.room.message` type but must not count:
    /// they render folded into their target, so mark-read can never
    /// advance past them and the badge would stick forever. Our own
    /// messages (including unconfirmed local echoes) never count either:
    /// a send would otherwise flash the "New" divider and badge until
    /// the read marker catches up past it — and the server-assigned
    /// timestamp on confirm is always newer than the echo, so no
    /// marker position can cover both.
    private func unreadCountedEvents(in timeline: [MessageEvent]) -> [MessageEvent] {
        timeline.filter {
            ($0.type == EventType.roomMessage.rawValue
                || $0.type == EventType.sticker.rawValue)
                && $0.messageContent?.relatesTo?.relType != .replacement
                && $0.sender != localUser
        }
    }

    /// Client-side unread estimate: message-like events newer than the
    /// read marker. Nil when no read-marker information exists (badge
    /// falls back to the server count); when the marker predates the
    /// timeline window, counts the whole window.
    public var clientUnreadCount: Int? {
        let messages = unreadCountedEvents(in: timeline)
        if let marker = readMarkerTsMs {
            return messages.filter { $0.originServerTs > marker }.count
        }
        return fullyReadEventId == nil ? nil : messages.count
    }

    /// First unread event: the oldest message-like event newer than the
    /// read marker. Distinct from ``fullyReadEventId`` (the *last read*
    /// event) — clients anchor "New" dividers and unread-focus here.
    /// Mirrors ``clientUnreadCount``: nil when no read-marker information
    /// exists or the room is fully read; when the marker predates the
    /// timeline window, the first event in the window.
    public var firstUnreadEventId: EventId? {
        let messages = unreadCountedEvents(in: timeline)
        if let marker = readMarkerTsMs {
            return messages.first { $0.originServerTs > marker }.map(\.eventId)
        }
        guard fullyReadEventId != nil else { return nil }
        return messages.first.map(\.eventId)
    }

    /// Badge-driving unread count: the client estimate when it exceeds
    /// the server value (server counts are not reliably populated),
    /// the server value otherwise. Highlights stay server-side.
    public var effectiveUnreadCount: Int {
        max(unreadCount, clientUnreadCount ?? unreadCount)
    }

    /// Emit `.unreadChanged` with badge-driving counts when they moved.
    private func emitUnreadIfChanged() {
        let effective = effectiveUnreadCount
        if effective != lastEmittedUnread {
            lastEmittedUnread = effective
            notify(.unreadChanged(notification: effective, highlight: highlightCount))
        }
    }

    /// Set the direct-chat flag (pushed by `StateStore` from `m.direct`).
    func setDirect(_ isDirect: Bool) {
        guard isDirect != self.isDirect else { return }
        self.isDirect = isDirect
        notify(.stateChanged)
    }

    /// Set the favourite flag (writes go through `AccountDataClient`;
    /// sync converges the same flag here).
    func setFavourite(_ isFavourite: Bool) {
        guard isFavourite != self.isFavourite else { return }
        self.isFavourite = isFavourite
        notify(.stateChanged)
    }

    /// Fold room account data (tags, fully-read marker) into room state.
    private func applyRoomAccountData(_ events: [BasicEvent]) {
        for event in events {
            if event.type == EventType.fullyRead.rawValue,
               let id = event.content["event_id"]?.stringValue,
               let eventId = try? EventId(id)
            {
                adoptFullyRead(eventId)
                continue
            }
            guard event.type == "m.tag" else { continue }
            let favourite = event.content["tags"]?.objectValue?["m.favourite"] != nil
            if favourite != isFavourite {
                isFavourite = favourite
                notify(.stateChanged)
            }
        }
    }

    /// Replace staged echoes with their server-confirmed events, in place.
    /// Callers notify afterwards (their append/reset rebuild covers it).
    private func confirmEchoes(in events: inout [MessageEvent]) {
        if !suppressedTransactions.isEmpty {
            // Cancelled echoes whose PUT still landed: discard the server
            // confirmation so no zombie event surfaces.
            events.removeAll {
                guard let txn = $0.unsigned?["transaction_id"]?.stringValue
                else { return false }
                return suppressedTransactions.contains(txn)
            }
        }
        guard !pendingEchoes.isEmpty else { return }
        events = events.map { event in
            guard
                let txn = event.unsigned?["transaction_id"]?.stringValue,
                let echoId = pendingEchoes[txn]
            else { return event }
            pendingEchoes.removeValue(forKey: txn)
            echoTransactions.removeValue(forKey: echoId)
            sendStates.removeValue(forKey: echoId)
            timeline.removeAll { $0.eventId == echoId }
            return event
        }
    }

    /// Stamp `redacted_because` onto window events targeted by stored
    /// `m.room.redaction` events, and prune the targets' content to the
    /// spec keep-lists so bodies don't linger locally. Incremental sync
    /// delivers a redaction as a new event without re-sending its target,
    /// so without this fold a redacted reaction would keep feeding its
    /// badge until restart (when history arrives with `redacted_because`
    /// already stamped).
    /// Never overwrites a server-supplied stamp.
    private func foldRedactions() {
        for redaction in timeline
        where EventType(rawValue: redaction.type) == .redaction {
            guard let target = redaction.redacts else { continue }
            stampRedaction(
                target: target,
                stamp: .object([
                    "type": .string(redaction.type),
                    "event_id": .string(redaction.eventId.value),
                    "sender": .string(redaction.sender.value),
                    "redacts": .string(target.value),
                ]))
            if let index = timeline.firstIndex(where: { $0.eventId == target }) {
                timeline[index].content = EventRedactor.prunedContent(
                    type: timeline[index].type, content: timeline[index].content)
            }
        }
    }

    /// Prepend older events from `/messages` pagination.
    public func prependHistory(_ events: [MessageEvent], prevBatch: BatchToken?) {
        timeline.insert(contentsOf: events, at: 0)
        self.prevBatch = prevBatch
        notify(.timelineReset)
        // Older events may still postdate the read marker.
        emitUnreadIfChanged()
    }

    /// Re-run the Megolm decryptor over stored events that are still
    /// ciphertext. Late-arriving keys — backup restores, room-key
    /// shares, sessions persisted across relaunch — otherwise never
    /// refresh already-stored failures, leaving "Unable to decrypt"
    /// placeholders stuck even though the keys are in the store.
    /// Returns the number of events decrypted; emits `.timelineReset`
    /// when nonzero so observers rebuild.
    @discardableResult
    public func retryDecryption(
        _ decryptor: @Sendable (MessageEvent, RoomId) async -> MessageEvent?
    ) async -> Int {
        var changed = 0
        for index in timeline.indices
            where timeline[index].type == RoomCrypto.roomEncryptedType
        {
            guard
                let decrypted = await decryptor(timeline[index], roomId),
                decrypted.type != RoomCrypto.roomEncryptedType
            else { continue }
            timeline[index] = decrypted
            changed += 1
        }
        if changed > 0 {
            notify(.timelineReset)
        }
        return changed
    }

    /// Record the latest fully-read event (drives unread badges).
    public func setFullyRead(_ eventId: EventId) {
        adoptFullyRead(eventId)
    }

    /// Whether the fully-read marker's timestamp still needs a
    /// single-event fetch: an ID is known but its event is outside the
    /// timeline window, so sync-time adoption couldn't resolve it and
    /// the marker falls back to the (often stale) receipt timestamp.
    public var needsMarkerResolution: Bool {
        guard let marker = fullyReadEventId, !resolvedMarkerIds.contains(marker) else {
            return false
        }
        return !timeline.contains { $0.eventId == marker }
    }

    /// Adopt a fetched fully-read timestamp. Max-only like receipts, so
    /// resolutions and markers converge instead of regressing each
    /// other. Stale fetches (marker moved on) are ignored.
    public func adoptResolvedMarkerTs(_ eventId: EventId, ts: Int) {
        guard eventId == fullyReadEventId else { return }
        resolvedMarkerIds.insert(eventId)
        readMarkerTsMs = max(readMarkerTsMs ?? Int.min, ts)
        emitUnreadIfChanged()
    }

    /// Adopt a fully-read marker: the ID is authoritative; the timestamp
    /// marker only advances, so receipts and markers converge instead of
    /// regressing each other.
    private func adoptFullyRead(_ eventId: EventId) {
        fullyReadEventId = eventId
        let resolvedTs = timeline.first(where: { $0.eventId == eventId })?.originServerTs
        if let ts = resolvedTs {
            readMarkerTsMs = max(readMarkerTsMs ?? Int.min, ts)
        }
        emitUnreadIfChanged()
    }

    // MARK: - Snapshots

    /// Capture serializable state for the on-disk cache.
    /// Echo delivery states are transient (in-flight PUTs die with the
    /// process) and intentionally not persisted.
    public func snapshot() -> RoomSnapshot {
        RoomSnapshot(
            roomId: roomId,
            name: name,
            topic: topic,
            avatarURL: avatarURL,
            membership: membership,
            members: members,
            timeline: timeline,
            unreadCount: unreadCount,
            highlightCount: highlightCount,
            prevBatch: prevBatch,
            fullyReadEventId: fullyReadEventId,
            readMarkerTsMs: readMarkerTsMs,
            isEncrypted: isEncrypted,
            canonicalAlias: canonicalAlias,
            altAliases: altAliases,
            pinnedEventIds: pinnedEventIds,
            successorRoomId: successorRoomId,
            isSpace: isSpace,
            isDirect: isDirect,
            isFavourite: isFavourite,
            spaceChildren: Array(spaceChildren),
            spaceParents: Array(spaceParents),
            canonicalParentIds: Array(canonicalParentIds),
            powerLevelsContent: powerLevelsContent,
            heroes: Array(heroes),
            hierarchyChildren: hierarchyChildren,
            hierarchyDirectChildren: hierarchyDirectChildren,
            hierarchyNextBatch: hierarchyNextBatch
        )
    }

    public func restore(_ snapshot: RoomSnapshot) {
        name = snapshot.name
        topic = snapshot.topic
        avatarURL = snapshot.avatarURL
        membership = snapshot.membership
        members = snapshot.members
        // Heal windows persisted before every stitch point deduped:
        // duplicate IDs break list rendering, so drop repeats on load.
        timeline = snapshot.timeline.dedupedByEventId()
        unreadCount = snapshot.unreadCount
        highlightCount = snapshot.highlightCount
        prevBatch = snapshot.prevBatch
        fullyReadEventId = snapshot.fullyReadEventId
        readMarkerTsMs = snapshot.readMarkerTsMs
        lastEmittedUnread = effectiveUnreadCount
        isEncrypted = snapshot.isEncrypted
        canonicalAlias = snapshot.canonicalAlias
        altAliases = snapshot.altAliases
        pinnedEventIds = snapshot.pinnedEventIds
        successorRoomId = snapshot.successorRoomId
        isSpace = snapshot.isSpace
        isDirect = snapshot.isDirect
        isFavourite = snapshot.isFavourite
        spaceChildren = Set(snapshot.spaceChildren)
        spaceParents = Set(snapshot.spaceParents)
        canonicalParentIds = Set(snapshot.canonicalParentIds)
        powerLevelsContent = snapshot.powerLevelsContent
        heroes = snapshot.heroes
        hierarchyChildren = snapshot.hierarchyChildren
        hierarchyDirectChildren = snapshot.hierarchyDirectChildren
        hierarchyNextBatch = snapshot.hierarchyNextBatch
    }

    /// Summarize this room for lists (name, topic, avatar, counts).
    public func info() -> RoomInfo {
        RoomInfo(
            roomId: roomId,
            name: displayName(),
            topic: topic,
            avatarURL: avatarURL,
            membership: membership,
            memberCount: members.count
        )
    }

    /// Best-effort display name: explicit name, else heroes/members, else ID.
    public func displayName() -> String {
        if let name, !name.isEmpty { return name }
        let others = members.keys.filter { $0 != localUser }.map(\.value)
        if !others.isEmpty { return others.sorted().joined(separator: ", ") }
        return roomId.value
    }

    // MARK: - Private

    /// Our own user ID, set when known (used for name fallback + receipts).
    public var localUser: UserId?

    private func applyStateEvents(_ events: [MessageEvent]) {
        var touchedMembers = false
        var touchedInfo = false
        for event in events {
            // Space graph edges bypass `EventType` (no enum cases): the
            // state key carries the other end, empty content clears it.
            if event.type == "m.space.child",
               let child = event.stateKey.map(RoomId.init(unchecked:)) {
                if event.content.isEmpty { spaceChildren.remove(child) } else { spaceChildren.insert(child) }
                touchedInfo = true
                continue
            }
            if event.type == "m.space.parent",
                let parent = event.stateKey.map(RoomId.init(unchecked:)) {
                if event.content.isEmpty {
                    spaceParents.remove(parent)
                    canonicalParentIds.remove(parent)
                } else {
                    spaceParents.insert(parent)
                    if event.content["canonical"]?.boolValue == true {
                        canonicalParentIds.insert(parent)
                    } else {
                        canonicalParentIds.remove(parent)
                    }
                }
                touchedInfo = true
                continue
            }
            switch EventType(rawValue: event.type) {
            case .roomMember:
                guard
                    let data = try? JSONEncoder().encode(event.content),
                    let content = try? JSONDecoder().decode(MemberContent.self, from: data)
                else { continue }
                let userId = event.stateKey
                    .map(UserId.init(unchecked:)) ?? event.sender
                // Leave/kick events often omit the profile, but the member
                // map feeds display-name resolution at render time: keep a
                // stored display name/avatar rather than wiping it, so a
                // profile-less leave still renders as "Alice left" instead
                // of falling back to the Matrix ID.
                var merged = content
                if merged.displayname == nil {
                    merged.displayname = members[userId]?.displayname
                }
                if merged.avatarUrl == nil {
                    merged.avatarUrl = members[userId]?.avatarUrl
                }
                members[userId] = merged
                touchedMembers = true
            case .roomName:
                name = event.content["name"]?.stringValue
                touchedInfo = true
            case .roomTopic:
                topic = event.content["topic"]?.stringValue
                touchedInfo = true
            case .roomAvatar:
                if let url = event.content["url"]?.stringValue {
                    avatarURL = try? MXCURI(url)
                } else {
                    avatarURL = nil
                }
                touchedInfo = true
            case .roomEncryption:
                if !isEncrypted {
                    isEncrypted = true
                    touchedInfo = true
                }
            case .roomPowerLevels:
                powerLevelsContent = event.content
                touchedInfo = true
            case .roomCanonicalAlias:
                canonicalAlias = event.content["alias"]?.stringValue
                altAliases = event.content["alt_aliases"]?.arrayValue?.compactMap(\.stringValue) ?? []
                touchedInfo = true
            case .roomPinnedEvents:
                pinnedEventIds = event.content["pinned"]?.arrayValue?.compactMap(\.stringValue) ?? []
                touchedInfo = true
            case .roomTombstone:
                successorRoomId = event.content["replacement_room"]?.stringValue
                touchedInfo = true
            case .roomCreate:
                let roomType = event.content["type"]?.stringValue
                if isSpace != (roomType == "m.space") {
                    isSpace = roomType == "m.space"
                    touchedInfo = true
                }
            default:
                break
            }
        }
        if touchedMembers { notify(.membersChanged) }
        if touchedInfo || touchedMembers { notify(.stateChanged) }
    }

    private func applyStrippedState(_ events: [StrippedStateEvent]) {
        for event in events {
            switch EventType(rawValue: event.type) {
            case .roomName:
                name = event.content["name"]?.stringValue
            case .roomAvatar:
                if let url = event.content["url"]?.stringValue {
                    avatarURL = try? MXCURI(url)
                }
            case .roomMember:
                if let membershipRaw = event.content["membership"]?.stringValue,
                   let membership = Membership(rawValue: membershipRaw)
                {
                    members[event.sender] = MemberContent(
                        membership: membership,
                        displayname: event.content["displayname"]?.stringValue,
                        avatarUrl: event.content["avatar_url"]?.stringValue
                    )
                }
            case .roomCreate:
                isSpace = event.content["type"]?.stringValue == "m.space"
            default:
                break
            }
        }
        notify(.stateChanged)
    }

    private func applyEphemeral(_ events: [BasicEvent]) {
        for event in events {
            switch EventType(rawValue: event.type) {
            case .typing:
                if let userIds = event.content["user_ids"]?.arrayValue {
                    typingUsers = userIds.compactMap {
                        $0.stringValue.map(UserId.init(unchecked:))
                    }
                    // The server echoes our own typing notification back;
                    // never show the local user as typing.
                    .filter { $0 != localUser }
                    notify(.typingChanged(users: typingUsers))
                }
            case .receipt:
                ingestOwnReceipts(event)
            default:
                break
            }
        }
    }

    /// Fold our own `m.read` / `m.read.private` receipt timestamps into
    /// the read marker. Threaded receipts carry `thread_id` and are
    /// skipped (main-timeline badges only). The marker only advances.
    private func ingestOwnReceipts(_ event: BasicEvent) {
        guard let selfId = localUser else { return }
        var latest: Int?
        for (_, receipt) in event.content {
            guard let kinds = receipt.objectValue else { continue }
            for kind in ["m.read", "m.read.private"] {
                guard
                    let entry = kinds[kind]?.objectValue?[selfId.value]?.objectValue,
                    entry["thread_id"] == nil,
                    let ts = entry["ts"]?.intValue
                else { continue }
                latest = max(latest ?? Int.min, ts)
            }
        }
        if let latest {
            readMarkerTsMs = max(readMarkerTsMs ?? Int.min, latest)
            emitUnreadIfChanged()
        }
    }
}
