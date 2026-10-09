#if canImport(SwiftData)
import Foundation
import MatrixKit
import SwiftData

/// `RoomStateProvider` over the normalized store: API-client enrichment
/// reads served from SwiftData rows, hierarchy writes through the
/// writer. Reads open short-lived contexts, so they never block sync.
public struct NormalizedRoomStateProvider: RoomStateProvider {
    private let reader: MatrixStoreReader
    private let writer: MatrixStoreWriter

    public init(
        modelContainer: ModelContainer, writer: MatrixStoreWriter,
        localUser: UserId? = nil
    ) {
        self.reader = MatrixStoreReader(
            modelContainer: modelContainer, localUser: localUser)
        self.writer = writer
    }

    public func roomState(_ roomId: RoomId) async -> RoomStateSummary? {
        try? reader.roomStateSummary(roomId)
    }

    public func setHierarchy(
        _ children: [SpaceChild],
        directChildren: [SpaceChildEdge],
        nextBatch: BatchToken?,
        for spaceId: RoomId
    ) async throws {
        try await writer.setHierarchy(
            children, directChildren: directChildren,
            nextBatch: nextBatch, for: spaceId)
    }

    public func spaceRoomIds() async -> [RoomId] {
        (try? reader.spaceRoomIds()) ?? []
    }

    public func member(
        _ roomId: RoomId, userId: UserId
    ) async -> MemberContent? {
        try? reader.memberContent(roomId: roomId, userId: userId)
    }
}
#endif
