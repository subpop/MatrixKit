#if canImport(SwiftData)
import Foundation
import MatrixKit
import SwiftData

/// Incremental write path for the normalized store.
///
/// Ports the `RoomActor`/`StateStore` fold: sync deltas go in via
/// `apply(_:)` / `applySliding(_:)`, one `save()` per call. Derived state
/// (effective unread, first-unread marker, read-marker timestamps) is
/// precomputed onto `SDRoom` so `@Query` reads stay simple.
///
/// Transient send bookkeeping (transaction-ID maps, suppression set,
/// resolved-marker IDs) lives here in memory, mirroring `RoomActor`.
/// Typing notifications are intentionally dropped — ephemeral only.
@ModelActor
public actor MatrixStoreWriter {
    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    private func deduped(_ events: [MessageEvent]) -> [MessageEvent] {
        var seen = Set<EventId>()
        return events.filter { seen.insert($0.eventId).inserted }
    }

    private var localUser: String?
    private var pendingEchoes: [String: String] = [:]
    private var echoTransactions: [String: String] = [:]
    private var suppressedTransactions: Set<String> = []
    private var resolvedMarkerIds: Set<String> = []

    // MARK: - Identity

    /// Set the local user (receipt filtering, own-message exclusion).
    /// Also persists to the meta row.
    public func setLocalUser(_ userId: UserId) throws {
        localUser = userId.value
        let meta = try fetchMeta()
        meta.localUser = userId.value
        try modelContext.save()
    }

    /// Persisted v2 cursor for the engines' `since`. See `SyncDeltaSink`.
    public var syncToken: BatchToken? {
        get throws {
            try fetchMeta().syncToken.map { BatchToken($0) }
        }
    }

    // MARK: - Delta application

    /// Apply a v2 sync delta: route per-room changes, store the cursor.
    public func apply(_ delta: SyncDelta) throws {
        let meta = try fetchMeta()
        meta.syncToken = delta.nextBatch.value
        for (roomId, roomDelta) in delta.joined {
            try applyJoined(roomDelta, roomId: roomId.value)
        }
        for (roomId, roomDelta) in delta.invited {
            try applyInvite(roomDelta, roomId: roomId.value)
        }
        for (roomId, roomDelta) in delta.left {
            try applyLeft(roomDelta, roomId: roomId.value)
        }
        for (roomId, roomDelta) in delta.knocked {
            try applyKnock(roomDelta, roomId: roomId.value)
        }
        for event in delta.accountData {
            try upsertAccountData(type: event.type, content: event.content)
        }
        try pushDirectFlags()
        try modelContext.save()
    }

    /// Apply a sliding-sync delta. Same routing as `apply(_:)` but the v2
    /// `syncToken` is untouched — the sliding `pos` cursor is
    /// connection-scoped, so the two engines never thrash one cursor.
    public func applySliding(_ delta: SyncDelta) throws {
        let meta = try fetchMeta()
        meta.slidingPos = delta.nextBatch.value
        for (roomId, roomDelta) in delta.joined {
            try applyJoined(roomDelta, roomId: roomId.value)
        }
        for (roomId, roomDelta) in delta.invited {
            try applyInvite(roomDelta, roomId: roomId.value)
        }
        for (roomId, roomDelta) in delta.left {
            try applyLeft(roomDelta, roomId: roomId.value)
        }
        for (roomId, roomDelta) in delta.knocked {
            try applyKnock(roomDelta, roomId: roomId.value)
        }
        for event in delta.accountData {
            try upsertAccountData(type: event.type, content: event.content)
        }
        try pushDirectFlags()
        try modelContext.save()
    }

    // MARK: - Joined / invite / leave / knock

    private func applyJoined(_ delta: JoinedRoomDelta, roomId: String) throws {
        let room = try fetchRoom(roomId)
        if !delta.timeline.isEmpty {
            // Full history is kept, so `limited` only governs the
            // `prevBatch` adoption below — existing rows are never
            // deleted. Incoming rows merge with dedupe, like the
            // append path in `RoomActor.applyJoined`.
            var incoming = try confirmEchoes(in: delta.timeline, room: room)
            let known = Set(try eventIds(roomId: roomId))
            incoming.removeAll { known.contains($0.eventId.value) }
            incoming = deduped(incoming)
            for event in incoming {
                try insertEvent(event, roomId: roomId, room: room)
            }
            if let maxTs = incoming.map(\.originServerTs).max() {
                room.latestMessageTs = max(room.latestMessageTs, maxTs)
            }
            try foldRedactions(incoming: incoming, roomId: roomId)
        }
        if let prevBatch = delta.prevBatch {
            if delta.timelineLimited || room.prevBatch == nil {
                room.prevBatch = prevBatch.value
            }
        }
        if !delta.state.isEmpty {
            try applyStateEvents(delta.state, room: room)
        }
        // Timeline-embedded state is not repeated in `state` by the
        // server, so fold it too (newest-last wins).
        let timelineState = delta.timeline.filter { $0.stateKey != nil }
        if !timelineState.isEmpty {
            try applyStateEvents(timelineState, room: room)
        }
        if !delta.heroes.isEmpty {
            room.heroes = try encoder.encode(delta.heroes.map(\.value))
        }
        if !delta.ephemeral.isEmpty {
            try applyEphemeral(delta.ephemeral, room: room)
        }
        try applyRoomAccountData(delta.accountData, room: room)
        if room.unread != delta.unreadCount || room.highlight != delta.highlightCount {
            room.unread = delta.unreadCount
            room.highlight = delta.highlightCount
        }
        try recomputeUnread(room: room)
        if room.membership != Membership.join.rawValue {
            room.membership = Membership.join.rawValue
            room.inviterId = nil
        }
    }

    private func applyInvite(_ delta: InvitedRoomDelta, roomId: String) throws {
        let room = try fetchRoom(roomId, membership: Membership.invite.rawValue)
        room.membership = Membership.invite.rawValue
        room.inviterId = delta.inviter?.value
        try applyStrippedState(delta.events, room: room)
    }

    private func applyLeft(_ delta: LeftRoomDelta, roomId: String) throws {
        let room = try fetchRoom(roomId, membership: Membership.leave.rawValue)
        if !delta.timeline.isEmpty {
            let known = Set(try eventIds(roomId: roomId))
            let incoming = deduped(
                delta.timeline.filter { !known.contains($0.eventId.value) })
            for event in incoming {
                try insertEvent(event, roomId: roomId, room: room)
            }
            if let maxTs = incoming.map(\.originServerTs).max() {
                room.latestMessageTs = max(room.latestMessageTs, maxTs)
            }
            try foldRedactions(incoming: incoming, roomId: roomId)
        }
        if !delta.state.isEmpty {
            try applyStateEvents(delta.state, room: room)
        }
        let timelineState = delta.timeline.filter { $0.stateKey != nil }
        if !timelineState.isEmpty {
            try applyStateEvents(timelineState, room: room)
        }
        try applyRoomAccountData(delta.accountData, room: room)
        room.membership = Membership.leave.rawValue
        room.inviterId = nil
    }

    private func applyKnock(_ delta: KnockedRoomDelta, roomId: String) throws {
        let room = try fetchRoom(roomId, membership: Membership.knock.rawValue)
        room.membership = Membership.knock.rawValue
        room.inviterId = nil
        try applyStrippedState(delta.events, room: room)
    }

    // MARK: - Local mutations (echoes, history, healing)

    /// Stage a locally-echoed send, tracked by transaction ID until sync
    /// confirms it or it is failed/cancelled.
    public func stageEcho(
        _ event: MessageEvent, roomId: RoomId, transactionId: TransactionId
    ) throws {
        let room = try fetchRoom(roomId.value)
        pendingEchoes[transactionId.value] = event.eventId.value
        echoTransactions[event.eventId.value] = transactionId.value
        try insertEvent(
            event, roomId: roomId.value, room: room,
            sendState: "pending")
        try modelContext.save()
    }

    /// Mark a staged send failed, keeping its echo visible with the reason.
    public func failEcho(transactionId: TransactionId, reason: String) throws {
        guard let echoId = pendingEchoes.removeValue(forKey: transactionId.value) else { return }
        echoTransactions.removeValue(forKey: echoId)
        let id = echoId
        let row = try modelContext.fetch(
            FetchDescriptor<SDRoomEvent>(
                predicate: #Predicate { $0.eventId == id })).first
        row?.sendState = "failed"
        row?.sendFailureReason = reason
        try modelContext.save()
    }

    /// Drop a staged send. Returns false when no echo holds the transaction.
    @discardableResult
    public func cancelEcho(transactionId: TransactionId) throws -> Bool {
        guard let echoId = pendingEchoes.removeValue(forKey: transactionId.value) else {
            return false
        }
        echoTransactions.removeValue(forKey: echoId)
        let id = echoId
        if let row = try modelContext.fetch(
            FetchDescriptor<SDRoomEvent>(
                predicate: #Predicate { $0.eventId == id })).first
        {
            modelContext.delete(row)
        }
        try modelContext.save()
        return true
    }

    /// The staged transaction behind an echo event ID, if any.
    public func echoTransactionId(for eventId: EventId) -> TransactionId? {
        echoTransactions[eventId.value].map { TransactionId($0) }
    }

    /// Drop future server confirmations for a transaction (after
    /// `cancelEcho`).
    public func suppressTransaction(_ transactionId: TransactionId) {
        suppressedTransactions.insert(transactionId.value)
    }

    /// Insert older events from `/messages` pagination. Existing rows win
    /// on overlap; the cursor always advances.
    public func prependHistory(
        _ events: [MessageEvent], roomId: RoomId, prevBatch: BatchToken?
    ) throws {
        let room = try fetchRoom(roomId.value)
        let known = Set(try eventIds(roomId: roomId.value))
        for event in deduped(events)
        where !known.contains(event.eventId.value) {
            try insertEvent(event, roomId: roomId.value, room: room)
        }
        room.prevBatch = prevBatch?.value
        try recomputeUnread(room: room)
        try modelContext.save()
    }

    /// Record the latest fully-read event (drives unread badges).
    public func setFullyRead(roomId: RoomId, eventId: EventId) throws {
        let room = try fetchRoom(roomId.value)
        try adoptFullyRead(eventId.value, room: room)
        try recomputeUnread(room: room)
        try modelContext.save()
    }

    /// Every room whose fully-read marker needs a single-event fetch: an
    /// ID is known but its event is absent from the store. See
    /// `MarkerHealingStore`.
    public func markersNeedingResolution() throws
        -> [(roomId: RoomId, marker: EventId)]
    {
        var out: [(roomId: RoomId, marker: EventId)] = []
        for room in try modelContext.fetch(FetchDescriptor<SDRoom>()) {
            guard let marker = room.fullyRead,
                  !resolvedMarkerIds.contains(marker)
            else { continue }
            let id = marker
            let found = try modelContext.fetch(
                FetchDescriptor<SDRoomEvent>(
                    predicate: #Predicate { $0.eventId == id })).first
            if found == nil {
                out.append((
                    roomId: RoomId(unchecked: room.roomId),
                    marker: EventId(unchecked: marker)))
            }
        }
        return out
    }

    /// Adopt a fetched fully-read timestamp. Max-only, like receipts;
    /// stale fetches (marker moved on) are ignored.
    public func adoptResolvedMarkerTs(
        _ eventId: EventId, roomId: RoomId, ts: Int
    ) throws {
        let room = try fetchRoom(roomId.value)
        guard eventId.value == room.fullyRead else { return }
        resolvedMarkerIds.insert(eventId.value)
        room.readMarkerTs = max(room.readMarkerTs ?? Int.min, ts)
        try recomputeUnread(room: room)
        try modelContext.save()
    }

    /// Adopt an out-of-band avatar URL (healed via a direct state fetch).
    public func adoptAvatarURL(_ url: MXCURI?, roomId: RoomId) throws {
        let room = try fetchRoom(roomId.value)
        room.avatarURL = url?.value
        try modelContext.save()
    }

    /// Adopt an out-of-band member entry. Never overwrites sync state.
    public func adoptMember(
        _ userId: UserId, content: MemberContent, roomId: RoomId
    ) throws {
        let key = "\(roomId.value)|\(userId.value)"
        let existing = try modelContext.fetch(
            FetchDescriptor<SDRoomMember>(
                predicate: #Predicate { $0.key == key })).first
        guard existing == nil else { return }
        let room = try fetchRoom(roomId.value)
        let row = SDRoomMember(
            roomId: roomId.value, userId: userId.value,
            membership: content.membership.rawValue,
            displayname: content.displayname,
            avatarUrl: content.avatarUrl,
            reason: content.reason,
            isDirect: content.isDirect)
        row.room = room
        modelContext.insert(row)
        try modelContext.save()
    }

    /// Merge member profiles fetched out of band (e.g. the `/members`
    /// response backing a room-details view). Unknown users are adopted
    /// outright; for known users only previously-missing profile fields
    /// are filled in — sync state stays authoritative for membership.
    public func mergeMemberProfiles(
        _ profiles: [UserId: MemberContent], roomId: RoomId
    ) throws {
        let room = try fetchRoom(roomId.value)
        // One fetch, not one per member: per-key fetches evaluate the
        // predicate against every stored member row in-process, stalling
        // (O(members × table)) on rooms with large memberships — observed
        // pinning the main thread for 10s+ on a ~1k-member space detail.
        let id = roomId.value
        let existing = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(
                FetchDescriptor<SDRoomMember>(
                    predicate: #Predicate { $0.roomId == id }))
                .map { ($0.key, $0) })
        for (userId, fetched) in profiles {
            let key = "\(roomId.value)|\(userId.value)"
            if let row = existing[key] {
                if row.displayname == nil {
                    row.displayname = fetched.displayname
                }
                if row.avatarUrl == nil {
                    row.avatarUrl = fetched.avatarUrl
                }
            } else {
                let row = SDRoomMember(
                    roomId: roomId.value, userId: userId.value,
                    membership: fetched.membership.rawValue,
                    displayname: fetched.displayname,
                    avatarUrl: fetched.avatarUrl,
                    reason: fetched.reason,
                    isDirect: fetched.isDirect)
                row.room = room
                modelContext.insert(row)
            }
        }
        try modelContext.save()
    }

    /// Adopt fetched hierarchy rows for a space (overwrites), so the
    /// detail view's next open renders from the store without a network
    /// round trip. Unknown spaces are created with `.leave` membership
    /// so browsing stays out of joined lists (sync corrects membership
    /// afterwards); existing rooms keep theirs.
    public func setHierarchy(
        _ children: [SpaceChild], directChildren: [SpaceChildEdge] = [],
        nextBatch: BatchToken?, for spaceId: RoomId
    ) throws {
        let room = try fetchRoom(
            spaceId.value, membership: Membership.leave.rawValue)
        room.hierarchyChildren = try encoder.encode(children)
        room.hierarchyDirectChildren = try encoder.encode(directChildren)
        room.hierarchyNextBatch = nextBatch?.value
        try modelContext.save()
    }

    // MARK: - Decryption support

    /// Stored events still ciphertext, as value types for a decryptor
    /// running outside the writer.
    public func encryptedEvents(roomId: RoomId) throws -> [MessageEvent] {
        let id = roomId.value
        let type = RoomCrypto.roomEncryptedType
        let rows = try modelContext.fetch(
            FetchDescriptor<SDRoomEvent>(
                predicate: #Predicate { $0.roomId == id && $0.type == type }))
        return rows.compactMap { try? decodeEvent($0) }
    }

    /// Write back a decrypted event, matching the ciphertext row by ID.
    public func replaceEvent(_ event: MessageEvent, roomId: RoomId) throws {
        let id = event.eventId.value
        guard let row = try modelContext.fetch(
            FetchDescriptor<SDRoomEvent>(
                predicate: #Predicate { $0.eventId == id })).first
        else { return }
        row.type = event.type
        row.sender = event.sender.value
        row.stateKey = event.stateKey
        row.redacts = event.redacts?.value
        row.ts = event.originServerTs
        row.content = try encoder.encode(event.content)
        row.unsigned = try event.unsigned.map { try encoder.encode($0) }
        let flags = Self.promotedFlags(for: event)
        row.isState = flags.isState
        row.isMessageLike = flags.isMessageLike
        row.relType = flags.relType
        row.threadRootId = flags.threadRootId
        try modelContext.save()
    }

    /// All stored events for a room, oldest first, as value types.
    public func storedEvents(roomId: RoomId) throws -> [MessageEvent] {
        let rows = try modelContext.fetch(
            SDRoomEvent.timelineDescriptor(roomId: roomId.value))
        return rows.compactMap { try? decodeEvent($0) }
    }

    /// IDs of all known rooms, regardless of membership. See
    /// `CiphertextStore`.
    public func roomIds() throws -> [RoomId] {
        try modelContext.fetch(FetchDescriptor<SDRoom>())
            .map { RoomId(unchecked: $0.roomId) }
    }

    // MARK: - Private fetch helpers

    private func fetchMeta() throws -> SDStoreMeta {
        if let meta = try modelContext.fetch(
            FetchDescriptor<SDStoreMeta>(
                predicate: #Predicate { $0.id == "meta" })).first
        {
            return meta
        }
        let meta = SDStoreMeta()
        modelContext.insert(meta)
        return meta
    }

    private func fetchRoom(
        _ roomId: String, membership: String = Membership.join.rawValue
    ) throws -> SDRoom {
        let id = roomId
        if let room = try modelContext.fetch(
            FetchDescriptor<SDRoom>(
                predicate: #Predicate { $0.roomId == id })).first
        {
            return room
        }
        let room = SDRoom(roomId: roomId, membership: membership)
        modelContext.insert(room)
        return room
    }

    private func eventIds(roomId: String) throws -> [String] {
        let id = roomId
        return try modelContext.fetch(
            FetchDescriptor<SDRoomEvent>(
                predicate: #Predicate { $0.roomId == id })).map(\.eventId)
    }

    private func upsertAccountData(
        type: String, content: [String: AnyCodable]
    ) throws {
        let key = type
        let data = try encoder.encode(content)
        if let row = try modelContext.fetch(
            FetchDescriptor<SDAccountData>(
                predicate: #Predicate { $0.type == key })).first
        {
            row.content = data
        } else {
            modelContext.insert(SDAccountData(type: type, content: data))
        }
    }

    /// Push `m.direct` membership into each room's direct flag.
    private func pushDirectFlags() throws {
        let key = "m.direct"
        guard let direct = try modelContext.fetch(
            FetchDescriptor<SDAccountData>(
                predicate: #Predicate { $0.type == key })).first,
            let userId = localUser,
            let content = try? decoder.decode(
                [String: AnyCodable].self, from: direct.content),
            let rooms = content[userId]?.arrayValue
        else { return }
        let ids = Set(rooms.compactMap { $0.stringValue })
        for room in try modelContext.fetch(FetchDescriptor<SDRoom>()) {
            room.isDirect = ids.contains(room.roomId)
        }
    }

    // MARK: - Event rows

    private func insertEvent(
        _ event: MessageEvent, roomId: String, room: SDRoom,
        sendState: String? = nil, sendFailureReason: String? = nil
    ) throws {
        let flags = Self.promotedFlags(for: event)
        let row = SDRoomEvent(
            roomId: roomId,
            eventId: event.eventId.value,
            ts: event.originServerTs,
            type: event.type,
            sender: event.sender.value,
            stateKey: event.stateKey,
            redacts: event.redacts?.value,
            content: try encoder.encode(event.content),
            unsigned: try event.unsigned.map { try encoder.encode($0) },
            isState: flags.isState,
            isMessageLike: flags.isMessageLike,
            relType: flags.relType,
            threadRootId: flags.threadRootId,
            sendState: sendState,
            sendFailureReason: sendFailureReason)
        row.room = room
        modelContext.insert(row)
    }

    private func decodeEvent(_ row: SDRoomEvent) throws -> MessageEvent {
        let content = try decoder.decode(
            [String: AnyCodable].self, from: row.content)
        let unsigned = try row.unsigned.map {
            try decoder.decode([String: AnyCodable].self, from: $0)
        }
        return MessageEvent(
            type: row.type,
            eventId: EventId(unchecked: row.eventId),
            sender: UserId(unchecked: row.sender),
            roomId: RoomId(unchecked: row.roomId),
            stateKey: row.stateKey,
            redacts: row.redacts.map(EventId.init(unchecked:)),
            originServerTs: row.ts,
            content: content,
            unsigned: unsigned)
    }

    private nonisolated static func promotedFlags(
        for event: MessageEvent
    ) -> (isState: Bool, isMessageLike: Bool, relType: String?, threadRootId: String?) {
        let isState = event.stateKey != nil
        let isMessageLike =
            event.type == EventType.roomMessage.rawValue
                || event.type == EventType.sticker.rawValue
        let relation = event.wireRelation
        return (
            isState, isMessageLike,
            relation?.relType?.rawValue,
            relation?.eventId?.value
        )
    }

    // MARK: - Echo confirmation & redactions

    /// Resolve staged echoes against server confirmations. Returns the
    /// events to insert (suppressed zombies dropped, echoes replaced).
    private func confirmEchoes(
        in events: [MessageEvent], room: SDRoom
    ) throws -> [MessageEvent] {
        var events = events
        if !suppressedTransactions.isEmpty {
            let suppressed = suppressedTransactions
            events.removeAll {
                guard let txn = $0.unsigned?["transaction_id"]?.stringValue
                else { return false }
                return suppressed.contains(txn)
            }
        }
        guard !pendingEchoes.isEmpty else { return events }
        return try events.map { event in
            guard
                let txn = event.unsigned?["transaction_id"]?.stringValue,
                let echoId = pendingEchoes[txn]
            else { return event }
            pendingEchoes.removeValue(forKey: txn)
            echoTransactions.removeValue(forKey: echoId)
            let id = echoId
            if let row = try modelContext.fetch(
                FetchDescriptor<SDRoomEvent>(
                    predicate: #Predicate { $0.eventId == id })).first
            {
                modelContext.delete(row)
            }
            return event
        }
    }

    /// Stamp `redacted_because` onto stored targets of incoming
    /// redactions and prune their content. Never overwrites a
    /// server-supplied stamp.
    private func foldRedactions(
        incoming: [MessageEvent], roomId: String
    ) throws {
        for redaction in incoming
        where EventType(rawValue: redaction.type) == .redaction {
            guard let target = redaction.redacts else { continue }
            let id = target.value
            guard let row = try modelContext.fetch(
                FetchDescriptor<SDRoomEvent>(
                    predicate: #Predicate { $0.eventId == id })).first
            else { continue }
            var unsigned: [String: AnyCodable]
            if let data = row.unsigned {
                unsigned = (try? decoder.decode(
                    [String: AnyCodable].self, from: data)) ?? [:]
            } else {
                unsigned = [:]
            }
            guard unsigned["redacted_because"] == nil else { continue }
            unsigned["redacted_because"] = .object([
                "type": .string(redaction.type),
                "event_id": .string(redaction.eventId.value),
                "sender": .string(redaction.sender.value),
                "redacts": .string(target.value),
            ])
            row.unsigned = try encoder.encode(unsigned)
            let content = try decoder.decode(
                [String: AnyCodable].self, from: row.content)
            row.content = try encoder.encode(
                EventRedactor.prunedContent(type: row.type, content: content))
        }
    }

    // MARK: - State folding

    private func applyStateEvents(
        _ events: [MessageEvent], room: SDRoom
    ) throws {
        // Member rows for this room, fetched once when the batch carries
        // membership: per-event keyed fetches evaluate against every
        // stored member row (see mergeMemberProfiles), so bulk joins
        // stall the same way on large rooms.
        var members: [String: SDRoomMember]?
        if events.contains(where: { EventType(rawValue: $0.type) == .roomMember }) {
            let id = room.roomId
            members = Dictionary(
                uniqueKeysWithValues: try modelContext.fetch(
                    FetchDescriptor<SDRoomMember>(
                        predicate: #Predicate { $0.roomId == id }))
                    .map { ($0.key, $0) })
        }
        for event in events {
            if event.type == "m.space.child",
               let child = event.stateKey
            {
                try applyEdge(
                    owner: room.roomId, peer: child,
                    kind: .child, present: !event.content.isEmpty,
                    room: room)
                continue
            }
            if event.type == "m.space.parent",
               let parent = event.stateKey
            {
                if event.content.isEmpty {
                    try removeEdges(
                        owner: room.roomId, peer: parent,
                        kinds: [.parent, .canonicalParent])
                } else {
                    try applyEdge(
                        owner: room.roomId, peer: parent,
                        kind: .parent, present: true, room: room)
                    try applyEdge(
                        owner: room.roomId, peer: parent,
                        kind: .canonicalParent,
                        present: event.content["canonical"]?.boolValue == true,
                        room: room)
                }
                continue
            }
            switch EventType(rawValue: event.type) {
            case .roomMember:
                let data = try encoder.encode(event.content)
                guard var content = try? decoder.decode(
                    MemberContent.self, from: data)
                else { continue }
                let subject = event.stateKey ?? event.sender.value
                // Profile-less leaves keep the stored profile so the
                // timeline still renders "Alice left".
                let key = "\(room.roomId)|\(subject)"
                if content.displayname == nil {
                    content.displayname = members?[key]?.displayname
                }
                if content.avatarUrl == nil {
                    content.avatarUrl = members?[key]?.avatarUrl
                }
                if let row = members?[key] {
                    row.membership = content.membership.rawValue
                    row.displayname = content.displayname
                    row.avatarUrl = content.avatarUrl
                    row.reason = content.reason
                    row.isDirect = content.isDirect
                } else {
                    let row = SDRoomMember(
                        roomId: room.roomId, userId: subject,
                        membership: content.membership.rawValue,
                        displayname: content.displayname,
                        avatarUrl: content.avatarUrl,
                        reason: content.reason,
                        isDirect: content.isDirect)
                    row.room = room
                    modelContext.insert(row)
                    members?[key] = row
                }
            case .roomName:
                room.name = event.content["name"]?.stringValue
            case .roomTopic:
                room.topic = event.content["topic"]?.stringValue
            case .roomAvatar:
                room.avatarURL = event.content["url"]?.stringValue
            case .roomEncryption:
                room.isEncrypted = true
            case .roomPowerLevels:
                room.powerLevelsContent = try encoder.encode(event.content)
            case .roomCanonicalAlias:
                room.canonicalAlias = event.content["alias"]?.stringValue
                room.altAliases = try encoder.encode(
                    event.content["alt_aliases"]?.arrayValue?
                        .compactMap(\.stringValue) ?? [])
            case .roomPinnedEvents:
                room.pinnedEventIds = try encoder.encode(
                    event.content["pinned"]?.arrayValue?
                        .compactMap(\.stringValue) ?? [])
            case .roomTombstone:
                room.successorRoomId =
                    event.content["replacement_room"]?.stringValue
            case .roomCreate:
                room.isSpace = event.content["type"]?.stringValue == "m.space"
            default:
                break
            }
        }
    }

    private func applyEdge(
        owner: String, peer: String, kind: SDEdgeKind, present: Bool,
        room: SDRoom?
    ) throws {
        let key = "\(owner)|\(kind.rawValue)|\(peer)"
        let existing = try modelContext.fetch(
            FetchDescriptor<SDRoomEdge>(
                predicate: #Predicate { $0.key == key })).first
        if present {
            if existing == nil {
                let edge = SDRoomEdge(
                    ownerRoomId: owner, peerRoomId: peer, kind: kind)
                edge.room = room
                modelContext.insert(edge)
            }
        } else if let existing {
            modelContext.delete(existing)
        }
    }

    private func removeEdges(
        owner: String, peer: String, kinds: [SDEdgeKind]
    ) throws {
        let kindsRaw = kinds.map(\.rawValue)
        let ownerId = owner
        let peerId = peer
        let rows = try modelContext.fetch(
            FetchDescriptor<SDRoomEdge>(
                predicate: #Predicate {
                    $0.ownerRoomId == ownerId && $0.peerRoomId == peerId
                }))
        for row in rows where kindsRaw.contains(row.kind) {
            modelContext.delete(row)
        }
    }

    private func applyStrippedState(
        _ events: [StrippedStateEvent], room: SDRoom
    ) throws {
        for event in events {
            switch EventType(rawValue: event.type) {
            case .roomName:
                room.name = event.content["name"]?.stringValue
            case .roomAvatar:
                if let url = event.content["url"]?.stringValue {
                    room.avatarURL = url
                }
            case .roomMember:
                if let membershipRaw = event.content["membership"]?.stringValue,
                   let membership = Membership(rawValue: membershipRaw)
                {
                    // Key by state key (the subject), not the sender.
                    let userId = event.stateKey
                    var content = MemberContent(
                        membership: membership,
                        displayname: event.content["displayname"]?.stringValue,
                        avatarUrl: event.content["avatar_url"]?.stringValue,
                        isDirect: event.content["is_direct"]?.boolValue)
                    let key = "\(room.roomId)|\(userId)"
                    if content.displayname == nil {
                        content.displayname = try modelContext.fetch(
                            FetchDescriptor<SDRoomMember>(
                                predicate: #Predicate { $0.key == key }))
                            .first?.displayname
                    }
                    if content.avatarUrl == nil {
                        content.avatarUrl = try modelContext.fetch(
                            FetchDescriptor<SDRoomMember>(
                                predicate: #Predicate { $0.key == key }))
                            .first?.avatarUrl
                    }
                    if let row = try modelContext.fetch(
                        FetchDescriptor<SDRoomMember>(
                            predicate: #Predicate { $0.key == key })).first
                    {
                        row.membership = content.membership.rawValue
                        row.displayname = content.displayname
                        row.avatarUrl = content.avatarUrl
                        row.isDirect = content.isDirect
                    } else {
                        let row = SDRoomMember(
                            roomId: room.roomId, userId: userId,
                            membership: content.membership.rawValue,
                            displayname: content.displayname,
                            avatarUrl: content.avatarUrl,
                            isDirect: content.isDirect)
                        row.room = room
                        modelContext.insert(row)
                    }
                }
            case .roomCreate:
                room.isSpace = event.content["type"]?.stringValue == "m.space"
            default:
                break
            }
        }
    }

    private func applyEphemeral(
        _ events: [BasicEvent], room: SDRoom
    ) throws {
        // Typing is ephemeral-only and intentionally dropped.
        for event in events where EventType(rawValue: event.type) == .receipt {
            try ingestOwnReceipts(event, room: room)
        }
    }

    /// Fold our own `m.read` / `m.read.private` receipt timestamps into
    /// the read marker. Threaded receipts are skipped. Max-only.
    private func ingestOwnReceipts(
        _ event: BasicEvent, room: SDRoom
    ) throws {
        guard let selfId = localUser else { return }
        var latest: Int?
        for (_, receipt) in event.content {
            guard let kinds = receipt.objectValue else { continue }
            for kind in ["m.read", "m.read.private"] {
                guard
                    let entry = kinds[kind]?.objectValue?[selfId]?.objectValue,
                    entry["thread_id"] == nil,
                    let ts = entry["ts"]?.intValue
                else { continue }
                latest = max(latest ?? Int.min, ts)
            }
        }
        if let latest {
            room.readMarkerTs = max(room.readMarkerTs ?? Int.min, latest)
        }
    }

    private func applyRoomAccountData(
        _ events: [BasicEvent], room: SDRoom
    ) throws {
        for event in events {
            if event.type == EventType.fullyRead.rawValue,
               let id = event.content["event_id"]?.stringValue
            {
                try adoptFullyRead(id, room: room)
                continue
            }
            if event.type == "m.tag" {
                room.isFavourite =
                    event.content["tags"]?.objectValue?["m.favourite"] != nil
            } else {
                // Other room account data (e.g. hierarchy cache callers
                // write explicitly) is persisted verbatim.
                let key = "\(room.roomId)|\(event.type)"
                let data = try encoder.encode(event.content)
                if let row = try modelContext.fetch(
                    FetchDescriptor<SDRoomAccountData>(
                        predicate: #Predicate { $0.key == key })).first
                {
                    row.content = data
                } else {
                    let row = SDRoomAccountData(
                        roomId: room.roomId, type: event.type,
                        content: data)
                    row.room = room
                    modelContext.insert(row)
                }
            }
        }
    }

    /// Adopt a fully-read marker: the ID is authoritative; the timestamp
    /// only advances, resolving from stored events when present.
    private func adoptFullyRead(_ eventId: String, room: SDRoom) throws {
        room.fullyRead = eventId
        let id = eventId
        if let row = try modelContext.fetch(
            FetchDescriptor<SDRoomEvent>(
                predicate: #Predicate { $0.eventId == id })).first
        {
            room.readMarkerTs = max(room.readMarkerTs ?? Int.min, row.ts)
        }
    }

    // MARK: - Unread precompute

    /// Recompute badge-driving counts onto the room row. Mirrors
    /// `RoomActor.effectiveUnreadCount` / `firstUnreadEventId`: edits and
    /// own messages never count.
    private func recomputeUnread(room: SDRoom) throws {
        let id = room.roomId
        let marker = room.readMarkerTs
        let selfId = localUser
        let rows = try modelContext.fetch(
            FetchDescriptor<SDRoomEvent>(
                predicate: #Predicate { $0.roomId == id && $0.isMessageLike }))
        let counted = rows.filter { row in
            guard row.relType != RelationType.replacement.rawValue else {
                return false
            }
            if let selfId, row.sender == selfId { return false }
            if let marker { return row.ts > marker }
            return room.fullyRead != nil
        }
        let clientCount: Int? =
            (marker != nil || room.fullyRead != nil)
                ? counted.count : nil
        room.effectiveUnread = max(room.unread, clientCount ?? room.unread)
        room.firstUnreadEventId = counted
            .sorted { $0.ts < $1.ts }.first?.eventId
    }
}

/// Sync-delta application. See `SyncDeltaSink`.
extension MatrixStoreWriter: SyncDeltaSink {}

/// Marker-heal pass support. See `MarkerHealingStore`.
extension MatrixStoreWriter: MarkerHealingStore {}

/// Ciphertext refresh for late-arriving keys. See `CiphertextStore`.
extension MatrixStoreWriter: CiphertextStore {
    public func knownRoomIds() async throws -> [RoomId] {
        try roomIds()
    }
}
#endif
