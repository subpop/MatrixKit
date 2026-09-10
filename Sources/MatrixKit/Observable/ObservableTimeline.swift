/// Observable message list for a room.
///
/// Rebuilds from the `Timeline` snapshot whenever the backing `RoomActor`
/// emits timeline updates, and aggregates `m.reaction` events onto their
/// targets. `focus(eventId:)` swaps in an event-context window
/// (`FocusedTimeline`) without touching the live window; `returnToLive()`
/// restores it.
import Foundation
import Observation

/// Whether the timeline shows live messages, a focused event window,
/// or a thread.
public enum TimelineFocus: Hashable, Sendable {
    /// Live messages anchored at the newest edge.
    case live
    /// Context window around one event.
    case focused(EventId)
    /// Thread rooted at one event.
    case thread(EventId)
}

@Observable @MainActor
public final class ObservableTimeline {
    /// The room this timeline belongs to.
    public let roomId: RoomId
    /// Render-ready events, oldest first. `m.reaction` events are folded
    /// into their targets' `reactions` and excluded from this list.
    public private(set) var events: [ObservableTimelineEvent]
    /// True while a pagination request is in flight (for spinners).
    public private(set) var isPaginating: Bool
    /// Whether older history exists server-side. `loadMore` is a no-op
    /// when false. In focus mode this reflects the window's back cursor.
    public private(set) var hasMore: Bool
    /// Whether the focus window reached the live edge. Only meaningful
    /// when `timelineFocus` is `.focused`; forward pagination flips it.
    public private(set) var hasReachedEnd: Bool
    /// Live messages or a focused event window.
    public private(set) var timelineFocus: TimelineFocus = .live
    /// Keywords that highlight matching events (fed by the app from push
    /// rules). Applied on the next rebuild; setting this refreshes.
    public var highlightKeywords: [String] = [] {
        didSet {
            guard highlightKeywords != oldValue else { return }
            refreshTask = Task { [weak self] in await self?.refresh() }
        }
    }

    private let timeline: Timeline
    private let room: RoomActor
    private let messages: any TimelinePaging
    private let localUser: UserId?
    private var focused: FocusedTimeline?
    private var thread: ThreadTimeline?
    private var decryptor:
        (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?
    // Like `observerTask` below: task handles must not refresh views,
    // and `deinit` (nonisolated) cancels it.
    @ObservationIgnored
    private nonisolated(unsafe) var refreshTask: Task<Void, Never>?
    // Set once in `init` (MainActor), cancelled in `deinit`; never mutated after.
    // Ignored by observation (a task handle must not refresh views);
    // `nonisolated(unsafe)` lets the nonisolated `deinit` cancel it.
    @ObservationIgnored
    private nonisolated(unsafe) var observerTask: Task<Void, Never>?

    init(
        timeline: Timeline, room: RoomActor, messages: any TimelinePaging,
        localUser: UserId?
    ) async {
        self.roomId = timeline.roomId
        self.timeline = timeline
        self.room = room
        self.messages = messages
        self.localUser = localUser
        self.events = []
        self.isPaginating = false
        self.hasMore = await room.prevBatch != nil
        self.hasReachedEnd = false
        await rebuild(from: room)
        observerTask = Task { [weak self] in
            guard let self else { return }
            for await update in await room.updates() {
                switch update {
                case .timelineAppended, .timelineReset, .membersChanged:
                    // Focus windows are stable snapshots; live updates
                    // apply when returning to live. Member changes also
                    // rebuild so healed or updated display names and
                    // avatars resolve on existing events.
                    if case .live = self.timelineFocus {
                        await self.rebuild(from: room)
                    }
                default:
                    break
                }
            }
        }
    }

    deinit {
        observerTask?.cancel()
        refreshTask?.cancel()
    }

    /// Arm (or re-arm) the decryptor for paginated history and focus
    /// windows. Called by `MatrixClient` after `configureEncryption()`.
    func setTimelineDecryptor(
        _ decryptor: (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?
    ) async {
        self.decryptor = decryptor
        await timeline.setDecryptor(decryptor)
    }

    /// Find a reaction event for toggling it off.
    public func reactionEvent(
        target: EventId, key: String, sender: UserId
    ) async -> EventId? {
        await timeline.reactionEvent(target: target, key: key, sender: sender)
    }

    /// Load older history (live), page the focus window backward, or
    /// page the thread backward. No-op when `hasMore` is false.
    public func loadMore(limit: Int = 50) async throws {
        if let thread {
            guard hasMore, !isPaginating else { return }
            isPaginating = true
            defer { isPaginating = false }
            do {
                _ = try await thread.loadMore(limit: limit)
                hasMore = await thread.canPaginateBack()
                await renderThread()
            } catch {
                isPaginating = false
                throw error
            }
            return
        }
        if let focused {
            guard hasMore, !isPaginating else { return }
            isPaginating = true
            defer { isPaginating = false }
            do {
                _ = try await focused.paginateBack(limit: limit)
                hasMore = await focused.canPaginateBack()
                await renderFocused()
            } catch {
                isPaginating = false
                throw error
            }
            return
        }
        guard hasMore, !isPaginating else { return }
        isPaginating = true
        defer { isPaginating = false }
        do {
            _ = try await timeline.paginateBack(limit: limit)
            hasMore = await timeline.canPaginateBack()
        } catch {
            isPaginating = false
            throw error
        }
    }

    /// Page the focus window toward the live edge. No-op when live,
    /// in a thread, or when `hasReachedEnd` is true.
    public func loadMoreFuture(limit: Int = 50) async throws {
        guard let focused, thread == nil, !hasReachedEnd, !isPaginating else { return }
        isPaginating = true
        defer { isPaginating = false }
        _ = try await focused.paginateForward(limit: limit)
        await renderFocused()
    }

    /// Focus on one event, loading context around it. The live window is
    /// preserved; `returnToLive()` restores it.
    public func focus(eventId: EventId, limit: Int = 20) async throws {
        let focused = FocusedTimeline(
            roomId: roomId, focusEventId: eventId, messages: messages)
        await focused.setDecryptor(decryptor)
        try await focused.load(limit: limit)
        self.focused = focused
        self.thread = nil
        timelineFocus = .focused(eventId)
        await renderFocused()
    }

    /// Leave the focus window or thread and restore the live timeline.
    public func returnToLive() async {
        focused = nil
        thread = nil
        timelineFocus = .live
        hasReachedEnd = false
        await rebuild(from: room)
    }

    /// Load a thread: the root event plus its `m.thread` replies.
    /// The live window is preserved; `returnToLive()` restores it.
    /// The live window doubles as fallback content on servers without
    /// the relations endpoint.
    public func loadThread(rootEventId: EventId, limit: Int = 50) async throws {
        let thread = ThreadTimeline(
            roomId: roomId, rootEventId: rootEventId, messages: messages)
        await thread.setDecryptor(decryptor)
        try await thread.load(limit: limit, localEvents: await room.timeline)
        self.focused = nil
        self.thread = thread
        timelineFocus = .thread(rootEventId)
        await renderThread()
    }

    /// Re-derive rendered events (live window, focus window, or thread).
    public func refresh() async {
        if thread != nil {
            await renderThread()
        } else if focused != nil {
            await renderFocused()
        } else {
            await rebuild(from: room)
        }
    }

    // MARK: - Private

    private func rebuild(from room: RoomActor) async {
        let snapshot = await room.timeline
        let members = await room.members
        let sendStates = await room.sendStates
        hasMore = await room.prevBatch != nil
        render(source: snapshot, members: members, sendStates: sendStates)
    }

    private func renderFocused() async {
        guard let focused else { return }
        let buffer = await focused.events
        let members = await room.members
        hasMore = await focused.canPaginateBack()
        hasReachedEnd = !(await focused.canPaginateForward())
        render(source: buffer, members: members, sendStates: [:])
    }

    private func renderThread() async {
        guard let thread else { return }
        let buffer = await thread.events()
        let members = await room.members
        hasMore = await thread.canPaginateBack()
        // Threads page backward only; newer replies arrive via sync
        // into the live window, not this snapshot.
        hasReachedEnd = true
        render(source: buffer, members: members, sendStates: [:])
    }

    private func render(
        source snapshot: [MessageEvent], members: [UserId: MemberContent],
        sendStates: [EventId: SendState]
    ) {
        // Aggregate reactions: target event -> key -> senders.
        // Redacted reactions (toggle-off) must not feed the badges.
        var reactionMap: [EventId: [String: [UserId]]] = [:]
        for event in snapshot
        where EventType(rawValue: event.type) == .reaction && !event.isRedacted {
            guard
                let data = try? JSONEncoder().encode(event.content),
                let content = try? JSONDecoder().decode(ReactionContent.self, from: data)
            else { continue }
            reactionMap[content.relatesTo.eventId, default: [:]][content.relatesTo.key, default: []]
                .append(event.sender)
        }
        // Fold edits: target event -> replacement content (last edit wins).
        var editMap: [EventId: MessageContent] = [:]
        for event in snapshot {
            guard
                let target = event.messageContent?.relatesTo?.eventId,
                event.messageContent?.relatesTo?.relType == .replacement,
                let replacement = ObservableTimelineEvent.editReplacement(in: event)
            else { continue }
            editMap[target] = replacement
        }
        // Rendered sources: edit targets with folded content.
        let folded: [MessageEvent] = snapshot.map { event in
            guard
                let replacement = editMap[event.eventId],
                let data = try? JSONEncoder().encode(replacement),
                let content = try? JSONDecoder().decode(
                    [String: AnyCodable].self, from: data)
            else { return event }
            var copy = event
            copy.content = content
            return copy
        }
        let byId: [EventId: MessageEvent] = Dictionary(
            folded.map { ($0.eventId, $0) }, uniquingKeysWith: { first, _ in first })
        // Redaction events are hidden: the redacted target carries the
        // tombstone via `redacted_because`, so rendering the redaction
        // itself would print a stray "deleted" bubble (e.g. toggling a
        // reaction off).
        let visible = folded.filter {
            EventType(rawValue: $0.type) != .reaction
                && EventType(rawValue: $0.type) != .redaction
                && !ObservableTimelineEvent.isEdit($0)
        }
        let rendered: [ObservableTimelineEvent] = visible.map { event in
                let wrapper = ObservableTimelineEvent.make(
                    from: event, localUser: localUser, members: members)
                let reactions = reactionMap[event.eventId] ?? [:]
                wrapper.reactions = reactions
                if editMap[event.eventId] != nil {
                    wrapper.isEdited = true
                }
                wrapper.reply = ObservableTimelineEvent.resolveReply(
                    for: event, in: byId, members: members)
                wrapper.sendState = sendStates[event.eventId]
                if let localUser {
                    wrapper.ownReactions = Set(reactions.keys.filter {
                        reactions[$0]?.contains(localUser) ?? false
                    })
                    let selfMentioned = wrapper.mentionedUserIds.contains(localUser)
                    wrapper.highlightedMentionUserId = selfMentioned ? localUser : nil
                    let matched = highlightKeywords.filter {
                        event.messageContent?.body.localizedCaseInsensitiveContains($0) ?? false
                    }
                    wrapper.highlightKeywords = matched
                    wrapper.isHighlighted = selfMentioned
                        || ObservableTimelineEvent.mentionsRoom(in: event)
                        || !matched.isEmpty
                }
                return wrapper
            }
        events = coalesceJoinProfileChanges(events: visible, rendered: rendered)
    }

    /// Fold profile noise from fresh joins into a single "joined" row.
    ///
    /// A self `m.room.member` join followed by profile-carrying join
    /// events from the same user (the client setting its name/avatar at
    /// join time) renders as one join row: the later `.profileChange`
    /// rows are dropped. The fresh-join window for a user ends when they
    /// send anything else or their membership changes again, so genuine
    /// later renames still show.
    private func coalesceJoinProfileChanges(
        events: [MessageEvent], rendered: [ObservableTimelineEvent]
    ) -> [ObservableTimelineEvent] {
        var freshJoins = Set<UserId>()
        var kept: [ObservableTimelineEvent] = []
        kept.reserveCapacity(rendered.count)
        for (event, wrapper) in zip(events, rendered) {
            if EventType(rawValue: event.type) == .roomMember,
               let key = event.stateKey, !key.isEmpty
            {
                let target = UserId(unchecked: key)
                let membership = Membership(
                    rawValue: event.content["membership"]?.stringValue ?? "")
                if event.sender == target, membership == .join {
                    if case .profileChange = wrapper.kind {
                        if freshJoins.contains(target) { continue }
                        kept.append(wrapper)
                        continue
                    }
                    freshJoins.insert(target)
                    kept.append(wrapper)
                    continue
                }
                freshJoins.remove(target)
                kept.append(wrapper)
                continue
            }
            freshJoins.remove(event.sender)
            kept.append(wrapper)
        }
        return kept
    }
}
