/// Message-search models: filters and display-ready results.
import Foundation

/// Result ordering for message search.
public enum SearchOrder: String, Hashable, Sendable {
    /// Most relevant first.
    case rank
    /// Most recent first.
    case recent
}

/// Narrow a message search to rooms/senders with an ordering.
public struct MessageSearchFilter: Hashable, Sendable {
    /// Only rooms with these IDs.
    public var roomIds: [RoomId]?
    /// Only messages from these senders.
    public var senderIds: [UserId]?
    /// Result ordering.
    public var orderBy: SearchOrder

    public init(
        roomIds: [RoomId]? = nil,
        senderIds: [UserId]? = nil,
        orderBy: SearchOrder = .recent
    ) {
        self.roomIds = roomIds
        self.senderIds = senderIds
        self.orderBy = orderBy
    }
}

/// One message-search hit, ready for display.
public struct MessageSearchResult: Hashable, Sendable, Identifiable {
    /// The matching event's ID.
    public var id: EventId { eventId }
    /// The matching event's ID.
    public var eventId: EventId
    /// The room holding the match.
    public var roomId: RoomId
    /// Room display name, if known.
    public var roomName: String?
    /// Match sender.
    public var sender: UserId
    /// Sender display name, if known.
    public var senderDisplayName: String?
    /// Sender avatar MXC URI, if known.
    public var senderAvatarURL: MXCURI?
    /// Plain-text body.
    public var body: String
    /// Send time.
    public var timestamp: Date
    /// Server relevance score, if reported.
    public var rank: Double?
    /// Words the server recommends highlighting.
    public var highlights: [String]

    public init(
        eventId: EventId,
        roomId: RoomId,
        roomName: String? = nil,
        sender: UserId,
        senderDisplayName: String? = nil,
        senderAvatarURL: MXCURI? = nil,
        body: String,
        timestamp: Date,
        rank: Double? = nil,
        highlights: [String] = []
    ) {
        self.eventId = eventId
        self.roomId = roomId
        self.roomName = roomName
        self.sender = sender
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
        self.body = body
        self.timestamp = timestamp
        self.rank = rank
        self.highlights = highlights
    }
}
